import AppKit
import CryptoKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePasswordTests: XCTestCase {
    private enum Format { case pkware, aes, sevenZip, encryptedHeaders }

    private final class Fixture {
        let directory: ArchiveTestDirectory
        let archive: URL
        let password = "fixture-password-2026"
        let original = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) }) + Data("original\0日本語\n".utf8)

        init(_ format: Format, publicEntry: Bool = false) throws {
            directory = try ArchiveTestDirectory()
            let isZIP = format == .pkware || format == .aes
            archive = directory.url.appendingPathComponent(isZIP ? "archive.zip" : "archive.7z")
            try original.write(to: directory.url.appendingPathComponent("secret.bin"))
            if publicEntry {
                XCTAssertTrue(isZIP)
                try Data("public".utf8).write(to: directory.url.appendingPathComponent("public.txt"))
                try directory.run("/usr/bin/zip", ["-q", archive.path, "public.txt"])
            }
            switch format {
            case .pkware:
                try directory.run("/usr/bin/zip", ["-q", "-P", password, archive.path, "secret.bin"])
            case .aes:
                try directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-tzip", "-p" + password,
                                                           "-mem=AES256", archive.path, "secret.bin"])
            case .sevenZip, .encryptedHeaders:
                var arguments = ["a", "-bd", "-y", "-p" + password]
                if format == .encryptedHeaders { arguments.append("-mhe=on") }
                try directory.run("/opt/homebrew/bin/7zz", arguments + [archive.path, "secret.bin"])
            }
        }

        func destination() throws -> URL {
            let url = directory.url.appendingPathComponent("out-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }
    }

    private func payloads(_ session: ArchiveSession, named name: String? = nil) async -> [ArchiveEntryPayload] {
        let snapshot = await session.snapshot()
        return snapshot.entries.filter { name == nil || $0.name == name }.map {
            ArchiveEntryPayload(archiveURL: session.sourceURL, generation: snapshot.generation,
                                entryIndex: $0.index, path: $0.name, isDirectory: $0.kind == .directory)
        }
    }

    private func extractSecret(_ fixture: Fixture, session: ArchiveSession) async throws {
        let destination = try fixture.destination()
        let selection = await payloads(session, named: "secret.bin")
        XCTAssertEqual(selection.count, 1)
        let result = try await ExtractionService.extract(selection, from: session, to: destination, progress: Progress())
        XCTAssertFalse(result.cancelled)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.written.count, 1)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("secret.bin")), fixture.original)
    }

    private func assertPassword(_ session: ArchiveSession, equals expected: String?) async {
        let actual = await session.password
        // XCTest の失敗文にもパスワードそのものを出さない。
        XCTAssertTrue(actual == expected, "Session password state")
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    @MainActor private func interface(_ fixture: Fixture) async throws -> (ArchiveDocument, ArchiveWindowController) {
        let vault = ArchivePasswordVault(key: SymmetricKey(size: .bits256),
                                         directory: fixture.directory.url.appendingPathComponent("vault"))
        let document = ArchiveDocument(passwordVault: vault)
        try document.read(from: fixture.archive, ofType: "archive")
        document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        if !document.isPasswordLocked { try await waitUntil { controller.outlineView.numberOfRows > 0 } }
        addTeardownBlock { @MainActor in
            let extraction = controller.extractionTask, unlock = controller.unlockTask
            document.close()
            await extraction?.value
            await unlock?.value
            await document.sessionCleanup?.value
            await document.materializationCleanup?.value
            await document.undoCleanup?.value
            withExtendedLifetime(fixture) {}
        }
        return (document, controller)
    }

    @MainActor private func selectSecret(_ controller: ArchiveWindowController) throws {
        let row = try XCTUnwrap((0..<controller.outlineView.numberOfRows).first {
            (controller.outlineView.item(atRow: $0) as? EntryNode)?.path == "secret.bin"
        })
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @MainActor private func respond(_ controller: ArchiveWindowController, password: String?) throws -> ArchivePasswordPrompt {
        let prompt = try XCTUnwrap(controller.passwordPrompt)
        let parent = try XCTUnwrap(prompt.alert.window.sheetParent)
        XCTAssertTrue(parent === controller.window)
        prompt.field.stringValue = password ?? "discard this input"
        parent.endSheet(prompt.alert.window, returnCode: password == nil ? .alertSecondButtonReturn : .alertFirstButtonReturn)
        return prompt
    }

    @MainActor func testPayloadZIPListsAndReadsPublicEntryWithoutPrompt() async throws {
        let fixture = try Fixture(.pkware, publicEntry: true)
        let (document, controller) = try await interface(fixture)
        let session = try XCTUnwrap(document.session)
        XCTAssertFalse(document.isPasswordLocked)
        XCTAssertEqual(controller.outlineView.numberOfRows, 2)
        XCTAssertNil(controller.passwordPrompt)
        var challenges: [ArchivePasswordChallenge] = []
        let password = fixture.password
        session.setPasswordPrompt { challenge in
            XCTAssertTrue(Thread.isMainThread)
            challenges.append(challenge)
            return password
        }
        let destination = try fixture.destination()
        let result = try await ExtractionService.extract(await payloads(session, named: "public.txt"),
            from: session, to: destination, progress: Progress())
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("public.txt")), Data("public".utf8))
        XCTAssertTrue(challenges.isEmpty)
        await assertPassword(session, equals: nil)
        try await extractSecret(fixture, session: session)
        XCTAssertEqual(challenges, [.required])
        await assertPassword(session, equals: password)
    }

    @MainActor private func wrongThenCorrect(_ format: Format) async throws {
        let fixture = try Fixture(format), session = try ArchiveSession(url: fixture.archive)
        let password = fixture.password
        var challenges: [ArchivePasswordChallenge] = []
        session.setPasswordPrompt { challenge in
            XCTAssertTrue(Thread.isMainThread)
            challenges.append(challenge)
            return challenges.count == 1 ? "incorrect" : password
        }
        try await extractSecret(fixture, session: session)
        XCTAssertEqual(challenges, [.required, .incorrect])
        await assertPassword(session, equals: password)
        try await extractSecret(fixture, session: session)
        XCTAssertEqual(challenges.count, 2)
        await session.close()
    }

    @MainActor func testTraditionalPKWAREWrongThenCorrectPasswordExtractsExactBytes() async throws {
        try await wrongThenCorrect(.pkware)
    }

    @MainActor func testWinZipAES256WrongThenCorrectPasswordExtractsExactBytes() async throws {
        try await wrongThenCorrect(.aes)
    }

    @MainActor func testSevenZipPayloadWrongThenCorrectPasswordExtractsExactBytes() async throws {
        try await wrongThenCorrect(.sevenZip)
    }

    func testInitialPasswordIsUsedForHeaderOpenAndExtractionReopen() async throws {
        let fixture = try Fixture(.encryptedHeaders)
        let session = try ArchiveSession(url: fixture.archive, password: fixture.password)
        try await extractSecret(fixture, session: session)
        let reader = try await session.extractionReader()
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), fixture.original)
        await session.close()
        await assertPassword(session, equals: nil)
    }

    @MainActor private func commitPreservesPassword(_ format: Format) async throws {
        let fixture = try Fixture(format), session = try ArchiveSession(url: fixture.archive)
        let password = fixture.password
        var prompts = 0
        session.setPasswordPrompt { _ in prompts += 1; return password }
        try await extractSecret(fixture, session: session)
        XCTAssertEqual(prompts, 1)
        let addition = fixture.directory.url.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: addition)
        let result = try await session.append(urls: [addition], to: "", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["added.txt"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(session.generation, 1)
        await assertPassword(session, equals: password)
        try await extractSecret(fixture, session: session)
        XCTAssertEqual(prompts, 1, "commit 後の URL からの再読込にも同じ鍵を渡す")
        let reader = try await session.extractionReader()
        let encrypted = try XCTUnwrap(reader.entries.first { $0.name == "secret.bin" })
        XCTAssertTrue(encrypted.isEncrypted)
        XCTAssertEqual(try reader.read(encrypted), fixture.original)
        await session.close()
    }

    @MainActor func testTraditionalZIPPasswordSurvivesAppendCommit() async throws {
        try await commitPreservesPassword(.pkware)
    }

    @MainActor func testAESZIPPasswordSurvivesAppendCommit() async throws {
        try await commitPreservesPassword(.aes)
    }

    @MainActor func testCloseClearsPasswordAndReopeningPromptsAgain() async throws {
        let fixture = try Fixture(.aes), password = fixture.password
        var prompts = 0
        let first = try ArchiveSession(url: fixture.archive)
        first.setPasswordPrompt { _ in prompts += 1; return password }
        try await extractSecret(fixture, session: first)
        await first.close()
        await assertPassword(first, equals: nil)
        let entries = await first.entries()
        XCTAssertTrue(entries.isEmpty)
        do { _ = try await first.extractionReader(); XCTFail("Closed reader") }
        catch { XCTAssertTrue(error is CancellationError) }
        let second = try ArchiveSession(url: fixture.archive)
        await assertPassword(second, equals: nil)
        second.setPasswordPrompt { _ in prompts += 1; return password }
        try await extractSecret(fixture, session: second)
        XCTAssertEqual(prompts, 2)
        await second.close()
    }

    @MainActor func testCancellingAfterWrongPayloadPasswordLeavesDestinationEmptyAndCanRetry() async throws {
        let fixture = try Fixture(.pkware, publicEntry: true), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive), destination = try fixture.destination()
        var challenges: [ArchivePasswordChallenge] = []
        session.setPasswordPrompt { challenge in
            challenges.append(challenge)
            if challenges.count == 1 { return "incorrect" }
            throw CancellationError()
        }
        do {
            _ = try await ExtractionService.extract(await payloads(session), from: session, to: destination, progress: Progress())
            XCTFail("Cancelled authentication")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(challenges, [.required, .incorrect])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        await assertPassword(session, equals: nil)
        let password = fixture.password
        session.setPasswordPrompt { _ in password }
        try await extractSecret(fixture, session: session)
        await session.close()
    }

    @MainActor func testHeaderEncryptedDocumentPromptsAfterReadAndWrongPasswordShowsRetryMessage() async throws {
        let fixture = try Fixture(.encryptedHeaders), before = try Data(contentsOf: fixture.archive)
        let (document, controller) = try await interface(fixture)
        XCTAssertTrue(document.isPasswordLocked)
        XCTAssertNil(document.session)
        XCTAssertEqual(controller.outlineView.numberOfRows, 0)
        XCTAssertNil(controller.passwordPrompt, "read と window 作成だけでは入力しない")
        controller.showWindow(nil)
        try await waitUntil { controller.passwordPrompt != nil }
        let first = try respond(controller, password: "incorrect")
        try await waitUntil { controller.passwordPrompt?.challenge == .incorrect }
        XCTAssertTrue(first.field.stringValue.isEmpty)
        XCTAssertNil(first.alert.window.sheetParent)
        XCTAssertTrue(document.isPasswordLocked)
        XCTAssertNil(document.session)
        let second = try XCTUnwrap(controller.passwordPrompt)
        XCTAssertEqual(second.alert.informativeText, ArchivePasswordChallenge.incorrect.message())
        XCTAssertTrue(second.field.stringValue.isEmpty)
        _ = try respond(controller, password: fixture.password)
        await controller.unlockTask?.value
        XCTAssertNil(controller.unlockTask)
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertFalse(document.isPasswordLocked)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(controller.outlineView.numberOfRows, 1)
        try await extractSecret(fixture, session: XCTUnwrap(document.session))
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    @MainActor func testCancelHeaderPromptKeepsCleanLockedDocumentAndUnlockButtonCanRetry() async throws {
        let fixture = try Fixture(.encryptedHeaders), before = try Data(contentsOf: fixture.archive)
        let (document, controller) = try await interface(fixture)
        controller.unlockArchive(nil)
        try await waitUntil { controller.passwordPrompt != nil }
        let prompt = try respond(controller, password: nil)
        await controller.unlockTask?.value
        XCTAssertNil(controller.unlockTask)
        XCTAssertNil(controller.extractionTask)
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertTrue(prompt.field.stringValue.isEmpty)
        XCTAssertTrue(document.isPasswordLocked)
        XCTAssertNil(document.session)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        controller.unlockArchive(nil)
        try await waitUntil { controller.passwordPrompt != nil }
        _ = try respond(controller, password: fixture.password)
        await controller.unlockTask?.value
        XCTAssertFalse(document.isPasswordLocked)
        try await extractSecret(fixture, session: XCTUnwrap(document.session))
    }

    @MainActor func testControllerExtractionCancelRemovesTaskAndBothSheets() async throws {
        let fixture = try Fixture(.aes, publicEntry: true), before = try Data(contentsOf: fixture.archive)
        let (document, controller) = try await interface(fixture)
        let session = try XCTUnwrap(document.session), destination = try fixture.destination()
        controller.startExtraction(await payloads(session), session: session, destination: destination, showProgress: true, entryCount: 2)
        try await waitUntil { controller.passwordPrompt != nil }
        let sheet = try XCTUnwrap(controller.extractionSheet)
        XCTAssertNil(sheet.window?.sheetParent, "進捗シートは入力中に退避する")
        _ = try respond(controller, password: nil)
        await controller.extractionTask?.value
        XCTAssertNil(controller.extractionTask)
        XCTAssertNil(controller.extractionSheet)
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        await assertPassword(session, equals: nil)
    }

    @MainActor func testControllerExtractionWrongThenCorrectFinishesWithoutAttachedSheet() async throws {
        let fixture = try Fixture(.aes)
        let (document, controller) = try await interface(fixture)
        let session = try XCTUnwrap(document.session), destination = try fixture.destination()
        controller.startExtraction(await payloads(session), session: session, destination: destination, showProgress: true, entryCount: 1)
        try await waitUntil { controller.passwordPrompt != nil }
        _ = try respond(controller, password: "incorrect")
        try await waitUntil { controller.passwordPrompt?.challenge == .incorrect }
        _ = try respond(controller, password: fixture.password)
        await controller.extractionTask?.value
        XCTAssertNil(controller.extractionTask)
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("secret.bin")), fixture.original)
    }

    @MainActor func testProgressCancellationAlsoCancelsPendingPasswordRequest() async throws {
        let fixture = try Fixture(.aes), (document, controller) = try await interface(fixture)
        let session = try XCTUnwrap(document.session), destination = try fixture.destination()
        controller.startExtraction(await payloads(session), session: session, destination: destination, showProgress: true, entryCount: 1)
        try await waitUntil { controller.passwordPrompt != nil }
        let task = controller.extractionTask
        try XCTUnwrap(controller.extractionSheet).progress.cancel()
        await task?.value
        XCTAssertNil(controller.extractionTask)
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        await assertPassword(session, equals: nil)
    }

    @MainActor func testCopyCancelPreservesPasteboardAndLeavesNoTask() async throws {
        let fixture = try Fixture(.pkware), (_, controller) = try await interface(fixture)
        try selectSecret(controller)
        let changeCount = NSPasteboard.general.changeCount
        controller.copy(nil)
        try await waitUntil { controller.passwordPrompt != nil }
        _ = try respond(controller, password: nil)
        await controller.extractionTask?.value
        XCTAssertNil(controller.extractionTask)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCount)
    }

    @MainActor func testCopyOutPublishesByteExactEncryptedEntryAfterPrompt() async throws {
        let fixture = try Fixture(.aes), session = try ArchiveSession(url: fixture.archive), password = fixture.password
        var prompts = 0
        session.setPasswordPrompt { _ in prompts += 1; return password }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else {
            throw XCTSkip("Named pasteboard service is unavailable in this environment")
        }
        let urls = try await ArchiveCopyOut.copy(await payloads(session), from: session, to: pasteboard, progress: Progress(),
            temporaryDirectory: ExtractionTemporaryDirectory(root: fixture.directory.url.appendingPathComponent("copy")))
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), fixture.original)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), urls.first?.absoluteString)
        await session.close()
    }

    @MainActor func testCopyPreparationAuthenticatesAndReturnsByteExactFile() async throws {
        let fixture = try Fixture(.aes), session = try ArchiveSession(url: fixture.archive), password = fixture.password
        var prompts = 0
        session.setPasswordPrompt { _ in prompts += 1; return password }
        let prepared = try await ArchiveCopyOut.prepare(await payloads(session), from: session, progress: Progress(),
            temporaryDirectory: ExtractionTemporaryDirectory(root: fixture.directory.url.appendingPathComponent("copy")))
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(prepared.paths, ["secret.bin"])
        XCTAssertEqual(prepared.urls.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(prepared.urls.first)), fixture.original)
        await session.close()
    }

    @MainActor func testQuickLookAndSpaceRequestPasswordAndCancelWithoutMaterializedItem() async throws {
        let fixture = try Fixture(.pkware), (document, controller) = try await interface(fixture)
        try selectSecret(controller)
        for space in [false, true] {
            if space { controller.outlineView.previewSelection?() }
            else { controller.togglePreviewPanel(nil) }
            try await waitUntil { controller.passwordPrompt != nil }
            let materialization = try XCTUnwrap(document.materializationController())
            let task = materialization.task
            XCTAssertNotNil(task)
            _ = try respond(controller, password: nil)
            await task?.value
            XCTAssertNil(materialization.task)
            XCTAssertNil(materialization.item(at: 0)?.previewItemURL)
            XCTAssertNil(controller.window?.attachedSheet)
        }
    }

    @MainActor func testOpenAndOpenWithRequestPasswordInsteadOfRefusalTooltip() async throws {
        let fixture = try Fixture(.aes), (document, controller) = try await interface(fixture)
        try selectSecret(controller)
        for action in [#selector(ArchiveWindowController.openEntry(_:)), #selector(ArchiveWindowController.openWithEntry(_:))] {
            let item = NSMenuItem(title: "Open", action: action, keyEquivalent: "")
            item.representedObject = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
            XCTAssertTrue(controller.validateMenuItem(item))
            XCTAssertNil(item.toolTip)
            if action == #selector(ArchiveWindowController.openEntry(_:)) { controller.openEntry(item) }
            else { controller.openWithEntry(item) }
            try await waitUntil { controller.passwordPrompt != nil }
            let materialization = try XCTUnwrap(document.materializationController()), task = materialization.task
            _ = try respond(controller, password: nil)
            await task?.value
            XCTAssertNil(materialization.task)
            XCTAssertNil(materialization.item(at: 0)?.previewItemURL)
            XCTAssertNil(controller.window?.attachedSheet)
        }
    }

    @MainActor func testOpenWithSubmenuRequestsPasswordWhenLookingUpApplications() async throws {
        let fixture = try Fixture(.pkware), (document, controller) = try await interface(fixture)
        try selectSecret(controller)
        let submenu = try XCTUnwrap(controller.outlineView.menu?.items.first { $0.submenu != nil }?.submenu)
        controller.menuNeedsUpdate(submenu)
        try await waitUntil { controller.passwordPrompt != nil }
        let task = document.materializationController()?.task
        _ = try respond(controller, password: nil)
        await task?.value
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
    }

    @MainActor func testMaterializerPublishesExactBytesAfterAuthentication() async throws {
        let fixture = try Fixture(.aes), session = try ArchiveSession(url: fixture.archive), password = fixture.password
        var prompts = 0
        session.setPasswordPrompt { _ in prompts += 1; return password }
        let worker = EntryMaterializer(session: session,
            temporaryDirectory: ExtractionTemporaryDirectory(root: fixture.directory.url.appendingPathComponent("preview")))
        let selection = await payloads(session)
        let payload = try XCTUnwrap(selection.first)
        let url = try await worker.materialize(payload, progress: Progress()) { _ in
            XCTAssertFalse(Thread.isMainThread, "復号と書き込みは main actor の外で実行する")
        }
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(try Data(contentsOf: url), fixture.original)
        await worker.close()
        await session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testTaskCancellationDismissesPromptAndClearsSecureField() async throws {
        let controller = ArchiveWindowController()
        defer { controller.close() }
        let task = Task { try await controller.requestPassword(.required) }
        try await waitUntil { controller.passwordPrompt != nil }
        let prompt = try XCTUnwrap(controller.passwordPrompt)
        prompt.field.stringValue = "discard on cancellation"
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled prompt") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertTrue(prompt.field.stringValue.isEmpty)
        XCTAssertTrue(prompt.waiters.isEmpty)
    }

    @MainActor func testConcurrentRequestsShareSheetAndCancelOnlyTheirOwnWaiter() async throws {
        let controller = ArchiveWindowController()
        defer { controller.close() }
        let first = Task { try await controller.requestPassword(.required) }
        let second = Task { try await controller.requestPassword(.required) }
        try await waitUntil { controller.passwordPrompt?.waiters.count == 2 }
        let prompt = try XCTUnwrap(controller.passwordPrompt)
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled waiter") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(controller.passwordPrompt === prompt)
        XCTAssertEqual(prompt.waiters.count, 1)
        _ = try respond(controller, password: "accepted")
        let value = try await second.value
        XCTAssertTrue(value == "accepted")
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertTrue(prompt.field.stringValue.isEmpty)
    }

    @MainActor func testDocumentCloseCancelsLockedPromptAndNewDocumentCanPrompt() async throws {
        let fixture = try Fixture(.encryptedHeaders), (document, controller) = try await interface(fixture)
        controller.unlockArchive(nil)
        try await waitUntil { controller.passwordPrompt != nil }
        let task = controller.unlockTask
        document.close()
        await task?.value
        await document.sessionCleanup?.value
        XCTAssertNil(controller.unlockTask)
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertNil(document.session)
        let (reopened, next) = try await interface(fixture)
        XCTAssertTrue(reopened.isPasswordLocked)
        next.unlockArchive(nil)
        try await waitUntil { next.passwordPrompt != nil }
        _ = try respond(next, password: nil)
        await next.unlockTask?.value
        XCTAssertTrue(reopened.isPasswordLocked)
    }

    @MainActor func testDocumentCloseReleasesSessionPassword() async throws {
        let fixture = try Fixture(.aes), (document, _) = try await interface(fixture)
        let session = try XCTUnwrap(document.session), password = fixture.password
        session.setPasswordPrompt { _ in password }
        try await extractSecret(fixture, session: session)
        document.close()
        await document.sessionCleanup?.value
        await assertPassword(session, equals: nil)
        XCTAssertNil(document.session)
    }

    func testReadWithoutPromptHandlerPreservesTypedPasswordRequiredError() async throws {
        let fixture = try Fixture(.pkware), session = try ArchiveSession(url: fixture.archive)
        let destination = try fixture.destination()
        do {
            _ = try await ExtractionService.extract(await payloads(session), from: session, to: destination, progress: Progress())
            XCTFail("Missing password")
        } catch { XCTAssertEqual(error as? KaitoError, .passwordRequired) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        await session.close()
    }

    @MainActor func testFilePromiseRetriesPasswordAndWritesExactBytesOnce() async throws {
        let fixture = try Fixture(.aes), (document, controller) = try await interface(fixture)
        let session = try XCTUnwrap(document.session), selection = await payloads(session)
        let delegate = ArchiveFilePromise(payload: try XCTUnwrap(selection.first), session: session)
        let destination = try fixture.destination().appendingPathComponent("promised.bin")
        let result = Mutex<(calls: Int, failure: (any Error)?)>((0, nil))
        delegate.filePromiseProvider(NSFilePromiseProvider(), writePromiseTo: destination) { @Sendable error in
            result.withLock { $0.calls += 1; $0.failure = error }
        }
        try await waitUntil { controller.passwordPrompt != nil }
        _ = try respond(controller, password: "incorrect")
        try await waitUntil { controller.passwordPrompt?.challenge == .incorrect }
        _ = try respond(controller, password: fixture.password)
        try await waitUntil { result.withLock { $0.calls > 0 } && !delegate.isWriting }
        XCTAssertEqual(result.withLock { $0.calls }, 1)
        XCTAssertNil(result.withLock { $0.failure })
        XCTAssertEqual(try Data(contentsOf: destination), fixture.original)
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
    }

    @MainActor func testMutationWhilePromptIsPendingRefusesOldSelectionWithoutAdoptingPassword() async throws {
        let fixture = try Fixture(.pkware), (document, controller) = try await interface(fixture)
        let session = try XCTUnwrap(document.session), selection = await payloads(session)
        let destination = try fixture.destination()
        let extraction = Task { try await ExtractionService.extract(selection, from: session, to: destination, progress: Progress()) }
        try await waitUntil { controller.passwordPrompt != nil }
        try await session.reloadAfterMutation()
        _ = try respond(controller, password: fixture.password)
        do { _ = try await extraction.value; XCTFail("Stale selection") }
        catch { XCTAssertTrue(error is ExtractionFailure) }
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        await assertPassword(session, equals: nil)
    }

    @MainActor func testSessionClosedDuringPromptCannotBeReopenedByLateAnswer() async throws {
        let fixture = try Fixture(.aes), (document, controller) = try await interface(fixture)
        let session = try XCTUnwrap(document.session), selection = await payloads(session)
        let destination = try fixture.destination()
        let extraction = Task { try await ExtractionService.extract(selection, from: session, to: destination, progress: Progress()) }
        try await waitUntil { controller.passwordPrompt != nil }
        await session.close()
        _ = try respond(controller, password: fixture.password)
        do { _ = try await extraction.value; XCTFail("Closed session") }
        catch { XCTAssertTrue(error is CancellationError) }
        await assertPassword(session, equals: nil)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        XCTAssertNil(controller.window?.attachedSheet)
    }

    private static func damageWorkingCopy(in root: URL) throws {
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".KaitoFinder-add-") }
        XCTAssertEqual(directories.count, 1)
        let work = try XCTUnwrap(directories.first).appendingPathComponent("archive.zip")
        // 公開直前 hook で fixture の作業コピーだけを壊し、公開後の read 失敗を再現する。
        try Data("invalid archive for reload failure".utf8).write(to: work)
    }

    func testPublishedAppendReloadFailureDoesNotExposePasswordOrReaderOptions() async throws {
        let fixture = try Fixture(.aes), session = try ArchiveSession(url: fixture.archive, password: fixture.password)
        let addition = fixture.directory.url.appendingPathComponent("added.txt"), root = fixture.directory.url
        try Data("added".utf8).write(to: addition)
        let result = try await session.append(urls: [addition], to: "", progress: Progress(),
                                              willPublish: { try Self.damageWorkingCopy(in: root) })
        XCTAssertEqual(result.addedPaths, ["added.txt"])
        let reason = try XCTUnwrap(result.reloadFailure)
        XCTAssertFalse(reason.contains(fixture.password))
        XCTAssertFalse(reason.contains("ReaderOptions"))
        XCTAssertEqual(session.generation, 1)
        let entries = await session.entries()
        XCTAssertTrue(entries.isEmpty)
        await session.close()
        await assertPassword(session, equals: nil)
    }

    @MainActor func testPublishedEditReloadFailureDoesNotExposePasswordOrReaderOptions() async throws {
        let fixture = try Fixture(.pkware), session = try ArchiveSession(url: fixture.archive, password: fixture.password)
        let entries = await session.entries(), root = fixture.directory.url
        let node = try XCTUnwrap(EntryNode.tree(from: entries).children.first)
        let result = try await session.rename(ArchiveEditSelection(node), to: "renamed.bin", progress: Progress(),
                                              willPublish: { try Self.damageWorkingCopy(in: root) })
        XCTAssertTrue(result.published)
        let reason = try XCTUnwrap(result.reloadFailure)
        XCTAssertFalse(reason.contains(fixture.password))
        XCTAssertFalse(reason.contains("ReaderOptions"))
        XCTAssertEqual(session.generation, 1)
        let refreshed = await session.entries()
        XCTAssertTrue(refreshed.isEmpty)
        await session.close()
        await assertPassword(session, equals: nil)
    }

    @MainActor func testPasswordPromptAndNewMessagesHaveEnglishAndJapaneseTranslations() throws {
        let app = Bundle(for: ArchiveDocument.self)
        for language in ["en", "ja"] {
            let bundle = try XCTUnwrap(Bundle(url: XCTUnwrap(app.url(forResource: language, withExtension: "lproj"))))
            let required = ArchivePasswordPrompt(challenge: .required, bundle: bundle)
            let incorrect = ArchivePasswordPrompt(challenge: .incorrect, bundle: bundle)
            XCTAssertFalse(required.alert.messageText.isEmpty)
            XCTAssertFalse(required.alert.informativeText.isEmpty)
            XCTAssertNotEqual(required.alert.informativeText, incorrect.alert.informativeText)
            XCTAssertEqual(required.field.stringValue, "")
            XCTAssertEqual(required.alert.buttons.count, 2)
            if language == "en" {
                XCTAssertEqual(required.alert.messageText, "Unlock Archive")
                XCTAssertEqual(required.field.placeholderString, "Password")
                XCTAssertEqual(incorrect.alert.informativeText, "The password is incorrect. Please try again.")
            }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("KaitoFinder/Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for (key, value) in strings {
            let entry = try XCTUnwrap(value as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for language in ["en", "ja"] {
                let translation = try XCTUnwrap(localizations[language] as? [String: Any], key)
                let unit = try XCTUnwrap(translation["stringUnit"] as? [String: String], key)
                XCTAssertEqual(unit["state"], "translated", key)
                XCTAssertFalse(try XCTUnwrap(unit["value"], key).isEmpty)
            }
        }
    }
}
