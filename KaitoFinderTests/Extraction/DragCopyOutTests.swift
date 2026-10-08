import AppKit
import Darwin
import KaitoKit
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import KaitoFinder

/// ドラッグの file promise（ArchiveFilePromise・FilePromiseRegistry・ArchivePromiseExtractionQueue）とコピー（ArchiveCopyOut）が
/// ちょうど一度だけ完了し、solid 書庫の reader を共有し、登録を掃除することを確かめる。書庫は ScenarioFixture で作り、
/// 書き込みは ScenarioGate で止める。観測点は setPromiseSourceForTesting。
nonisolated final class DragCopyOutTests: XCTestCase {
    @MainActor func testFolderProviderUsesFolderUTI() throws {
        guard UTType.folder.conforms(to: .directory) else {
            throw XCTSkip("この実行環境では LaunchServices が public.folder を解決できません")
        }
        let fixture = try Fixture(tar: true)
        let session = try ArchiveSession(url: fixture.archive)
        let delegate = ArchiveFilePromise(payload: fixture.payload("outer/folder/", session: session, directory: true), session: session)
        XCTAssertEqual(try delegate.makeProvider().fileType, UTType.folder.identifier)
    }

    /// `ScenarioFixture` の書庫（既定は ZIP、`tar` なら USTAR の tar）と、promise の書き出し先 `out/`。
    private final class Fixture {
        let scenario: ScenarioFixture
        let output: URL
        var parent: URL { scenario.root }
        var archive: URL { scenario.archive }
        init(tar: Bool = false) throws {
            scenario = try ScenarioFixture(script: tar ? """
                with tarfile.open(p, 'w', format=tarfile.USTAR_FORMAT) as t:
                    d = tarfile.TarInfo('outer/folder/'); d.type = tarfile.DIRTYPE; d.mode = 0o755; t.addfile(d)
                    f = tarfile.TarInfo('outer/folder/a.txt'); f.size = 5; t.addfile(f, io.BytesIO(b'hello'))
                    h = tarfile.TarInfo('outer/folder/deep/link'); h.type = tarfile.LNKTYPE
                    h.linkname = 'outer/folder/a.txt'; t.addfile(h)
                    f = tarfile.TarInfo('outside'); f.size = 3; t.addfile(f, io.BytesIO(b'out'))
                """ : Self.zipScript([("folder/a.txt", "hello"), ("folder/deep/b.txt", "world"), ("other.txt", "other")]),
                suffix: tar ? "tar" : "zip")
            output = scenario.root.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        /// 書庫と同じ path へ `script` で書き直す（`p` は書庫の path）。
        func run(_ script: String) throws {
            _ = try scenario.pythonArchive(archive.lastPathComponent, script: script)
        }
        func writeZIP(_ entries: [(String, String)]) throws {
            try run(Self.zipScript(entries))
        }
        // 置換で新しい inode を作り、旧 reader の reopen との差を検査する。
        private static func zipScript(_ entries: [(String, String)]) -> String {
            let pairs = entries.map { "('\($0.0)', '\($0.1)')" }.joined(separator: ",")
            return "import os\nwith zipfile.ZipFile(p + '.new', 'w') as z:\n for n, v in [\(pairs)]: z.writestr(n, v)\nos.replace(p + '.new', p)"
        }
        func writeSolidSevenZip(groupSizes: [Int]) throws {
            try run("""
            import binascii, struct
            groups = \(groupSizes)
            payloads = [bytes([65 + i]) for i in range(sum(groups))]
            packed = b''.join(payloads)
            names = b'\\x00' + ''.join(chr(97 + i) + '\\x00' for i in range(len(payloads))).encode('utf-16le')
            header = bytes([1, 4, 6, 0, len(groups), 9] + groups + [0, 7, 11, len(groups), 0])
            header += bytes([1, 1, 0] * len(groups) + [12] + groups + [0, 8, 13] + groups + [9])
            header += bytes([1] * (len(payloads) - len(groups)) + [10, 1])
            header += b''.join(struct.pack('<I', binascii.crc32(b)) for b in payloads)
            header += bytes([0, 0, 5, len(payloads), 17, len(names)]) + names + bytes([0, 0])
            start = struct.pack('<QQI', len(packed), len(header), binascii.crc32(header))
            archive = b'7z\\xbc\\xaf\\x27\\x1c\\x00\\x04' + struct.pack('<I', binascii.crc32(start))
            open(p, 'wb').write(archive + start + packed + header)
            """)
        }
        // 展開で復元した読み取り専用の directory も消せるように片付け、fixture の directory の削除は ScenarioFixture に任せる。
        deinit { try? ExtractionTemporaryDirectory(root: parent).sweepOnLaunch() }
        func payload(_ path: String, session: ArchiveSession, index: Int? = nil, directory: Bool = false) -> ArchiveEntryPayload {
            ArchiveEntryPayload(archiveURL: archive, generation: session.generation, entryIndex: index, path: path, isDirectory: directory)
        }
    }

    @MainActor private func write(_ delegate: ArchiveFilePromise, to url: URL) async throws -> (any Error)? {
        let provider = NSFilePromiseProvider()
        let calls = Mutex(0)
        let failure = Mutex<(any Error)?>(nil)
        delegate.filePromiseProvider(provider, writePromiseTo: url) { @Sendable error in
            calls.withLock { $0 += 1 }
            failure.withLock { $0 = error }
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while calls.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // 完了後の二重通知も観測する。各成功・失敗・取消し経路で件数を明示的に assert。
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.withLock { $0 }, 1)
        return failure.withLock { $0 }
    }

    @MainActor func testPromiseDelegateMethodsAreCallableThroughObjCProtocolOffMainThread() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let delegate = ArchiveFilePromise(payload: fixture.payload("folder/a.txt", session: session, index: 0), session: session)
        // 修正前もコンパイルできるよう main actor 上で型消去し、同一プロセスでの受信と同じ
        // 非 Sendable の ObjC 参照のスレッド越えを、この回帰テストで明示的に再現する。
        nonisolated(unsafe) let protocolDelegate: any NSFilePromiseProviderDelegate = delegate
        nonisolated(unsafe) let provider = NSFilePromiseProvider(fileType: "public.data", delegate: delegate)

        try await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            // SDK の protocol 要件は @MainActor のため、Swift 経由では背景スレッドから呼べない。
            // NSObject.perform で AppKit と同じ @objc thunk を通し、実装の動的隔離検査を再現する。
            let delegate = protocolDelegate as! NSObject
            let name = delegate.perform(
                #selector(NSFilePromiseProviderDelegate.filePromiseProvider(_:fileNameForType:)),
                with: provider, with: "public.data")?.takeUnretainedValue() as? String
            let queue = try XCTUnwrap(delegate.perform(
                #selector(NSFilePromiseProviderDelegate.operationQueue(for:)),
                with: provider)?.takeUnretainedValue() as? OperationQueue)
            XCTAssertEqual(name, "a.txt")
            XCTAssertFalse(queue === OperationQueue.main)
        }.value
    }

    @MainActor func testPromiseSingleFileCompletesExactlyOnceOnSuccess() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let delegate = ArchiveFilePromise(payload: fixture.payload("folder/a.txt", session: session, index: 0), session: session)
        let url = fixture.output.appendingPathComponent("renamed.txt")
        let error = try await write(delegate, to: url)
        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
        XCTAssertFalse(delegate.operationQueue(for: try delegate.makeProvider()) === OperationQueue.main)
    }

    @MainActor func testFolderPromiseHasOneProviderAndPreservesHardlinkSubtree() async throws {
        let fixture = try Fixture(tar: true)
        let session = try ArchiveSession(url: fixture.archive)
        let delegate = ArchiveFilePromise(payload: fixture.payload("outer/folder/", session: session, index: 0, directory: true), session: session)
        XCTAssertEqual(delegate.promisedType, UTType.folder)
        let url = fixture.output.appendingPathComponent("renamed-folder")
        let error = try await write(delegate, to: url)
        XCTAssertNil(error, "\(String(describing: error))")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("a.txt"), encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("deep/link"), encoding: .utf8), "hello")
        var file = stat(), link = stat()
        XCTAssertEqual(lstat(url.appendingPathComponent("a.txt").path, &file), 0)
        XCTAssertEqual(lstat(url.appendingPathComponent("deep/link").path, &link), 0)
        XCTAssertEqual(file.st_ino, link.st_ino)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("outer").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("outside").path))
    }

    @MainActor func testVirtualFolderPromiseExpandsWholeSubtree() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let snapshot = await session.snapshot()
        let tree = EntryNode.tree(from: snapshot.entries)
        let folder = try XCTUnwrap(tree.children.first { $0.name == "folder" })
        XCTAssertTrue(folder.isVirtual)
        XCTAssertEqual(folder.path, "folder")
        let payload = ArchiveEntryPayload(node: folder, archiveURL: fixture.archive, generation: snapshot.generation)
        let url = fixture.output.appendingPathComponent("folder")
        let error = try await write(ArchiveFilePromise(payload: payload, session: session), to: url)
        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("deep/b.txt"), encoding: .utf8), "world")
        let extracted = fixture.parent.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        let result = try await ExtractionService.extract([payload], from: session, to: extracted, progress: Progress())
        XCTAssertTrue(result.failures.isEmpty)
        let temporary = ExtractionTemporaryDirectory(root: fixture.parent.appendingPathComponent("copies"))
        let copied = try await ArchiveCopyOut.prepare([payload], from: session, progress: Progress(), temporaryDirectory: temporary)
        for output in [url, extracted.appendingPathComponent("folder"), try XCTUnwrap(copied.urls.first)] {
            var info = stat()
            XCTAssertEqual(lstat(output.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o755 & ~ExtractionPermissions.processMask)
        }
    }

    private final class CountingSolidSource: ByteSource {
        let source: FileByteSource
        let packedOffsets: Set<UInt64>
        let packedReadStarts = Mutex(0)
        var length: UInt64 { source.length }
        init(_ url: URL, packedOffsets: Set<UInt64> = [32]) throws {
            source = try FileByteSource(url: url)
            self.packedOffsets = packedOffsets
        }
        func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64) throws -> Int {
            if packedOffsets.contains(offset) { packedReadStarts.withLock { $0 += 1 } }
            return try source.read(into: buffer, at: offset)
        }
    }

    @MainActor func testTwentySolidPromisesShareOneSerialReaderAndBoundedDecodePasses() async throws {
        let fixture = try Fixture()
        try fixture.writeSolidSevenZip(groupSizes: [20])
        let session = try ArchiveSession(url: fixture.archive), source = try CountingSolidSource(fixture.archive)
        await session.setPromiseSourceForTesting(source)
        let entries = await session.entries()
        XCTAssertEqual(entries.count, 20)
        XCTAssertEqual(Set(entries.map(\.solidGroup)), [0])
        let registry = FilePromiseRegistry()
        let promises = try entries.map { entry in
            try registry.register(payload: fixture.payload(entry.name, session: session, index: entry.index), session: session)
        }
        registry.began(sessionID: 42, promises: promises.map(\.id))
        let queue = try XCTUnwrap(promises.first?.provider.delegate as? ArchiveFilePromise).debugExtractionQueue
        let completed = expectation(description: "Twenty promises")
        completed.expectedFulfillmentCount = 20
        for (promise, entry) in zip(promises, entries).reversed() {
            let delegate = try XCTUnwrap(promise.provider.delegate as? ArchiveFilePromise)
            XCTAssertTrue(delegate.debugExtractionQueue === queue)
            delegate.filePromiseProvider(promise.provider, writePromiseTo: fixture.output.appendingPathComponent(entry.name)) { @Sendable error in
                XCTAssertNil(error)
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 15)
        XCTAssertEqual(queue.maximumActiveCount.withLock { $0 }, 1)
        XCTAssertEqual(queue.readerReopenCount.withLock { $0 }, 1)
        XCTAssertEqual(queue.processedIndices.withLock { $0 }, Array(0..<20))
        XCTAssertGreaterThan(source.packedReadStarts.withLock { $0 }, 0)
        XCTAssertLessThanOrEqual(source.packedReadStarts.withLock { $0 }, 2)
        for entry in entries {
            XCTAssertEqual(try Data(contentsOf: fixture.output.appendingPathComponent(entry.name)), Data([UInt8(65 + entry.index)]))
        }
        await session.close()
    }

    @MainActor func testNonSolidPromisesRunFourIndependentRowsAtATime() async throws {
        let fixture = try Fixture(), count = 20
        try fixture.writeZIP((0..<count).map { ("file-\($0).txt", "contents-\($0)") })
        let session = try ArchiveSession(url: fixture.archive), entries = await session.entries()
        XCTAssertTrue(entries.allSatisfy { $0.solidGroup < 0 })
        let registry = FilePromiseRegistry(), gates = (0..<count).map { _ in ScenarioGate() }
        let promises = try entries.map { entry in
            try registry.register(payload: fixture.payload(entry.name, session: session, index: entry.index),
                session: session, didWrite: { _ in gates[entry.index].pauseOnce() })
        }
        registry.began(sessionID: 43, promises: promises.map(\.id))
        let queue = try XCTUnwrap(promises.first?.provider.delegate as? ArchiveFilePromise).debugExtractionQueue
        let delegates = try promises.map { try XCTUnwrap($0.provider.delegate as? ArchiveFilePromise) }
        let completed = expectation(description: "Independent promises")
        completed.expectedFulfillmentCount = count
        let callbackCount = Mutex(0), callbacksFinished = AsyncGate()
        for index in entries.indices.reversed() {
            let promise = promises[index], entry = entries[index], delegate = delegates[index]
            delegate.filePromiseProvider(promise.provider, writePromiseTo: fixture.output.appendingPathComponent(entry.name)) { @Sendable error in
                XCTAssertNil(error)
                completed.fulfill()
                if callbackCount.withLock({ $0 += 1; return $0 }) == count {
                    Task { await callbacksFinished.release() }
                }
            }
        }
        // 同期 gate は cooperative pool の thread を止める。VM の CPU 数も上限になる。
        let concurrency = min(4, ProcessInfo.processInfo.activeProcessorCount)
        func releaseAndDrain() async {
            for gate in gates { gate.release() }
            await fulfillment(of: [completed], timeout: 30)
            // expectation が時間切れでも fixture を先に破棄しない。欠落は test timeout で検出する。
            await callbacksFinished.waitIgnoringCancellation()
            XCTAssertEqual(queue.activeCount.withLock { $0 }, 0)
            await session.close()
        }
        do {
            try await scenarioWait { gates.filter(\.isEntered).count == concurrency }
            XCTAssertEqual(gates.filter(\.isEntered).count, concurrency)
            XCTAssertEqual(queue.activeCount.withLock { $0 }, concurrency)
            XCTAssertEqual(queue.maximumActiveCount.withLock { $0 }, concurrency)
            XCTAssertFalse(gates.dropFirst(4).contains { $0.isEntered })
        } catch {
            await releaseAndDrain()
            throw error
        }
        await releaseAndDrain()
        XCTAssertLessThanOrEqual(queue.maximumActiveCount.withLock { $0 }, 4)
        XCTAssertLessThanOrEqual(queue.readerReopenCount.withLock { $0 }, 4)
        for entry in entries {
            XCTAssertEqual(try String(contentsOf: fixture.output.appendingPathComponent(entry.name), encoding: .utf8),
                           "contents-\(entry.index)")
        }
    }

    @MainActor func testDifferentSolidGroupsRunConcurrentlyAndEachReusesItsOrderedReader() async throws {
        let fixture = try Fixture()
        try fixture.writeSolidSevenZip(groupSizes: [10, 10])
        let session = try ArchiveSession(url: fixture.archive)
        let source = try CountingSolidSource(fixture.archive, packedOffsets: [32, 42])
        await session.setPromiseSourceForTesting(source)
        let entries = await session.entries(), registry = FilePromiseRegistry()
        XCTAssertEqual(entries.map(\.solidGroup), Array(repeating: 0, count: 10) + Array(repeating: 1, count: 10))
        let gates = [ScenarioGate(), ScenarioGate()]
        defer { for gate in gates { gate.release() } }
        let promises = try entries.map { entry in
            try registry.register(payload: fixture.payload(entry.name, session: session, index: entry.index),
                session: session, didWrite: { _ in
                    if entry.index == 1 || entry.index == 10 { gates[entry.solidGroup].pauseOnce() }
                })
        }
        registry.began(sessionID: 44, promises: promises.map(\.id))
        let queue = try XCTUnwrap(promises.first?.provider.delegate as? ArchiveFilePromise).debugExtractionQueue
        let first = try XCTUnwrap(promises[0].provider.delegate as? ArchiveFilePromise)
        let firstError = try await write(first, to: fixture.output.appendingPathComponent(entries[0].name))
        XCTAssertNil(firstError)
        XCTAssertEqual(queue.readerReopenCount.withLock { $0 }, 1)
        let completed = expectation(description: "Two solid groups")
        completed.expectedFulfillmentCount = 19
        let secondGroup = try XCTUnwrap(promises[10].provider.delegate as? ArchiveFilePromise)
        secondGroup.filePromiseProvider(promises[10].provider,
            writePromiseTo: fixture.output.appendingPathComponent(entries[10].name)) { @Sendable error in
                XCTAssertNil(error)
                completed.fulfill()
            }
        try await scenarioWait { gates[1].isEntered }
        let initialReadStarts = source.packedReadStarts.withLock { $0 }
        for (promise, entry) in zip(promises, entries).reversed() where entry.index != 0 && entry.index != 10 {
            let delegate = try XCTUnwrap(promise.provider.delegate as? ArchiveFilePromise)
            delegate.filePromiseProvider(promise.provider, writePromiseTo: fixture.output.appendingPathComponent(entry.name)) { @Sendable error in
                XCTAssertNil(error)
                completed.fulfill()
            }
        }
        try await scenarioWait { gates.allSatisfy(\.isEntered) }
        XCTAssertEqual(queue.activeCount.withLock { $0 }, 2)
        for gate in gates { gate.release() }
        await fulfillment(of: [completed], timeout: 15)
        XCTAssertEqual(queue.maximumActiveCount.withLock { $0 }, 2)
        XCTAssertEqual(queue.readerReopenCount.withLock { $0 }, 2)
        let processed = queue.processedIndices.withLock { $0 }
        for group in 0..<2 {
            XCTAssertEqual(processed.filter { entries[$0].solidGroup == group }, Array((group * 10)..<(group * 10 + 10)))
        }
        XCTAssertGreaterThanOrEqual(source.packedReadStarts.withLock { $0 }, 2)
        XCTAssertLessThanOrEqual(source.packedReadStarts.withLock { $0 }, 4)
        XCTAssertEqual(source.packedReadStarts.withLock { $0 }, initialReadStarts,
                       "遅れて届いた行でも solid folder を先頭から読み直さない")
        for entry in entries {
            XCTAssertEqual(try Data(contentsOf: fixture.output.appendingPathComponent(entry.name)), Data([UInt8(65 + entry.index)]))
        }
        await session.close()
    }

    @MainActor func testSharedPromiseReaderRefreshesAfterPasswordAcceptance() async throws {
        let fixture = try Fixture()
        try fixture.run("""
        import subprocess, os
        secret = os.path.join(os.path.dirname(p), 'secret')
        open(secret, 'wb').write(b'protected')
        subprocess.run(['\(ExternalTool.zip)', '-q', '-j', '-P', 'key', p, secret], check=True)
        """)
        let session = try ArchiveSession(url: fixture.archive), queue = ArchivePromiseExtractionQueue()
        session.setPasswordPrompt(PasswordPrompts.fixed("key"))
        for (index, name) in [(2, "other.txt"), (3, "secret")] {
            let delegate = ArchiveFilePromise(payload: fixture.payload(name, session: session, index: index), session: session)
            delegate.useExtractionQueue(queue)
            let error = try await write(delegate, to: fixture.output.appendingPathComponent(name))
            XCTAssertNil(error)
        }
        XCTAssertEqual(queue.readerReopenCount.withLock { $0 }, 2)
        XCTAssertEqual(try String(contentsOf: fixture.output.appendingPathComponent("secret"), encoding: .utf8), "protected")
        await session.close()
    }

    @MainActor func testPromiseCompletesExactlyOnceOnFailureAndDoesNotOverwrite() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let url = fixture.output.appendingPathComponent("existing")
        try Data("untouched".utf8).write(to: url)
        let error = try await write(ArchiveFilePromise(payload: fixture.payload("folder/a.txt", session: session, index: 0), session: session), to: url)
        XCTAssertNotNil(error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "untouched")
    }

    @MainActor func testPromiseCompletesExactlyOnceOnCancellation() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let progress = Progress(totalUnitCount: 0)
        progress.cancel()
        let url = fixture.output.appendingPathComponent("cancelled")
        let error = try await write(ArchiveFilePromise(payload: fixture.payload("folder", session: session, directory: true), session: session, progress: progress), to: url)
        XCTAssertTrue(error is CancellationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testGenerationMismatchResolvesPathUsingNewReader() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let payload = fixture.payload("folder/a.txt", session: session, index: 0)
        try fixture.writeZIP([("wrong.txt", "wrong"), ("folder/a.txt", "replacement")])
        try await session.reloadAfterMutation()
        XCTAssertEqual(session.generation, payload.generation + 1)
        let url = fixture.output.appendingPathComponent("resolved")
        let error = try await write(ArchiveFilePromise(payload: payload, session: session), to: url)
        XCTAssertNil(error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "replacement")
    }

    @MainActor func testGenerationMismatchMissingPathFailsExactlyOnce() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let payload = fixture.payload("folder/a.txt", session: session, index: 0)
        try fixture.writeZIP([("wrong.txt", "wrong")])
        try await session.reloadAfterMutation()
        let url = fixture.output.appendingPathComponent("missing")
        let error = try await write(ArchiveFilePromise(payload: payload, session: session), to: url)
        XCTAssertNotNil(error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testRegistrySweepsUncalledDragsAndPendingProviders() throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let registry = FilePromiseRegistry()
        let now = Date()
        weak var lastDelegate: ArchiveFilePromise?
        for drag in 0..<300 {
            let promise = try registry.register(payload: fixture.payload("folder/a.txt", session: session, index: 0), session: session, now: now)
            lastDelegate = promise.provider.delegate as? ArchiveFilePromise
            registry.began(sessionID: drag, promises: [promise.id])
            registry.ended(sessionID: drag, now: now)
        }
        _ = try registry.register(payload: fixture.payload("other.txt", session: session, index: 2), session: session, now: now)
        XCTAssertEqual(registry.count, 301)
        XCTAssertNotNil(lastDelegate)
        registry.sweep(now: now.addingTimeInterval(registry.gracePeriod + 1))
        XCTAssertEqual(registry.count, 0)
        XCTAssertNil(lastDelegate)
        XCTAssertEqual(registry.sessionCount, 0)
    }

    @MainActor func testRegisteringFiveThousandPromisesSweepsAtMostOncePerDrag() async throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("drag.zip")
        let names = (0..<5_000).map { "item-\($0)" }
        try ReleaseReviewFixtures.zip(names.map { ($0, Data()) }).write(to: archive)
        let session = try ArchiveSession(url: archive), registry = FilePromiseRegistry(), owner = UUID()
        let payloads = names.enumerated().map { index, name in
            ArchiveEntryPayload(archiveURL: archive, generation: session.generation,
                                entryIndex: index, path: name, isDirectory: false)
        }
        let start = ContinuousClock.now
        for payload in payloads { _ = try registry.register(payload: payload, session: session, owner: owner) }
        registry.beganPending(sessionID: 1, owner: owner)
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(registry.count, 5_000)
        XCTAssertLessThanOrEqual(registry.sweepCount, 2, "Drag initiation must not sweep once per promised row")
        XCTAssertLessThan(elapsed, .milliseconds(200), "Registering 5,000 promises must finish within 200 ms")
        registry.ended(sessionID: 1)
        registry.sweep(now: Date().addingTimeInterval(registry.gracePeriod + 1))
        XCTAssertEqual(registry.count, 0)
        await session.close()
    }

    @MainActor func testRegistrySweepChecksDeadlinesBeforeDelegateWriteState() async throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("deadlines.zip")
        try ReleaseReviewFixtures.zip([("item", Data())]).write(to: archive)
        let session = try ArchiveSession(url: archive), registry = FilePromiseRegistry(), now = Date()
        let payload = ArchiveEntryPayload(archiveURL: archive, generation: session.generation,
                                          entryIndex: 0, path: "item", isDirectory: false)
        _ = try registry.register(payload: payload, session: session, now: now)
        let activeDrag = try registry.register(payload: payload, session: session, now: now)
        registry.began(sessionID: 1, promises: [activeDrag.id])
        let before = registry.sweepWritingCheckCount
        registry.sweep(now: now.addingTimeInterval(registry.gracePeriod - 1))
        XCTAssertEqual(registry.sweepWritingCheckCount, before,
                       "Unexpired and active-drag promises must not take the delegate mutex")
        XCTAssertEqual(registry.count, 2)
        registry.sweep(now: now.addingTimeInterval(registry.gracePeriod + 1))
        XCTAssertEqual(registry.sweepWritingCheckCount - before, 1, "Only expired promises need a write-state check")
        XCTAssertEqual(registry.count, 1)
        registry.ended(sessionID: 1, now: now)
        registry.sweep(now: now.addingTimeInterval(registry.gracePeriod + 1))
        XCTAssertEqual(registry.count, 0)
        await session.close()
    }

    @MainActor func testRegistryRetainsAfterDragEndAndReleasesAfterWrite() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let registry = FilePromiseRegistry()
        let promise = try registry.register(payload: fixture.payload("folder/a.txt", session: session, index: 0), session: session)
        registry.began(sessionID: 1, promises: [promise.id])
        registry.ended(sessionID: 1)
        XCTAssertEqual(registry.count, 1)
        let delegate = try XCTUnwrap(promise.provider.delegate as? ArchiveFilePromise)
        let error = try await write(delegate, to: fixture.output.appendingPathComponent("file"))
        XCTAssertNil(error)
        XCTAssertEqual(registry.count, 0)
    }

    @MainActor func testRegistryWaitTracksOnlyItsSessionAndFinishesAfterSweep() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let other = try ArchiveSession(url: fixture.archive)
        let registry = FilePromiseRegistry(), now = Date()
        _ = try registry.register(payload: fixture.payload("folder/a.txt", session: session, index: 0),
                                  session: session, now: now)
        let pending = try registry.register(payload: fixture.payload("other.txt", session: other, index: 2),
                                            session: other, now: now)
        registry.began(sessionID: 1, promises: [pending.id])
        var finished = false
        let wait = Task {
            await registry.waitUntilNoPromises(for: session)
            finished = true
        }
        await Task.yield()
        XCTAssertFalse(finished)
        registry.sweep(now: now.addingTimeInterval(registry.gracePeriod + 1))
        try await scenarioWait { finished }
        await wait.value
        XCTAssertEqual(registry.count, 1, "他の session の進行中の drag は待たない")
        await registry.waitUntilNoPromises(for: session)
        registry.ended(sessionID: 1, now: now)
        registry.sweep(now: now.addingTimeInterval(registry.gracePeriod + 1))
        await session.close()
        await other.close()
    }

    @MainActor func testInvalidPromiseTypeFallsBackToData() {
        // item は data/directory のどちらにも準拠しない。url は data に準拠するため使わない。
        // この三つの期待値は LaunchServices が利用できない環境でも変わらない。
        XCTAssertEqual(ArchiveFilePromise.validatedType(.item), .data)
        XCTAssertEqual(ArchiveFilePromise.validatedType(.folder), .folder)
        XCTAssertEqual(ArchiveFilePromise.validatedType(.data), .data)
    }

    @MainActor func testCopyPublishesExistingRealURLsAndPlainTextOnNamedPasteboard() async throws {
        let fixture = try Fixture()
        try fixture.writeZIP([("folder/a.txt", "hello"), ("folder/deep/b.txt", "world"),
                              ("other.txt", "other"), ("third.txt", "third")])
        let session = try ArchiveSession(url: fixture.archive)
        let pasteboard = NSPasteboard(name: .init("KaitoFinderTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else {
            throw XCTSkip("この実行環境では名前付き pasteboard サービスへ書き込めません")
        }
        let allPayloads = [fixture.payload("folder", session: session, directory: true),
                           fixture.payload("other.txt", session: session, index: 2),
                           fixture.payload("third.txt", session: session, index: 3)]
        for count in [2, 3] {
            let expectedPaths = Array(["folder", "other.txt", "third.txt"].prefix(count))
            let urls = try await ArchiveCopyOut.copy(Array(allPayloads.prefix(count)), from: session, to: pasteboard,
                progress: Progress(totalUnitCount: 0),
                temporaryDirectory: ExtractionTemporaryDirectory(root: fixture.parent.appendingPathComponent("temp")))
            let read = try XCTUnwrap(pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])
            XCTAssertEqual(read.count, count)
            XCTAssertEqual(read, urls)
            // 全体の連結結果と個々の項目を両方検査し、後続パスの二重掲載を防ぐ。
            XCTAssertEqual(pasteboard.string(forType: .string), expectedPaths.joined(separator: "\n"))
            let items = try XCTUnwrap(pasteboard.pasteboardItems)
            XCTAssertEqual(items.count, count)
            XCTAssertEqual(items.compactMap { $0.string(forType: .string) }, expectedPaths)
            XCTAssertEqual(items.compactMap { $0.string(forType: .fileURL) }, urls.map(\.absoluteString))
            let folder = try XCTUnwrap(read.first)
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8), "hello")
            XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("deep/b.txt"), encoding: .utf8), "world")
            for (url, expected) in zip(read.dropFirst(), ["other", "third"]) {
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), expected)
            }
            XCTAssertFalse(pasteboard.types?.contains(NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")) ?? true)
        }
    }

    @MainActor func testCancelledCopyPreservesPasteboardWithoutPartialURLs() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let pasteboard = NSPasteboard(name: .init("KaitoFinderTests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else {
            throw XCTSkip("この実行環境では名前付き pasteboard サービスへ書き込めません")
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let changeCount = pasteboard.changeCount
        let progress = Progress(totalUnitCount: 0)
        do {
            _ = try await ArchiveCopyOut.copy([fixture.payload("folder", session: session, directory: true)],
                from: session, to: pasteboard, progress: progress,
                temporaryDirectory: ExtractionTemporaryDirectory(root: fixture.parent.appendingPathComponent("temp")),
                didProcess: { _ in progress.cancel() })
            XCTFail("取消しが成功扱いになりました")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 1)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertNil(pasteboard.string(forType: .fileURL))
    }

    func testCopyPreparationEagerlyCreatesFilesAndSurvivesHelperLifetime() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let prepared = try await ArchiveCopyOut.prepare(
            [fixture.payload("folder", session: session, directory: true), fixture.payload("other.txt", session: session, index: 2)],
            from: session, progress: Progress(totalUnitCount: 0),
            temporaryDirectory: ExtractionTemporaryDirectory(root: fixture.parent.appendingPathComponent("temp")))
        XCTAssertEqual(prepared.paths, ["folder", "other.txt"])
        XCTAssertEqual(prepared.urls.count, 2)
        XCTAssertEqual(try String(contentsOf: prepared.urls[0].appendingPathComponent("a.txt"), encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: prepared.urls[0].appendingPathComponent("deep/b.txt"), encoding: .utf8), "world")
        XCTAssertEqual(try String(contentsOf: prepared.urls[1], encoding: .utf8), "other")
    }

    func testCopyPreparationCancellationStopsBeforeReturningURLs() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let progress = Progress(totalUnitCount: 0)
        let temp = fixture.parent.appendingPathComponent("temp")
        do {
            _ = try await ArchiveCopyOut.prepare([fixture.payload("folder", session: session, directory: true)],
                from: session, progress: progress, temporaryDirectory: ExtractionTemporaryDirectory(root: temp),
                didProcess: { _ in progress.cancel() })
            XCTFail("部分的な URL が成功として返されました")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(progress.completedUnitCount, 5)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 1)
        let staged = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("folder/a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.appendingPathComponent("folder/deep/b.txt").path))
    }

    @MainActor func testFolderPromiseReportsUnsafeChildrenRatherThanSilentlyDroppingThem() async throws {
        let fixture = try Fixture()
        try fixture.writeZIP([("folder/good", "ok"), ("folder/../escape", "bad")])
        let session = try ArchiveSession(url: fixture.archive)
        let destination = fixture.output.appendingPathComponent("folder")
        let error = try await write(ArchiveFilePromise(payload: fixture.payload("folder", session: session, directory: true), session: session), to: destination)
        XCTAssertNotNil(error)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("good"), encoding: .utf8), "ok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("escape").path))
    }

    @MainActor func testRegistrySweepKeepsAnActiveWriteUntilCompletion() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let registry = FilePromiseRegistry()
        let promise = try registry.register(payload: fixture.payload("folder/a.txt", session: session, index: 0), session: session)
        registry.began(sessionID: 1, promises: [promise.id])
        registry.ended(sessionID: 1)
        let delegate = try XCTUnwrap(promise.provider.delegate as? ArchiveFilePromise)
        let gate = DispatchSemaphore(value: 0)
        let calls = Mutex(0)
        let error = Mutex<(any Error)?>(nil)
        delegate.filePromiseProvider(promise.provider, writePromiseTo: fixture.output.appendingPathComponent("file")) { @Sendable failure in
            error.withLock { $0 = failure }
            calls.withLock { $0 += 1 }
            gate.wait()
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while calls.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        registry.sweep(now: Date().addingTimeInterval(registry.gracePeriod + 1))
        XCTAssertEqual(registry.count, 1)
        gate.signal()
        while registry.count > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertNil(error.withLock { $0 })
        XCTAssertEqual(registry.count, 0)
    }

    @MainActor func testRegistryRetainsOverlappingWritesUntilEveryCompletion() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let registry = FilePromiseRegistry(), gate = ScenarioGate(), secondGate = ScenarioGate()
        defer { gate.release(); secondGate.release() }
        let writes = Mutex(0)
        let promise = try registry.register(payload: fixture.payload("folder/a.txt", session: session, index: 0),
            session: session, didWrite: { _ in
                if writes.withLock({ $0 += 1; return $0 }) == 1 { gate.pauseOnce() }
                else { secondGate.pauseOnce() }
            })
        let delegate = try XCTUnwrap(promise.provider.delegate as? ArchiveFilePromise)
        let completions = Mutex(0), errors = Mutex<[String]>([])
        for name in ["first", "second"] {
            delegate.filePromiseProvider(promise.provider, writePromiseTo: fixture.output.appendingPathComponent(name)) { @Sendable error in
                if let error { errors.withLock { $0.append(String(describing: error)) } }
                completions.withLock { $0 += 1 }
            }
        }
        try await scenarioWait { gate.isEntered }
        XCTAssertEqual(completions.withLock { $0 }, 0)
        XCTAssertFalse(secondGate.isEntered)
        gate.release()
        try await scenarioWait { secondGate.isEntered && completions.withLock { $0 } == 1 }
        // completion は registry の main actor callback より先。callback が進む機会も与える。
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(delegate.isWriting)
        XCTAssertTrue(registry.hasActiveWrites)
        XCTAssertEqual(registry.count, 1)
        registry.sweep(now: Date().addingTimeInterval(registry.gracePeriod + 1))
        XCTAssertEqual(registry.count, 1)
        secondGate.release()
        try await scenarioWait { completions.withLock { $0 } == 2 && registry.count == 0 }
        XCTAssertFalse(delegate.isWriting)
        XCTAssertTrue(errors.withLock { $0.isEmpty })
        for name in ["first", "second"] {
            XCTAssertEqual(try Data(contentsOf: fixture.output.appendingPathComponent(name)), Data("hello".utf8))
        }
    }

    @MainActor func testFailedMutationReloadInvalidatesOldPromises() async throws {
        let fixture = try Fixture()
        let session = try ArchiveSession(url: fixture.archive)
        let payload = fixture.payload("folder/a.txt", session: session, index: 0)
        try FileManager.default.removeItem(at: fixture.archive)
        do {
            try await session.reloadAfterMutation()
            XCTFail("存在しない書庫を読み直しました")
        } catch { }
        XCTAssertEqual(session.generation, payload.generation + 1)
        let destination = fixture.output.appendingPathComponent("stale")
        let error = try await write(ArchiveFilePromise(payload: payload, session: session), to: destination)
        XCTAssertNotNil(error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

}
