import AppKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class LayoutOverflowTests: XCTestCase {
    private var longArchiveName: String {
        String(String(repeating: "旅行の写真 Archive ", count: 6).prefix(66)) + ".zip"
    }

    @MainActor private func forEachLanguage(_ body: (String, Bundle) throws -> Void) throws {
        let app = Bundle(for: ArchiveDocument.self)
        for language in ["ja", "en"] {
            let url = try XCTUnwrap(app.url(forResource: language, withExtension: "lproj"), language)
            try body(language, XCTUnwrap(Bundle(url: url), language))
        }
    }

    @MainActor private func checkOverflow(_ view: NSView, name: String, file: StaticString, line: UInt) {
        let violations = UISnapshot.overflowViolations(in: view)
        XCTAssertTrue(violations.isEmpty, "\(name)\n" + violations.joined(separator: "\n"), file: file, line: line)
    }

    // 描画と添付を先に済ませ、はみ出しで失敗しても画像を残す。
    @MainActor private func snapshot(_ view: NSView, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try UISnapshot.render(view, name: name)
        checkOverflow(view, name: name, file: file, line: line)
    }

    @MainActor private func snapshot(_ window: NSWindow, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try UISnapshot.render(window, name: name)
        checkOverflow(try XCTUnwrap(window.contentView), name: name, file: file, line: line)
    }

    @MainActor private func snapshot(_ alert: NSAlert, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try UISnapshot.render(alert, name: name)
        checkOverflow(try XCTUnwrap(alert.window.contentView), name: name, file: file, line: line)
    }

    @MainActor func testPasswordPromptsInJapaneseAndEnglish() throws {
        XCTAssertEqual(longArchiveName.count, 70)
        try forEachLanguage { language, bundle in
            let names: [(String, String?)] = [("no-name", nil), ("short-name", "写真.zip"), ("long-name", longArchiveName)]
            let challenges: [(String, ArchivePasswordChallenge)] = [("required", .required), ("incorrect", .incorrect)]
            for (state, challenge) in challenges {
                for (kind, archiveName) in names {
                    let prompt = ArchivePasswordPrompt(challenge: challenge, archiveName: archiveName, bundle: bundle)
                    let name = "\(language)-password-\(state)-\(kind)"
                    try snapshot(prompt.alert, name: name)
                    XCTAssertLessThanOrEqual(prompt.alert.window.frame.width, 500, name)
                    XCTAssertGreaterThanOrEqual(prompt.field.bounds.width, 300, name)
                }
            }
        }
    }

    @MainActor func testLockedWindowAndFooterInJapaneseAndEnglish() throws {
        try forEachLanguage { language, bundle in
            let controller = ArchiveWindowController(bundle: bundle)
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            window.setFrameAutosaveName("")
            controller.outlineView.autosaveTableColumns = false
            window.setContentSize(NSSize(width: 1040, height: 684))
            controller.displayLocked()
            window.layoutIfNeeded()
            let content = try XCTUnwrap(window.contentView)
            XCTAssertEqual(content.bounds.size, NSSize(width: 1040, height: 684))
            try snapshot(content, name: "\(language)-locked-window")
            let footer = try XCTUnwrap(content.subviews.first { $0.identifier?.rawValue == "archive.footer" } as? NSStackView)
            XCTAssertFalse(footer.isHidden)
            XCTAssertTrue(footer.arrangedSubviews.contains { $0 is NSButton && !$0.isHidden })
            try snapshot(footer, name: "\(language)-locked-footer")
        }
    }

    @MainActor func testSettingsTabsInJapaneseAndEnglish() throws {
        try forEachLanguage { language, bundle in
            let suite = try ArchivePreferencesTestDefaults()
            let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults), bundle: bundle)
            defer { controller.close() }
            controller.window?.setFrameAutosaveName("")
            let tabs = ["general", "compression", "extraction"]
            XCTAssertEqual(controller.tabController.tabViewItems.count, tabs.count)
            for (index, tab) in tabs.enumerated() {
                controller.tabController.selectedTabViewItemIndex = index
                controller.window?.layoutIfNeeded()
                try snapshot(controller.tabController.view, name: "\(language)-settings-\(tab)")
            }
        }
    }

    private func entry(encrypted: Bool) -> ArchiveEntry {
        ArchiveEntry(index: 0, rawName: RawName(bytes: Array("file.txt".utf8)), name: "file.txt", pathComponents: ["file.txt"],
                     kind: .file, uncompressedSize: 1, compressedSize: 1, modificationDate: nil, posixPermissions: nil,
                     isEncrypted: encrypted, solidGroup: -1, crc32: nil, methodDescription: "stored", formatSpecific: [:])
    }

    @MainActor func testConversionAlertsInJapaneseAndEnglish() throws {
        try forEachLanguage { language, bundle in
            for encrypted in [false, true] {
                let alert = ArchiveConversionNotice.makeAlert(formatName: "7z", entries: [entry(encrypted: encrypted)], bundle: bundle)
                try snapshot(alert, name: "\(language)-conversion-\(encrypted ? "encrypted" : "plain")")
            }
        }
    }

    @MainActor func testDeleteConfirmationInJapaneseAndEnglish() throws {
        try forEachLanguage { language, bundle in
            try snapshot(ArchiveWindowController.makeDeletionConfirmation(bundle: bundle), name: "\(language)-delete-confirmation")
        }
    }

    @MainActor func testImportFailureAlertsInJapaneseAndEnglish() throws {
        try forEachLanguage { language, bundle in
            let reason = (1...3).map { index in
                "\(index)-\(longArchiveName): " + String(localized: "このアーカイブは変更できません。", bundle: bundle)
            }.joined(separator: "\n")
            for added in [false, true] {
                let alert = ArchiveWindowController.makeImportFailureAlert(reason, added: added, bundle: bundle)
                try snapshot(alert, name: "\(language)-import-failure-\(added ? "reload" : "unchanged")")
            }
        }
    }

    @MainActor func testEditFailureAlertsInJapaneseAndEnglish() throws {
        try forEachLanguage { language, bundle in
            let reason = String(localized: "選択した項目とアーカイブ内の項目が一致しません。アーカイブを開き直してください。", bundle: bundle)
            for published in [false, true] {
                let alert = ArchiveWindowController.makeEditFailureAlert(reason, published: published, bundle: bundle)
                try snapshot(alert, name: "\(language)-edit-failure-\(published ? "reload" : "unchanged")")
            }
        }
    }

    @MainActor func testExtractionFailureAlertsInJapaneseAndEnglish() throws {
        try forEachLanguage { language, bundle in
            let reason = String(localized: "アーカイブが閉じられています。", bundle: bundle)
            try snapshot(ArchiveWindowController.makeFailureAlert(reason, bundle: bundle), name: "\(language)-extraction-failure")
        }
    }

    @MainActor func testBatchExtractionFailureAlertInJapaneseAndEnglish() throws {
        try forEachLanguage { language, bundle in
            let reason = String(localized: "このアーカイブは変更できません。", bundle: bundle)
            let failures = ["写真.zip", "documents.7z", longArchiveName].map {
                ArchiveBatchExtractor.Failure(archive: URL(fileURLWithPath: "/tmp").appendingPathComponent($0), reason: reason)
            }
            let alert = try XCTUnwrap(ArchiveBatchExtractionController.failureAlert(
                for: .init(extracted: [], failures: failures, cancelled: false), bundle: bundle))
            try snapshot(alert, name: "\(language)-batch-extraction-failure")
        }
    }

    @MainActor func testSavePanelAccessoryInJapaneseAndEnglish() throws {
        try forEachLanguage { language, bundle in
            let suite = try ArchivePreferencesTestDefaults()
            let save = ArchiveSavePanel(sources: [URL(fileURLWithPath: "/tmp/写真.jpg")], defaults: suite.defaults, bundle: bundle)
            let accessory = try XCTUnwrap(save.panel.accessoryView)
            // 保存パネル本体を開かず、実際に渡されたアクセサリを監査する。
            try snapshot(accessory, name: "\(language)-save-panel-accessory")
        }
    }

    @MainActor func testStandaloneProgressSheetInJapaneseAndEnglish() throws {
        try forEachLanguage { language, bundle in
            let progress = Progress(totalUnitCount: 1_000)
            progress.completedUnitCount = 345
            let title = String(localized: "項目を展開しています", bundle: bundle) + " — " + longArchiveName
            let sheet = ExtractionProgressSheet(progress: progress, title: title, bundle: bundle)
            defer { sheet.finish() }
            sheet.beginStandalone()
            let window = try XCTUnwrap(sheet.window)
            XCTAssertNil(window.sheetParent)
            XCTAssertEqual(window.title, title)
            try snapshot(window, name: "\(language)-standalone-progress")
        }
    }
}
