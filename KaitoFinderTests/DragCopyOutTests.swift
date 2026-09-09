import AppKit
import Darwin
import KaitoKit
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import KaitoFinder

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

    private final class Fixture {
        let parent: URL
        let archive: URL
        let output: URL
        init(tar: Bool = false) throws {
            parent = FileManager.default.temporaryDirectory.appendingPathComponent("KaitoFinder-DragTests-" + UUID().uuidString)
            archive = parent.appendingPathComponent(tar ? "fixture.tar" : "fixture.zip")
            output = parent.appendingPathComponent("out")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            guard chmod(parent.path, 0o700) == 0 else { throw ExtractionFailure.system(errno) }
            if tar {
                try run("""
                with tarfile.open(p, 'w', format=tarfile.USTAR_FORMAT) as t:
                    d = tarfile.TarInfo('outer/folder/'); d.type = tarfile.DIRTYPE; d.mode = 0o755; t.addfile(d)
                    f = tarfile.TarInfo('outer/folder/a.txt'); f.size = 5; t.addfile(f, io.BytesIO(b'hello'))
                    h = tarfile.TarInfo('outer/folder/deep/link'); h.type = tarfile.LNKTYPE
                    h.linkname = 'outer/folder/a.txt'; t.addfile(h)
                    f = tarfile.TarInfo('outside'); f.size = 3; t.addfile(f, io.BytesIO(b'out'))
                """)
            } else { try writeZIP([("folder/a.txt", "hello"), ("folder/deep/b.txt", "world"), ("other.txt", "other")]) }
        }
        func run(_ script: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", "import sys, zipfile, tarfile, io\np=sys.argv[1]\n" + script, archive.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ExtractionFailure.refused("fixture 生成失敗") }
        }
        func writeZIP(_ entries: [(String, String)]) throws {
            let pairs = entries.map { "('\($0.0)', '\($0.1)')" }.joined(separator: ",")
            // 置換で新しい inode を作り、旧 reader の reopen との差を検査する。
            try run("import os\nwith zipfile.ZipFile(p + '.new', 'w') as z:\n for n, v in [\(pairs)]: z.writestr(n, v)\nos.replace(p + '.new', p)")
        }
        deinit {
            try? ExtractionTemporaryDirectory(root: parent).sweepOnLaunch()
            try? FileManager.default.removeItem(at: parent)
        }
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
        XCTAssertEqual(progress.completedUnitCount, 1)
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
        XCTAssertEqual(progress.completedUnitCount, 1)
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
