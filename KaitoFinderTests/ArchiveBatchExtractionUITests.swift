import AppKit
import CryptoKit
import Synchronization
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
        preserveApplicationMenus()
        let app = Bundle(for: ArchiveDocument.self)
        for (language, title) in [("ja", "アーカイブを展開…"), ("en", "Expand Archives…")] {
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
        XCTAssertTrue(panel.allowedContentTypes.isEmpty)
        XCTAssertTrue(panel.delegate is ArchiveOpenPanelDelegate)
        // UTType は識別子を小文字に正規化する(com.shunnag.KaitoFinder.ar-archive → …kaitofinder…)。
        XCTAssertEqual(Set(ArchiveBatchExtractionController.archiveContentTypes(bundle: app).map { $0.identifier.lowercased() }),
                       Set(expected.map { $0.lowercased() }))
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
        XCTAssertEqual(AppDelegate.archivesToExtract(from: pasteboard), [first, second, directory.url])
    }

    @MainActor func testFinderExtractionRemovesDuplicateURLsPreservingOrder() throws {
        let directory = try ArchiveTestDirectory(), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else { throw XCTSkip("名前付きペーストボードを利用できない") }
        let first = directory.url.appendingPathComponent("first.zip"), second = directory.url.appendingPathComponent("second.7z")
        try Data().write(to: first)
        try Data().write(to: second)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first as NSURL, second as NSURL, first as NSURL]))
        XCTAssertEqual(AppDelegate.archivesToExtract(from: pasteboard), [first, second])
    }

    @MainActor func testFinderExtractionDeduplicatesStandardizedSymlinkPathsKeepingFirstURL() throws {
        let directory = try ArchiveTestDirectory(), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else { throw XCTSkip("名前付きペーストボードを利用できない") }
        let archive = directory.url.appendingPathComponent("archive.zip"), link = directory.url.appendingPathComponent("link.zip")
        let second = directory.url.appendingPathComponent("second.7z")
        try Data().write(to: archive)
        try Data().write(to: second)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)
        let normalized = directory.url.appendingPathComponent("./archive.zip")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([link as NSURL, second as NSURL, archive as NSURL, normalized as NSURL]))
        XCTAssertEqual(AppDelegate.archivesToExtract(from: pasteboard), [link, second])
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
        store.preferences.revealsExtractedItemsInFinder = true
        let revealed = Mutex<[[URL]]>([])
        let vault = ArchivePasswordVault(key: SymmetricKey(size: .bits256), directory: directory.url.appendingPathComponent("vault"))
        let controller = ArchiveBatchExtractionController(store: store, passwordVault: vault,
            reveal: { urls in revealed.withLock { $0.append(urls) } })
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
        XCTAssertEqual(sheet.detail, archive.lastPathComponent)
        prompt.field.stringValue = "batch-password"
        prompt.rememberCheckbox.state = .on
        window.endSheet(prompt.alert.window, returnCode: .alertFirstButtonReturn)
        let completed = await task.value
        let report = try XCTUnwrap(completed)
        XCTAssertEqual(report.extracted, [archive])
        XCTAssertEqual(revealed.withLock { $0 }, [[directory.url.appendingPathComponent("locked", isDirectory: true)]])
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

    @MainActor func testIncorrectRememberedBatchPasswordIsRemovedBeforePromptAndReplacedOnlyWhenRequested() async throws {
        for remember in [false, true] {
            let directory = try ArchiveTestDirectory(), suite = try ArchivePreferencesTestDefaults()
            let bytes = Data("secret contents".utf8), password = "batch-password"
            let source = directory.url.appendingPathComponent("secret.txt")
            let archive = directory.url.appendingPathComponent("locked.zip")
            try bytes.write(to: source)
            try directory.run("/usr/bin/zip", ["-q", "-P", password, archive.path, "secret.txt"])
            let store = ArchivePreferencesStore(defaults: suite.defaults)
            store.preferences.folderPolicy = .always
            let vault = ArchivePasswordVault(key: SymmetricKey(size: .bits256),
                                             directory: directory.url.appendingPathComponent("vault"))
            let saved = await vault.save("incorrect remembered value", for: .file(archive))
            XCTAssertTrue(saved)
            let controller = ArchiveBatchExtractionController(store: store, passwordVault: vault, reveal: { _ in })
            var challenges: [ArchivePasswordChallenge] = []
            let report = await controller.extract(archives: [archive], base: nil, preferences: store.preferences, progress: Progress(),
                passwordPrompt: { url, challenge in
                    XCTAssertEqual(url, archive)
                    challenges.append(challenge)
                    let stored = await vault.password(for: .file(archive))
                    XCTAssertNil(stored, "失効した記憶値は入力を求める前に削除する")
                    return ArchivePasswordResponse(password: password, remember: remember)
                })
            XCTAssertEqual(challenges, [.incorrect])
            XCTAssertEqual(report.extracted, [archive])
            XCTAssertTrue(report.failures.isEmpty)
            XCTAssertFalse(report.cancelled)
            XCTAssertEqual(try Data(contentsOf: directory.url.appendingPathComponent("locked/secret.txt")), bytes)
            let stored = await vault.password(for: .file(archive))
            XCTAssertEqual(stored, remember ? password : nil)
            XCTAssertNil(controller.destinationPanel)
            XCTAssertNil(controller.progressSheet)
            XCTAssertNil(controller.passwordPrompt)
        }
    }

    @MainActor func testIncorrectRememberedBatchPasswordIsInvalidatedOnlyOnce() async throws {
        let directory = try ArchiveTestDirectory(), suite = try ArchivePreferencesTestDefaults()
        let source = directory.url.appendingPathComponent("secret.txt")
        let archive = directory.url.appendingPathComponent("locked.zip")
        try Data("secret contents".utf8).write(to: source)
        try directory.run("/usr/bin/zip", ["-q", "-P", "batch-password", archive.path, "secret.txt"])
        let store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.folderPolicy = .always
        let vault = ArchivePasswordVault(key: SymmetricKey(size: .bits256),
                                         directory: directory.url.appendingPathComponent("vault"))
        let oldPassword = "incorrect remembered value"
        let saved = await vault.save(oldPassword, for: .file(archive))
        XCTAssertTrue(saved)
        let controller = ArchiveBatchExtractionController(store: store, passwordVault: vault, reveal: { _ in })
        var challenges: [ArchivePasswordChallenge] = []
        let report = await controller.extract(archives: [archive], base: nil, preferences: store.preferences, progress: Progress(),
            passwordPrompt: { _, challenge in
                challenges.append(challenge)
                let stored = await vault.password(for: .file(archive))
                if challenges.count == 1 {
                    XCTAssertNil(stored)
                    // 同じ値が別の操作で再保存されても、二度目の再入力では削除しない。
                    let savedAgain = await vault.save(oldPassword, for: .file(archive))
                    XCTAssertTrue(savedAgain)
                    return ArchivePasswordResponse(password: "another incorrect value", remember: false)
                }
                XCTAssertEqual(stored, oldPassword)
                return ArchivePasswordResponse(password: "batch-password", remember: false)
            })
        XCTAssertEqual(challenges, [.incorrect, .incorrect])
        XCTAssertEqual(report.extracted, [archive])
        XCTAssertTrue(report.failures.isEmpty)
        let stored = await vault.password(for: .file(archive))
        XCTAssertEqual(stored, oldPassword)
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
                XCTAssertEqual(title, "2個のアーカイブを展開中…")
                XCTAssertEqual(prompt.alert.informativeText, "“private.zip”のパスワードを入力してください。")
                XCTAssertEqual(alert.informativeText, "first.zip: First reason。\nsecond.7z: Second reason。")
            } else {
                XCTAssertEqual(alert.messageText, "Could not expand 2 archives")
                XCTAssertEqual(title, "Expanding 2 Archives…")
                XCTAssertEqual(prompt.alert.informativeText, "Please enter the password for “private.zip”.")
                XCTAssertEqual(alert.informativeText, "first.zip: First reason.\nsecond.7z: Second reason.")
            }
        }
        XCTAssertNil(ArchiveBatchExtractionController.failureAlert(for: .init(extracted: [], failures: [], cancelled: false)))
        XCTAssertNil(ArchiveBatchExtractionController.failureAlert(for: .init(extracted: [], failures: [], cancelled: true)))
    }

    @MainActor func testProgressTitlesForEveryOperationInJapaneseAndEnglish() throws {
        let cases: [(ArchiveProgressOperation, String, String)] = [
            (.expanding, "項目を展開中…", "Extracting…"),
            (.adding, "項目を追加中…", "Adding…"),
            (.moving, "項目を移動中…", "Moving…"),
            (.deleting, "項目を削除中…", "Deleting…"),
            (.renaming, "名称を変更中…", "Renaming…"),
            (.creatingFolder, "フォルダを作成中…", "Creating Folder…"),
            (.creatingArchive, "アーカイブを作成中…", "Creating Archive…"),
            (.expandingArchive("smoke.zip"), "“smoke.zip”を展開中…", "Expanding “smoke.zip”…"),
            (.expandingArchives(12), "12個のアーカイブを展開中…", "Expanding 12 Archives…")
        ]
        let app = Bundle(for: ArchiveDocument.self)
        for language in ["ja", "en"] {
            let bundle = try XCTUnwrap(Bundle(url: XCTUnwrap(app.url(forResource: language, withExtension: "lproj"))))
            for (operation, japanese, english) in cases {
                let expected = language == "ja" ? japanese : english
                XCTAssertEqual(operation.title(bundle: bundle), expected)
                let progress = Progress(totalUnitCount: 10)
                let sheet = ExtractionProgressSheet(progress: progress, title: operation.title(bundle: bundle), bundle: bundle)
                defer { sheet.finish() }
                XCTAssertEqual(sheet.window?.title, expected)
                XCTAssertEqual(sheet.titleLabel.stringValue, expected)
                progress.completedUnitCount = 3
                sheet.detail = "photo.jpg"
                XCTAssertEqual(sheet.statusLabel.stringValue,
                    String(localized: "\(progress.completedUnitCount) / \(progress.totalUnitCount)項目", bundle: bundle))
                XCTAssertEqual(sheet.detailLabel.stringValue, "photo.jpg")
                sheet.cancelExtraction(nil)
                XCTAssertTrue(progress.isCancelled)
            }
            let defaultSheet = ExtractionProgressSheet(progress: Progress(), bundle: bundle)
            defer { defaultSheet.finish() }
            XCTAssertEqual(defaultSheet.window?.title, ArchiveProgressOperation.expanding.title(bundle: bundle))
        }
    }

}
