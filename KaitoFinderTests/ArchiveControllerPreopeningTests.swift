import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveControllerPreopeningTests: XCTestCase {
    @MainActor private func makeController() throws -> ArchiveDocumentController {
        // NSDocumentController.init() は、指定したサブクラスでなく既存の共有インスタンスを返す。
        let controller = try XCTUnwrap(NSDocumentController.shared as? ArchiveDocumentController)
        let delay = controller.openingRevealDelay, recordsRecents = controller.recordsRecentDocuments
        let willStart = controller.preopenWillStart, didFinish = controller.preopenDidFinish
        let willMakeDocument = controller.preopenWillMakeDocument
        controller.recordsRecentDocuments = false
        addTeardownBlock { @MainActor in
            controller.openingRevealDelay = delay
            controller.recordsRecentDocuments = recordsRecents
            controller.preopenWillStart = willStart
            controller.preopenDidFinish = didFinish
            controller.preopenWillMakeDocument = willMakeDocument
        }
        return controller
    }

    @MainActor private func open(_ controller: NSDocumentController, _ url: URL,
                                 display: Bool = false) async -> (NSDocument?, Bool, NSError?) {
        await withCheckedContinuation { continuation in
            controller.openDocument(withContentsOf: url, display: display) { document, wasOpen, error in
                continuation.resume(returning: (document, wasOpen, error.map { $0 as NSError }))
            }
        }
    }

    @MainActor private func openTogether(_ controller: NSDocumentController, _ requests: [(URL, Bool)]) async
        -> [(NSDocument?, Bool, NSError?)] {
        await withCheckedContinuation { continuation in
            var results: [(NSDocument?, Bool, NSError?)?] = Array(repeating: nil, count: requests.count)
            for (index, request) in requests.enumerated() {
                controller.openDocument(withContentsOf: request.0, display: request.1) { document, wasOpen, error in
                    results[index] = (document, wasOpen, error.map { $0 as NSError })
                    if results.allSatisfy({ $0 != nil }) { continuation.resume(returning: results.compactMap { $0 }) }
                }
            }
        }
    }

    @MainActor private func cleanUp(_ document: ArchiveDocument, in directory: ArchiveTestDirectory) {
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            withExtendedLifetime(directory) {}
        }
    }

    @MainActor func testHundredThousandEntryZIPKeepsMainThreadResponsiveAndParsesOnce() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            for i in range(100_000): z.writestr(f'entry-{i:06d}.txt', b'')
        """)
        let controller = try makeController()
        let samples = Mutex((stop: false, count: 0, worst: 0.0))
        let stopped = expectation(description: "latency sampler stopped")
        DispatchQueue.global(qos: .userInitiated).async {
            while !samples.withLock({ $0.stop }) {
                let start = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.sync {}
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                samples.withLock { $0.count += 1; $0.worst = max($0.worst, elapsed) }
                Thread.sleep(forTimeInterval: 0.001)
            }
            stopped.fulfill()
        }
        defer { samples.withLock { $0.stop = true } }
        try await waitUntil { samples.withLock { $0.count > 0 } }
        let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        let (opened, wasOpen, error) = await open(controller, fixture.archive)
        samples.withLock { $0.stop = true }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertNil(error)
        XCTAssertFalse(wasOpen)
        let document = try XCTUnwrap(opened as? ArchiveDocument)
        cleanUp(document, in: fixture.directory)
        let session = try XCTUnwrap(document.session)
        let entries = await session.entries()
        XCTAssertEqual(entries.count, 100_000)
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - before, 1)
        XCTAssertGreaterThan(samples.withLock { $0.count }, 2)
        XCTAssertLessThan(samples.withLock { $0.worst }, 100, "main queue latency in milliseconds")
    }

    @MainActor func testConcurrentRequestsJoinOneParseAndPreserveAlreadyOpenFlag() async throws {
        preserveArchiveWindowFrame()
        let fixture = try ScenarioFixture(), controller = try makeController()
        let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        let results = await openTogether(controller, [(fixture.archive, false), (fixture.archive, true)])
        let (one, firstWasOpen, firstError) = results[0]
        let (two, secondWasOpen, secondError) = results[1]
        XCTAssertNil(firstError)
        XCTAssertNil(secondError)
        XCTAssertTrue(one === two)
        XCTAssertFalse(firstWasOpen)
        XCTAssertTrue(secondWasOpen)
        let document = try XCTUnwrap(one as? ArchiveDocument)
        cleanUp(document, in: fixture.directory)
        XCTAssertNotNil(document.session)
        XCTAssertEqual(document.windowControllers.count, 1)
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - before, 1)
        let (again, alreadyOpen, error) = await open(controller, fixture.archive)
        XCTAssertTrue(again === document)
        XCTAssertTrue(alreadyOpen)
        XCTAssertNil(error)
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - before, 1)
    }

    @MainActor func testConcurrentSplitMembersJoinAtGate() async throws {
        let fixture = try SplitArchiveFixture(volumeCount: 3), controller = try makeController()
        let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        let results = await openTogether(controller, [(fixture.volumes[1], false), (fixture.volumes[2], false)])
        let (one, _, firstError) = results[0]
        let (two, wasOpen, secondError) = results[1]
        XCTAssertNil(firstError)
        XCTAssertNil(secondError)
        XCTAssertTrue(one === two)
        XCTAssertTrue(wasOpen)
        let document = try XCTUnwrap(one as? ArchiveDocument)
        cleanUp(document, in: fixture.directory)
        XCTAssertEqual(document.fileURL, fixture.archive)
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - before, 1)
    }

    @MainActor func testLoadingPanelRevealsAfterDelayAndFinishesWithOpen() async throws {
        let fixture = try ScenarioFixture(), controller = try makeController(), gate = AsyncGate()
        controller.openingRevealDelay = .milliseconds(100)
        controller.preopenWillStart = { try await gate.wait() }
        let task = Task { await open(controller, fixture.archive) }
        try await waitUntil { controller.openingSheet(for: fixture.archive) != nil }
        let sheet = try XCTUnwrap(controller.openingSheet(for: fixture.archive))
        let panel = try XCTUnwrap(sheet.window)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 0)
        try await waitUntil { panel.isVisible }
        XCTAssertEqual(panel.alphaValue, 1)
        XCTAssertTrue(sheet.indicator.isIndeterminate)
        XCTAssertTrue(sheet.statusLabel.isHidden)
        XCTAssertEqual(panel.title, ArchiveProgressOperation.openingArchive(fixture.archive.lastPathComponent).title())
        await gate.release()
        let (opened, _, error) = await task.value
        XCTAssertNil(error)
        cleanUp(try XCTUnwrap(opened as? ArchiveDocument), in: fixture.directory)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(controller.openingSheet(for: fixture.archive))
    }

    @MainActor func testFastOpenNeverRevealsLoadingPanel() async throws {
        let fixture = try ScenarioFixture(), controller = try makeController(), gate = AsyncGate()
        controller.openingRevealDelay = .milliseconds(500)
        controller.preopenWillStart = { try await gate.wait() }
        let task = Task { await open(controller, fixture.archive) }
        try await waitUntil { controller.openingSheet(for: fixture.archive) != nil }
        let panel = try XCTUnwrap(controller.openingSheet(for: fixture.archive)?.window)
        let revealed = Mutex(false)
        let observation = panel.observe(\.alphaValue, options: [.new]) { _, change in
            if change.newValue == 1 { revealed.withLock { $0 = true } }
        }
        await gate.release()
        let (opened, _, error) = await task.value
        XCTAssertNil(error)
        cleanUp(try XCTUnwrap(opened as? ArchiveDocument), in: fixture.directory)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(revealed.withLock { $0 })
        withExtendedLifetime(observation) {}
    }

    @MainActor func testJoinedCancellationCompletesEveryRequestWithSameError() async throws {
        let fixture = try ScenarioFixture(), controller = try makeController(), gate = AsyncGate()
        controller.preopenWillStart = { try await gate.wait() }
        let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        let failures: [NSError?] = await withCheckedContinuation { continuation in
            var failures: [NSError?] = []
            for _ in 0..<2 {
                controller.openDocument(withContentsOf: fixture.archive, display: false) { document, wasOpen, error in
                    XCTAssertNil(document)
                    XCTAssertFalse(wasOpen)
                    failures.append(error.map { $0 as NSError })
                    if failures.count == 2 { continuation.resume(returning: failures) }
                }
            }
            controller.openingSheet(for: fixture.archive)?.cancelExtraction(nil)
        }
        XCTAssertEqual(failures[0]?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(failures[0]?.code, NSUserCancelledError)
        XCTAssertTrue(failures[0] === failures[1])
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 }, before)
    }

    @MainActor func testInvalidArchiveReportsReadError() async throws {
        let directory = try ArchiveTestDirectory(), controller = try makeController()
        let url = directory.url.appendingPathComponent("invalid.zip")
        try Data("not a zip".utf8).write(to: url)
        let (document, wasOpen, error) = await open(controller, url)
        XCTAssertNil(document)
        XCTAssertFalse(wasOpen)
        let failure = try XCTUnwrap(error)
        XCTAssertEqual(failure.domain, "com.shunnag.KaitoFinder.document")
        XCTAssertEqual(failure.code, 1)
        let reason = ArchiveAlertText.informativeText(ArchiveErrorText.describe(KaitoError.unsupportedFormat))
        XCTAssertTrue(failure.localizedDescription.contains(reason))
        XCTAssertEqual(failure.localizedFailureReason, reason)
        XCTAssertNotNil(failure.userInfo[NSUnderlyingErrorKey])
    }

    @MainActor func testCancelCompressedTarClosesUnlinkedStagingBeforeCompletion() async throws {
        let fixture = try ScenarioFixture(script: """
        class Zeros:
            def read(self, n): return bytes(n)
        with tarfile.open(p, 'w:bz2') as t:
            entry = tarfile.TarInfo('zeros.bin')
            entry.size = 384 * 1024 * 1024
            t.addfile(entry, Zeros())
        """, suffix: "tar.bz2")
        let controller = try makeController()
        controller.openingRevealDelay = .zero
        let before = Self.unlinkedStagingFiles()
        let task = Task { await open(controller, fixture.archive) }
        defer { controller.openingSheet(for: fixture.archive)?.cancelExtraction(nil) }
        var staging: Set<UInt64> = []
        try await waitUntil(timeout: .seconds(30)) {
            staging = Self.unlinkedStagingFiles().subtracting(before)
            return !staging.isEmpty
        }
        let sheet = try XCTUnwrap(controller.openingSheet(for: fixture.archive))
        sheet.cancelExtraction(nil)
        let (document, wasOpen, error) = await task.value
        XCTAssertNil(document)
        XCTAssertFalse(wasOpen)
        XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error?.code, NSUserCancelledError)
        XCTAssertTrue(controller.documents.isEmpty)
        XCTAssertTrue(Self.unlinkedStagingFiles().isDisjoint(with: staging))
        XCTAssertNil(controller.openingSheet(for: fixture.archive))
        XCTAssertFalse(sheet.window?.isVisible ?? true)
    }

    private static func unlinkedStagingFiles() -> Set<UInt64> {
        // KaitoKit の staging は直ちに unlink されるので、保持 fd の inode を追う。
        var result: Set<UInt64> = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? [] {
            guard let fd = Int32(name) else { continue }
            var info = stat()
            if fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
               info.st_nlink == 0, info.st_size >= 64 * 1024 * 1024 { result.insert(info.st_ino) }
        }
        return result
    }

    @MainActor func testIdentityReplacementFallsBackAndClosesStaleSession() async throws {
        let fixture = try ScenarioFixture(), controller = try makeController()
        let replacement = try fixture.pythonArchive("replacement.zip", script:
            "with zipfile.ZipFile(p, 'w') as z: z.writestr('replacement.txt', b'new')")
        var stale: ArchiveSession?
        controller.preopenDidFinish = { contents in
            stale = contents.sessionForTesting
            try Data(contentsOf: replacement).write(to: fixture.archive, options: .atomic)
        }
        let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        let (opened, _, error) = await open(controller, fixture.archive)
        XCTAssertNil(error)
        let document = try XCTUnwrap(opened as? ArchiveDocument)
        cleanUp(document, in: fixture.directory)
        let session = try XCTUnwrap(document.session)
        XCTAssertFalse(session === stale)
        let entries = await session.entries()
        XCTAssertEqual(entries.map(\.name), ["replacement.txt"])
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - before, 2)
        await assertClosed(try XCTUnwrap(stale))
    }

    @MainActor func testControllerCreationErrorClosesUnconsumedSession() async throws {
        let fixture = try ScenarioFixture(), controller = try makeController()
        var creations = 0
        controller.preopenWillMakeDocument = { url, _ in
            creations += 1
            XCTAssertEqual(url, fixture.archive)
            XCTAssertNotNil(ArchiveDocument.preopenedArchive.get())
            throw NSError(domain: "OpeningTest", code: 42)
        }
        var unused: ArchiveSession?
        controller.preopenDidFinish = { unused = $0.sessionForTesting }
        let (document, wasOpen, error) = await open(controller, fixture.archive)
        XCTAssertEqual(creations, 1)
        XCTAssertNil(document)
        XCTAssertFalse(wasOpen)
        XCTAssertEqual(error?.domain, "OpeningTest")
        XCTAssertEqual(error?.code, 42)
        XCTAssertTrue(controller.documents.isEmpty)
        await assertClosed(try XCTUnwrap(unused))
    }

    @MainActor func testCancellationAfterPreopenClosesUnconsumedSession() async throws {
        let fixture = try ScenarioFixture(), controller = try makeController()
        var unused: ArchiveSession?
        controller.preopenDidFinish = { [weak controller] in
            unused = $0.sessionForTesting
            let sheet = try XCTUnwrap(controller?.openingSheet(for: fixture.archive))
            // Task への通知が遅れた状態を固定し、Progress の取消しだけで止まることを確かめる。
            sheet.progress.cancellationHandler = nil
            sheet.cancelExtraction(nil)
            XCTAssertTrue(sheet.progress.isCancelled)
        }
        let (document, wasOpen, error) = await open(controller, fixture.archive)
        XCTAssertNil(document)
        XCTAssertFalse(wasOpen)
        XCTAssertEqual(error?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(error?.code, NSUserCancelledError)
        XCTAssertTrue(controller.documents.isEmpty)
        await assertClosed(try XCTUnwrap(unused))
    }

    @MainActor func testLockedControllerOpenKeepsUnlockUI() async throws {
        preserveArchiveWindowFrame()
        let directory = try ArchiveTestDirectory(), controller = try makeController()
        let archive = directory.url.appendingPathComponent("locked.7z")
        try Data("secret".utf8).write(to: directory.url.appendingPathComponent("secret.txt"))
        try directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-pfixture-password", "-mhe=on", archive.path, "secret.txt"])
        let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        let (opened, wasOpen, error) = await open(controller, archive, display: true)
        XCTAssertNil(error)
        XCTAssertFalse(wasOpen)
        let document = try XCTUnwrap(opened as? ArchiveDocument)
        cleanUp(document, in: directory)
        XCTAssertTrue(document.isPasswordLocked)
        XCTAssertEqual(document.lockedURL, archive)
        XCTAssertNil(document.session)
        let window = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        XCTAssertEqual(window.unlockButton.keyEquivalent, "\r")
        XCTAssertTrue(window.outlineView.enclosingScrollView?.isHidden ?? false)
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - before, 1)
    }

    @MainActor func testAdoptedOptionsFollowDocumentsOwnPreferences() async throws {
        let fixture = try ScenarioFixture(), suite = try ArchivePreferencesTestDefaults()
        let store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.zipLevel = 2
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        cleanUp(document, in: fixture.directory)
        let contents = try await ArchiveDocument.preopen(fixture.archive, preferences: store.preferences,
            metadataStore: .shared, recoveryIndex: .shared)
        let session = try XCTUnwrap(contents.sessionForTesting)
        let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        try ArchiveDocument.preopenedArchive.withValue(.success(contents)) {
            try document.read(from: fixture.archive, ofType: "public.zip-archive")
        }
        await contents.close()
        XCTAssertTrue(document.session === session)
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 }, before)
        XCTAssertEqual(session.writerOptions(.zip).deflateLevel, 2)
        store.preferences.zipLevel = 9
        store.preferences.excludesHiddenFiles = true
        let level = await Task.detached { session.writerOptions(.zip).deflateLevel }.value
        XCTAssertEqual(level, 9)
        let directory = fixture.directory.url.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in ["visible.txt", ".hidden"] { try Data(name.utf8).write(to: directory.appendingPathComponent(name)) }
        _ = try await session.append(urls: [directory], to: "", progress: Progress())
        let names = await session.entries().map(\.name)
        XCTAssertTrue(names.contains("input/visible.txt"))
        XCTAssertFalse(names.contains("input/.hidden"))
    }

    @MainActor func testControllerSessionObservesPreferencesAfterOpening() async throws {
        let fixture = try ScenarioFixture(), controller = try makeController(), store = ArchivePreferencesStore.shared
        let previous = store.preferences
        defer { store.preferences = previous }
        store.preferences.zipLevel = 2
        let (opened, _, error) = await open(controller, fixture.archive)
        XCTAssertNil(error)
        let document = try XCTUnwrap(opened as? ArchiveDocument)
        cleanUp(document, in: fixture.directory)
        let session = try XCTUnwrap(document.session)
        store.preferences.zipLevel = 8
        let level = await Task.detached { session.writerOptions(.zip).deflateLevel }.value
        XCTAssertEqual(level, 8)
    }

    @MainActor func testDeferredInitialDisplayInstallsPendingSnapshotAndTree() async throws {
        preserveArchiveWindowFrame()
        let fixture = try ScenarioFixture(), suite = try ArchivePreferencesTestDefaults()
        let store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.saveBehavior = .onSave
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        cleanUp(document, in: fixture.directory)
        try document.read(from: fixture.archive, ofType: "public.zip-archive")
        let session = try XCTUnwrap(document.session)
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        try await waitUntil { session.pendingReadSnapshot != nil && controller.outlineView.numberOfRows == 1 }
        XCTAssertEqual(session.pendingReadSnapshot?.entries.map(\.name), ["original.txt"])
        XCTAssertEqual((controller.outlineView.item(atRow: 0) as? EntryNode)?.path, "original.txt")
        XCTAssertTrue(document.pendingChanges.isEmpty)
    }

    @MainActor func testMismatchedURLSaveBehaviorAndStoresAlwaysParseFresh() async throws {
        let fixture = try ScenarioFixture(), suite = try ArchivePreferencesTestDefaults()
        let other = try fixture.pythonArchive("other.zip", script:
            "with zipfile.ZipFile(p, 'w') as z: z.writestr('other.txt', b'other')")
        for mismatch in 0..<4 {
            let store = ArchivePreferencesStore(defaults: suite.defaults)
            store.preferences.saveBehavior = mismatch == 1 ? .onSave : .immediate
            let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store,
                volumeMetadataStore: mismatch == 2 ? ArchiveVolumeMetadataStore(fileURL: fixture.root.appendingPathComponent("metadata")) : .shared,
                volumeRecoveryIndex: mismatch == 3 ? RecoverableWorkIndex(fileURL: fixture.root.appendingPathComponent("recovery")) : .shared)
            cleanUp(document, in: fixture.directory)
            let contents = try await ArchiveDocument.preopen(fixture.archive, preferences: ArchivePreferences(),
                metadataStore: .shared, recoveryIndex: .shared)
            let unused = try XCTUnwrap(contents.sessionForTesting)
            let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
            try ArchiveDocument.preopenedArchive.withValue(.success(contents)) {
                try document.read(from: mismatch == 0 ? other : fixture.archive, ofType: "public.zip-archive")
            }
            await contents.close()
            XCTAssertFalse(document.session === unused)
            XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - before, 1)
            await assertClosed(unused)
        }
    }

    private func assertClosed(_ session: ArchiveSession, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await session.extractionReader()
            XCTFail("unused session must be closed", file: file, line: line)
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)", file: file, line: line) }
    }
}
