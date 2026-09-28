import Darwin
import Foundation
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ParallelExtractionTests: XCTestCase {
    private struct Node: Equatable {
        let mode: mode_t
        let seconds: Int?
        let nanos: Int?
        let data: Data?
        let quarantine: Data?
    }

    private func tree(_ root: URL, ignoringDates: Set<String>) throws -> [String: Node] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var result: [String: Node] = [:]
        for case let url as URL in enumerator {
            let canonical = try XCTUnwrap(ExtractionPath.resolvedPath(root.path))
            let path = String(url.path.dropFirst(canonical.count + 1))
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
            result[path] = Node(mode: info.st_mode,
                seconds: ignoringDates.contains(path) ? nil : info.st_mtimespec.tv_sec,
                nanos: ignoringDates.contains(path) ? nil : info.st_mtimespec.tv_nsec,
                data: info.st_mode & S_IFMT == S_IFREG ? try Data(contentsOf: url) : nil,
                quarantine: try ExtractionQuarantine.read(from: url))
        }
        return result
    }

    @discardableResult private func compare(_ fixture: ScenarioFixture,
        selected: [ArchiveEntry]? = nil, promisedItem: ArchiveEntryPayload? = nil, readOnly: Bool = false,
        ignoringDates: Set<String> = [], prepare: (URL) throws -> Void = { _ in }) throws -> ExtractionResult {
        let quarantine = Data("0083;65000000;KaitoFinder-M9;".utf8)
        var results: [ExtractionResult] = [], roots: [URL] = [], byteCounts: [Int] = []
        defer {
            for root in roots {
                _ = chmod(root.path, 0o700)
                try? ExtractionTemporaryDirectory(root: root).sweepOnLaunch()
            }
        }
        for execution in [ExtractionExecution.serial, .parallel(workers: 4)] {
            let rawRoot = fixture.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: false)
            let root = URL(fileURLWithPath: try XCTUnwrap(ExtractionPath.resolvedPath(rawRoot.path)), isDirectory: true)
            try prepare(root)
            let destination = promisedItem == nil ? root : root.appendingPathComponent("promised")
            let reader = try ArchiveReader.open(url: fixture.archive)
            let progress = Progress(), processed = Mutex<[Int]>([]), bytes = Mutex(0)
            let result = try ExtractionService.extractResolved(selected ?? reader.entries, reader: reader,
                to: destination, quarantine: quarantine, progress: progress, promisedItem: promisedItem,
                readOnly: readOnly, didWrite: { count in bytes.withLock { $0 += count } },
                didProcess: { index in processed.withLock { $0.append(index) } }, execution: execution)
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
            XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, (selected ?? reader.entries).count)
            XCTAssertEqual(processed.withLock { $0.sorted() }, (selected ?? reader.entries).map(\.index))
            for item in result.written {
                var info = stat()
                XCTAssertEqual(lstat(item.url.path, &info), 0)
                XCTAssertTrue(item.matches(info))
                if item.entryIndex != nil { XCTAssertNotNil(item.identity) }
            }
            results.append(result)
            roots.append(root)
            byteCounts.append(bytes.withLock { $0 })
        }
        func written(_ index: Int) -> [String] {
            results[index].written.map {
                "\($0.entryIndex.map(String.init) ?? "nil"):\(String($0.url.path.dropFirst(roots[index].path.count + 1)))"
            }
        }
        XCTAssertEqual(written(0).count, written(1).count)
        for (first, second) in zip(written(0), written(1)) { XCTAssertEqual(first, second) }
        XCTAssertEqual(results[0].failures.map(\.entryIndex), results[1].failures.map(\.entryIndex))
        XCTAssertEqual(results[0].failures.map(\.name), results[1].failures.map(\.name))
        XCTAssertEqual(results[0].failures.map(\.reason), results[1].failures.map(\.reason))
        XCTAssertEqual(results[0].cancelled, results[1].cancelled)
        XCTAssertEqual(byteCounts[0], byteCounts[1])
        let first = try tree(roots[0], ignoringDates: ignoringDates)
        let second = try tree(roots[1], ignoringDates: ignoringDates)
        XCTAssertEqual(first.keys.sorted(), second.keys.sorted())
        for (path, node) in first { XCTAssertEqual(node, second[path], path) }
        return results[1]
    }

    func testTwoThousandNestedZIPFilesMatchSerialIncludingMetadata() throws {
        let fixture = try ScenarioFixture(script: ScenarioFixture.zipScript(count: 2000, size: 8192))
        let result = try compare(fixture)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.written.count, 2021)
    }

    func testTarExplicitDirectoriesAreFinishedAfterChildrenAndReadOnlyFilesMatch() throws {
        let fixture = try ScenarioFixture(script: """
        with tarfile.open(p, 'w', format=tarfile.USTAR_FORMAT) as t:
            for i in range(80):
                f = tarfile.TarInfo('root/deep/f%03d' % i)
                f.mode = 0o754 if i % 2 else 0o640
                f.mtime = 1000000020 + i
                f.size = 131072
                t.addfile(f, io.BytesIO(bytes([i]) * f.size))
            for name, mode in [('root/deep', 0o500), ('root', 0o750)]:
                d = tarfile.TarInfo(name)
                d.type = tarfile.DIRTYPE
                d.mode = mode
                d.mtime = 1000000000
                t.addfile(d)
        """, suffix: "tar")
        XCTAssertTrue(try compare(fixture).failures.isEmpty)
        XCTAssertTrue(try compare(fixture, readOnly: true).failures.isEmpty)
    }

    func testHostileZIPHasIdenticalWinnersAndFailureReasons() throws {
        let fixture = try ScenarioFixture(script: """
        import warnings
        warnings.simplefilter('ignore')
        with zipfile.ZipFile(p, 'w') as z:
            for name in ['same', 'same', 'caf\\u00e9', 'cafe\\u0301', '../escape', '/absolute',
                         'parent', 'parent/child', 'Case', 'case', 'dir/', 'dir/child',
                         'childFirst/a', 'childFirst', 'folder/a', 'FOLDER/A', 'folder/',
                         'existing', 'existingDir/', 'link/child', 'link']:
                i = zipfile.ZipInfo(name, (2020, 1, 2, 3, 4, 6))
                i.create_system = 3
                i.external_attr = ((stat.S_IFDIR | 0o755) if name.endswith('/') else (stat.S_IFREG | 0o640)) << 16
                z.writestr(i, b'' if name.endswith('/') else name.encode())
            for i in range(80): z.writestr(zipfile.ZipInfo('independent-%03d' % i), b'x' * 131072)
        """)
        let result = try compare(fixture, ignoringDates: ["childFirst", "existing", "existingDir", "link"]) { root in
            try Data("original".utf8).write(to: root.appendingPathComponent("existing"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("existingDir"), withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path,
                                                       withDestinationPath: "existingDir")
        }
        XCTAssertTrue(result.failures.contains { $0.name == "parent/child" })
        XCTAssertTrue(result.failures.contains { $0.name == "../escape" })
        XCTAssertFalse(result.failures.contains { $0.name == "/absolute" })
    }

    func testFailedStreamDoesNotReserveCaseAliasOrLeaveNewParents() throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            for name in ['broken', 'BROKEN', 'bad/child', 'bad', 'unsupported/child', 'unsupported', 'healthy']:
                z.writestr(zipfile.ZipInfo(name), b'payload')
        data = bytearray(open(p, 'rb').read())
        pos = 0
        while True:
            pos = data.find(b'PK\\x03\\x04', pos)
            if pos < 0: break
            n, e = struct.unpack_from('<HH', data, pos + 26)
            name = bytes(data[pos+30:pos+30+n])
            if name in [b'broken', b'bad/child']: data[pos+30+n+e] ^= 0xff
            if name == b'unsupported/child': struct.pack_into('<H', data, pos + 8, 255)
            pos += 30 + n + e
        pos = 0
        while True:
            pos = data.find(b'PK\\x01\\x02', pos)
            if pos < 0: break
            n = struct.unpack_from('<H', data, pos + 28)[0]
            if bytes(data[pos+46:pos+46+n]) == b'unsupported/child': struct.pack_into('<H', data, pos + 10, 255)
            pos += 46 + n
        open(p, 'wb').write(data)
        """)
        let result = try compare(fixture, ignoringDates: ["bad"])
        XCTAssertTrue(result.failures.contains { $0.name == "broken" })
        XCTAssertTrue(result.written.contains { $0.url.lastPathComponent == "BROKEN" })
        XCTAssertTrue(result.written.contains { $0.url.lastPathComponent == "unsupported" })
    }

    func testSubtreeAndFileMappingsMatchSerial() throws {
        let fixture = try ScenarioFixture(script: ScenarioFixture.zipScript(count: 80, size: 131072))
        let entries = try ArchiveReader.open(url: fixture.archive).entries
        let virtual = ArchiveEntryPayload(archiveURL: fixture.archive, generation: 0, entryIndex: nil,
                                          path: "root", isDirectory: true)
        XCTAssertTrue(try compare(fixture, selected: Array(entries.dropFirst()), promisedItem: virtual,
                                  ignoringDates: ["promised"]).failures.isEmpty)
        let explicit = ArchiveEntryPayload(archiveURL: fixture.archive, generation: 0, entryIndex: 0,
                                           path: "root/", isDirectory: true)
        XCTAssertTrue(try compare(fixture, promisedItem: explicit).failures.isEmpty)
        let file = try XCTUnwrap(entries.first { $0.kind == .file })
        let promised = ArchiveEntryPayload(archiveURL: fixture.archive, generation: 0, entryIndex: file.index,
                                           path: file.name, isDirectory: false)
        XCTAssertTrue(try compare(fixture, selected: [file], promisedItem: promised, readOnly: true).failures.isEmpty)
        let duplicates = try compare(fixture, selected: entries.filter { $0.kind == .file }, promisedItem: promised)
        XCTAssertEqual(duplicates.failures.count, 79)
    }

    func testTwoSolidGroupsAndIndependentSevenZipEntriesMatchSerial() throws {
        let fixture = try ScenarioFixture(script: Self.sevenZipScript, suffix: "7z")
        let entries = try ArchiveReader.open(url: fixture.archive).entries
        XCTAssertEqual(entries.map(\.solidGroup), [0, 0, 0, 0, 1, 1, 1, 1, -1, -1])
        let files = entries.enumerated().map { ParallelExtraction.File(position: $0.offset, entry: $0.element,
                                                                       components: [$0.element.name]) }
        XCTAssertEqual(ParallelExtraction.buckets(files).map { $0.map(\.entry.index) }, [[0, 1, 2, 3], [4, 5, 6, 7], [8], [9]])
        XCTAssertTrue(try compare(fixture).failures.isEmpty)
    }

    @MainActor func testSolidGroupsAndIndependentEntriesRunConcurrentlyWithoutReorderingGroups() async throws {
        let fixture = try ScenarioFixture(script: Self.sevenZipScript, suffix: "7z")
        let archive = fixture.archive, root = fixture.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let gates = (0..<4).map { _ in ScenarioGate() }, writes = Mutex(0), processed = Mutex<[Int]>([])
        defer { for gate in gates { gate.release() } }
        let task = Task.detached {
            let reader = try ArchiveReader.open(url: archive)
            return try ExtractionService.extractResolved(reader.entries, reader: reader, to: root, quarantine: nil,
                progress: Progress(), didWrite: { _ in
                    let index = writes.withLock { value in defer { value += 1 }; return value }
                    if index < gates.count { gates[index].pauseOnce() }
                }, didProcess: { index in processed.withLock { $0.append(index) } }, execution: .parallel(workers: 4))
        }
        try await scenarioWait { gates.allSatisfy(\.isEntered) }
        XCTAssertTrue(processed.withLock { $0.isEmpty })
        for gate in gates { gate.release() }
        let result = try await task.value
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.written.compactMap(\.entryIndex), Array(0..<10))
        for range in [0..<4, 4..<8] {
            XCTAssertEqual(processed.withLock { $0.filter { range.contains($0) } }, Array(range))
        }
    }

    func testSourcesKeepTheSerialPathEvenWhenParallelIsForced() throws {
        let fixture = try ScenarioFixture(script: ScenarioFixture.zipScript(count: 80, size: 131072))
        let root = fixture.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let reader = try ArchiveReader.open(url: fixture.archive), processed = Mutex<[Int]>([])
        let result = try ExtractionService.extractResolved(reader.entries, reader: reader, to: root, quarantine: nil,
            progress: Progress(), didProcess: { index in processed.withLock { $0.append(index) } },
            sources: .init(base: [], positions: [:], additions: [:]), execution: .parallel(workers: 4))
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(processed.withLock { $0 }, reader.entries.map(\.index))
    }

    func testEligibilityAndSmallOrNonPlainRunsStaySerial() throws {
        let fixture = try ScenarioFixture(script: ScenarioFixture.zipScript(count: 80, size: 131072))
        let entries = try ArchiveReader.open(url: fixture.archive).entries
        let automatic = ExtractionExecution.automatic
        XCTAssertEqual(automatic.workerCount(entries: entries, hasSources: false), min(ProcessInfo.processInfo.activeProcessorCount, 8))
        XCTAssertEqual(automatic.workerCount(entries: entries, hasSources: true), 1)
        XCTAssertEqual(automatic.workerCount(entries: Array(entries.suffix(63)), hasSources: false), 1)
        XCTAssertEqual(ExtractionExecution.parallel(workers: 0).workerCount(entries: entries, hasSources: false), 1)
        let tiny = try ScenarioFixture(script: ScenarioFixture.zipScript(count: 80, size: 1))
        XCTAssertEqual(automatic.workerCount(entries: try ArchiveReader.open(url: tiny.archive).entries, hasSources: false), 1)
        let solid = try ScenarioFixture(script: Self.sevenZipScript, suffix: "7z")
        let group = Array(try ArchiveReader.open(url: solid.archive).entries.prefix(4))
        XCTAssertEqual(ExtractionExecution.parallel(workers: 4).workerCount(entries: group, hasSources: false), 1)
        let links = try ScenarioFixture(script: """
        with tarfile.open(p, 'w') as t:
            for name, kind in [('sym', tarfile.SYMTYPE), ('hard', tarfile.LNKTYPE), ('fifo', tarfile.FIFOTYPE)]:
                i = tarfile.TarInfo(name)
                i.type = kind
                i.linkname = 'target'
                t.addfile(i)
        """, suffix: "tar")
        for entry in try ArchiveReader.open(url: links.archive).entries {
            XCTAssertEqual(ExtractionExecution.parallel(workers: 4).workerCount(entries: entries + [entry], hasSources: false), 1)
        }
    }

    func testOutOfOrderProgressCapsEachEntryAndTopsUpFailures() throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            for name, data in [('a', b'a'*100), ('b', b'b'*200), ('empty', b'')]: z.writestr(name, data)
        """)
        let entries = try ArchiveReader.open(url: fixture.archive).entries
        let progress = Progress(), counter = ExtractionProgress(entries: entries, progress: progress)
        counter.wrote(150, at: 1)
        counter.wrote(1000, at: 0)
        XCTAssertEqual(progress.completedUnitCount, 250)
        counter.finishedEntry(at: 2)
        counter.finishedEntry(at: 0)
        XCTAssertEqual(progress.completedUnitCount, 251)
        counter.finishedEntry(at: 1)
        XCTAssertEqual(progress.completedUnitCount, 301)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 3)
    }

    @MainActor func testProgressCancellationStopsAllFourWorkersAndFinishesDirectories() async throws {
        try await cancellation(cancelTask: false)
    }

    @MainActor func testTaskCancellationReachesGCDWorkers() async throws {
        try await cancellation(cancelTask: true)
    }

    @MainActor private func cancellation(cancelTask: Bool) async throws {
        let fixture = try ScenarioFixture(script: ScenarioFixture.zipScript(count: 80, size: 512 * 1024))
        let root = fixture.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let archive = fixture.archive, progress = Progress(), gates = (0..<4).map { _ in ScenarioGate() }
        let writes = Mutex(0)
        defer { for gate in gates { gate.release() } }
        let task = Task.detached {
            let reader = try ArchiveReader.open(url: archive)
            return try ExtractionService.extractResolved(reader.entries, reader: reader, to: root, quarantine: nil,
                progress: progress, didWrite: { _ in
                    let index = writes.withLock { value in defer { value += 1 }; return value }
                    if index < gates.count { gates[index].pauseOnce() }
                }, execution: .parallel(workers: 4))
        }
        try await scenarioWait { gates.allSatisfy(\.isEntered) }
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 21)
        XCTAssertGreaterThan(progress.completedUnitCount, 21)
        XCTAssertLessThan(progress.fractionCompleted, 1)
        if cancelTask {
            task.cancel()
            try await Task.sleep(for: .milliseconds(50))
        } else { progress.cancel() }
        for gate in gates { gate.release() }
        let result = try await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.written.count, 21)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 21)
        let reader = try ArchiveReader.open(url: archive)
        for entry in reader.entries where entry.kind == .directory {
            var info = stat()
            XCTAssertEqual(lstat(root.appendingPathComponent(entry.name).path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o755 & ~ExtractionPermissions.processMask)
            XCTAssertEqual(Double(info.st_mtimespec.tv_sec), try XCTUnwrap(entry.modificationDate).timeIntervalSince1970)
        }
        XCTAssertEqual(try tree(root, ignoringDates: []).count, 21)
    }

    private static let sevenZipScript = """
    import binascii
    groups = [4, 4, 1, 1]
    payloads = [bytes([65+i]) for i in range(sum(groups))]
    packed = b''.join(payloads)
    names = b'\\x00' + ''.join(chr(97+i) + '\\x00' for i in range(len(payloads))).encode('utf-16le')
    header = bytes([1, 4, 6, 0, len(groups), 9] + groups + [0, 7, 11, len(groups), 0])
    header += bytes([1, 1, 0] * len(groups) + [12] + groups + [0, 8, 13] + groups + [9])
    header += bytes([1] * (len(payloads) - len(groups)) + [10, 1])
    header += b''.join(struct.pack('<I', binascii.crc32(b)) for b in payloads)
    header += bytes([0, 0, 5, len(payloads), 17, len(names)]) + names
    times = bytes([1, 0]) + struct.pack('<Q', (1000000000 + 11644473600) * 10000000) * len(payloads)
    header += bytes([20, len(times)]) + times + bytes([0, 0])
    start = struct.pack('<QQI', len(packed), len(header), binascii.crc32(header))
    archive = b'7z\\xbc\\xaf\\x27\\x1c\\x00\\x04' + struct.pack('<I', binascii.crc32(start))
    open(p, 'wb').write(archive + start + packed + header)
    """
}
