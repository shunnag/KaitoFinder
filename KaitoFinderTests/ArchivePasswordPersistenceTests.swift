import AppKit
import CryptoKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePasswordPersistenceTests: XCTestCase {
    private enum Format { case zip, encryptedHeaders }

    private final class Fixture {
        let root: ArchiveTestDirectory
        let format: Format
        let key = SymmetricKey(size: .bits256)
        let original = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) }) + Data("vault fixture 日本語".utf8)
        let password = "remembered-fixture-password"
        var archive: URL { root.url.appendingPathComponent(format == .zip ? "archive.zip" : "archive.7z") }
        var vaultDirectory: URL { root.url.appendingPathComponent("passwords", isDirectory: true) }
        var vaultFile: URL { vaultDirectory.appendingPathComponent("vault.enc") }

        init(_ format: Format) throws {
            self.format = format
            root = try ArchiveTestDirectory()
            try original.write(to: root.url.appendingPathComponent("secret.bin"))
            try encrypt(password: password)
        }

        func vault() -> ArchivePasswordVault { ArchivePasswordVault(key: key, directory: vaultDirectory) }

        func encrypt(password: String) throws {
            if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
            let options = format == .zip ? ["-tzip", "-mem=AES256"] : ["-mhe=on"]
            try root.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-p" + password] + options + [archive.path, "secret.bin"])
        }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    @MainActor private func interface(_ fixture: Fixture, vault: ArchivePasswordVault? = nil) async throws
        -> (ArchiveDocument, ArchiveWindowController) {
        let document = ArchiveDocument(passwordVault: vault ?? fixture.vault())
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

    @MainActor private func respond(_ controller: ArchiveWindowController, password: String?, remember: Bool) throws {
        let prompt = try XCTUnwrap(controller.passwordPrompt)
        prompt.field.stringValue = password ?? "cancelled input"
        prompt.rememberCheckbox.state = remember ? .on : .off
        let parent = try XCTUnwrap(prompt.alert.window.sheetParent)
        parent.endSheet(prompt.alert.window, returnCode: password == nil ? .alertSecondButtonReturn : .alertFirstButtonReturn)
    }

    @MainActor private func startRead(_ fixture: Fixture, document: ArchiveDocument,
                                     controller: ArchiveWindowController) async throws -> URL {
        let session = try XCTUnwrap(document.session), snapshot = await session.snapshot()
        let entry = try XCTUnwrap(snapshot.entries.first { $0.name == "secret.bin" })
        let payload = ArchiveEntryPayload(archiveURL: session.sourceURL, generation: snapshot.generation,
                                         entryIndex: entry.index, path: entry.name, isDirectory: false)
        let destination = fixture.root.url.appendingPathComponent("out-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        controller.startExtraction([payload], session: session, destination: destination, showProgress: false, entryCount: 1)
        return destination.appendingPathComponent("secret.bin")
    }

    @MainActor private func finishRead(_ fixture: Fixture, controller: ArchiveWindowController, output: URL,
                                      withoutPrompt: Bool = false) async throws {
        if withoutPrompt {
            try await waitUntil { controller.extractionTask == nil || controller.passwordPrompt != nil }
            XCTAssertNil(controller.passwordPrompt, "Remembered password must avoid a prompt")
            if controller.passwordPrompt != nil { controller.cancelExtraction() }
        }
        await controller.extractionTask?.value
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertEqual(try Data(contentsOf: output), fixture.original)
    }

    private func assertPassword(_ fixture: Fixture, equals expected: String?) async {
        let actual = await fixture.vault().password(for: .file(fixture.archive))
        XCTAssertTrue(actual == expected, "Persisted password state")
    }

    @MainActor func testHeaderCheckboxDefaultsOffAndCreatesNoVault() async throws {
        let fixture = try Fixture(.encryptedHeaders), (document, controller) = try await interface(fixture)
        controller.unlockArchive(nil)
        try await waitUntil { controller.passwordPrompt != nil }
        XCTAssertEqual(controller.passwordPrompt?.rememberCheckbox.state, .off)
        try respond(controller, password: fixture.password, remember: false)
        await controller.unlockTask?.value
        XCTAssertFalse(document.isPasswordLocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultFile.path))
        await assertPassword(fixture, equals: nil)
    }

    @MainActor func testPayloadCheckboxDefaultsOffAndReopeningPromptsAgain() async throws {
        let fixture = try Fixture(.zip), (document, controller) = try await interface(fixture)
        let output = try await startRead(fixture, document: document, controller: controller)
        try await waitUntil { controller.passwordPrompt != nil }
        XCTAssertEqual(controller.passwordPrompt?.rememberCheckbox.state, .off)
        try respond(controller, password: fixture.password, remember: false)
        try await finishRead(fixture, controller: controller, output: output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultFile.path))
        document.close()
        await document.sessionCleanup?.value
        let (reopened, next) = try await interface(fixture)
        _ = try await startRead(fixture, document: reopened, controller: next)
        try await waitUntil { next.passwordPrompt != nil }
        try respond(next, password: nil, remember: false)
        await next.extractionTask?.value
    }

    @MainActor func testHeaderRemembersOnlyCorrectPasswordAndReopensWithoutPrompt() async throws {
        let fixture = try Fixture(.encryptedHeaders), (document, controller) = try await interface(fixture)
        controller.unlockArchive(nil)
        try await waitUntil { controller.passwordPrompt != nil }
        try respond(controller, password: "incorrect", remember: true)
        try await waitUntil { controller.passwordPrompt?.challenge == .incorrect }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultFile.path))
        XCTAssertEqual(controller.passwordPrompt?.rememberCheckbox.state, .off)
        try respond(controller, password: fixture.password, remember: true)
        await controller.unlockTask?.value
        XCTAssertFalse(document.isPasswordLocked)
        await assertPassword(fixture, equals: fixture.password)
        document.close()
        await document.sessionCleanup?.value
        let (reopened, next) = try await interface(fixture)
        next.unlockArchive(nil)
        try await waitUntil { next.unlockTask == nil || next.passwordPrompt != nil }
        XCTAssertNil(next.passwordPrompt)
        XCTAssertFalse(reopened.isPasswordLocked)
        let output = try await startRead(fixture, document: reopened, controller: next)
        try await finishRead(fixture, controller: next, output: output, withoutPrompt: true)
    }

    @MainActor func testPayloadRemembersOnlyVerifiedPasswordAndReopensWithoutPrompt() async throws {
        let fixture = try Fixture(.zip), (document, controller) = try await interface(fixture)
        let output = try await startRead(fixture, document: document, controller: controller)
        try await waitUntil { controller.passwordPrompt != nil }
        try respond(controller, password: "incorrect", remember: true)
        try await waitUntil { controller.passwordPrompt?.challenge == .incorrect }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultFile.path))
        XCTAssertEqual(controller.passwordPrompt?.rememberCheckbox.state, .off)
        try respond(controller, password: fixture.password, remember: true)
        try await finishRead(fixture, controller: controller, output: output)
        await assertPassword(fixture, equals: fixture.password)
        document.close()
        await document.sessionCleanup?.value
        let (reopened, next) = try await interface(fixture)
        let nextOutput = try await startRead(fixture, document: reopened, controller: next)
        try await finishRead(fixture, controller: next, output: nextOutput, withoutPrompt: true)
    }

    @MainActor func testStaleHeaderPasswordIsRemovedBeforePromptAndNewPasswordOpens() async throws {
        let fixture = try Fixture(.encryptedHeaders), replacement = "replacement-fixture-password"
        let saved = await fixture.vault().save(fixture.password, for: .file(fixture.archive))
        XCTAssertTrue(saved)
        try fixture.encrypt(password: replacement)
        let (document, controller) = try await interface(fixture)
        controller.unlockArchive(nil)
        try await waitUntil { controller.passwordPrompt != nil }
        await assertPassword(fixture, equals: nil)
        try respond(controller, password: replacement, remember: true)
        await controller.unlockTask?.value
        XCTAssertFalse(document.isPasswordLocked)
        await assertPassword(fixture, equals: replacement)
    }

    @MainActor func testStalePayloadPasswordFallsBackAndStoresReplacement() async throws {
        let fixture = try Fixture(.zip), replacement = "replacement-fixture-password"
        let saved = await fixture.vault().save(fixture.password, for: .file(fixture.archive))
        XCTAssertTrue(saved)
        try fixture.encrypt(password: replacement)
        let (document, controller) = try await interface(fixture)
        let output = try await startRead(fixture, document: document, controller: controller)
        try await waitUntil { controller.passwordPrompt != nil }
        XCTAssertEqual(controller.passwordPrompt?.challenge, .incorrect)
        await assertPassword(fixture, equals: nil)
        try respond(controller, password: replacement, remember: true)
        try await finishRead(fixture, controller: controller, output: output)
        await assertPassword(fixture, equals: replacement)
        document.close()
        await document.sessionCleanup?.value
        let (reopened, next) = try await interface(fixture)
        let nextOutput = try await startRead(fixture, document: reopened, controller: next)
        try await finishRead(fixture, controller: next, output: nextOutput, withoutPrompt: true)
    }

    @MainActor func testStalePayloadIsNotReplacedWhenCheckboxIsOff() async throws {
        let fixture = try Fixture(.zip)
        let saved = await fixture.vault().save("old password", for: .file(fixture.archive))
        XCTAssertTrue(saved)
        let (document, controller) = try await interface(fixture)
        let output = try await startRead(fixture, document: document, controller: controller)
        try await waitUntil { controller.passwordPrompt != nil }
        await assertPassword(fixture, equals: nil)
        try respond(controller, password: fixture.password, remember: false)
        try await finishRead(fixture, controller: controller, output: output)
        await assertPassword(fixture, equals: nil)
    }

    @MainActor func testCancelWithRememberCheckedNeverWrites() async throws {
        for format in [Format.zip, .encryptedHeaders] {
            let fixture = try Fixture(format), (document, controller) = try await interface(fixture)
            if format == .encryptedHeaders { controller.unlockArchive(nil) }
            else { _ = try await startRead(fixture, document: document, controller: controller) }
            try await waitUntil { controller.passwordPrompt != nil }
            try respond(controller, password: nil, remember: true)
            await controller.unlockTask?.value
            await controller.extractionTask?.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultFile.path))
        }
    }

    @MainActor func testRememberedPasswordSurvivesAppendReplacingInode() async throws {
        let fixture = try Fixture(.zip), (document, controller) = try await interface(fixture)
        let output = try await startRead(fixture, document: document, controller: controller)
        try await waitUntil { controller.passwordPrompt != nil }
        try respond(controller, password: fixture.password, remember: true)
        try await finishRead(fixture, controller: controller, output: output)
        let before = try FileManager.default.attributesOfItem(atPath: fixture.archive.path)[.systemFileNumber] as? NSNumber
        let addition = fixture.root.url.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: addition)
        let result = try await document.append(urls: [addition], to: "", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["added.txt"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(result.reloadFailure)
        let after = try FileManager.default.attributesOfItem(atPath: fixture.archive.path)[.systemFileNumber] as? NSNumber
        XCTAssertNotEqual(try XCTUnwrap(before), try XCTUnwrap(after), "Append must actually replace the inode")
        document.close()
        await document.sessionCleanup?.value
        await document.undoCleanup?.value
        let (reopened, next) = try await interface(fixture)
        let nextOutput = try await startRead(fixture, document: reopened, controller: next)
        try await finishRead(fixture, controller: next, output: nextOutput, withoutPrompt: true)
    }

    @MainActor func testForgetMenuWorksWithoutDocumentAndRecoversUnavailableVault() async throws {
        let fixture = try Fixture(.zip), vault = fixture.vault(), delegate = AppDelegate(passwordVault: vault)
        let saved = await vault.save(fixture.password, for: .file(fixture.archive))
        let other = ArchivePasswordVault.Key.file(fixture.root.url.appendingPathComponent("other.zip"))
        let savedOther = await vault.save("other password", for: other)
        XCTAssertTrue(saved && savedOther)
        let oldWindowMenu = NSApp.windowsMenu
        defer { NSApp.windowsMenu = oldWindowMenu }
        let menu = delegate.makeMenu()
        let item = try XCTUnwrap(menu.items.flatMap { $0.submenu?.items ?? [] }
            .first { $0.action == #selector(AppDelegate.forgetArchivePasswords(_:)) })
        XCTAssertTrue(item.target === delegate)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await delegate.forgetPasswordsTask?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultFile.path))
        let remaining = await vault.password(for: other)
        XCTAssertTrue(remaining == nil, "Forgotten password state")
        await assertPassword(fixture, equals: nil)
        try Data("corrupt vault".utf8).write(to: fixture.vaultFile)
        let unavailable = fixture.vault(), available = await unavailable.isAvailable()
        XCTAssertFalse(available)
        let recoveryDelegate = AppDelegate(passwordVault: unavailable)
        recoveryDelegate.forgetArchivePasswords(nil)
        await recoveryDelegate.forgetPasswordsTask?.value
        let recovered = await unavailable.save(fixture.password, for: .file(fixture.archive))
        XCTAssertTrue(recovered)
        await assertPassword(fixture, equals: fixture.password)
    }

    @MainActor func testForgetWhileHeaderPromptIsPendingPreventsLateSave() async throws {
        let fixture = try Fixture(.encryptedHeaders), vault = fixture.vault()
        let (document, controller) = try await interface(fixture, vault: vault)
        controller.unlockArchive(nil)
        try await waitUntil { controller.passwordPrompt != nil }
        let forgotten = await vault.forgetAll()
        XCTAssertTrue(forgotten)
        try respond(controller, password: fixture.password, remember: true)
        await controller.unlockTask?.value
        XCTAssertFalse(document.isPasswordLocked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultFile.path))
    }

    @MainActor func testDocumentChangedDuringPromptDoesNotRememberCandidate() async throws {
        let fixture = try Fixture(.zip), (document, _) = try await interface(fixture)
        let session = try XCTUnwrap(document.session)
        do {
            _ = try await document.password(for: session, challenge: .required) {
                try await session.reloadAfterMutation()
                return ArchivePasswordResponse(password: fixture.password, remember: true)
            }
            XCTFail("A stale password request must fail")
        } catch { XCTAssertTrue(error is ExtractionFailure) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultFile.path))
    }

    @MainActor func testSessionClosedDuringPromptDoesNotRememberCandidate() async throws {
        let fixture = try Fixture(.zip), (document, _) = try await interface(fixture)
        let session = try XCTUnwrap(document.session)
        do {
            _ = try await document.password(for: session, challenge: .required) {
                await session.close()
                return ArchivePasswordResponse(password: fixture.password, remember: true)
            }
            XCTFail("A closed session must not save a candidate")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultFile.path))
    }

    @MainActor func testRememberCheckboxAndForgetStringsHaveBothTranslations() throws {
        let app = Bundle(for: ArchiveDocument.self)
        for language in ["ja", "en"] {
            let bundle = try XCTUnwrap(Bundle(url: XCTUnwrap(app.url(forResource: language, withExtension: "lproj"))))
            let prompt = ArchivePasswordPrompt(challenge: .required, bundle: bundle)
            XCTAssertEqual(prompt.rememberCheckbox.state, .off)
            XCTAssertEqual(prompt.rememberCheckbox.title, language == "ja" ? "このパスワードを記憶" : "Remember this password")
            XCTAssertEqual(String(localized: "記憶したパスワードをすべて削除", bundle: bundle),
                           language == "ja" ? "記憶したパスワードをすべて削除" : "Forget All Saved Passwords")
            XCTAssertEqual(String(localized: "記憶したパスワードを削除できませんでした", bundle: bundle),
                           language == "ja" ? "記憶したパスワードを削除できませんでした" : "Could not forget saved passwords.")
            XCTAssertTrue((prompt.alert.accessoryView as? NSStackView)?.arrangedSubviews.contains(prompt.rememberCheckbox) == true)
        }
    }
}
