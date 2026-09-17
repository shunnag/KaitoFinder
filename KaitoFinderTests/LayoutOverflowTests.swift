import AppKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class LayoutOverflowTests: XCTestCase {
    private var longArchiveName: String {
        String(String(repeating: "旅行の写真 Archive ", count: 6).prefix(66)) + ".zip"
    }

    @MainActor private func forEachLanguage(_ languages: [String] = LocalizationAcceptance.languages, _ body: (String, Bundle) throws -> Void) throws {
        let app = Bundle(for: ArchiveDocument.self)
        for language in languages {
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

    @MainActor func testPasswordPromptsInEveryLanguage() throws {
        XCTAssertEqual(longArchiveName.count, 70)
        try forEachLanguage(LocalizationAcceptance.languages) { language, bundle in
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

    @MainActor func testLockedPlaceholderInEveryLanguage() throws {
        let frameAutosave = ArchiveWindowFrameAutosave()
        defer { frameAutosave.restore() }
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
            XCTAssertFalse(footer.arrangedSubviews.contains { $0 is NSButton })
            XCTAssertTrue(controller.outlineView.isHiddenOrHasHiddenAncestor)
            XCTAssertFalse(controller.lockedPlaceholder.isHidden)
            XCTAssertTrue(controller.statusBar.isHidden)
            XCTAssertFalse(controller.searchField.isEnabled)
            XCTAssertEqual(controller.unlockButton.title, String(localized: "ロックを解除…", bundle: bundle))
            XCTAssertEqual(controller.unlockButton.keyEquivalent, "\r")
            XCTAssertTrue(window.defaultButtonCell === controller.unlockButton.cell)
            for item in try XCTUnwrap(window.toolbar).items where item.itemIdentifier != .flexibleSpace && item.itemIdentifier != .space {
                XCTAssertFalse(controller.validateToolbarItem(item), item.label)
                XCTAssertFalse(item.isEnabled, item.label)
            }
            let placeholder = controller.lockedPlaceholder
            let stack = try XCTUnwrap(placeholder.subviews.first as? NSStackView)
            XCTAssertEqual(stack.frame.midX, placeholder.bounds.midX, accuracy: 0.5)
            XCTAssertEqual(stack.frame.midY, placeholder.bounds.midY, accuracy: 0.5)
            try snapshot(placeholder, name: "\(language)-locked-placeholder")
            window.setContentSize(NSSize(width: 600, height: 300))
            try snapshot(window, name: "\(language)-locked-window-small")
        }
    }

    @MainActor func testSettingsTabsInEveryLanguage() throws {
        try forEachLanguage(LocalizationAcceptance.languages) { language, bundle in
            let suite = try ArchivePreferencesTestDefaults()
            let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults), bundle: bundle)
            defer { controller.close() }
            controller.window?.setFrameAutosaveName("")
            let tabs = ["general", "compression", "extraction"]
            XCTAssertEqual(controller.tabController.tabViewItems.count, tabs.count)
            let window = try XCTUnwrap(controller.window)
            XCTAssertFalse(window.styleMask.contains(.resizable))
            if let visible = window.screen?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
            }
            let initialSize = try XCTUnwrap(window.contentView).bounds.size
            XCTAssertGreaterThanOrEqual(initialSize.width, 560)
            var heights: [CGFloat] = []
            for (index, tab) in tabs.enumerated() {
                let top = window.frame.maxY
                controller.tabController.selectedTabViewItemIndex = index
                controller.window?.layoutIfNeeded()
                let pane = try XCTUnwrap(controller.tabController.tabViewItems[index].viewController)
                let content = try XCTUnwrap(window.contentView)
                XCTAssertEqual(content.bounds.width, initialSize.width, accuracy: 0.5, language)
                XCTAssertEqual(content.bounds.height, pane.preferredContentSize.height, accuracy: 0.5, language)
                XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, language)
                heights.append(content.bounds.height)
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                    try snapshot(content, name: "\(language)-settings-\(tab)-\(name)")
                    if ["ja", "en"].contains(language), let frame = content.superview {
                        try UISnapshot.render(frame, name: "\(language)-settings-\(tab)-\(name)-window")
                    }
                }
                window.appearance = nil
                if index == 1 {
                    for (slider, label) in [(controller.zipLevelSlider, controller.zipLevelLabel),
                                            (controller.tarGzipLevelSlider, controller.tarGzipLevelLabel)] {
                        let original = label.frame
                        for level in [6, 9] {
                            slider.integerValue = level
                            XCTAssertTrue(slider.sendAction(slider.action, to: slider.target))
                            window.layoutIfNeeded()
                            XCTAssertEqual(label.alignment, .right)
                            XCTAssertEqual(label.frame, original)
                            // NSTextFieldの描画余白を除いた整列領域が固定の24ポイント幅。
                            XCTAssertEqual(label.alignmentRect(forFrame: label.frame).width, 24, accuracy: 0.5)
                        }
                    }
                    try snapshot(controller.tabController.view, name: "\(language)-settings-compression-level-9")
                }
                if index == 0 || index == 2 {
                    let popups = index == 0 ? [controller.defaultFormatPopup, controller.openingBehaviorPopup]
                        : [controller.extractionDestinationPopup, controller.afterExpansionPopup, controller.folderPolicyPopup]
                    for popup in popups {
                        for item in 0..<popup.numberOfItems {
                            popup.selectItem(at: item)
                            XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
                            window.layoutIfNeeded()
                            checkOverflow(controller.tabController.view, name: "\(language)-settings-\(tab)-\(item)", file: #filePath, line: #line)
                        }
                    }
                }
            }
            XCTAssertGreaterThan(heights[1], heights[0], language)
            XCTAssertGreaterThan(heights[1], heights[2], language)
            controller.tabController.selectedTabViewItemIndex = 0
            window.layoutIfNeeded()
            XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.size, initialSize, language)
        }
    }

    @MainActor func testWelcomeWindowInEveryLanguageAndAppearance() throws {
        try forEachLanguage(LocalizationAcceptance.languages) { language, bundle in
            let suite = try ArchivePreferencesTestDefaults()
            let controller = WelcomeWindowController(store: ArchivePreferencesStore(defaults: suite.defaults),
                bundle: bundle, createAction: {}, createDropAction: { _, _ in })
            defer { controller.close() }
            let content = try XCTUnwrap(controller.window?.contentView)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                content.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                content.setFrameSize(WelcomeWindowController.contentSize)
                try snapshot(content, name: "\(language)-welcome-\(name)")
                XCTAssertEqual(content.bounds.size, NSSize(width: 720, height: 440))
                XCTAssertEqual(controller.openDropZone.frame.width, controller.createDropZone.frame.width)
                XCTAssertEqual(controller.createDropZone.frame.minX - controller.openDropZone.frame.maxX, 24, accuracy: 0.5)
                for zone in [controller.openDropZone, controller.createDropZone] {
                    // 省略で監査を通さず、全キャプションを最大二行で見せる。
                    XCTAssertEqual(zone.captionLabel.lineBreakMode, .byWordWrapping)
                    let font = try XCTUnwrap(zone.captionLabel.font)
                    let twoLines = ceil(NSLayoutManager().defaultLineHeight(for: font)) * 2 + 2
                    XCTAssertLessThanOrEqual(zone.captionLabel.bounds.height, twoLines, language)
                }
            }
        }
    }

    private func entry(encrypted: Bool) -> ArchiveEntry {
        ArchiveEntry(index: 0, rawName: RawName(bytes: Array("file.txt".utf8)), name: "file.txt", pathComponents: ["file.txt"],
                     kind: .file, uncompressedSize: 1, compressedSize: 1, modificationDate: nil, posixPermissions: nil,
                     isEncrypted: encrypted, solidGroup: -1, crc32: nil, methodDescription: "stored", formatSpecific: [:])
    }

    @MainActor func testConversionAlertsInEveryLanguage() throws {
        try forEachLanguage { language, bundle in
            for encrypted in [false, true] {
                let alert = ArchiveConversionNotice.makeAlert(formatName: "7z", entries: [entry(encrypted: encrypted)], bundle: bundle)
                try snapshot(alert, name: "\(language)-conversion-\(encrypted ? "encrypted" : "plain")")
            }
        }
    }

    @MainActor func testDeleteConfirmationInEveryLanguage() throws {
        try forEachLanguage { language, bundle in
            try snapshot(ArchiveWindowController.makeDeletionConfirmation(bundle: bundle), name: "\(language)-delete-confirmation")
        }
    }

    @MainActor func testImportFailureAlertsInEveryLanguage() throws {
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

    @MainActor func testEditFailureAlertsInEveryLanguage() throws {
        try forEachLanguage { language, bundle in
            let reason = String(localized: "選択した項目とアーカイブ内の項目が一致しません。アーカイブを開き直してください。", bundle: bundle)
            for published in [false, true] {
                let alert = ArchiveWindowController.makeEditFailureAlert(reason, published: published, bundle: bundle)
                try snapshot(alert, name: "\(language)-edit-failure-\(published ? "reload" : "unchanged")")
            }
        }
    }

    @MainActor func testExtractionFailureAlertsInEveryLanguage() throws {
        try forEachLanguage { language, bundle in
            let reason = String(localized: "アーカイブが閉じられています。", bundle: bundle)
            try snapshot(ArchiveWindowController.makeFailureAlert(reason, bundle: bundle), name: "\(language)-extraction-failure")
        }
    }

    @MainActor func testBatchExtractionFailureAlertInEveryLanguage() throws {
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

    @MainActor func testSavePanelAccessoryInEveryLanguageAndFormat() throws {
        try forEachLanguage(LocalizationAcceptance.languages) { language, bundle in
            let suite = try ArchivePreferencesTestDefaults()
            let save = ArchiveSavePanel(sources: [URL(fileURLWithPath: "/tmp/写真.jpg")], defaults: suite.defaults, bundle: bundle)
            let accessory = try XCTUnwrap(save.panel.accessoryView)
            // 保存パネル本体を開かず、実際に渡されたアクセサリを監査する。
            for (index, format) in ArchiveSavePanelController.formats.enumerated() {
                save.formatPopup.selectItem(at: index)
                XCTAssertTrue(save.formatPopup.sendAction(save.formatPopup.action, to: save.formatPopup.target))
                for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    accessory.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                    try snapshot(accessory, name: "\(language)-save-panel-\(ArchiveCreationPlan.filenameExtension(for: format))-\(style)")
                }
                XCTAssertGreaterThanOrEqual(accessory.bounds.width, 360, language)
            }
        }
    }

    @MainActor func testStandaloneProgressSheetTruncates120CharacterNamesInEveryLanguage() throws {
        try forEachLanguage(LocalizationAcceptance.languages) { language, bundle in
            let progress = Progress(totalUnitCount: 1_000)
            progress.completedUnitCount = 345
            let archiveName = String(String(repeating: "旅行の写真 Archive ", count: 10).prefix(116)) + ".zip"
            let detail = String(String(repeating: "長いファイル名 VeryLongFileName_", count: 8).prefix(116)) + ".jpg"
            XCTAssertEqual(archiveName.count, 120)
            XCTAssertEqual(detail.count, 120)
            let title = ArchiveProgressOperation.expandingArchive(archiveName).title(bundle: bundle)
            let sheet = ExtractionProgressSheet(progress: progress, title: title, detail: detail, bundle: bundle)
            defer { sheet.finish() }
            sheet.beginStandalone()
            let window = try XCTUnwrap(sheet.window)
            XCTAssertNil(window.sheetParent)
            XCTAssertEqual(window.title, title)
            XCTAssertEqual(sheet.titleLabel.stringValue, title)
            XCTAssertEqual(sheet.detailLabel.stringValue, detail)
            for label in [sheet.titleLabel, sheet.detailLabel] {
                XCTAssertTrue(label.usesSingleLineMode, language)
                XCTAssertEqual(label.maximumNumberOfLines, 1, language)
                XCTAssertEqual(label.lineBreakMode, .byTruncatingMiddle, language)
                XCTAssertEqual(label.cell?.wraps, false, language)
            }
            XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.width, 420)
            try snapshot(window, name: "\(language)-standalone-progress")
            let height = try XCTUnwrap(window.contentView).bounds.height
            sheet.detail = String(repeating: "a", count: 116) + ".txt"
            XCTAssertEqual(sheet.detail.count, 120)
            XCTAssertEqual(window.contentView?.bounds.height, height)
            try snapshot(window, name: "\(language)-progress-unbroken-name")
            sheet.detail = ""
            XCTAssertTrue(sheet.detailLabel.isHidden)
            XCTAssertEqual(sheet.statusLabel.stringValue, String(localized: "\(progress.completedUnitCount) / \(progress.totalUnitCount)項目", bundle: bundle))
            try snapshot(window, name: "\(language)-progress-no-item")
        }
    }

    @MainActor func testStatusBarWithLargeCountsInEveryLanguage() throws {
        let frameAutosave = ArchiveWindowFrameAutosave()
        defer { frameAutosave.restore() }
        try forEachLanguage { language, bundle in
            let controller = ArchiveWindowController(bundle: bundle)
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            window.setFrameAutosaveName("")
            window.setContentSize(NSSize(width: 600, height: 300))
            controller.display(EntryNode.tree(from: []))
            let states: [(String, Int?, Int)] = [("all", nil, 0), ("filter", 876_543_210, 0), ("selection", nil, 876_543_210)]
            for (state, filtered, selected) in states {
                controller.statusBar.stringValue = ArchiveStatusBarText.text(totalCount: 987_654_321,
                    totalSize: 9_876_543_210_000, filteredCount: filtered, selectedCount: selected,
                    selectedSize: 8_765_432_100_000, bundle: bundle)
                window.layoutIfNeeded()
                XCTAssertEqual(controller.statusBar.alignment, .center)
                XCTAssertEqual(controller.statusBar.frame.midX, try XCTUnwrap(window.contentView).bounds.midX, accuracy: 0.5)
                try snapshot(controller.statusBar, name: "\(language)-status-\(state)")
            }
        }
    }

}
