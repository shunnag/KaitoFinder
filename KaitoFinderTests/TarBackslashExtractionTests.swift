import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class TarBackslashExtractionTests: XCTestCase {
    private final class Fixture {
        let directory: ArchiveTestDirectory
        let archive: URL
        static let editable = ["back\\slash.txt", "dir\\sub/file.txt", "a\\b", "a/b", "C:drive.txt", "a\\.\\b"]
        static let hostile = ["ok.txt", "x\\..\\y", "..\\up.txt", "é\\x", "e\u{301}\\x"]

        init(suffix: String = "tar", names: [String] = Fixture.editable) throws {
            directory = try ArchiveTestDirectory()
            archive = directory.url.appendingPathComponent("fixture." + suffix)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: names), as: UTF8.self)
            try directory.run(ExternalTool.python3, ["-c", #"""
            import io, json, sys, tarfile, zipfile
            path, suffix, names = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
            if suffix == 'zip':
                with zipfile.ZipFile(path, 'w') as archive:
                    for i, name in enumerate(names):
                        archive.writestr(name, str(i).encode())
            else:
                with tarfile.open(path, 'w:gz' if suffix == 'tar.gz' else 'w', format=tarfile.PAX_FORMAT) as archive:
                    for i, name in enumerate(names):
                        data = str(i).encode() if i < 6 else b'x'
                        entry = tarfile.TarInfo(name)
                        entry.size, entry.mode, entry.mtime = len(data), 0o644, 1700000000
                        archive.addfile(entry, io.BytesIO(data))
            """#, archive.path, suffix, json])
        }

        func output(_ name: String = UUID().uuidString) throws -> URL {
            let url = directory.url.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return url
        }
    }

    private struct TreeItem: Equatable {
        let path: [UInt8]
        let kind: mode_t
        let data: Data
    }

    private func tree(_ root: URL, excluding: String? = nil) throws -> [TreeItem] {
        var items: [TreeItem] = []
        func visit(_ parent: URL, prefix: String) throws {
            for url in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                if prefix.isEmpty, url.lastPathComponent == excluding { continue }
                let path = prefix + url.lastPathComponent
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
                let kind = info.st_mode & S_IFMT
                items.append(.init(path: Array(path.utf8), kind: kind, data: kind == S_IFREG ? try Data(contentsOf: url) : Data()))
                if kind == S_IFDIR { try visit(url, prefix: path + "/") }
            }
        }
        try visit(root, prefix: "")
        return items.sorted { $0.path.lexicographicallyPrecedes($1.path) }
    }

    private func assertEditableOutput(_ output: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: output.path)
        XCTAssertEqual(Set(names.map { Data($0.utf8) }), Set(["back\\slash.txt", "dir\\sub", "a\\b", "a", "C:drive.txt", "a\\.\\b"].map { Data($0.utf8) }))
        for (index, path) in Fixture.editable.enumerated() {
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(path)), Data(String(index).utf8), path)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("dir\\sub").path).map { Data($0.utf8) }, [Data("file.txt".utf8)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("back/slash.txt").path))
    }

    @MainActor private func payload(_ path: String, entries: [KaitoKit.ArchiveEntry], session: ArchiveSession) throws -> ArchiveEntryPayload {
        var nodes = EntryNode.tree(from: entries, format: session.reservationFormat).children
        while let node = nodes.popLast() {
            if node.path.utf8.elementsEqual(path.utf8) { return .init(node: node, session: session, generation: session.generation) }
            nodes += node.children
        }
        throw ArchiveEditError.missingFolder(path)
    }

    @MainActor private func assertFolder(_ item: ArchiveEntryPayload, session: ArchiveSession, fixture: Fixture) async throws {
        if session.usesPendingReading {
            XCTAssertEqual(try XCTUnwrap(session.pendingReadSnapshot).resolve(item).map(\.name), ["dir\\sub/file.txt"])
        }
        let output = try fixture.output()
        let result = try await ExtractionService.extract([item], from: session, to: output, progress: Progress())
        try ArchiveCopyOut.check(result)
        XCTAssertEqual(try tree(output).map(\.path), [Array("dir\\sub".utf8), Array("dir\\sub/file.txt".utf8)])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("dir\\sub/file.txt")), Data("1".utf8))
    }

    @MainActor private func assertEditableArchive(suffix: String, behavior: ArchivePreferences.SaveBehavior) async throws {
        let fixture = try Fixture(suffix: suffix), defaults = try ArchivePreferencesTestDefaults()
        let store = ArchivePreferencesStore(defaults: defaults.defaults)
        store.preferences.saveBehavior = behavior
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        defer { document.close() }
        try document.read(from: fixture.archive, ofType: "public.data")
        document.fileURL = fixture.archive
        document.fileType = "public.data"
        let session = try XCTUnwrap(document.session)
        XCTAssertEqual(session.format, .tar)
        XCTAssertTrue(session.capabilities.canEdit)
        let original = try Data(contentsOf: fixture.archive)
        let entries = try await document.projectedEntries(), output = try fixture.output()
        let result = try await ExtractionService.extract(.init(entries: entries), from: session, to: output)
        try ArchiveCopyOut.check(result)
        try assertEditableOutput(output)
        let item = try payload("back\\slash.txt", entries: entries, session: session)
        let entry = try XCTUnwrap(entries.first { $0.name == item.path })
        XCTAssertTrue(EntryReadCapability(entry: entry, isDirectory: false, format: session.format).canPreview)
        let promise = ArchiveFilePromise(payload: item, session: session), provider = try promise.makeProvider()
        let name = promise.filePromiseProvider(provider, fileNameForType: provider.fileType)
        XCTAssertEqual(Array(name.utf8), Array("back\\slash.txt".utf8))
        let promised = try fixture.output().appendingPathComponent(name)
        let failure: (any Error)? = await withCheckedContinuation { continuation in
            promise.filePromiseProvider(provider, writePromiseTo: promised) { @Sendable error in continuation.resume(returning: error) }
        }
        XCTAssertNil(failure)
        XCTAssertEqual(try Data(contentsOf: promised), Data("0".utf8))
        let worker = EntryMaterializer(session: session, temporaryDirectory: .init(root: try fixture.output()))
        let preview = try await worker.materialize(item, progress: Progress())
        XCTAssertEqual(Array(preview.lastPathComponent.utf8), Array("back\\slash.txt".utf8))
        XCTAssertEqual(try Data(contentsOf: preview), Data("0".utf8))
        await worker.close()
        let copied = try await ArchiveCopyOut.prepare([item], from: session, progress: Progress(), temporaryDirectory: .init(root: fixture.output()))
        XCTAssertEqual(copied.urls.map { Array($0.lastPathComponent.utf8) }, [Array("back\\slash.txt".utf8)])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copied.urls.first)), Data("0".utf8))
        try await assertFolder(payload("dir\\sub", entries: entries, session: session), session: session, fixture: fixture)
        if behavior == .onSave {
            let source = fixture.directory.url.appendingPathComponent("new\\name")
            try Data("staged".utf8).write(to: source)
            _ = try await document.append(urls: [source], to: "", progress: Progress())
            let projected = try await document.projectedEntries()
            let added = try payload("new\\name", entries: projected, session: session)
            let stagedOutput = try fixture.output()
            try ArchiveCopyOut.check(await ExtractionService.extract([added], from: session, to: stagedOutput, progress: Progress()))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stagedOutput.path).map { Data($0.utf8) }, [Data("new\\name".utf8)])
            XCTAssertEqual(try Data(contentsOf: stagedOutput.appendingPathComponent("new\\name")), Data("staged".utf8))
            XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
            document.undoManager?.undo()
            // Undo が同期で公開した deferredBase を、背景の再構築より先に解決する。
            let undone = try XCTUnwrap(session.pendingReadSnapshot)
            XCTAssertEqual(undone.nameSyntax, .posix)
            XCTAssertTrue(document.pendingChanges.isEmpty)
            let folder = try payload("dir\\sub", entries: undone.entries, session: session)
            XCTAssertEqual(try undone.resolve(folder).map(\.name), ["dir\\sub/file.txt"])
            try await assertFolder(folder, session: session, fixture: fixture)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), original)
    }

    @MainActor func testTarImmediateExtractionAndReadPaths() async throws { try await assertEditableArchive(suffix: "tar", behavior: .immediate) }
    @MainActor func testTarDeferredExtractionAdditionAndUndo() async throws { try await assertEditableArchive(suffix: "tar", behavior: .onSave) }
    @MainActor func testTarGzipImmediateExtractionAndReadPaths() async throws { try await assertEditableArchive(suffix: "tar.gz", behavior: .immediate) }
    @MainActor func testTarGzipDeferredExtractionAdditionAndUndo() async throws { try await assertEditableArchive(suffix: "tar.gz", behavior: .onSave) }

    func testHostileTarNamesAndCanonicalDuplicateLeaveParentUntouched() async throws {
        for suffix in ["tar", "tar.gz"] {
            let fixture = try Fixture(suffix: suffix, names: Fixture.hostile), output = try fixture.output("out")
            let sentinel = fixture.directory.url.appendingPathComponent("sentinel")
            try Data("untouched".utf8).write(to: sentinel)
            let before = try tree(fixture.directory.url, excluding: "out")
            let session = try ArchiveSession(url: fixture.archive)
            XCTAssertFalse(session.capabilities.canEdit)
            let result = try await ExtractionService.extract(.init(entries: await session.entries()), from: session, to: output)
            XCTAssertEqual(result.failures.map { Data($0.name.utf8) }, ["x\\..\\y", "..\\up.txt", "e\u{301}\\x"].map { Data($0.utf8) })
            XCTAssertEqual(result.failures.prefix(2).map(\.reason), Array(repeating: String(localized: "パスに..成分があります。"), count: 2))
            XCTAssertEqual(result.failures.last?.reason, String(localized: "重複する出力名です（アーカイブ順で最初のentryを優先）。"))
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("ok.txt")), Data("0".utf8))
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("é\\x")), Data("3".utf8))
            XCTAssertEqual(try tree(fixture.directory.url, excluding: "out"), before)
        }
    }

    func testForcedParallelAndSerialPreserveIdenticalNameBytesKindsAndContents() throws {
        let fixture = try Fixture(names: Fixture.editable + (0..<8).map { "extra\($0)" })
        let reader = try ArchiveReader.open(url: fixture.archive), serial = try fixture.output(), parallel = try fixture.output()
        XCTAssertEqual(ExtractionExecution.parallel(workers: 2).workerCount(entries: reader.entries, hasSources: false), 2)
        for (output, execution) in [(serial, ExtractionExecution.serial), (parallel, .parallel(workers: 2))] {
            let result = try ExtractionService.extractResolved(reader.entries, reader: reader, to: output, quarantine: nil, progress: Progress(), execution: execution)
            try ArchiveCopyOut.check(result)
        }
        XCTAssertEqual(try tree(serial), try tree(parallel))
        for (index, path) in Fixture.editable.enumerated() {
            XCTAssertEqual(try Data(contentsOf: parallel.appendingPathComponent(path)), Data(String(index).utf8))
        }
    }

    @MainActor func testZIPKeepsPortableExtractionCapabilityAndPromiseName() async throws {
        let fixture = try Fixture(suffix: "zip", names: ["a\\b.txt", "x\\..\\y"]), output = try fixture.output()
        let session = try ArchiveSession(url: fixture.archive), entries = await session.entries()
        let result = try await ExtractionService.extract(.init(entries: entries), from: session, to: output)
        XCTAssertEqual(result.failures.map(\.name), ["x\\..\\y"])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("a/b.txt")), Data("0".utf8))
        XCTAssertEqual(EntryReadCapability(entry: entries[1], isDirectory: false, format: session.format).refusal, .invalidPath)
        let promise = ArchiveFilePromise(payload: .init(archiveURL: fixture.archive, generation: session.generation, entryIndex: entries[0].index, path: entries[0].name, isDirectory: false), session: session)
        let provider = try promise.makeProvider()
        XCTAssertEqual(promise.filePromiseProvider(provider, fileNameForType: provider.fileType), "b.txt")
    }

    func testComponentSyntaxTableAndFormatBoundary() throws {
        let cases: [(String, [String]?, [String]?)] = [
            ("/C:\\a\\.\\b", ["a", "b"], ["C:\\a\\.\\b"]), ("/./a//b", ["a", "b"], ["a", "b"]),
            ("a\\..\\b", nil, nil), ("C:", nil, ["C:"]), ("a/../b", nil, nil), ("a\0b", nil, nil),
            ("back\\slash.txt", ["back", "slash.txt"], ["back\\slash.txt"]),
            ("", nil, nil), (".", nil, nil), ("/", nil, nil), ("/\u{301}../..", nil, nil)
        ]
        for (name, portable, posix) in cases {
            for (syntax, expected) in [(ExtractionPath.NameSyntax.portable, portable), (.posix, posix)] {
                if let expected { XCTAssertEqual(try ExtractionPath.components(name, syntax: syntax), expected, name) }
                else { XCTAssertThrowsError(try ExtractionPath.components(name, syntax: syntax), name) }
            }
        }
        XCTAssertEqual(ExtractionPath.NameSyntax(KaitoKit.ArchiveFormat.tar), .posix)
        for format: KaitoKit.ArchiveFormat in [.zip, .cpio, .ar, .xar, .iso] { XCTAssertEqual(ExtractionPath.NameSyntax(format), .portable) }
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip, .tarBzip2, .tarXZ] { XCTAssertEqual(ExtractionPath.NameSyntax(format), .posix) }
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .lha] { XCTAssertEqual(ExtractionPath.NameSyntax(format), .portable) }
    }

    func testDestinationKeepsPortableDefaultAndDefendsPOSIXComponents() throws {
        let fixture = try Fixture(), output = try fixture.output()
        let portable = try ExtractionDestination(url: output, quarantine: nil)
        XCTAssertThrowsError(try portable.validate(["back\\slash.txt"]))
        let posix = try ExtractionDestination(url: output, quarantine: nil, nameSyntax: .posix)
        for name in ["back\\slash.txt", "C:x"] { XCTAssertNoThrow(try posix.validate([name])) }
        for name in ["x\\..\\y", "..", ".", "a/b", "a\0b", "", "..\\up.txt", "a\\..\u{301}\\..\\b"] {
            XCTAssertThrowsError(try posix.validate([name]), name)
        }
    }

    func testBSDTarVerbatimPathsMatchFixtureANameBytesKindsAndContents() throws {
        let fixture = try Fixture(), expected = try fixture.output(), actual = try fixture.output()
        // bsdtar の既定は C: を外すため、この安全な fixture だけは名前をそのまま使う。
        try fixture.directory.run(ExternalTool.bsdtar, ["-Pxf", fixture.archive.path, "-C", expected.path])
        let reader = try ArchiveReader.open(url: fixture.archive)
        try ArchiveCopyOut.check(ExtractionService.extractResolved(reader.entries, reader: reader, to: actual, quarantine: nil, progress: Progress()))
        try assertEditableOutput(actual)
        XCTAssertEqual(try tree(actual), try tree(expected))
    }

    private func assertVolumeExtraction(at parent: URL) async throws {
        let area = parent.appendingPathComponent("P13-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: area, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: area) }
        for names in [Fixture.editable, Fixture.hostile] {
            let fixture = try Fixture(names: names)
            let output = area.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let sentinel = area.appendingPathComponent("sentinel")
            try Data("untouched".utf8).write(to: sentinel)
            let before = try tree(area, excluding: "out")
            let session = try ArchiveSession(url: fixture.archive)
            let result = try await ExtractionService.extract(.init(entries: await session.entries()), from: session, to: output)
            XCTAssertFalse(result.cancelled)
            XCTAssertEqual(try tree(area, excluding: "out"), before)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: area.path)), ["out", "sentinel"])
            print("P13 VOLUME \(parent.path) FAILURES: \(result.failures.map { "\($0.name): \($0.reason)" })")
            for item in try tree(output) { print("P13 VOLUME NAME: \(String(decoding: item.path, as: UTF8.self)) UTF8: \(item.path) KIND: \(item.kind)") }
            print("P13 VOLUME OUTSIDE ROOT UNCHANGED")
            try FileManager.default.removeItem(at: output)
        }
    }

    func testExtractionOntoConfiguredDestination() async throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOFINDER_P13_DESTINATION"], !path.isEmpty else {
            throw XCTSkip("KAITOFINDER_P13_DESTINATION is not configured")
        }
        try await assertVolumeExtraction(at: URL(fileURLWithPath: path, isDirectory: true))
    }

    func testExtractionOntoFAT32() async throws {
        let disk = try VolumePublishTestDisk("MS-DOS FAT32")
        try await assertVolumeExtraction(at: disk.mount)
        try disk.detach()
    }

    func testExtractionOntoExFAT() async throws {
        let disk = try VolumePublishTestDisk("ExFAT")
        try await assertVolumeExtraction(at: disk.mount)
        try disk.detach()
    }
}
