import AppKit
import CryptoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveBatchExtractionUITests: XCTestCase {
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    private func declaration() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("KaitoFinder/Info.plist")), format: nil) as? [String: Any])
    }

    @MainActor func testFinderExtractionServiceSelectorAndDeclaredArchiveTypesMatchDocuments() throws {
        let plist = try declaration(), services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        XCTAssertEqual(services.count, 2)
        let service = try XCTUnwrap(services.last)
        XCTAssertEqual(service["NSMessage"] as? String, "extractArchives")
        XCTAssertEqual(service["NSPortName"] as? String, "KaitoFinder")
        XCTAssertEqual(service["NSMenuItem"] as? [String: String], ["default": "KaitoFinderで展開"])
        XCTAssertEqual(service["NSRequiredContext"] as? [String: String], ["NSApplicationIdentifier": "com.apple.finder"])
        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let expected = Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        let types = try XCTUnwrap(service["NSSendFileTypes"] as? [String])
        XCTAssertEqual(Set(types), expected)
        XCTAssertEqual(types.count, expected.count)
        XCTAssertFalse(types.contains("public.item"))
        XCTAssertTrue(AppDelegate().responds(to: #selector(AppDelegate.extractArchives(_:userData:error:))))
    }

    @MainActor func testFileMenuExtractionImmediatelyFollowsNewArchiveInBothLanguages() throws {
        let app = Bundle(for: ArchiveDocument.self)
        for (language, title) in [("ja", "アーカイブを展開…"), ("en", "Extract Archives…")] {
            let bundle = try XCTUnwrap(Bundle(url: XCTUnwrap(app.url(forResource: language, withExtension: "lproj"))))
            let delegate = AppDelegate(), menu = delegate.makeMenu(bundle: bundle)
            let file = try XCTUnwrap(menu.item(withTitle: String(localized: "ファイル", bundle: bundle))?.submenu)
            let item = try XCTUnwrap(file.items.first { $0.action == #selector(AppDelegate.extractArchivesFromMenu(_:)) })
            XCTAssertEqual(item.title, title)
            XCTAssertEqual(file.index(of: item), file.indexOfItem(withTitle: String(localized: "新規アーカイブ…", bundle: bundle)) + 1)
            XCTAssertTrue(item.target === delegate)
            XCTAssertEqual(item.keyEquivalent, "")
        }
    }

    @MainActor func testOpenPanelsSelectMultipleDeclaredArchivesAndOneDestinationFolder() throws {
        let app = Bundle(for: ArchiveDocument.self), panel = ArchiveBatchExtractionController.makeArchivePanel(bundle: app)
        let plist = try declaration(), documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let expected = Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection)
        // UTType は識別子を小文字に正規化する(com.shunnag.KaitoFinder.ar-archive → …kaitofinder…)。
        XCTAssertEqual(Set(panel.allowedContentTypes.map { $0.identifier.lowercased() }), Set(expected.map { $0.lowercased() }))
        XCTAssertEqual(panel.prompt, String(localized: "展開", bundle: app))
        let destination = ArchiveBatchExtractionController.makeDestinationPanel(bundle: app)
        XCTAssertFalse(destination.canChooseFiles)
        XCTAssertTrue(destination.canChooseDirectories)
        XCTAssertTrue(destination.canCreateDirectories)
        XCTAssertFalse(destination.allowsMultipleSelection)
        XCTAssertEqual(destination.prompt, String(localized: "展開", bundle: app))
    }

    @MainActor func testFinderExtractionReadsOnlyFileURLsFromPasteboard() throws {
        let directory = try ArchiveTestDirectory(), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else { throw XCTSkip("名前付きペーストボードを利用できない") }
        let first = directory.url.appendingPathComponent("a.zip"), second = directory.url.appendingPathComponent("b.7z")
        try Data().write(to: first)
        try Data().write(to: second)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first as NSURL, second as NSURL, directory.url as NSURL,
                                               NSURL(string: "https://example.com/archive.zip")!]))
        XCTAssertEqual(AppDelegate.archivesToExtract(from: pasteboard), [first, second])
    }

    @MainActor func testSecondBatchServiceRequestIsRejectedAndMenuIsIgnoredWhileChoosingDestination() async throws {
        let directory = try ArchiveTestDirectory(), suite = try ArchivePreferencesTestDefaults()
        let store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.extractionDestination = .ask
        let vault = ArchivePasswordVault(key: SymmetricKey(size: .bits256), directory: directory.url.appendingPathComponent("vault"))
        let delegate = AppDelegate(passwordVault: vault, preferencesStore: store)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else { throw XCTSkip("名前付きペーストボードを利用できない") }
        let archive = directory.url.appendingPathComponent("example.zip")
        try Data().write(to: archive)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([archive as NSURL]))
        addTeardownBlock { @MainActor in
            let task = delegate.batchExtractionTask
            task?.cancel()
            await task?.value
        }
        var error: NSString = ""
        delegate.extractArchives(pasteboard, userData: "", error: &error)
        XCTAssertEqual(error, "")
        try await waitUntil { delegate.batchExtractionController?.destinationPanel != nil }
        let originalPanel = delegate.batchExtractionController?.destinationPanel
        XCTAssertNotNil(delegate.batchExtractionTask)
        delegate.extractArchives(pasteboard, userData: "", error: &error)
        XCTAssertEqual(error as String, String(localized: "別の操作が完了するまでお待ちください。"))
        delegate.extractArchivesFromMenu(nil)
        XCTAssertNil(delegate.batchExtractionOpenPanel)
        XCTAssertTrue(delegate.batchExtractionController?.destinationPanel === originalPanel)
        let task = delegate.batchExtractionTask
        task?.cancel()
        await task?.value
        XCTAssertNil(delegate.batchExtractionTask)
        XCTAssertNil(delegate.batchExtractionController)
    }

    @MainActor func testBatchPasswordSheetUsesStandaloneProgressWindowAndRemembersSuccessfulPassword() async throws {
        let directory = try ArchiveTestDirectory(), suite = try ArchivePreferencesTestDefaults(), bytes = Data("secret contents".utf8)
        let source = directory.url.appendingPathComponent("secret.txt"), archive = directory.url.appendingPathComponent("locked.zip")
        try bytes.write(to: source)
        try directory.run("/usr/bin/zip", ["-q", "-P", "batch-password", archive.path, "secret.txt"])
        let store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.folderPolicy = .always
        let vault = ArchivePasswordVault(key: SymmetricKey(size: .bits256), directory: directory.url.appendingPathComponent("vault"))
        let controller = ArchiveBatchExtractionController(store: store, passwordVault: vault)
        let documents = NSDocumentController.shared.documents.count
        let task = Task { await controller.extract(archives: [archive]) }
        addTeardownBlock { @MainActor in task.cancel(); _ = await task.value }
        try await waitUntil { controller.passwordPrompt != nil }
        let prompt = try XCTUnwrap(controller.passwordPrompt), sheet = try XCTUnwrap(controller.progressSheet)
        let window = try XCTUnwrap(sheet.window)
        XCTAssertNil(controller.destinationPanel)
        XCTAssertNil(window.sheetParent)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue(prompt.alert.window.sheetParent === window)
        XCTAssertTrue(prompt.alert.informativeText.contains(archive.lastPathComponent))
        XCTAssertEqual(window.title, ArchiveBatchExtractionController.progressTitle(count: 1))
        XCTAssertEqual(sheet.progress.totalUnitCount, 1)
        prompt.field.stringValue = "batch-password"
        prompt.rememberCheckbox.state = .on
        window.endSheet(prompt.alert.window, returnCode: .alertFirstButtonReturn)
        let completed = await task.value
        let report = try XCTUnwrap(completed)
        XCTAssertEqual(report.extracted, [archive])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: directory.url.appendingPathComponent("locked/secret.txt")), bytes)
        let saved = await vault.password(for: .file(archive))
        XCTAssertTrue(saved == "batch-password")
        XCTAssertTrue(prompt.field.stringValue.isEmpty)
        XCTAssertTrue(prompt.waiters.isEmpty)
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.progressSheet)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(NSDocumentController.shared.documents.count, documents)
    }

    @MainActor func testProgressCancellationDismissesPendingBatchPasswordSheet() async throws {
        let directory = try ArchiveTestDirectory(), suite = try ArchivePreferencesTestDefaults()
        let source = directory.url.appendingPathComponent("secret.txt"), archive = directory.url.appendingPathComponent("locked.zip")
        try Data("secret".utf8).write(to: source)
        try directory.run("/usr/bin/zip", ["-q", "-P", "batch-password", archive.path, "secret.txt"])
        let store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.folderPolicy = .always
        let vault = ArchivePasswordVault(key: SymmetricKey(size: .bits256), directory: directory.url.appendingPathComponent("vault"))
        let controller = ArchiveBatchExtractionController(store: store, passwordVault: vault)
        let task = Task { await controller.extract(archives: [archive]) }
        addTeardownBlock { @MainActor in task.cancel(); _ = await task.value }
        try await waitUntil { controller.passwordPrompt != nil }
        let prompt = try XCTUnwrap(controller.passwordPrompt), sheet = try XCTUnwrap(controller.progressSheet)
        prompt.field.stringValue = "discard this input"
        sheet.cancelExtraction(nil)
        let completed = await task.value
        let report = try XCTUnwrap(completed)
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.extracted.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(prompt.waiters.isEmpty)
        XCTAssertTrue(prompt.field.stringValue.isEmpty)
        XCTAssertNil(prompt.alert.window.sheetParent)
        XCTAssertNil(controller.passwordPrompt)
        XCTAssertNil(controller.progressSheet)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent("locked").path))
    }

    @MainActor func testBatchAlertsProgressAndPasswordNamesAreLocalizedWithCorrectPunctuation() throws {
        let app = Bundle(for: ArchiveDocument.self)
        let failures = [ArchiveBatchExtractor.Failure(archive: URL(fileURLWithPath: "/tmp/first.zip"), reason: "First reason"),
                        ArchiveBatchExtractor.Failure(archive: URL(fileURLWithPath: "/tmp/second.7z"), reason: "Second reason.")]
        for language in ["ja", "en"] {
            let bundle = try XCTUnwrap(Bundle(url: XCTUnwrap(app.url(forResource: language, withExtension: "lproj"))))
            let alert = try XCTUnwrap(ArchiveBatchExtractionController.failureAlert(
                for: .init(extracted: [], failures: failures, cancelled: false), bundle: bundle))
            let title = ArchiveBatchExtractionController.progressTitle(count: 2, bundle: bundle)
            let prompt = ArchivePasswordPrompt(challenge: .required, archiveName: "private.zip", bundle: bundle)
            let retry = ArchivePasswordPrompt(challenge: .incorrect, archiveName: "private.zip", bundle: bundle)
            XCTAssertTrue(prompt.alert.informativeText.contains("private.zip"))
            XCTAssertTrue(retry.alert.informativeText.contains("private.zip"))
            XCTAssertNotEqual(prompt.alert.informativeText, retry.alert.informativeText)
            XCTAssertFalse(prompt.alert.messageText.hasSuffix("。"))
            XCTAssertFalse(alert.messageText.hasSuffix("。"))
            if language == "ja" {
                XCTAssertEqual(alert.messageText, "2個のアーカイブを展開できませんでした")
                XCTAssertEqual(title, "2個のアーカイブを展開しています")
                XCTAssertEqual(prompt.alert.informativeText, "「private.zip」のパスワードを入力してください。")
                XCTAssertEqual(alert.informativeText, "first.zip: First reason。\nsecond.7z: Second reason。")
            } else {
                XCTAssertEqual(alert.messageText, "Could not extract 2 archives")
                XCTAssertEqual(title, "Extracting 2 archives")
                XCTAssertEqual(prompt.alert.informativeText, "Enter the password for “private.zip”.")
                XCTAssertEqual(alert.informativeText, "first.zip: First reason.\nsecond.7z: Second reason.")
            }
        }
        XCTAssertNil(ArchiveBatchExtractionController.failureAlert(for: .init(extracted: [], failures: [], cancelled: false)))
        XCTAssertNil(ArchiveBatchExtractionController.failureAlert(for: .init(extracted: [], failures: [], cancelled: true)))
    }
}
