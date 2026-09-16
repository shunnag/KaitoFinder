import AppKit
import CryptoKit
import GyoshukuKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ApplicationTerminationTests: XCTestCase {
    @MainActor private func delegate(documents: [ArchiveDocument]) throws -> AppDelegate {
        let directory = try ArchiveTestDirectory(), suite = try ArchivePreferencesTestDefaults()
        let vault = ArchivePasswordVault(key: SymmetricKey(size: .bits256), directory: directory.url.appendingPathComponent("vault"))
        let delegate = AppDelegate(passwordVault: vault, preferencesStore: ArchivePreferencesStore(defaults: suite.defaults))
        delegate.terminationDocuments = { documents }
        delegate.quitConfirmation = { XCTFail("操作がないのに終了を確認しました"); return false }
        delegate.terminationReply = { _ in XCTFail("遅延していない終了に返答しました") }
        addTeardownBlock { @MainActor in withExtendedLifetime((directory, suite)) {} }
        return delegate
    }

    @MainActor private func pausedExtraction() async throws
        -> (ArchiveDocument, ArchiveWindowController, URL, ScenarioGate, Task<Void, Never>) {
        let fixture = try ScenarioFixture(script:
            "with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as z: z.writestr('large.bin', b'x' * (4 * 1024 * 1024))")
        let (document, controller) = try await scenarioDocument(fixture)
        let session = try XCTUnwrap(document.session), out = try fixture.folder("out"), gate = ScenarioGate()
        let tree = EntryNode.tree(from: await session.entries())
        let payloads = ArchiveEntryPayload.payloads(for: tree.children, archiveURL: fixture.archive, generation: document.generation)
        controller.startExtraction(payloads, session: session, destination: out, showProgress: false, entryCount: 1,
                                   didWrite: { _ in gate.pauseOnce() })
        let task = try XCTUnwrap(controller.extractionTask)
        addTeardownBlock { @MainActor in
            gate.release()
            controller.cancelExtraction()
            await task.value
        }
        try await scenarioWait { gate.isEntered }
        XCTAssertTrue(document.hasWorkInFlight)
        XCTAssertTrue(controller.hasWorkInFlight)
        let output = out.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        return (document, controller, output, gate, task)
    }

    @MainActor private func pausedPromiseWrite(completionHandler: @escaping @Sendable (Error?) -> Void) async throws
        -> (ArchiveDocument, FilePromiseRegistry, ArchiveFilePromise, URL, ScenarioGate) {
        let fixture = try ScenarioFixture(script:
            "with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as z: z.writestr('large.bin', b'x' * (4 * 1024 * 1024))")
        let (document, controller) = try await scenarioDocument(fixture)
        let session = try XCTUnwrap(document.session), out = try fixture.folder("out"), gate = ScenarioGate()
        let registry = FilePromiseRegistry(automaticallySweeps: false)
        let payload = ArchiveEntryPayload(archiveURL: fixture.archive, generation: session.generation,
            entryIndex: 0, path: "large.bin", isDirectory: false)
        let promise = try registry.register(payload: payload, session: session, didWrite: { _ in gate.pauseOnce() })
        let writer = try XCTUnwrap(promise.provider.delegate as? ArchiveFilePromise)
        let output = out.appendingPathComponent("large.bin")
        addTeardownBlock { @MainActor in
            writer.progress.cancel()
            gate.release()
            try await self.scenarioWait { !writer.isWriting }
            registry.sweep(now: Date().addingTimeInterval(registry.gracePeriod + 1))
        }
        writer.filePromiseProvider(promise.provider, writePromiseTo: output, completionHandler: completionHandler)
        try await scenarioWait { gate.isEntered }
        XCTAssertTrue(registry.hasActiveWrites)
        XCTAssertFalse(document.hasWorkInFlight)
        XCTAssertFalse(controller.hasWorkInFlight)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertLessThan(try Data(contentsOf: output).count, 4 * 1024 * 1024)
        return (document, registry, writer, output, gate)
    }

    // J-3a: drag promise だけが書き込み中でも、取消しと partial の回収後に一度だけ返答する。
    @MainActor func testConfirmedQuitWaitsForPromiseCancellationAndRemovesPartialFile() async throws {
        let completion = Mutex<(calls: Int, error: (any Error)?)>((0, nil))
        let (document, registry, writer, output, gate) = try await pausedPromiseWrite { error in
            completion.withLock { $0.calls += 1; $0.error = error }
        }
        let delegate = try delegate(documents: [document])
        delegate.terminationPromiseRegistry = registry
        var confirmations = 0, replies: [Bool] = []
        let replied = expectation(description: "promise の取消しと後始末後に終了へ返答")
        replied.assertForOverFulfill = true
        delegate.quitConfirmation = { confirmations += 1; return true }
        delegate.terminationReply = { answer in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(registry.hasActiveWrites)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(completion.withLock { $0.calls }, 1)
            XCTAssertTrue(completion.withLock { $0.error is CancellationError })
            replies.append(answer)
            replied.fulfill()
        }
        addTeardownBlock { @MainActor in gate.release(); await delegate.terminationTask?.value }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(writer.progress.isCancelled)
        XCTAssertTrue(registry.hasActiveWrites)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        // main actor に後始末を開始させても、gate が閉じている間は終了へ返答しない。
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(replies.isEmpty)
        gate.release()
        await fulfillment(of: [replied], timeout: 5)
        await delegate.terminationTask?.value
        try await scenarioWait { !registry.hasActiveWrites }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(completion.withLock { $0.calls }, 1)
        XCTAssertTrue(completion.withLock { $0.error is CancellationError })
        XCTAssertEqual(replies, [true])
    }

    // J-3a: 終了を断った場合は promise を取り消さず、4 MiB すべてを渡す。
    @MainActor func testDecliningQuitLetsPromiseWriteFinishWithAllBytes() async throws {
        let completion = Mutex<(calls: Int, error: (any Error)?)>((0, nil))
        let (document, registry, writer, output, gate) = try await pausedPromiseWrite { error in
            completion.withLock { $0.calls += 1; $0.error = error }
        }
        let delegate = try delegate(documents: [document])
        delegate.terminationPromiseRegistry = registry
        var confirmations = 0
        delegate.quitConfirmation = { confirmations += 1; return false }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
        XCTAssertEqual(confirmations, 1)
        XCTAssertNil(delegate.terminationTask)
        XCTAssertFalse(writer.progress.isCancelled)
        XCTAssertTrue(registry.hasActiveWrites)
        gate.release()
        try await scenarioWait { !registry.hasActiveWrites }
        XCTAssertEqual(completion.withLock { $0.calls }, 1)
        XCTAssertNil(completion.withLock { $0.error })
        XCTAssertEqual(try Data(contentsOf: output), Data(repeating: 0x78, count: 4 * 1024 * 1024))
    }

    // J-3b: 別名で保存前の未要求 promise は終了を遅らせず、close で旧 session も閉じる。
    @MainActor func testQuitAfterSaveAsClosesOldSessionWithUnstartedPromiseWithinTwoSeconds() async throws {
        let fixture = try ScenarioFixture(), (document, _) = try await scenarioDocument(fixture)
        let oldSession = try XCTUnwrap(document.session), registry = FilePromiseRegistry.shared
        let original = try Data(contentsOf: fixture.archive)
        let payload = ArchiveEntryPayload(archiveURL: fixture.archive, generation: oldSession.generation,
            entryIndex: 0, path: "original.txt", isDirectory: false)
        let promise = try registry.register(payload: payload, session: oldSession)
        defer { registry.sweep(now: Date().addingTimeInterval(registry.gracePeriod + 1)) }
        let writer = try XCTUnwrap(promise.provider.delegate as? ArchiveFilePromise)
        let destination = fixture.root.appendingPathComponent("saved.7z")
        let archiveWriter = try ArchiveWriter.create(url: destination, format: .sevenZip)
        try archiveWriter.add(data: Data("original".utf8), as: payload.path)
        try archiveWriter.finish()
        try await document.switchBackingFile(to: destination)
        let newSession = try XCTUnwrap(document.session)
        XCTAssertFalse(newSession === oldSession)
        XCTAssertEqual(newSession.format, .sevenZip)
        XCTAssertEqual(document.fileURL, destination)
        let retained = await oldSession.entries()
        XCTAssertFalse(retained.isEmpty)
        XCTAssertTrue(registry.hasPromises(for: oldSession))
        XCTAssertFalse(writer.isWriting)
        XCTAssertFalse(document.hasWorkInFlight)
        XCTAssertFalse(document.needsTerminationCleanup)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        let delegate = try delegate(documents: [document])
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
        XCTAssertNil(delegate.terminationTask)

        let started = ContinuousClock.now
        document.close()
        let cleanup = try XCTUnwrap(document.sessionCleanup)
        let cleaned = expectation(description: "旧 session の後始末は promise の保持期限を待たない")
        var finished = false
        let wait = Task { await cleanup.value; finished = true; cleaned.fulfill() }
        await fulfillment(of: [cleaned], timeout: 2)
        XCTAssertTrue(finished)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        // 回帰時にも期限切れを進め、fixture の後始末を長時間待たせない。
        registry.sweep(now: Date().addingTimeInterval(registry.gracePeriod + 1))
        await wait.value
        let oldEntries = await oldSession.entries(), newEntries = await newSession.entries()
        XCTAssertTrue(oldEntries.isEmpty)
        XCTAssertTrue(newEntries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), original)
        XCTAssertEqual(try ScenarioFixture.contents(destination), [payload.path: Data("original".utf8)])
    }

    // T1: 後始末のない通常の終了は、確認も非同期の返答も挟まない。
    @MainActor func testIdleDocumentTerminatesImmediatelyWithoutConfirmationOrReply() async throws {
        let fixture = try ScenarioFixture(), (document, controller) = try await scenarioDocument(fixture)
        let delegate = try delegate(documents: [document])
        XCTAssertFalse(controller.hasWorkInFlight)
        XCTAssertFalse(document.hasWorkInFlight)
        XCTAssertFalse(document.needsTerminationCleanup)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
        XCTAssertNil(delegate.terminationTask)
    }

    // T2: 終了をキャンセルした場合は、展開そのものを取り消さない。
    @MainActor func testDecliningQuitLetsExtractionFinishWithAllBytes() async throws {
        let (document, controller, output, gate, task) = try await pausedExtraction()
        let delegate = try delegate(documents: [document])
        var confirmations = 0
        delegate.quitConfirmation = { confirmations += 1; return false }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
        XCTAssertEqual(confirmations, 1)
        XCTAssertNil(delegate.terminationTask)
        XCTAssertFalse(task.isCancelled)
        gate.release()
        await task.value
        XCTAssertFalse(controller.hasWorkInFlight)
        XCTAssertFalse(document.hasWorkInFlight)
        XCTAssertEqual(try Data(contentsOf: output), Data(repeating: 0x78, count: 4 * 1024 * 1024))
    }

    // T3: 同期の戻り時には partial が残り、返答時には削除が完了している。
    @MainActor func testConfirmedQuitRepliesOnceAfterRemovingPartialExtraction() async throws {
        let (document, _, output, gate, task) = try await pausedExtraction()
        let delegate = try delegate(documents: [document])
        var confirmations = 0, replies: [Bool] = []
        let replied = expectation(description: "展開の後始末後に終了へ返答")
        replied.assertForOverFulfill = true
        delegate.quitConfirmation = { confirmations += 1; return true }
        delegate.terminationReply = { answer in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertFalse(document.hasWorkInFlight)
            replies.append(answer)
            replied.fulfill()
        }
        addTeardownBlock { @MainActor in gate.release(); await delegate.terminationTask?.value }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertLessThan(try Data(contentsOf: output).count, 4 * 1024 * 1024)
        try await scenarioWait { task.isCancelled }
        gate.release()
        await fulfillment(of: [replied], timeout: 5)
        await delegate.terminationTask?.value
        await Task.yield()
        XCTAssertEqual(replies, [true])
    }

    // T4: 公開直前の追加を取り消し、作業コピーと pending undo を削除する。
    @MainActor func testConfirmedQuitCancelsPublicationAndRemovesWorkingDirectory() async throws {
        let fixture = try ScenarioFixture(), (document, _) = try await scenarioDocument(fixture)
        let source = try fixture.file("added.txt"), before = try ScenarioFixture.digest(fixture.archive)
        let gate = ScenarioGate(), progress = Progress(), delegate = try delegate(documents: [document])
        let append = Task { try await document.append(urls: [source], to: "", progress: progress,
                                                      willPublish: { gate.pauseOnce() }) }
        addTeardownBlock { @MainActor in
            progress.cancel()
            append.cancel()
            gate.release()
            _ = await append.result
            await delegate.terminationTask?.value
        }
        func workingDirectories() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".KaitoFinder-add-") }
        }
        try await scenarioWait { gate.isEntered }
        XCTAssertTrue(document.hasWorkInFlight)
        var confirmations = 0, replies: [Bool] = []
        let replied = expectation(description: "公開の取消しと後始末後に終了へ返答")
        replied.assertForOverFulfill = true
        delegate.quitConfirmation = { confirmations += 1; return true }
        delegate.terminationReply = { answer in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue((try? workingDirectories())?.isEmpty == true)
            XCTAssertEqual(try? ScenarioFixture.digest(fixture.archive), before)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
            replies.append(answer)
            replied.fulfill()
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertFalse(try workingDirectories().isEmpty)
        try await scenarioWait { progress.isCancelled }
        gate.release()
        await fulfillment(of: [replied], timeout: 5)
        await delegate.terminationTask?.value
        do {
            _ = try await append.value
            XCTFail("終了の取消し後に追加を公開しました")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        await Task.yield()
        XCTAssertEqual(replies, [true])
    }

    // T5: 作業がなくても undo の clone は、確認なしで破棄を待つ。
    @MainActor func testIdleUndoSlotIsDisposedBeforeReplyWithoutConfirmation() async throws {
        let fixture = try ScenarioFixture(), (document, _) = try await scenarioDocument(fixture)
        _ = try await document.createFolder(in: "", progress: Progress())
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
        let directory = try XCTUnwrap(document.archiveUndoStack.slots.first).directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(document.hasWorkInFlight)
        XCTAssertTrue(document.needsTerminationCleanup)
        let delegate = try delegate(documents: [document])
        var replies: [Bool] = []
        let replied = expectation(description: "undo スロットの削除後に終了へ返答")
        replied.assertForOverFulfill = true
        delegate.terminationReply = { answer in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            replies.append(answer)
            replied.fulfill()
        }
        addTeardownBlock { @MainActor in await delegate.terminationTask?.value }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertTrue(replies.isEmpty)
        await fulfillment(of: [replied], timeout: 5)
        await delegate.terminationTask?.value
        await Task.yield()
        XCTAssertEqual(replies, [true])
        XCTAssertNotNil(document.session)
        // AppKit がこの後 close() しても、二重の破棄と既存の await 契約は安全。
        document.close()
        await document.undoCleanup?.value
        await document.materializationCleanup?.value
        await document.sessionCleanup?.value
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // T6: 取消しに反応しない worker を待ち続けず、後始末の完了後も二重返答しない。
    @MainActor func testDeadlineRepliesWhileExtractionIsStillBlocked() async throws {
        let (document, _, output, gate, _) = try await pausedExtraction()
        let delegate = try delegate(documents: [document])
        delegate.terminationGracePeriod = .milliseconds(300)
        delegate.quitConfirmation = { true }
        var replies: [Bool] = []
        let replied = expectation(description: "後始末の上限で終了へ返答")
        replied.assertForOverFulfill = true
        delegate.terminationReply = { answer in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(document.hasWorkInFlight)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
            replies.append(answer)
            replied.fulfill()
        }
        addTeardownBlock { @MainActor in
            gate.release()
            await delegate.terminationTask?.value
            XCTAssertFalse(document.hasWorkInFlight)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertEqual(replies, [true])
        }
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true])
    }

    // T7: 文書のない Services の一括展開も、取消しを観測して戻るまで待つ。
    @MainActor func testQuitWaitsForAppLevelBatchExtractionCancellation() async throws {
        let fixture = try ScenarioFixture(), delegate = try delegate(documents: [])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else { throw XCTSkip("名前付きペーストボードを利用できない") }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fixture.archive as NSURL]))
        let cancellation = Mutex<(cancelled: Bool, continuation: CheckedContinuation<Void, Never>?)>((false, nil))
        var started = false, returned = false, confirmations = 0, replies: [Bool] = []
        delegate.batchExtractionHandler = { archives in
            XCTAssertEqual(archives, [fixture.archive])
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let cancelled = cancellation.withLock { state in
                        if state.cancelled { return true }
                        state.continuation = continuation
                        return false
                    }
                    started = true
                    if cancelled { continuation.resume() }
                }
            } onCancel: {
                let continuation = cancellation.withLock { state in
                    state.cancelled = true
                    let continuation = state.continuation
                    state.continuation = nil
                    return continuation
                }
                continuation?.resume()
            }
            returned = true
        }
        let replied = expectation(description: "一括展開の取消し完了後に終了へ返答")
        replied.assertForOverFulfill = true
        delegate.quitConfirmation = { confirmations += 1; return true }
        delegate.terminationReply = { answer in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(cancellation.withLock { $0.cancelled })
            XCTAssertTrue(returned)
            XCTAssertNil(delegate.batchExtractionTask)
            replies.append(answer)
            replied.fulfill()
        }
        addTeardownBlock { @MainActor in
            let task = delegate.batchExtractionTask
            task?.cancel()
            await task?.value
            await delegate.terminationTask?.value
            delegate.terminationReply = nil
        }
        var error: NSString = ""
        delegate.extractArchives(pasteboard, userData: "", error: &error)
        XCTAssertEqual(error, "")
        try await scenarioWait { started }
        XCTAssertNotNil(delegate.batchExtractionTask)
        XCTAssertFalse(returned)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(confirmations, 1)
        XCTAssertTrue(replies.isEmpty)
        await fulfillment(of: [replied], timeout: 5)
        await delegate.terminationTask?.value
        await Task.yield()
        XCTAssertEqual(replies, [true])
    }
}
