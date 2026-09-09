import Darwin
import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

/// 入力は標準 Python の ZIP/tar writer で毎回生成し、既存書庫を流用しない。
nonisolated final class ExtractionTests: XCTestCase {
    private final class Fixture {
        let parent: URL
        let destination: URL
        let archive: URL

        init(_ script: String, suffix: String = "zip") throws {
            parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("KaitoFinder-ExtractionTests-" + UUID().uuidString)
            destination = parent.appendingPathComponent("out", isDirectory: true)
            archive = parent.appendingPathComponent("fixture." + suffix)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            guard chmod(parent.path, 0o700) == 0 else { throw ExtractionFailure.system(errno) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", "import sys, zipfile, tarfile, io, stat, struct\np = sys.argv[1]\n" + script, archive.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ExtractionFailure.refused("fixture 生成失敗") }
        }

        deinit {
            try? ExtractionTemporaryDirectory(root: parent).sweepOnLaunch()
            try? FileManager.default.removeItem(at: parent)
        }

        func extract(progress: Progress = Progress(totalUnitCount: 0),
                     didProcess: (@Sendable (Int) -> Void)? = nil) async throws -> ExtractionResult {
            let session = try ArchiveSession(url: archive)
            return try await ExtractionService.extract(ExtractionSelection(entries: await session.entries()),
                from: session, to: destination, progress: progress, didProcess: didProcess)
        }

        func text(_ path: String) throws -> String {
            try String(contentsOf: destination.appendingPathComponent(path), encoding: .utf8)
        }
    }

    func testHostileZIPRefusesTraversalAndLeavesParentUntouched() async throws {
        let fixture = try Fixture("""
        z = zipfile.ZipFile(p, 'w')
        z.writestr('../escape.txt', 'x')
        z.writestr('/abs.txt', 'x')
        z.writestr('a/../../deep.txt', 'x')
        z.writestr('ok.txt', 'x')
        z.writestr('a\\\\..\\\\..\\\\windows.txt', 'x')
        z.close()
        """)
        let sentinel = fixture.parent.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.parent.path).sorted()
        let archiveBefore = try Data(contentsOf: fixture.archive)
        let result = try await fixture.extract()
        XCTAssertEqual(result.failures.map(\.name), ["../escape.txt", "a/../../deep.txt", "a\\..\\..\\windows.txt"])
        XCTAssertEqual(try fixture.text("ok.txt"), "x")
        // 設計 §9 に従い絶対名は拒否ではなく先頭 / を除去する。
        XCTAssertEqual(try fixture.text("abs.txt"), "x")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).sorted(), ["abs.txt", "ok.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.parent.path).sorted(), before)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.archive), archiveBefore)
        for failure in result.failures { print("REFUSED [\(failure.entryIndex)] \(failure.name): \(failure.reason)") }
        print("WRITTEN: \(result.written.map { $0.url.lastPathComponent }.sorted()); PARENT UNCHANGED")
    }

    func testPathSanitizationAndResolvedContainment() throws {
        XCTAssertEqual(try ExtractionPath.components("/C:\\a\\.\\b"), ["a", "b"])
        XCTAssertEqual(try ExtractionPath.components("/./a//b"), ["a", "b"])
        for name in ["", ".", "/", "C:", "a/../b", "a\\..\\b", "a\0b", "/\u{301}../.."] {
            XCTAssertThrowsError(try ExtractionPath.components(name), name)
        }
        let root = URL(fileURLWithPath: "/private/tmp/root")
        XCTAssertFalse(ExtractionPath.isInside(root.appendingPathComponent("../outside"), root: root))
        XCTAssertFalse(ExtractionPath.isInside(URL(fileURLWithPath: "/private/tmp/root-sibling/a"), root: root))
        XCTAssertFalse(ExtractionPath.isInside(root, root: root))
    }

    func testPreexistingIntermediateAndLeafSymlinksNeverRedirectWrites() async throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            for name in ['redirect/pwn', 'leaf', 'internal/pwn', 'ok']:
                z.writestr(name, 'new')
        """)
        let outside = fixture.parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let victim = outside.appendingPathComponent("victim")
        try Data("original".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: fixture.destination.appendingPathComponent("redirect"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: fixture.destination.appendingPathComponent("leaf"), withDestinationURL: victim)
        try FileManager.default.createDirectory(at: fixture.destination.appendingPathComponent("real"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: fixture.destination.appendingPathComponent("internal").path, withDestinationPath: "real")
        XCTAssertFalse(ExtractionPath.isInside(fixture.destination.appendingPathComponent("redirect/pwn"), root: fixture.destination))
        let result = try await fixture.extract()
        XCTAssertEqual(result.failures.count, 3)
        XCTAssertEqual(try fixture.text("ok"), "new")
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["victim"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.appendingPathComponent("real").path).isEmpty)
    }

    func testSymlinkTargetsInsideOutsideAndForwardReference() async throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            for name, target in [('escape', '../outside'), ('absolute', '/etc/passwd'),
                                 ('safe', 'ok'), ('sub/up', '../ok'),
                                 ('future', 'later'), ('tricky', 'missing/../../outside')]:
                i = zipfile.ZipInfo(name)
                i.create_system = 3
                i.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(i, target)
            z.writestr('ok', 'yes')
            z.writestr('later', 'future data')
        """)
        let result = try await fixture.extract()
        XCTAssertEqual(result.failures.map(\.name), ["escape", "absolute", "tricky"])
        XCTAssertEqual(try fixture.text("safe"), "yes")
        XCTAssertEqual(try fixture.text("sub/up"), "yes")
        XCTAssertEqual(try fixture.text("future"), "future data")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.appendingPathComponent("safe").path), "ok")
    }

    func testSymlinkDotDotCannotBeReinterpretedByLaterEntry() async throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            for name, target in [('first', 'future/../outside'), ('future', 'nested/deep')]:
                i = zipfile.ZipInfo(name)
                i.create_system = 3
                i.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(i, target)
        """)
        let result = try await fixture.extract()
        XCTAssertEqual(result.failures.map(\.name), ["first"])
        XCTAssertEqual(result.written.map(\.entryIndex), [1])
    }

    func testDuplicateNamesFirstArchiveEntryWinsIncludingNormalization() async throws {
        let fixture = try Fixture("""
        import warnings
        warnings.filterwarnings('ignore', category=UserWarning)
        with zipfile.ZipFile(p, 'w') as z:
            for name, text in [('same', 'first'), ('same', 'second'), ('./same', 'third'),
                               ('caf\\u00e9', 'NFC'), ('cafe\\u0301', 'NFD'),
                               ('dir/', ''), ('dir/', ''), ('dir/child', 'child')]:
                z.writestr(name, text)
        """)
        let result = try await fixture.extract()
        XCTAssertEqual(try fixture.text("same"), "first")
        XCTAssertEqual(try fixture.text("café"), "NFC")
        XCTAssertEqual(try fixture.text("dir/child"), "child")
        XCTAssertEqual(result.failures.map(\.entryIndex), [1, 2, 4, 6])
    }

    func testExistingFileAndDirectoryAreNotOverwritten() async throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('existing', 'new')
            z.writestr('dir/', '')
            z.writestr('dir/child', 'yes')
        """)
        try Data("old".utf8).write(to: fixture.destination.appendingPathComponent("existing"))
        try FileManager.default.createDirectory(at: fixture.destination.appendingPathComponent("dir"), withIntermediateDirectories: false)
        let result = try await fixture.extract()
        XCTAssertEqual(result.failures.map(\.entryIndex), [0, 1])
        XCTAssertEqual(try fixture.text("existing"), "old")
        XCTAssertEqual(try fixture.text("dir/child"), "yes")
    }

    func testQuarantinePropagatesToFilesDirectoriesAndSymlinks() async throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('explicit/', '')
            z.writestr('explicit/virtual/ok', 'yes')
            i = zipfile.ZipInfo('link')
            i.create_system = 3
            i.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(i, 'explicit/virtual/ok')
        """)
        let quarantine = Data("0081;66df0000;KaitoFinderTests;".utf8)
        let status = quarantine.withUnsafeBytes {
            setxattr(fixture.archive.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        XCTAssertEqual(status, 0)
        let result = try await fixture.extract()
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.written.count, 4)
        for item in result.written { XCTAssertEqual(try ExtractionQuarantine.read(from: item.url), quarantine, item.url.path) }
    }

    func testArchiveWithoutQuarantineProducesNoQuarantine() async throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('dir/file', 'local')
        """)
        XCTAssertNil(try ExtractionQuarantine.read(from: fixture.archive))
        let result = try await fixture.extract()
        XCTAssertTrue(result.failures.isEmpty)
        for item in result.written { XCTAssertNil(try ExtractionQuarantine.read(from: item.url)) }
        let file = fixture.destination.appendingPathComponent("dir/file")
        try ExtractionQuarantine.apply(Data("0081;66df0000;test;".utf8), to: file)
        try ExtractionQuarantine.apply(nil, to: file)
        XCTAssertNil(try ExtractionQuarantine.read(from: file))
    }

    func testCancellationStopsPartwayAndReportsFileProgress() async throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            for n in range(10): z.writestr(str(n), 'data')
        """)
        let progress = Progress(totalUnitCount: 0)
        let result = try await fixture.extract(progress: progress) { index in
            if index == 2 { progress.cancel() }
        }
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.written.count, 3)
        XCTAssertEqual(progress.completedUnitCount, 3)
        XCTAssertEqual(progress.totalUnitCount, 10)
        XCTAssertEqual(progress.kind, .file)
        XCTAssertEqual(progress.userInfo[.fileOperationKindKey] as? Progress.FileOperationKind, .copying)
        XCTAssertEqual(progress.userInfo[.fileURLKey] as? URL, fixture.destination)
        XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 10)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).count, 3)
    }

    func testTaskCancellationAndPrecancelledProgress() async throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            for n in range(4): z.writestr(str(n), 'data')
        """)
        let progress = Progress(totalUnitCount: 0)
        progress.cancel()
        let before = try await fixture.extract(progress: progress)
        XCTAssertTrue(before.cancelled)
        XCTAssertTrue(before.written.isEmpty)
        let task = Task {
            try await fixture.extract { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        let during = try await task.value
        XCTAssertTrue(during.cancelled)
        XCTAssertEqual(during.written.count, 1)
    }

    func testCorruptEntryIsRemovedAndLaterEntriesContinue() async throws {
        let fixture = try Fixture("""
        import warnings
        warnings.filterwarnings('ignore', category=UserWarning)
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('before', 'good')
            z.writestr('bad', 'CORRUPT ME')
            z.writestr('bad', 'must not replace corrupt first')
            z.writestr('after', 'still good')
        with zipfile.ZipFile(p) as z: offset = z.infolist()[1].header_offset
        b = bytearray(open(p, 'rb').read())
        n, e = struct.unpack_from('<HH', b, offset + 26)
        b[offset + 30 + n + e] ^= 0xff
        open(p, 'wb').write(b)
        """)
        let result = try await fixture.extract()
        XCTAssertEqual(result.failures.map(\.entryIndex), [1, 2])
        XCTAssertEqual(try fixture.text("before"), "good")
        XCTAssertEqual(try fixture.text("after"), "still good")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("bad").path))
    }

    @MainActor
    func testSubtreeArchiveOrderHardlinksAndDeepestLastDirectoryAttributes() async throws {
        let fixture = try Fixture("""
        with tarfile.open(p, 'w', format=tarfile.USTAR_FORMAT) as t:
            for name, mode, timestamp in [('sub', 0o500, 1000000000), ('sub/deep', 0o510, 1000000020)]:
                i = tarfile.TarInfo(name)
                i.type = tarfile.DIRTYPE
                i.mode = mode
                i.mtime = timestamp
                t.addfile(i)
            i = tarfile.TarInfo('sub/deep/body')
            i.size = 4
            i.mode = 0o640
            t.addfile(i, io.BytesIO(b'body'))
            i = tarfile.TarInfo('sub/deep/link')
            i.type = tarfile.LNKTYPE
            i.linkname = 'sub/deep/body'
            t.addfile(i)
            i = tarfile.TarInfo('excluded')
            i.size = 1
            t.addfile(i, io.BytesIO(b'x'))
        """, suffix: "tar")
        let session = try ArchiveSession(url: fixture.archive)
        let entries = await session.entries()
        let tree = EntryNode.tree(from: entries)
        let subtree = try XCTUnwrap(tree.children.first { $0.name == "sub" })
        let selection = ExtractionSelection(nodes: [subtree, subtree.children[0]])
        XCTAssertEqual(selection.entries.map(\.index), [0, 1, 2, 3])
        let result = try await ExtractionService.extract(selection, from: session, to: fixture.destination)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.written.compactMap(\.entryIndex), [0, 1, 2, 3])
        XCTAssertEqual(try fixture.text("sub/deep/link"), "body")
        var body = stat(), link = stat()
        XCTAssertEqual(lstat(fixture.destination.appendingPathComponent("sub/deep/body").path, &body), 0)
        XCTAssertEqual(lstat(fixture.destination.appendingPathComponent("sub/deep/link").path, &link), 0)
        XCTAssertEqual(body.st_ino, link.st_ino)
        XCTAssertEqual(body.st_mode & 0o777, 0o640)
        for (name, mode, time) in [("sub", 0o500, 1000000000), ("sub/deep", 0o510, 1000000020)] {
            var info = stat()
            XCTAssertEqual(lstat(fixture.destination.appendingPathComponent(name).path, &info), 0)
            XCTAssertEqual(Int(info.st_mode & 0o777), mode)
            XCTAssertEqual(info.st_mtimespec.tv_sec, time)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("excluded").path))
    }

    @MainActor
    func testSingleFileVirtualSubtreeAndMixedSelection() async throws {
        for mode in 0..<3 {
            let fixture = try Fixture("""
            with zipfile.ZipFile(p, 'w') as z:
                z.writestr('sub/deep/file', 'nested')
                z.writestr('single', 'one')
                z.writestr('excluded', 'no')
            """)
            let session = try ArchiveSession(url: fixture.archive)
            let tree = EntryNode.tree(from: await session.entries())
            let sub = try XCTUnwrap(tree.children.first { $0.name == "sub" })
            let single = try XCTUnwrap(tree.children.first { $0.name == "single" })
            let nodes = mode == 0 ? [single] : mode == 1 ? [sub] : [single, sub]
            let result = try await ExtractionService.extract(ExtractionSelection(nodes: nodes), from: session, to: fixture.destination)
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(result.written.compactMap(\.entryIndex), mode == 0 ? [1] : mode == 1 ? [0] : [0, 1])
            if mode != 0 { XCTAssertEqual(try fixture.text("sub/deep/file"), "nested") }
            if mode != 1 { XCTAssertEqual(try fixture.text("single"), "one") }
        }
    }

    func testTemporaryDirectorySurvivesHelperLifetimeAndSweepDoesNotFollowLinks() throws {
        let fixture = try Fixture("with zipfile.ZipFile(p, 'w'): pass")
        let root = fixture.parent.appendingPathComponent("owned", isDirectory: true)
        let first = try ExtractionTemporaryDirectory(root: root).create()
        let second = try ExtractionTemporaryDirectory(root: root).create()
        XCTAssertNotEqual(first, second)
        try Data("keep".utf8).write(to: fixture.parent.appendingPathComponent("sentinel"))
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("outside"), withDestinationURL: fixture.parent)
        try Data("temp".utf8).write(to: second.appendingPathComponent("file"))
        XCTAssertEqual(chmod(second.path, 0o000), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        try ExtractionTemporaryDirectory(root: root).sweepOnLaunch()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.parent.appendingPathComponent("sentinel"), encoding: .utf8), "keep")
        let redirect = fixture.parent.appendingPathComponent("redirect")
        try FileManager.default.createSymbolicLink(at: redirect, withDestinationURL: root)
        XCTAssertThrowsError(try ExtractionTemporaryDirectory(root: redirect).sweepOnLaunch())
        XCTAssertThrowsError(try ExtractionDestination(url: redirect, quarantine: nil))
    }
    func testSolidGroupStaysInArchiveOrderAndConcurrentRequestsUseIndependentReaders() async throws {
        let fixture = try Fixture("""
        import binascii
        # 7z: Copy coder 1 個、solid folder 1 個、substream 3 個。全長は 128 未満。
        payloads = [b'first', b'second', b'third']
        packed = b''.join(payloads)
        names = b'\\x00' + 'a\\x00b\\x00c\\x00'.encode('utf-16le')
        header = bytes([1, 4, 6, 0, 1, 9, len(packed), 0,
                        7, 11, 1, 0, 1, 1, 0, 12, len(packed), 0,
                        8, 13, 3, 9, len(payloads[0]), len(payloads[1]), 10, 1])
        header += b''.join(struct.pack('<I', binascii.crc32(b)) for b in payloads)
        header += bytes([0, 0, 5, 3, 17, len(names)]) + names + bytes([0, 0])
        start = struct.pack('<QQI', len(packed), len(header), binascii.crc32(header))
        archive = b'7z\\xbc\\xaf\\x27\\x1c\\x00\\x04' + struct.pack('<I', binascii.crc32(start))
        open(p, 'wb').write(archive + start + packed + header)
        """, suffix: "7z")
        let session = try ArchiveSession(url: fixture.archive)
        let entries = await session.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(Set(entries.map(\.solidGroup)).count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(entries.first).solidGroup, 0)
        let second = fixture.parent.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let selection = ExtractionSelection(entries: entries.reversed())
        let firstDestination = fixture.destination
        async let firstResult = ExtractionService.extract(selection, from: session, to: firstDestination)
        async let secondResult = ExtractionService.extract(selection, from: session, to: second)
        let (first, other) = try await (firstResult, secondResult)
        for result in [first, other] {
            XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
            XCTAssertEqual(result.written.compactMap(\.entryIndex), [0, 1, 2])
        }
        for (name, value) in [("a", "first"), ("b", "second"), ("c", "third")] {
            XCTAssertEqual(try fixture.text(name), value)
            XCTAssertEqual(try String(contentsOf: second.appendingPathComponent(name), encoding: .utf8), value)
        }
        // 同じ session の閲覧 reader も展開後に引き続き利用できる。
        let after = await session.entries()
        XCTAssertEqual(after, entries)
    }

    func testCancellationWithinFileRemovesPartialPayload() throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('large', b'x' * (1024 * 1024))
        """)
        let reader = try ArchiveReader.open(url: fixture.archive)
        let entry = try XCTUnwrap(reader.entries.first)
        let destination = try ExtractionDestination(url: fixture.destination, quarantine: nil)
        var checks = 0
        XCTAssertThrowsError(try destination.file(["large"], entry: entry, stream: reader.stream(entry)) {
            checks += 1
            if checks == 4 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 4)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    func testBodylessHardlinkCannotUsePreexistingTargetFromAnotherExtraction() async throws {
        let fixture = try Fixture("""
        with tarfile.open(p, 'w', format=tarfile.USTAR_FORMAT) as t:
            i = tarfile.TarInfo('body')
            i.size = 4
            t.addfile(i, io.BytesIO(b'body'))
            i = tarfile.TarInfo('link')
            i.type = tarfile.LNKTYPE
            i.linkname = 'body'
            t.addfile(i)
        """, suffix: "tar")
        let session = try ArchiveSession(url: fixture.archive)
        let entries = await session.entries()
        let first = try await ExtractionService.extract(ExtractionSelection(entries: [entries[0]]), from: session, to: fixture.destination)
        XCTAssertTrue(first.failures.isEmpty)
        let second = try await ExtractionService.extract(ExtractionSelection(entries: [entries[1]]), from: session, to: fixture.destination)
        XCTAssertEqual(second.failures.map(\.entryIndex), [1])
        XCTAssertTrue(second.written.isEmpty)
        XCTAssertEqual(try fixture.text("body"), "body")
    }

    func testEmptySelectionAndMismatchedEntry() async throws {
        let fixture = try Fixture("with zipfile.ZipFile(p, 'w') as z: z.writestr('good', 'yes')")
        let session = try ArchiveSession(url: fixture.archive)
        let empty = try await ExtractionService.extract(ExtractionSelection(entries: []), from: session, to: fixture.destination)
        XCTAssertTrue(empty.written.isEmpty)
        XCTAssertTrue(empty.failures.isEmpty)
        XCTAssertFalse(empty.cancelled)
        let fake = ArchiveEntry(index: 999, rawName: RawName(bytes: Array("fake".utf8)), name: "fake",
            pathComponents: ["fake"], kind: .file, uncompressedSize: 0, compressedSize: 0,
            modificationDate: nil, posixPermissions: nil, isEncrypted: false, solidGroup: -1,
            crc32: nil, methodDescription: "stored", formatSpecific: [:])
        let entries = await session.entries()
        let result = try await ExtractionService.extract(ExtractionSelection(entries: [fake] + entries), from: session, to: fixture.destination)
        XCTAssertEqual(result.failures.map(\.entryIndex), [999])
        XCTAssertEqual(try fixture.text("good"), "yes")
    }

    func testSymlinkChainsAbsoluteInternalTargetsAndCycles() async throws {
        let fixture = try Fixture("""
        import os
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('ok', 'yes')
            for name, target in [('first', 'ok'), ('chain', 'first'),
                                 ('absolute', os.path.join(os.path.dirname(p), 'out', 'ok')),
                                 ('cycleA', 'cycleB'), ('cycleB', 'cycleA'), ('self', 'self')]:
                i = zipfile.ZipInfo(name)
                i.create_system = 3
                i.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(i, target)
        """)
        XCTAssertTrue(ExtractionPath.isInside(fixture.destination, root: FileManager.default.temporaryDirectory))
        let result = try await fixture.extract()
        XCTAssertEqual(result.failures.map(\.name), ["cycleB", "self"])
        XCTAssertEqual(try fixture.text("chain"), "yes")
        XCTAssertEqual(try fixture.text("absolute"), "yes")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.appendingPathComponent("chain").path), "first")
    }

    func testExistingSymlinkBeforeDotDotIsResolvedBeforeStandardization() async throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            for name, target in [('unsafe', 'redirect/../sentinel'), ('safe', 'real/deep/../ok')]:
                i = zipfile.ZipInfo(name)
                i.create_system = 3
                i.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(i, target)
        """)
        let outside = fixture.parent.appendingPathComponent("outside/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let real = fixture.destination.appendingPathComponent("real/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("yes".utf8).write(to: fixture.destination.appendingPathComponent("real/ok"))
        try FileManager.default.createSymbolicLink(at: fixture.destination.appendingPathComponent("redirect"), withDestinationURL: outside)
        XCTAssertFalse(ExtractionPath.isInside(fixture.destination.appendingPathComponent("redirect/../sentinel"), root: fixture.destination))
        let result = try await fixture.extract()
        XCTAssertEqual(result.failures.map(\.name), ["unsafe"])
        XCTAssertEqual(try fixture.text("safe"), "yes")
    }

    func testCancellationStillFinalizesCreatedDirectoryAttributes() async throws {
        let fixture = try Fixture("""
        with tarfile.open(p, 'w', format=tarfile.USTAR_FORMAT) as t:
            i = tarfile.TarInfo('dir')
            i.type = tarfile.DIRTYPE
            i.mode = 0o500
            i.mtime = 1000000000
            t.addfile(i)
            for name in ['dir/first', 'dir/second']:
                i = tarfile.TarInfo(name)
                i.size = 1
                t.addfile(i, io.BytesIO(b'x'))
        """, suffix: "tar")
        let progress = Progress(totalUnitCount: 0)
        let result = try await fixture.extract(progress: progress) { index in
            if index == 1 { progress.cancel() }
        }
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.written.compactMap(\.entryIndex), [0, 1])
        var info = stat()
        XCTAssertEqual(lstat(fixture.destination.appendingPathComponent("dir").path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o500)
        XCTAssertEqual(info.st_mtimespec.tv_sec, 1000000000)
    }

    func testTemporaryRootSymlinksAllowRootTargetsAndRejectSelfAliases() async throws {
        let fixture = try Fixture("""
        import os
        with zipfile.ZipFile(p, 'w') as z:
            for name, target in [('dot', '.'), ('sub/up', '..'),
                                 ('absoluteRoot', os.path.join(os.path.dirname(p), 'out'))]:
                i = zipfile.ZipInfo(name)
                i.create_system = 3
                i.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(i, target)
        """)
        XCTAssertTrue(ExtractionPath.isInside(fixture.destination, root: FileManager.default.temporaryDirectory))
        let result = try await fixture.extract()
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        var root = stat()
        XCTAssertEqual(stat(fixture.destination.path, &root), 0)
        for name in ["dot", "sub/up", "absoluteRoot"] {
            var target = stat()
            XCTAssertEqual(stat(fixture.destination.appendingPathComponent(name).path, &target), 0, name)
            XCTAssertEqual(target.st_dev, root.st_dev)
            XCTAssertEqual(target.st_ino, root.st_ino)
        }
        let destination = try ExtractionDestination(url: fixture.destination, quarantine: nil)
        XCTAssertEqual(destination.url([]).path, ExtractionPath.resolvedPath(fixture.destination.path))
        print("TEMP ROOT: \(fixture.destination.path); CANONICAL ROOT: \(destination.url([]).path)")
        // 大文字小文字を区別しないボリュームでは、文字列比較で検出できない自己参照も検証する。
        try Data().write(to: fixture.destination.appendingPathComponent("caseProbe"))
        if FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("CASEPROBE").path) {
            XCTAssertThrowsError(try destination.symlink(["SelfCase"], target: "selfcase"))
            var info = stat()
            XCTAssertEqual(lstat(fixture.destination.appendingPathComponent("SelfCase").path, &info), -1)
            XCTAssertEqual(errno, ENOENT)
        }
    }

    func testTemporarySweepRemovesThreeHundredLevelsWithBoundedDescriptors() throws {
        let fixture = try Fixture("with zipfile.ZipFile(p, 'w'): pass")
        let temporary = ExtractionTemporaryDirectory(root: fixture.parent.appendingPathComponent("owned"))
        let extracted = try temporary.create()
        var descriptor = open(extracted.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        do {
            for _ in 0..<300 {
                guard mkdirat(descriptor, "d", 0o700) == 0 else { throw ExtractionFailure.system(errno) }
                let child = openat(descriptor, "d", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw ExtractionFailure.system(errno) }
                close(descriptor)
                descriptor = child
            }
        } catch { close(descriptor); throw error }
        close(descriptor)
        let sibling = try temporary.create()
        try Data("also removed".utf8).write(to: sibling.appendingPathComponent("file"))
        // runner の上限を変更せず、通常の fd 上限下で深い木と兄弟を両方掃除する。
        try temporary.sweepOnLaunch()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporary.root.path).isEmpty)
        try temporary.sweepOnLaunch()
    }

    func testTwentyThousandDirectoryPromotionsKeepUniqueResults() throws {
        let fixture = try Fixture("with zipfile.ZipFile(p, 'w'): pass")
        let destination = try ExtractionDestination(url: fixture.destination, quarantine: nil)
        let count = 20_000
        for index in 0..<count { try destination.directory(["d\(index)"], explicit: false) }
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            for index in 0..<count { try destination.directory(["d\(index)"], explicit: true) }
        }
        // 実時間の固定閾値は使わず、大量の昇格で作成物と順序を失わないことを確認する。
        XCTAssertEqual(destination.createdDirectories.count, count)
        XCTAssertEqual(Set(destination.createdDirectories.map(\.lastPathComponent)).count, count)
        XCTAssertEqual(destination.createdDirectories.first?.lastPathComponent, "d0")
        XCTAssertEqual(destination.createdDirectories.last?.lastPathComponent, "d19999")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).count, count)
        print("DIRECTORY PROMOTIONS: \(count), elapsed: \(elapsed)")
    }

    @MainActor
    func testDocumentOptsIntoConcurrentReadingAndParsesOffMainThread() async throws {
        let fixture = try Fixture("""
        with tarfile.open(p, 'w', format=tarfile.USTAR_FORMAT) as t:
            i = tarfile.TarInfo('background')
            i.size = 4
            t.addfile(i, io.BytesIO(b'data'))
        """, suffix: "tar")
        XCTAssertTrue(ArchiveDocument.canConcurrentlyReadDocuments(ofType: "public.tar-archive"))
        XCTAssertTrue(ArchiveDocument.canConcurrentlyReadDocuments(ofType: "public.zip-archive"))
        let archive = fixture.archive
        // NSDocument の並行読み込み契約と、read が呼ぶ parser の非 main 実行を分けて検証する。
        // NSDocument 自体を Swift Task へ転送せず、AppKit の隔離規約を維持する。
        let session = try await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return try ArchiveSession(url: archive)
        }.value
        XCTAssertEqual(session.sourceURL, archive)
        let entries = await session.entries()
        XCTAssertEqual(entries.map(\.name), ["background"])
    }

    func testRestoredFileAndDirectoryPermissionsRespectProcessUmask() async throws {
        let fixture = try Fixture("""
        with zipfile.ZipFile(p, 'w') as z:
            for name, kind, mode in [('executable', stat.S_IFREG, 0o777),
                                      ('file', stat.S_IFREG, 0o666), ('dir/', stat.S_IFDIR, 0o777)]:
                i = zipfile.ZipInfo(name)
                i.create_system = 3
                i.external_attr = (kind | mode) << 16
                z.writestr(i, '' if name.endswith('/') else 'data')
        """)
        // open の mode は OS が umask を適用する。プロセスの値をテスト中に変更しない。
        let probe = open(fixture.parent.appendingPathComponent("mask-probe").path,
                         O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o777)
        XCTAssertGreaterThanOrEqual(probe, 0)
        guard probe >= 0 else { return }
        var original = stat()
        XCTAssertEqual(fstat(probe, &original), 0)
        close(probe)
        let allowed = original.st_mode & 0o777
        XCTAssertEqual(allowed & 0o022, 0, "この回帰テストは通常の umask（022 等）で実行する")
        let result = try await fixture.extract()
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        for (name, declared) in [("executable", mode_t(0o777)), ("file", mode_t(0o666)), ("dir", mode_t(0o777))] {
            var info = stat()
            XCTAssertEqual(lstat(fixture.destination.appendingPathComponent(name).path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, declared & allowed, name)
            XCTAssertEqual(info.st_mode & 0o022, 0, name)
        }
    }

}
