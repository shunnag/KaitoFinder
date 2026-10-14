import AppKit
import GyoshukuKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePreferencesUITests: XCTestCase {
    @MainActor func testFolderOpeningPopupPersistsAndRefreshes() throws {
        _ = NSApplication.shared
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let controller = PreferencesWindowController(store: store)
        defer { controller.close() }
        let popup = controller.folderOpeningPopup
        XCTAssertEqual(popup.itemTitles, [String(localized: "フォルダに移動"), String(localized: "その場で展開")])
        XCTAssertEqual(popup.accessibilityLabel(), String(localized: "フォルダを開くとき:"))
        XCTAssertEqual(popup.indexOfSelectedItem, 0)
        popup.selectItem(at: 1)
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        XCTAssertEqual(store.preferences.folderOpening, .expand)
        store.preferences.folderOpening = .enter
        XCTAssertEqual(popup.indexOfSelectedItem, 0)
        controller.viewModel.selectFolderOpening(at: -1)
        controller.viewModel.selectFolderOpening(at: 2)
        XCTAssertEqual(store.preferences.folderOpening, .enter)
    }

    @MainActor func testCompressionThreadViewModelChoicesAndMemoryWarning() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        for hardware in [ArchiveHardware(processors: 8, memory: 8 << 30, automaticThreads: 8),
                         ArchiveHardware(processors: 16, memory: 128 << 30, automaticThreads: 16),
                         ArchiveHardware(processors: 4, memory: 2 << 30, automaticThreads: 2)] {
            store.preferences.compressionThreads = 0
            let model = PreferencesViewModel(store: store, hardware: hardware)
            XCTAssertEqual(model.compressionThreadChoices, Array(0...hardware.processors))
            XCTAssertEqual(model.compressionThreadIndex, 0)
            for index in model.compressionThreadChoices {
                model.selectCompressionThreads(at: index)
                XCTAssertEqual(store.preferences.compressionThreads, index)
                XCTAssertEqual(model.compressionThreadIndex, index)
                let threads = index == 0 ? hardware.automaticCompressionThreads() : index
                let bytes = ArchiveHardware.estimatedLZMA2Memory(threads: threads)
                XCTAssertTrue(model.memoryNote.text.contains(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)))
                XCTAssertEqual(model.memoryNote.warns, bytes > hardware.memory / 4)
            }
            let before = store.preferences
            model.selectCompressionThreads(at: -1)
            model.selectCompressionThreads(at: hardware.processors + 1)
            XCTAssertEqual(store.preferences, before)
        }
        store.preferences.compressionThreads = 4
        let threshold = ArchiveHardware.estimatedLZMA2Memory(threads: 4) * 4
        XCTAssertFalse(PreferencesViewModel(store: store, hardware: .init(processors: 4, memory: threshold)).memoryNote.warns)
        XCTAssertTrue(PreferencesViewModel(store: store, hardware: .init(processors: 4, memory: threshold - 4)).memoryNote.warns)
    }

    @MainActor func testCompressionThreadPopupPersistsRefreshesAndKeepsTabHeight() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        for hardware in [ArchiveHardware(processors: 8, memory: 8 << 30, automaticThreads: 8),
                         ArchiveHardware(processors: 16, memory: 128 << 30, automaticThreads: 16),
                         ArchiveHardware(processors: 4, memory: 2 << 30, automaticThreads: 2)] {
            for saved in [0, 20] {
                store.preferences.compressionThreads = saved
                let controller = PreferencesWindowController(store: store, hardware: hardware)
                defer { controller.close() }
                let window = try XCTUnwrap(controller.window)
                window.setFrameAutosaveName("")
                controller.tabController.selectedTabViewItemIndex = 3
                window.layoutIfNeeded()
                let pane = try XCTUnwrap(controller.tabController.tabViewItems[3].viewController)
                let content = try XCTUnwrap(window.contentView)
                let height = pane.preferredContentSize.height
                let choices = Array(0...max(hardware.processors, saved))
                let automatic = String(format: String(localized: "自動（%lld）"), hardware.automaticCompressionThreads())
                XCTAssertEqual(controller.compressionThreadsPopup.itemTitles, [automatic] + choices.dropFirst().map { String($0) })
                XCTAssertEqual(controller.compressionThreadsPopup.indexOfSelectedItem, saved)
                XCTAssertEqual(controller.compressionThreadsPopup.accessibilityLabel(), String(localized: "圧縮の並列数:"))
                for threads in choices {
                    store.preferences.compressionThreads = saved
                    controller.compressionThreadsPopup.selectItem(at: threads)
                    sendAction(controller.compressionThreadsPopup)
                    window.layoutIfNeeded()
                    XCTAssertEqual(store.preferences.compressionThreads, threads)
                    XCTAssertEqual(controller.compressionThreadsPopup.indexOfSelectedItem, threads)
                    XCTAssertEqual(pane.preferredContentSize.height, height, accuracy: 0.5)
                    XCTAssertEqual(content.bounds.height, height, accuracy: 0.5)
                    XCTAssertEqual(controller.compressionMemoryNote.stringValue, controller.viewModel.memoryNote.text)
                }
                store.preferences.compressionThreads = 0
                XCTAssertEqual(controller.compressionThreadsPopup.indexOfSelectedItem, 0)
                controller.compressionThreadsPopup.selectItem(at: 1)
                controller.showWindow(nil)
                XCTAssertEqual(controller.compressionThreadsPopup.indexOfSelectedItem, 0)
            }
        }
    }

    @MainActor func testCompressionMemoryWarningTextAndColorFollowSelection() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let controller = PreferencesWindowController(store: store, hardware: .init(processors: 4, memory: 2 << 30, automaticThreads: 2))
        defer { controller.close() }
        let warning = String(localized: "物理メモリに対して大きいため、ほかの処理が遅くなることがあります。")
        let automatic = controller.compressionMemoryNote.stringValue
        XCTAssertFalse(automatic.contains(warning))
        XCTAssertEqual(controller.compressionMemoryNote.textColor, .secondaryLabelColor)
        controller.compressionThreadsPopup.selectItem(at: 4)
        sendAction(controller.compressionThreadsPopup)
        XCTAssertNotEqual(controller.compressionMemoryNote.stringValue, automatic)
        XCTAssertTrue(controller.compressionMemoryNote.stringValue.contains(warning))
        XCTAssertEqual(controller.compressionMemoryNote.textColor, .systemOrange)
        store.preferences.compressionThreads = 0
        XCTAssertEqual(controller.compressionMemoryNote.stringValue, automatic)
        XCTAssertEqual(controller.compressionMemoryNote.textColor, .secondaryLabelColor)
    }

    @MainActor func testViewModelEveryControlUpdatesStore() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let model = PreferencesViewModel(store: store)
        var expected = ArchivePreferences()
        func check() { XCTAssertEqual(ArchivePreferencesStore(defaults: suite.defaults).preferences, expected) }
        for (index, format) in ArchivePreferences.formats.enumerated() {
            model.selectDefaultFormat(at: index)
            expected.defaultFormat = format
            check()
        }
        for (index, behavior) in PreferencesViewModel.saveBehaviors.enumerated() {
            model.selectSaveBehavior(at: index)
            expected.saveBehavior = behavior
            check()
            XCTAssertEqual(model.saveBehaviorIndex, index)
        }
        for (index, behavior) in PreferencesViewModel.openingBehaviors.enumerated() {
            model.selectOpeningBehavior(at: index)
            expected.openingBehavior = behavior
            check()
            XCTAssertEqual(model.openingBehaviorIndex, index)
        }
        for (index, position) in PreferencesViewModel.additionPositions.enumerated() {
            model.changeAdditionPosition(to: position)
            expected.additionPosition = position
            check()
            XCTAssertEqual(model.additionPositionIndex, index)
        }
        for (index, owners) in PreferencesViewModel.tarCarriedOwnerPolicies.enumerated() {
            model.changeTarCarriedOwnerIDs(to: owners)
            expected.tarCarriedOwnerIDs = owners
            check()
            XCTAssertEqual(model.tarCarriedOwnerIDsIndex, index)
        }
        for (index, method) in PreferencesViewModel.zipMethods.enumerated() {
            model.selectZipMethod(at: index)
            expected.zipMethod = method
            check()
        }
        model.selectZipMethod(at: 0)
        expected.zipMethod = .deflate
        for level in 1...9 {
            model.changeZipLevel(to: level)
            expected.zipLevel = level
            check()
            XCTAssertEqual(model.zipLevelLabel, String(level))
            model.changeTarGzipLevel(to: 10 - level)
            expected.tarGzipLevel = 10 - level
            check()
            XCTAssertEqual(model.tarGzipLevelLabel, String(10 - level))
            model.changeTarBzip2Level(to: level)
            expected.tarBzip2Level = level
            check()
            XCTAssertEqual(model.tarBzip2LevelLabel, String(level))
        }
        for enabled in [true, false] {
            model.changeRenamesOnClick(to: enabled)
            expected.renamesOnClick = enabled
            check()
            model.changeZipSkipsCompressedTypes(to: enabled)
            expected.zipSkipsCompressedTypes = enabled
            check()
            model.changeTarPreservesOwnerIDs(to: enabled)
            expected.tarPreservesOwnerIDs = enabled
            check()
            model.selectAfterExpansion(at: enabled ? 1 : 0)
            expected.trashesArchiveAfterExtraction = enabled
            check()
            XCTAssertEqual(model.afterExpansionIndex, enabled ? 1 : 0)
            model.changeRevealsExtractedItemsInFinder(to: enabled)
            expected.revealsExtractedItemsInFinder = enabled
            check()
        }
        for (index, destination) in PreferencesViewModel.extractionDestinations.enumerated() {
            model.selectExtractionDestination(at: index)
            expected.extractionDestination = destination
            check()
        }
        for (index, policy) in PreferencesViewModel.folderPolicies.enumerated() {
            model.selectFolderPolicy(at: index)
            expected.folderPolicy = policy
            check()
        }
    }

    @MainActor func testViewModelLoadsStoredValuesAndClampsLiveLevels() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let saved = ArchivePreferences(defaultFormat: .tarGzip, zipMethod: .stored, zipLevel: 8,
                                       zipSkipsCompressedTypes: false, tarGzipLevel: 2, tarBzip2Level: 4, tarPreservesOwnerIDs: true,
                                       extractionDestination: .ask, folderPolicy: .never, trashesArchiveAfterExtraction: true,
                                       revealsExtractedItemsInFinder: true, openingBehavior: .newWindow)
        store.preferences = saved
        let model = PreferencesViewModel(store: ArchivePreferencesStore(defaults: suite.defaults))
        XCTAssertEqual(model.preferences, saved)
        XCTAssertEqual(model.defaultFormatIndex, 2)
        XCTAssertEqual(model.openingBehaviorIndex, 2)
        XCTAssertEqual(model.zipMethodIndex, 1)
        XCTAssertEqual(model.extractionDestinationIndex, 1)
        XCTAssertEqual(model.folderPolicyIndex, 2)
        XCTAssertEqual(model.afterExpansionIndex, 1)
        XCTAssertEqual(model.zipLevelLabel, "8")
        XCTAssertEqual(model.tarGzipLevelLabel, "2")
        XCTAssertEqual(model.tarBzip2LevelLabel, "4")
        for (input, expected) in [(Int.min, 1), (0, 1), (42, 9), (Int.max, 9)] {
            model.changeZipLevel(to: input)
            model.changeTarGzipLevel(to: input)
            model.changeTarBzip2Level(to: input)
            XCTAssertEqual(store.preferences.zipLevel, expected)
            XCTAssertEqual(store.preferences.tarGzipLevel, expected)
            XCTAssertEqual(store.preferences.tarBzip2Level, expected)
            XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveZipLevel"), expected)
            XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveTarGzipLevel"), expected)
            XCTAssertEqual(model.zipLevelLabel, String(expected))
            XCTAssertEqual(model.tarGzipLevelLabel, String(expected))
            XCTAssertEqual(model.tarBzip2LevelLabel, String(expected))
        }
        let before = store.preferences
        for index in [-1, 99] {
            model.selectDefaultFormat(at: index)
            model.selectOpeningBehavior(at: index)
            model.selectZipMethod(at: index)
            model.selectExtractionDestination(at: index)
            model.selectFolderPolicy(at: index)
            model.selectAfterExpansion(at: index)
        }
        XCTAssertEqual(store.preferences, before)
    }

    @MainActor private func sendAction(_ control: NSControl, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(control.action, file: file, line: line)
        XCTAssertTrue(control.sendAction(control.action, to: control.target), file: file, line: line)
    }

    @MainActor func testSettingsControlsPersistAndRefreshWithoutReopening() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let controller = PreferencesWindowController(store: store)
        defer { controller.close() }
        XCTAssertEqual(controller.renamesOnClickCheckbox.state, .on)
        controller.renamesOnClickCheckbox.performClick(nil)
        XCTAssertFalse(store.preferences.renamesOnClick)
        controller.defaultFormatPopup.selectItem(at: try XCTUnwrap(ArchivePreferences.formats.firstIndex(of: .lha)))
        sendAction(controller.defaultFormatPopup)
        XCTAssertEqual(store.preferences.defaultFormat, .lha)
        controller.saveBehaviorPopup.selectItem(at: 1)
        sendAction(controller.saveBehaviorPopup)
        XCTAssertEqual(store.preferences.saveBehavior, .onSave)
        controller.openingBehaviorPopup.selectItem(at: 1)
        sendAction(controller.openingBehaviorPopup)
        XCTAssertEqual(store.preferences.openingBehavior, .newTab)
        controller.additionPositionPopup.selectItem(at: 1)
        sendAction(controller.additionPositionPopup)
        XCTAssertEqual(store.preferences.additionPosition, .beginning)
        controller.tarCarriedOwnerIDsPopup.selectItem(at: 1)
        sendAction(controller.tarCarriedOwnerIDsPopup)
        XCTAssertEqual(store.preferences.tarCarriedOwnerIDs, .reset)
        store.preferences.additionPosition = .end
        store.preferences.tarCarriedOwnerIDs = .keep
        XCTAssertEqual(controller.additionPositionPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.tarCarriedOwnerIDsPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.additionPositionPopup.accessibilityLabel(), String(localized: "追加した項目の位置"))
        XCTAssertEqual(controller.tarCarriedOwnerIDsPopup.accessibilityLabel(), String(localized: "変更しない項目の所有者ID"))
        controller.zipLevelSlider.integerValue = 9
        sendAction(controller.zipLevelSlider)
        XCTAssertEqual(store.preferences.zipLevel, 9)
        XCTAssertEqual(controller.zipLevelLabel.stringValue, "9")
        controller.zipMethodPopup.selectItem(at: 1)
        sendAction(controller.zipMethodPopup)
        XCTAssertEqual(store.preferences.zipMethod, .stored)
        XCTAssertFalse(controller.zipLevelSlider.isEnabled)
        controller.zipSkipsCompressedTypesCheckbox.state = .off
        sendAction(controller.zipSkipsCompressedTypesCheckbox)
        XCTAssertFalse(store.preferences.zipSkipsCompressedTypes)
        controller.tarGzipLevelSlider.integerValue = 1
        sendAction(controller.tarGzipLevelSlider)
        XCTAssertEqual(store.preferences.tarGzipLevel, 1)
        XCTAssertEqual(controller.tarGzipLevelLabel.stringValue, "1")
        controller.tarBzip2LevelSlider.integerValue = 3
        sendAction(controller.tarBzip2LevelSlider)
        XCTAssertEqual(store.preferences.tarBzip2Level, 3)
        XCTAssertEqual(controller.tarBzip2LevelLabel.stringValue, "3")
        controller.tarPreservesOwnerIDsCheckbox.state = .on
        sendAction(controller.tarPreservesOwnerIDsCheckbox)
        XCTAssertTrue(store.preferences.tarPreservesOwnerIDs)
        controller.extractionDestinationPopup.selectItem(at: 1)
        sendAction(controller.extractionDestinationPopup)
        XCTAssertEqual(store.preferences.extractionDestination, .ask)
        controller.folderPolicyPopup.selectItem(at: 2)
        sendAction(controller.folderPolicyPopup)
        XCTAssertEqual(store.preferences.folderPolicy, .never)
        controller.afterExpansionPopup.selectItem(at: 1)
        sendAction(controller.afterExpansionPopup)
        XCTAssertTrue(store.preferences.trashesArchiveAfterExtraction)
        controller.revealsExtractedItemsInFinderCheckbox.state = .on
        sendAction(controller.revealsExtractedItemsInFinderCheckbox)
        XCTAssertTrue(store.preferences.revealsExtractedItemsInFinder)
        // 保存パネルなど、別の入口で保存した変更も開いたままの画面へ同期する。
        store.preferences = ArchivePreferences()
        XCTAssertEqual(controller.renamesOnClickCheckbox.state, .on)
        XCTAssertEqual(controller.defaultFormatPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.openingBehaviorPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.saveBehaviorPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.zipMethodPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.zipLevelSlider.integerValue, 6)
        XCTAssertEqual(controller.zipLevelLabel.stringValue, "6")
        XCTAssertTrue(controller.zipLevelSlider.isEnabled)
        XCTAssertEqual(controller.zipSkipsCompressedTypesCheckbox.state, .on)
        XCTAssertEqual(controller.tarGzipLevelSlider.integerValue, 6)
        XCTAssertEqual(controller.tarGzipLevelLabel.stringValue, "6")
        XCTAssertEqual(controller.tarBzip2LevelSlider.integerValue, 9)
        XCTAssertEqual(controller.tarBzip2LevelLabel.stringValue, "9")
        XCTAssertEqual(controller.tarPreservesOwnerIDsCheckbox.state, .off)
        XCTAssertEqual(controller.extractionDestinationPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.folderPolicyPopup.indexOfSelectedItem, 1)
        XCTAssertEqual(controller.afterExpansionPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.revealsExtractedItemsInFinderCheckbox.state, .off)
    }

    @MainActor func testSavePanelAndSettingsShareDefaultFormat() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let model = PreferencesViewModel(store: store)
        model.selectDefaultFormat(at: 2)
        let save = ArchiveSavePanel(sources: [URL(fileURLWithPath: "/tmp/preferences.txt")], store: store)
        XCTAssertEqual(save.controller.format, store.preferences.defaultFormat)
        XCTAssertEqual(save.formatPopup.indexOfSelectedItem, 2)
        save.formatPopup.selectItem(at: try XCTUnwrap(ArchivePreferences.formats.firstIndex(of: .sevenZip)))
        sendAction(save.formatPopup)
        XCTAssertEqual(store.preferences.defaultFormat, .sevenZip)
        XCTAssertEqual(model.defaultFormatIndex, ArchivePreferences.formats.firstIndex(of: .sevenZip))
        XCTAssertEqual(suite.defaults.string(forKey: "ArchiveCreationFormat"), "7z")
        XCTAssertEqual(ArchiveSavePanelController(defaults: suite.defaults).format, .sevenZip)
    }

    @MainActor func testSettingsMenuCommandCommaAndWindowControllerReuse() throws {
        preserveApplicationMenus()
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let delegate = AppDelegate(preferencesStore: store), menu = delegate.makeMenu()
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertEqual(appMenu.items[0].title, String(localized: "KaitoFinderについて"))
        XCTAssertTrue(appMenu.items[1].isSeparatorItem)
        let settings = appMenu.items[2]
        XCTAssertEqual(settings.title, String(localized: "設定…"))
        XCTAssertEqual(settings.keyEquivalent, ",")
        XCTAssertEqual(settings.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(settings.action, #selector(AppDelegate.showPreferences(_:)))
        XCTAssertTrue(settings.target === delegate)
        XCTAssertNil(delegate.preferencesWindowController)
        try performMenuItem(settings)
        let first = try XCTUnwrap(delegate.preferencesWindowController), window = try XCTUnwrap(first.window)
        defer { first.close() }
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.title, String(localized: "設定"))
        XCTAssertEqual(window.frameAutosaveName, "Preferences")
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(first.tabController.tabStyle, .toolbar)
        XCTAssertEqual(first.tabController.tabViewItems.map(\.label),
                       [String(localized: "一般"), String(localized: "圧縮"), String(localized: "展開"), String(localized: "パフォーマンス"), String(localized: "アップデート")])
        first.close()
        try performMenuItem(settings)
        XCTAssertTrue(delegate.preferencesWindowController === first)
        XCTAssertTrue(delegate.preferencesWindowController?.window === window)
        XCTAssertTrue(window.isVisible)
    }

    func testSettingsStringsHaveAllTwentySixTranslations() throws {
        let root = TestPaths.repositoryRoot
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("KaitoFinder/Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let source = try ["PreferencesWindowController.swift", "CompressionOptionHelp.swift"].map {
            try String(contentsOf: root.appendingPathComponent("KaitoFinder/UI/" + $0), encoding: .utf8)
        }.joined(separator: "\n")
        let expression = try NSRegularExpression(pattern: #"String\(localized: "([^"]+)""#)
        let keys = expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
            String(source[Range($0.range(at: 1), in: source)!])
        } + ["設定…"]
        XCTAssertGreaterThan(Set(keys).count, 20)
        for key in Set(keys) {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for language in LocalizationAcceptance.languages {
                let localized = try XCTUnwrap(localizations[language] as? [String: Any], "\(language): \(key)")
                let unit = try XCTUnwrap(localized["stringUnit"] as? [String: Any])
                let text = try XCTUnwrap(unit["value"] as? String)
                XCTAssertFalse(text.isEmpty)
                XCTAssertEqual(unit["state"] as? String, "translated")
                if language == "ja" { XCTAssertEqual(text, key) }
                if key == "設定…", language == "en" { XCTAssertEqual(text, "Settings…") }
            }
        }
    }

    @MainActor func testCompressionPaneWidthIsIndependentOfScrollerStyle() throws {
        for language in ["ja", "en", "da"] {
            let suite = try ArchivePreferencesTestDefaults()
            let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults),
                bundle: try LocalizationAcceptance.bundle(language))
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            window.setFrameAutosaveName("")
            window.layoutIfNeeded()
            let initialWidth = try XCTUnwrap(window.contentView).bounds.width
            let pane = try XCTUnwrap(controller.tabController.tabViewItems[1].viewController)
            let scroll = pane.view.subviews.compactMap { $0 as? NSScrollView }.first
            // スクロール不要のペインでも、各内部タブと外部タブの往復で共通幅を保つ。
            for style: NSScroller.Style in [.legacy, .overlay, .legacy] {
                scroll?.scrollerStyle = style
                scroll?.tile()
                for inner in 0..<controller.compressionTabView.numberOfTabViewItems {
                    controller.compressionTabView.selectTabViewItem(at: inner)
                    for index in [1, 0, 1, 3, 1] {
                        controller.tabController.selectedTabViewItemIndex = index
                        window.layoutIfNeeded()
                        XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.width, initialWidth, accuracy: 0.5, language)
                        XCTAssertEqual(pane.preferredContentSize.width, initialWidth, accuracy: 0.5, language)
                        XCTAssertEqual(pane.view.fittingSize.width, initialWidth, accuracy: 0.5, language)
                        XCTAssertEqual(pane.view.bounds.width, initialWidth, accuracy: 0.5, language)
                    }
                }
            }
        }
    }

    @MainActor func testInitialCompressionTabFollowsDefaultFormat() throws {
        for format in ArchivePreferences.formats {
            let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
            store.preferences.defaultFormat = format
            let controller = PreferencesWindowController(store: store)
            defer { controller.close() }
            let expected = format == .zip ? "zip" : format == .sevenZip ? "sevenZip" : format == .lha ? "lha" : "tar"
            XCTAssertEqual(controller.compressionTabView.selectedTabViewItem?.identifier as? String,
                           "preferences.compression." + expected)
            XCTAssertEqual(controller.compressionTabView.tabViewType, .topTabsBezelBorder)
            XCTAssertEqual(controller.compressionTabView.tabViewItems.map(\.label), ["ZIP", "7z", "tar", "LHA"])
            let pane = try XCTUnwrap(controller.tabController.tabViewItems[1].viewController)
            controller.tabController.selectedTabViewItemIndex = 1
            let height = pane.preferredContentSize.height
            controller.compressionTabView.selectTabViewItem(at: 2)
            controller.compressionTabView.selectTabViewItem(at: controller.viewModel.initialCompressionTabIndex)
            XCTAssertEqual(pane.preferredContentSize.height, height, accuracy: 0.5)
        }
    }

    @MainActor func testFormatPopupsUseSavePanelCatalogsAndPersistEveryLevel() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let controller = PreferencesWindowController(store: store)
        defer { controller.close() }
        let performance = try XCTUnwrap(controller.tabController.tabViewItems[3].viewController?.view)
        for control in [controller.compressionThreadsPopup, controller.compressionMemoryNote,
                        controller.powerPolicyPopup, controller.prefersSpeedCheckbox, controller.prefersSpeedNote] {
            XCTAssertTrue(control.isDescendant(of: performance))
        }
        for (popup, format) in [(controller.sevenZipMethodPopup, GyoshukuKit.ArchiveFormat.sevenZip),
                                (controller.lhaMethodPopup, .lha)] {
            let compression = controller.viewModel.compressionController(for: format)
            let standard = format == .sevenZip ? ArchivePreferences().sevenZipMethod.rawValue : ArchivePreferences().lhaMethod.rawValue
            XCTAssertEqual(popup.itemTitles, compression.methods.map {
                $0.rawValue.lowercased() == standard ? String(format: String(localized: "%@（標準）"), $0.title()) : $0.title()
            })
        }
        let levels: [(NSPopUpButton, GyoshukuKit.ArchiveFormat, KeyPath<ArchivePreferences, Int>)] = [
            (controller.sevenZipLevelPopup, .sevenZip, \.sevenZipLevel),
            (controller.lhaLevelPopup, .lha, \.lhaLevel),
            (controller.tarXZLevelPopup, .tarXZ, \.tarXZLevel),
            (controller.tarZstdLevelPopup, .tarZstd, \.tarZstdLevel),
            (controller.tarLzipLevelPopup, .tarLzip, \.tarLzipLevel),
            (controller.tarLZMALevelPopup, .tarLZMA, \.tarLZMALevel)
        ]
        for (popup, format, key) in levels {
            let compression = controller.viewModel.compressionController(for: format)
            XCTAssertEqual(popup.itemTitles, compression.levels.map {
                $0.title(startsAtZero: compression.startsAtZero, zstd: compression.usesZstd)
            })
            XCTAssertEqual(popup.isEnabled, compression.isLevelEnabled)
            for (index, level) in compression.levels.enumerated() {
                popup.selectItem(at: index)
                sendAction(popup)
                XCTAssertEqual(ArchivePreferencesStore(defaults: suite.defaults).preferences[keyPath: key], level.rawValue)
                XCTAssertEqual(popup.indexOfSelectedItem, index)
                XCTAssertEqual(store.preferences.defaultFormat, .zip)
            }
        }
        XCTAssertEqual(controller.sevenZipSolidCheckbox.isEnabled,
                       controller.viewModel.compressionController(for: .sevenZip).showsSevenZipOptions)
        XCTAssertEqual(controller.sevenZipFilterPopup.isEnabled,
                       controller.viewModel.compressionController(for: .sevenZip).showsSevenZipOptions)
    }

    @MainActor func testCompressionHelpUpdatesWithoutChangingPaneOrWindowSize() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        for language in LocalizationAcceptance.languages {
            let controller = PreferencesWindowController(store: store, bundle: try LocalizationAcceptance.bundle(language))
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            window.setFrameAutosaveName("")
            controller.tabController.selectedTabViewItemIndex = 1
            window.layoutIfNeeded()
            let width = window.frame.width
            let pane = try XCTUnwrap(controller.tabController.tabViewItems[1].viewController)
            XCTAssertEqual(controller.compressionTabView.tabViewItems.map(\.label), ["ZIP", "7z", "tar", "LHA"], language)
            for (inner, popup, description) in [(0, controller.zipMethodPopup, controller.zipMethodDescription),
                                                (1, controller.sevenZipMethodPopup, controller.sevenZipMethodDescription),
                                                (3, controller.lhaMethodPopup, controller.lhaMethodDescription)] {
                controller.compressionTabView.selectTabViewItem(at: inner)
                window.layoutIfNeeded()
                let descriptionHeight = description.bounds.height
                let size = window.frame.size
                let paneSize = pane.preferredContentSize
                var descriptions = Set<String>()
                for index in 0..<popup.numberOfItems {
                    let help = try XCTUnwrap(popup.item(at: index)?.toolTip)
                    XCTAssertFalse(help.isEmpty, language)
                    popup.selectItem(at: index)
                    sendAction(popup)
                    window.layoutIfNeeded()
                    XCTAssertEqual(popup.toolTip, help)
                    XCTAssertEqual(description.stringValue, help)
                    descriptions.insert(help)
                    XCTAssertEqual(description.bounds.height, descriptionHeight, accuracy: 0.5, language)
                    XCTAssertEqual(window.frame.size, size, language)
                    XCTAssertEqual(pane.preferredContentSize, paneSize, language)
                    XCTAssertTrue(UISnapshot.overflowViolations(in: pane.view).isEmpty, language)
                }
                XCTAssertEqual(descriptions.count, popup.numberOfItems)
            }
            controller.compressionTabView.selectTabViewItem(at: 1)
            for index in 0..<controller.sevenZipFilterPopup.numberOfItems {
                let help = try XCTUnwrap(controller.sevenZipFilterPopup.item(at: index)?.toolTip)
                XCTAssertFalse(help.isEmpty)
                controller.sevenZipFilterPopup.selectItem(at: index)
                sendAction(controller.sevenZipFilterPopup)
                XCTAssertEqual(controller.sevenZipFilterPopup.toolTip, help)
            }
            for inner in [0, 1, 2, 3, 0] {
                controller.compressionTabView.selectTabViewItem(at: inner)
                window.layoutIfNeeded()
                XCTAssertEqual(window.frame.width, width, accuracy: 0.5, language)
                XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.size, pane.preferredContentSize, language)
            }
            for control: NSControl in [controller.zipLevelSlider, controller.sevenZipLevelPopup, controller.lhaLevelPopup,
                                       controller.tarGzipLevelSlider, controller.tarBzip2LevelSlider,
                                       controller.tarXZLevelPopup, controller.tarZstdLevelPopup,
                                       controller.tarLzipLevelPopup, controller.tarLZMALevelPopup,
                                       controller.sevenZipSolidCheckbox, controller.zipSkipsCompressedTypesCheckbox,
                                       controller.compressionThreadsPopup, controller.powerPolicyPopup, controller.prefersSpeedCheckbox] {
                XCTAssertFalse(try XCTUnwrap(control.toolTip).isEmpty, language)
            }
        }
    }

    @MainActor func testInnerCompressionTabsResizeWindowAndKeepTopEdgeAndWidth() throws {
        for language in ["ja", "en"] {
            let suite = try ArchivePreferencesTestDefaults()
            let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults),
                                                         bundle: try LocalizationAcceptance.bundle(language))
            defer { controller.close() }
            let window = try XCTUnwrap(controller.window)
            window.setFrameAutosaveName("")
            if let visible = window.screen?.visibleFrame {
                window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
            }
            controller.tabController.selectedTabViewItemIndex = 1
            let width = window.frame.width, top = window.frame.maxY
            let pane = try XCTUnwrap(controller.tabController.tabViewItems[1].viewController)
            var heights: [Int: CGFloat] = [:]
            for inner in [2, 0, 1, 3, 2] {
                controller.compressionTabView.selectTabViewItem(at: inner)
                window.layoutIfNeeded()
                heights[inner] = pane.preferredContentSize.height
                XCTAssertEqual(window.frame.width, width, accuracy: 0.5, language)
                XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, language)
                XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.size, pane.preferredContentSize, language)
                let innerPane = try XCTUnwrap(controller.compressionTabView.selectedTabViewItem?.view)
                let tab = PreferencesViewModel.CompressionTab.allCases[inner]
                let button = try XCTUnwrap(controller.compressionResetButtons[tab])
                let buttonFrame = button.convert(button.bounds, to: innerPane)
                XCTAssertGreaterThanOrEqual(innerPane.bounds.maxY - buttonFrame.maxY, 12, language)
                XCTAssertLessThanOrEqual(innerPane.bounds.maxY - buttonFrame.maxY, 20, language)
                XCTAssertTrue(innerPane.isFlipped)
                XCTAssertTrue(UISnapshot.overflowViolations(in: pane.view).isEmpty, language)
            }
            let scroll = try XCTUnwrap(pane.view.subviews.compactMap { $0 as? NSScrollView }.first)
            if !scroll.hasVerticalScroller {
                for inner in [0, 1, 3] { XCTAssertLessThan(try XCTUnwrap(heights[inner]), try XCTUnwrap(heights[2]), language) }
            }
            let initialHeight = try XCTUnwrap(heights[0])
            controller.compressionTabView.selectTabViewItem(at: 0)
            XCTAssertEqual(pane.preferredContentSize.height, initialHeight, accuracy: 0.5, language)
        }
    }

    @MainActor private func spinPreferencesRunLoop(for interval: TimeInterval) {
        let elapsed = expectation(description: "設定のcommonモードで\(interval)秒待つ")
        let timer = Timer(timeInterval: interval, repeats: false) { _ in elapsed.fulfill() }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        wait(for: [elapsed], timeout: 2)
    }

    @MainActor private func requireMotionAnimations() throws {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { throw XCTSkip("視差効果を減らす設定が有効です。") }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if session?["CGSSessionScreenIsLocked"] as? Bool == true { throw XCTSkip("画面がロックされています。") }
    }

    @MainActor func testRapidTabSwitchingEndsAtLastSelectionSize() throws {
        let suite = try ArchivePreferencesTestDefaults()
        let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults))
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        if let visible = window.screen?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
        }
        let width = window.frame.width
        func containsImageView(_ view: NSView) -> Bool {
            view is NSImageView || view.subviews.contains { containsImageView($0) }
        }
        // 非表示、表示中、アニメーション無効の三経路で、最後の選択から目標を計算する。
        for mode in 0..<3 {
            controller.tabController.animationsEnabled = mode != 2
            if mode > 0 { controller.showWindow(nil) }
            // 同期の連続選択に加え、前のフェードの途中で次の選択を送る。
            let switches = mode == 1 ? [(false, 1), (false, 0), (true, 1), (true, 0)] : [(false, 1), (false, 0)]
            for (yieldsBetweenSelections, finalOuter) in switches {
                let top = window.frame.maxY
                var selections = [(1, 2), (0, 0), (1, 1), (3, 3), (1, 0), (4, 2), (1, 3)]
                // 最後が一般でも、非表示の圧縮タブ変更で伸縮が中断されないことを確かめる。
                if finalOuter == 0 { selections.append((0, 2)) }
                for (outer, inner) in selections {
                    controller.tabController.selectedTabViewItemIndex = outer
                    controller.compressionTabView.selectTabViewItem(at: inner)
                    XCTAssertTrue(controller.tabController.transitionOptions.isEmpty)
                    if yieldsBetweenSelections {
                        spinPreferencesRunLoop(for: 0.05)
                    }
                }
                let pane = try XCTUnwrap(controller.tabController.tabViewItems[finalOuter].viewController)
                let size = try XCTUnwrap(controller.tabController.targetContentSize)
                let frameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
                let expected = NSRect(x: window.frame.minX, y: top - frameSize.height, width: width, height: frameSize.height)
                XCTAssertEqual(try XCTUnwrap(controller.tabController.targetWindowFrame), expected)
                if controller.tabController.animatesSelection {
                    spinPreferencesRunLoop(for: 0.6)
                } else {
                    XCTAssertEqual(window.frame, expected)
                }
                window.layoutIfNeeded()
                XCTAssertFalse(controller.tabController.isResizing)
                XCTAssertEqual(controller.tabController.preferredContentSize, size)
                XCTAssertEqual(pane.preferredContentSize, size)
                XCTAssertEqual(window.frame, expected)
                XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.size, size)
                let violations = UISnapshot.overflowViolations(in: try XCTUnwrap(window.contentView))
                XCTAssertTrue(violations.isEmpty, "mode \(mode), yielded \(yieldsBetweenSelections)\n" + violations.joined(separator: "\n"))
                let tabView = controller.tabController.tabView
                let selected = try XCTUnwrap(tabView.selectedTabViewItem?.view)
                let visible = tabView.subviews.filter { !$0.isHiddenOrHasHiddenAncestor }
                XCTAssertEqual(tabView.subviews.count, 1)
                XCTAssertEqual(visible.count, 1)
                XCTAssertTrue(visible.first === selected)
                for item in controller.tabController.tabViewItems {
                    XCTAssertEqual(try XCTUnwrap(item.viewController?.view).alphaValue, 1)
                }
                XCTAssertFalse(containsImageView(controller.compressionTabView))
                for item in controller.compressionTabView.tabViewItems {
                    let innerPane = try XCTUnwrap(item.view)
                    XCTAssertEqual(innerPane.subviews.count, 1)
                    XCTAssertFalse(containsImageView(innerPane))
                    XCTAssertEqual(innerPane.alphaValue, 1)
                    XCTAssertEqual(try XCTUnwrap(innerPane.subviews.first).alphaValue, 1)
                }
            }
        }
    }

    @MainActor private final class MotionSamples {
        var markers: [String: [CGFloat]] = [:]
        var heights = Set<CGFloat>()
        var nextSelection = 1
    }

    @MainActor private static func sampleMotion(in controller: PreferencesWindowController, into samples: MotionSamples) {
        guard let window = controller.window, let content = window.contentView else { return }
        samples.heights.insert(window.frame.height)
        var markers: [(String, NSView)] = []
        if controller.tabController.selectedTabViewItemIndex == 1 {
            markers = [("excludesDSStore", controller.excludesDSStoreCheckbox), ("compressionTabs", controller.compressionTabView)]
            if let item = controller.compressionTabView.selectedTabViewItem,
               let stack = item.view?.subviews.first as? NSStackView, let first = stack.arrangedSubviews.first {
                markers.append(("inner.\(item.identifier ?? "")", first))
            } else {
                XCTFail("選択した圧縮ペインの先頭コントロールを計測できません。")
            }
        } else if controller.tabController.selectedTabViewItemIndex == 0 {
            markers = [("keepsFoldersOnTop", controller.keepsFoldersOnTopCheckbox)]
        }
        for (name, marker) in markers {
            XCTAssertTrue(marker.window === window, "\(name)が計測対象のウインドウにありません。")
            let distance = content.bounds.height - content.convert(marker.bounds, from: marker).maxY
            samples.markers[name, default: []].append(distance)
        }
    }

    @MainActor private func assertControlsStayedStill(_ samples: MotionSamples, context: String,
                                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(samples.markers.isEmpty, context, file: file, line: line)
        for (marker, distances) in samples.markers {
            XCTAssertLessThanOrEqual(distances.max()! - distances.min()!, 0.5,
                                     "\(context): \(marker) \(distances)", file: file, line: line)
        }
    }

    @MainActor func testSwitchKeepsControlsStillWhileWindowResizes() throws {
        for language in ["ja", "en"] {
            for legacy in [false, true] {
                let suite = try ArchivePreferencesTestDefaults()
                let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults),
                                                             bundle: try LocalizationAcceptance.bundle(language))
                defer { controller.close() }
                let window = try XCTUnwrap(controller.window)
                window.setFrameAutosaveName("")
                controller.tabController.drivesResizeWithTimer = false
                controller.showWindow(nil)
                if let visible = window.screen?.visibleFrame {
                    window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
                }
                let compression = try XCTUnwrap(controller.tabController.tabViewItems[1].viewController)
                let scroll = try XCTUnwrap(compression.view.subviews.compactMap { $0 as? NSScrollView }.first)
                if legacy { scroll.scrollerStyle = .legacy; scroll.tile() }

                func step(from start: NSRect, through progress: [CGFloat], context: String) -> MotionSamples {
                    let samples = MotionSamples()
                    let target = controller.tabController.targetWindowFrame!
                    let animated = controller.tabController.animatesSelection
                    // 「視差効果を減らす」でもテストを省略せず、即時切り替えを確かめる。
                    XCTAssertEqual(window.frame, animated ? start : target, context)
                    for p in progress {
                        controller.tabController.applyResizeProgress(p)
                        window.layoutIfNeeded()
                        let height = (start.height + (target.height - start.height) * p).rounded()
                        let commanded = !animated || p == 1 ? target
                            : NSRect(x: start.minX, y: start.maxY - height, width: start.width, height: height)
                        XCTAssertEqual(window.frame.maxY, start.maxY, accuracy: 0.5, context)
                        XCTAssertEqual(window.frame, commanded, context)
                        let contentSize = window.contentRect(forFrameRect: commanded).size
                        XCTAssertEqual(controller.tabController.preferredContentSize, contentSize, context)
                        XCTAssertEqual(controller.tabController.tabViewItems[controller.tabController.selectedTabViewItemIndex].viewController?.preferredContentSize,
                                       contentSize, context)
                        Self.sampleMotion(in: controller, into: samples)
                    }
                    assertControlsStayedStill(samples, context: context)
                    if progress.last == 1 {
                        XCTAssertEqual(window.frame, target, context)
                        XCTAssertEqual(controller.tabController.preferredContentSize, controller.tabController.targetContentSize)
                        XCTAssertEqual(controller.tabController.tabViewItems[controller.tabController.selectedTabViewItemIndex].viewController?.preferredContentSize,
                                       controller.tabController.targetContentSize)
                    }
                    return samples
                }
                let progress = (0...10).map { CGFloat($0) / 10 }
                for (from, to) in [(0, 1), (1, 0), (0, 2), (2, 0), (1, 3), (3, 1)] {
                    controller.tabController.animationsEnabled = false
                    controller.tabController.selectedTabViewItemIndex = 1
                    controller.compressionTabView.selectTabViewItem(at: from)
                    window.layoutIfNeeded()
                    controller.tabController.animationsEnabled = true
                    let start = window.frame
                    controller.compressionTabView.selectTabViewItem(at: to)
                    _ = step(from: start, through: progress, context: "\(language), legacy \(legacy), inner \(from)→\(to)")
                }
                for (from, to) in [(0, 1), (1, 0)] {
                    controller.tabController.animationsEnabled = false
                    controller.compressionTabView.selectTabViewItem(at: 0)
                    controller.tabController.selectedTabViewItemIndex = from
                    window.layoutIfNeeded()
                    controller.tabController.animationsEnabled = true
                    let start = window.frame
                    controller.tabController.selectedTabViewItemIndex = to
                    _ = step(from: start, through: progress, context: "\(language), legacy \(legacy), outer \(from)→\(to)")
                }
                // 拡大中の再選択と、縮小で保留したレイアウトの確定後の再選択を検査する。
                for (from, via, to) in [(0, 1, 2), (1, 0, 3)] {
                    controller.tabController.animationsEnabled = false
                    controller.tabController.selectedTabViewItemIndex = 1
                    controller.compressionTabView.selectTabViewItem(at: from)
                    window.layoutIfNeeded()
                    controller.tabController.animationsEnabled = true
                    let start = window.frame
                    controller.compressionTabView.selectTabViewItem(at: via)
                    let first = step(from: start, through: [0, 0.1, 0.2, 0.3, 0.4, 0.5], context: "\(language), legacy \(legacy), interrupted \(from)→\(via)")
                    let interrupted = window.frame
                    controller.compressionTabView.selectTabViewItem(at: to)
                    let second = step(from: interrupted, through: progress, context: "\(language), legacy \(legacy), interrupted →\(to)")
                    for name in ["excludesDSStore", "compressionTabs"] {
                        let distances = (first.markers[name] ?? []) + (second.markers[name] ?? [])
                        XCTAssertFalse(distances.isEmpty)
                        XCTAssertLessThanOrEqual(distances.max()! - distances.min()!, 0.5, "\(language): \(name) interrupted chain")
                    }
                }
            }
        }
    }

    @MainActor func testRealTimerResizeKeepsControlsStill() throws {
        try requireMotionAnimations()
        let suite = try ArchivePreferencesTestDefaults()
        let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults))
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        controller.showWindow(nil)
        if let visible = window.screen?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
        }
        XCTAssertTrue(controller.tabController.animatesSelection)
        for (from, selections) in [(0, [1]), (1, [0]), (0, [1, 2, 3, 0])] {
            controller.tabController.animationsEnabled = false
            controller.tabController.selectedTabViewItemIndex = 1
            controller.compressionTabView.selectTabViewItem(at: from)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            spinPreferencesRunLoop(for: 0.05)
            controller.tabController.animationsEnabled = true
            let top = window.frame.maxY, width = window.frame.width
            let samples = MotionSamples()
            let sample: @MainActor () -> Void = { Self.sampleMotion(in: controller, into: samples) }
            let sampler = Timer(timeInterval: 0.004, repeats: true) { _ in
                MainActor.assumeIsolated { sample() }
            }
            RunLoop.main.add(sampler, forMode: .common)
            defer { sampler.invalidate() }
            // 選択もcommonモードで送り、表示準備の完了から次の選択まで30msを置く。
            let selectNext: @MainActor () -> Bool = {
                guard samples.nextSelection < selections.count else { return false }
                controller.compressionTabView.selectTabViewItem(at: selections[samples.nextSelection])
                samples.nextSelection += 1
                return samples.nextSelection < selections.count
            }
            controller.compressionTabView.selectTabViewItem(at: selections[0])
            window.layoutIfNeeded()
            sample()
            let selectionTimer = Timer(timeInterval: 0.03, repeats: true) { timer in
                let continues = MainActor.assumeIsolated { selectNext() }
                if continues { timer.fireDate = Date().addingTimeInterval(0.03) }
                else { timer.invalidate() }
            }
            defer { selectionTimer.invalidate() }
            if selections.count > 1 { RunLoop.main.add(selectionTimer, forMode: .common) }
            spinPreferencesRunLoop(for: 0.5)
            sampler.invalidate()
            selectionTimer.invalidate()
            window.layoutIfNeeded()
            sample()
            XCTAssertGreaterThan(samples.heights.count, 3, "real timer \(from)→\(selections): \(samples.heights.sorted())")
            assertControlsStayedStill(samples, context: "real timer \(from)→\(selections)")
            XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5)
            XCTAssertEqual(window.frame.width, width, accuracy: 0.5)
            XCTAssertEqual(window.frame, controller.tabController.targetWindowFrame)
            XCTAssertFalse(controller.tabController.isResizing)
            XCTAssertEqual(controller.tabController.preferredContentSize, controller.tabController.targetContentSize)
            XCTAssertEqual(controller.tabController.tabViewItems[1].viewController?.preferredContentSize,
                           controller.tabController.targetContentSize)
        }
    }

    @MainActor func testClosingDuringResizeStopsTimerAndCommitsLayout() throws {
        try requireMotionAnimations()
        for action in ["controllerClose", "windowClose", "orderOut"] {
            for (from, to) in [(0, 1), (1, 0)] {
                let suite = try ArchivePreferencesTestDefaults()
                let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults))
                defer { controller.close() }
                let window = try XCTUnwrap(controller.window)
                window.setFrameAutosaveName("")
                controller.tabController.animationsEnabled = false
                controller.showWindow(nil)
                if let visible = window.screen?.visibleFrame {
                    window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
                }
                controller.tabController.selectedTabViewItemIndex = 1
                let pane = try XCTUnwrap(controller.tabController.tabViewItems[1].viewController)
                let scroll = try XCTUnwrap(pane.view.subviews.compactMap { $0 as? NSScrollView }.first)
                let document = try XCTUnwrap(scroll.documentView)
                controller.compressionTabView.selectTabViewItem(at: to)
                window.layoutIfNeeded()
                let completedDocumentSize = document.frame.size
                controller.compressionTabView.selectTabViewItem(at: from)
                window.layoutIfNeeded()
                controller.tabController.animationsEnabled = true
                controller.compressionTabView.selectTabViewItem(at: to)
                XCTAssertTrue(controller.tabController.isResizing, action)
                let incoming = try XCTUnwrap(controller.compressionTabView.selectedTabViewItem?.view?.subviews.first)
                spinPreferencesRunLoop(for: 0.05)
                let target = try XCTUnwrap(controller.tabController.targetWindowFrame)
                let size = try XCTUnwrap(controller.tabController.targetContentSize)
                switch action {
                case "controllerClose": controller.close()
                case "windowClose": window.close()
                default: window.orderOut(nil)
                }
                XCTAssertFalse(controller.tabController.isResizing, action)
                XCTAssertEqual(window.frame, target, action)
                XCTAssertEqual(controller.tabController.preferredContentSize, size, action)
                XCTAssertEqual(pane.preferredContentSize, size, action)
                XCTAssertEqual(document.frame.size, completedDocumentSize, action)
                XCTAssertEqual(incoming.alphaValue, 1, action)
                spinPreferencesRunLoop(for: 0.4)
                XCTAssertFalse(controller.tabController.isResizing, action)
                XCTAssertEqual(window.frame, target, action)
            }
        }
    }

    @MainActor func testCompletedResizeStopsTimer() throws {
        try requireMotionAnimations()
        let suite = try ArchivePreferencesTestDefaults()
        let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults))
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        controller.tabController.animationsEnabled = false
        controller.showWindow(nil)
        if let visible = window.screen?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 20, y: visible.maxY - 20))
        }
        controller.tabController.selectedTabViewItemIndex = 1
        controller.compressionTabView.selectTabViewItem(at: 0)
        window.layoutIfNeeded()
        controller.tabController.animationsEnabled = true
        for index in [1, 0] {
            controller.compressionTabView.selectTabViewItem(at: index)
            XCTAssertTrue(controller.tabController.isResizing)
            spinPreferencesRunLoop(for: 0.4)
            XCTAssertFalse(controller.tabController.isResizing)
            XCTAssertEqual(window.frame, controller.tabController.targetWindowFrame)
            XCTAssertEqual(controller.tabController.preferredContentSize, controller.tabController.targetContentSize)
        }
    }

    @MainActor func testDetachingDuringResizeStopsTimer() throws {
        try requireMotionAnimations()
        let suite = try ArchivePreferencesTestDefaults()
        let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults))
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        controller.tabController.animationsEnabled = false
        controller.showWindow(nil)
        controller.tabController.selectedTabViewItemIndex = 1
        controller.compressionTabView.selectTabViewItem(at: 0)
        window.layoutIfNeeded()
        controller.tabController.animationsEnabled = true
        controller.compressionTabView.selectTabViewItem(at: 1)
        XCTAssertTrue(controller.tabController.isResizing)
        spinPreferencesRunLoop(for: 0.05)
        window.contentViewController = nil
        spinPreferencesRunLoop(for: 0.4)
        XCTAssertFalse(controller.tabController.isResizing)
    }

    @MainActor func testPreferencesViewsStartWithNonnegativeGeometry() throws {
        func check(_ view: NSView, context: String) {
            for size in [view.frame.size, view.bounds.size] {
                XCTAssertTrue(size.width.isFinite && size.height.isFinite, context)
                XCTAssertGreaterThanOrEqual(size.width, 0, context)
                XCTAssertGreaterThanOrEqual(size.height, 0, context)
            }
            if let tabs = view as? NSTabView {
                XCTAssertGreaterThanOrEqual(tabs.contentRect.size.width, 0, context)
                XCTAssertGreaterThanOrEqual(tabs.contentRect.size.height, 0, context)
            }
            for child in view.subviews { check(child, context: context) }
        }
        for language in ["ja", "en"] {
            let suite = try ArchivePreferencesTestDefaults()
            let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults),
                                                         bundle: try LocalizationAcceptance.bundle(language))
            defer { controller.close() }
            check(controller.tabController.view, context: language)
            for item in controller.tabController.tabViewItems {
                check(try XCTUnwrap(item.viewController?.view), context: language)
            }
            for item in controller.compressionTabView.tabViewItems { check(try XCTUnwrap(item.view), context: language) }
            controller.tabController.animationsEnabled = false
            controller.showWindow(nil)
            controller.tabController.selectedTabViewItemIndex = 1
            for index in [0, 1, 2, 3] {
                controller.compressionTabView.selectTabViewItem(at: index)
                controller.window?.layoutIfNeeded()
                check(controller.tabController.view, context: language)
            }
        }
    }

    @MainActor private final class ChangeCount { var value = 0 }

    @MainActor func testResetButtonsRestoreOnlyTheirFormatDefaults() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let controller = PreferencesWindowController(store: store)
        defer { controller.close() }
        let defaults = ArchivePreferences()
        var changed = defaults
        changed.zipMethod = .ppmd
        changed.zipLevel = 1
        changed.zipLZMALevel = 2
        changed.zipZstdLevel = 4
        changed.zipPPMdLevel = 3
        changed.zipSkipsCompressedTypes.toggle()
        changed.sevenZipMethod = .ppmd
        changed.sevenZipLevel = 2
        changed.sevenZipPPMdLevel = 3
        changed.sevenZipSolid.toggle()
        changed.sevenZipFilter = .delta
        changed.tarGzipLevel = 1
        changed.tarBzip2Level = 2
        changed.tarXZLevel = 3
        changed.tarZstdLevel = 4
        changed.tarLzipLevel = 5
        changed.tarLZMALevel = 7
        changed.tarPreservesOwnerIDs.toggle()
        changed.tarCarriedOwnerIDs = .reset
        changed.lhaMethod = .lh7
        changed.lhaLevel = 8
        changed.defaultFormat = .tarXZ
        changed.excludesDSStore.toggle()
        changed.excludesHiddenFiles.toggle()
        changed.compressionThreads = 3
        changed.prefersSpeed.toggle()
        changed.powerPolicy = .alwaysUseAllCores
        let count = ChangeCount()
        let observer = NotificationCenter.default.addObserver(forName: ArchivePreferencesStore.didChange,
                                                               object: store, queue: .main) { _ in
            MainActor.assumeIsolated { count.value += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for tab in PreferencesViewModel.CompressionTab.allCases {
            XCTAssertFalse(try XCTUnwrap(controller.compressionResetButtons[tab]).isEnabled)
        }
        for tab in PreferencesViewModel.CompressionTab.allCases {
            store.preferences = changed
            for other in PreferencesViewModel.CompressionTab.allCases {
                XCTAssertFalse(controller.viewModel.compressionDefaultsAreCurrent(for: other))
                XCTAssertTrue(try XCTUnwrap(controller.compressionResetButtons[other]).isEnabled)
            }
            var expected = changed
            switch tab {
            case .zip:
                expected.zipMethod = defaults.zipMethod
                expected.zipLevel = defaults.zipLevel
                expected.zipLZMALevel = defaults.zipLZMALevel
                expected.zipZstdLevel = defaults.zipZstdLevel
                expected.zipPPMdLevel = defaults.zipPPMdLevel
                expected.zipSkipsCompressedTypes = defaults.zipSkipsCompressedTypes
            case .sevenZip:
                expected.sevenZipMethod = defaults.sevenZipMethod
                expected.sevenZipLevel = defaults.sevenZipLevel
                expected.sevenZipPPMdLevel = defaults.sevenZipPPMdLevel
                expected.sevenZipSolid = defaults.sevenZipSolid
                expected.sevenZipFilter = defaults.sevenZipFilter
            case .tar:
                expected.tarGzipLevel = defaults.tarGzipLevel
                expected.tarBzip2Level = defaults.tarBzip2Level
                expected.tarXZLevel = defaults.tarXZLevel
                expected.tarZstdLevel = defaults.tarZstdLevel
                expected.tarLzipLevel = defaults.tarLzipLevel
                expected.tarLZMALevel = defaults.tarLZMALevel
                expected.tarPreservesOwnerIDs = defaults.tarPreservesOwnerIDs
                expected.tarCarriedOwnerIDs = defaults.tarCarriedOwnerIDs
            case .lha:
                expected.lhaMethod = defaults.lhaMethod
                expected.lhaLevel = defaults.lhaLevel
            }
            count.value = 0
            let button = try XCTUnwrap(controller.compressionResetButtons[tab])
            XCTAssertEqual(button.identifier?.rawValue, "preferences.compression.reset." + tab.rawValue)
            XCTAssertEqual(button.title, String(localized: "標準に戻す"))
            XCTAssertEqual(button.toolTip, String(format: String(localized: "%@の設定を標準に戻します。"), tab.title))
            XCTAssertEqual(button.accessibilityLabel(), String(format: String(localized: "%@の設定を標準に戻す"), tab.title))
            sendAction(button)
            XCTAssertEqual(count.value, 1)
            XCTAssertEqual(store.preferences, expected)
            XCTAssertEqual(ArchivePreferencesStore(defaults: suite.defaults).preferences, expected)
            for other in PreferencesViewModel.CompressionTab.allCases {
                XCTAssertEqual(controller.viewModel.compressionDefaultsAreCurrent(for: other), other == tab)
                XCTAssertEqual(try XCTUnwrap(controller.compressionResetButtons[other]).isEnabled, other != tab)
            }
            // 別の入口での変更も有効状態へ即座に反映する。
            store.preferences = defaults
            for other in PreferencesViewModel.CompressionTab.allCases {
                XCTAssertFalse(try XCTUnwrap(controller.compressionResetButtons[other]).isEnabled)
            }
        }
    }

    @MainActor func testDefaultMethodItemsCarryStandardMarker() throws {
        let catalog = try LocalizationAcceptance.catalog()
        for language in LocalizationAcceptance.languages {
            let marker = try XCTUnwrap(catalog.strings["%@（標準）"]?.localizations[language]).stringUnit
            let level = try XCTUnwrap(catalog.strings["6（標準）"]?.localizations[language]).stringUnit.value
            XCTAssertEqual(marker.state, "translated")
            XCTAssertEqual(String(format: marker.value, "6"), level, language)
        }
        for language in ["ja", "en"] {
            let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
            let bundle = try LocalizationAcceptance.bundle(language)
            let controller = PreferencesWindowController(store: store, bundle: bundle)
            defer { controller.close() }
            let defaults = ArchivePreferences()
            let sevenZip = controller.viewModel.compressionController(for: .sevenZip)
            let lha = controller.viewModel.compressionController(for: .lha)
            let popups: [(NSPopUpButton, [String], Int)] = [
                (controller.zipMethodPopup, [String(localized: "Deflate", bundle: bundle), String(localized: "無圧縮", bundle: bundle),
                                             "BZip2", "LZMA", "XZ", String(localized: "Zstandard", bundle: bundle), String(localized: "PPMd", bundle: bundle)],
                 try XCTUnwrap(PreferencesViewModel.zipMethods.firstIndex(of: defaults.zipMethod))),
                (controller.sevenZipMethodPopup, sevenZip.methods.map { $0.title(bundle: bundle) }, sevenZip.selectedMethodIndex),
                (controller.lhaMethodPopup, lha.methods.map { $0.title(bundle: bundle) }, lha.selectedMethodIndex),
                (controller.sevenZipFilterPopup, ArchivePreferences.SevenZipFilter.allCases.map { $0.title(bundle: bundle) },
                 try XCTUnwrap(ArchivePreferences.SevenZipFilter.allCases.firstIndex(of: defaults.sevenZipFilter)))
            ]
            for (popup, original, standard) in popups {
                for (index, title) in original.enumerated() {
                    let expected = index == standard ? String(format: String(localized: "%@（標準）", bundle: bundle), title) : title
                    XCTAssertEqual(popup.item(at: index)?.title, expected, language)
                    popup.selectItem(at: index)
                    sendAction(popup)
                    XCTAssertEqual(popup.indexOfSelectedItem, index, language)
                }
            }
        }
    }

    @MainActor func testPerFormatSelectionsRoundTripThroughExistingPreferenceKeys() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let model = PreferencesViewModel(store: store)
        func saved() -> ArchivePreferences { ArchivePreferencesStore(defaults: suite.defaults).preferences }
        let sevenZipMethods: [ArchivePreferences.SevenZipMethod] = [.lzma2, .lzma, .deflate, .bzip2, .ppmd]
        for (methodIndex, method) in sevenZipMethods.enumerated() {
            model.selectSevenZipMethod(at: methodIndex)
            XCTAssertEqual(model.sevenZipMethodIndex, methodIndex)
            XCTAssertEqual(saved().sevenZipMethod, method)
            let compression = model.compressionController(for: .sevenZip)
            for (index, level) in compression.levels.enumerated() {
                model.selectSevenZipLevel(at: index)
                XCTAssertEqual(model.sevenZipLevelIndex, index)
                let preferences = saved()
                if method == .ppmd && level != .none {
                    XCTAssertEqual(preferences.sevenZipPPMdLevel, level.rawValue)
                    XCTAssertNotEqual(preferences.sevenZipLevel, -1)
                } else { XCTAssertEqual(preferences.sevenZipLevel, level.rawValue) }
            }
        }
        model.selectSevenZipMethod(at: 4)
        model.selectSevenZipLevel(at: 0)
        XCTAssertEqual(saved().sevenZipLevel, -1)
        model.selectSevenZipLevel(at: 2)
        XCTAssertEqual(saved().sevenZipLevel, 6)
        XCTAssertEqual(saved().sevenZipPPMdLevel, 2)
        for (index, method) in [ArchivePreferences.LhaMethod.lh5, .lh6, .lh7].enumerated() {
            model.selectLHAMethod(at: index)
            XCTAssertEqual(model.lhaMethodIndex, index)
            XCTAssertEqual(saved().lhaMethod, method)
            for (levelIndex, level) in model.compressionController(for: .lha).levels.enumerated() {
                model.selectLHALevel(at: levelIndex)
                XCTAssertEqual(saved().lhaLevel, level.rawValue)
                XCTAssertEqual(model.lhaLevelIndex, levelIndex)
            }
        }
        let tarSelections: [(GyoshukuKit.ArchiveFormat, (Int) -> Void, KeyPath<ArchivePreferences, Int>)] = [
            (.tarXZ, { model.selectTarXZLevel(at: $0) }, \.tarXZLevel),
            (.tarZstd, { model.selectTarZstdLevel(at: $0) }, \.tarZstdLevel),
            (.tarLzip, { model.selectTarLzipLevel(at: $0) }, \.tarLzipLevel),
            (.tarLZMA, { model.selectTarLZMALevel(at: $0) }, \.tarLZMALevel)
        ]
        for (format, select, key) in tarSelections {
            for (index, level) in model.compressionController(for: format).levels.enumerated() {
                select(index)
                XCTAssertEqual(saved()[keyPath: key], level.rawValue)
                XCTAssertEqual(model.compressionController(for: format).selectedLevelIndex, index)
            }
        }
        for enabled in [true, false] {
            model.changeSevenZipSolid(to: enabled)
            XCTAssertEqual(saved().sevenZipSolid, enabled)
        }
        for (index, filter) in ArchivePreferences.SevenZipFilter.allCases.enumerated() {
            model.selectSevenZipFilter(at: index)
            XCTAssertEqual(saved().sevenZipFilter, filter)
        }
        let before = saved()
        for index in [-1, 99] {
            model.selectSevenZipMethod(at: index)
            model.selectSevenZipLevel(at: index)
            model.selectSevenZipFilter(at: index)
            model.selectLHAMethod(at: index)
            model.selectLHALevel(at: index)
            for (_, select, _) in tarSelections { select(index) }
        }
        XCTAssertEqual(saved(), before)
    }

    @MainActor func testToolbarSwitchesPanesWithoutMovingControlsOffScreen() throws {
        let suite = try ArchivePreferencesTestDefaults()
        let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults))
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        controller.tabController.animationsEnabled = false
        controller.showWindow(nil)
        let visible = try XCTUnwrap(window.screen).visibleFrame
        window.setFrameOrigin(NSPoint(x: visible.minX + 20, y: visible.minY + 20))
        let initialSize = try XCTUnwrap(window.contentView).bounds.size
        let toolbar = try XCTUnwrap(window.toolbar)
        for index in [1, 2, 3, 4, 0] {
            let pane = controller.tabController.tabViewItems[index]
            let identifier = try XCTUnwrap(pane.identifier as? String)
            let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == identifier })
            let action = try XCTUnwrap(item.action)
            XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item))
            window.layoutIfNeeded()
            XCTAssertEqual(controller.tabController.selectedTabViewItemIndex, index)
            XCTAssertTrue(visible.insetBy(dx: -0.5, dy: -0.5).contains(window.frame))
            XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.width, initialSize.width, accuracy: 0.5)
            let violations = UISnapshot.overflowViolations(in: try XCTUnwrap(window.contentView))
            XCTAssertTrue(violations.isEmpty, "\(identifier)\n" + violations.joined(separator: "\n"))
        }
        XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.size, initialSize)
    }

    @MainActor func testExtractionSettingsUseArchiveUtilityLabelsInEveryLanguage() throws {
        // この固定値はAppleの設定ウインドウ用語集に基づく。翻訳ファイルから期待値を読み戻さない。
        let expected: [String: [String]] = [
            "ja": ["展開したファイルの保存場所:", "展開後:", "フォルダを作成:",
                "アーカイブと同じディレクトリ内", "場所を選択…",
                "アーカイブをそのままにする", "アーカイブをゴミ箱に入れる", "展開した項目をFinderに表示"],
            "en": ["Save expanded file(s) into:", "After expanding:", "Create folder:",
                "In the same directory as the archive", "into…",
                "Leave the archive alone", "Move the archive to the Trash", "Reveal expanded items in Finder"],
            "de": ["Entpackte Dateien sichern:", "Nach dem Entpacken:", "Ordner erstellen:",
                "Im Ordner des Archivs", "In …",
                "Archiv nicht bewegen", "Archiv in den Papierkorb bewegen", "Entpackte Objekte im Finder anzeigen"],
            "fr": ["Enregistrer les fichiers décompressés :", "Après la décompression :", "Créer un dossier :",
                "dans le même répertoire que l’archive", "dans…",
                "laisser l’archive telle quelle", "placer l’archive dans la corbeille", "Afficher le ou les éléments décompressés dans le Finder"],
            "es": ["Guardar archivos descomprimidos:", "Tras la descompresión:", "Crear carpeta:",
                "en el mismo directorio que el archivo comprimido", "en…",
                "no tocar el archivo comprimido", "trasladar el archivo comprimido a la papelera", "Mostrar ítems descomprimidos en el Finder"],
            "it": ["Salva file espansi:", "Dopo espansione:", "Crea cartella:",
                "nella stessa directory dell’archivio", "in…",
                "non toccare archivio", "sposta archivio nel Cestino", "Mostra elemento(i) espanso(i) nel Finder"],
            "pt-BR": ["Salvar arquivos expandidos:", "Depois de expandir:", "Criar pasta:",
                "no mesmo diretório do arquivo comprimido", "dentro de…",
                "não fazer nada com o arquivo comprimido", "mover arquivo comprimido para o Lixo", "Mostrar conteúdo expandido no Finder"],
            "zh-Hans": ["保存已解压缩的文件：", "解压缩后：", "创建文件夹：",
                "放在归档的同一个目录", "放在…",
                "保留归档", "将归档移到废纸篓", "在访达中显示已解压缩的项目"],
            "zh-Hant": ["儲存解壓縮的檔案：", "解壓縮後：", "製作檔案夾：",
                "封存檔的同一目錄", "位置⋯",
                "保留封存檔", "將封存檔丟到「垃圾桶」", "在Finder中顯示解壓縮的項目"],
            "ko": ["압축 해제된 파일 저장:", "압축 해제 후:", "폴더 생성:",
                "아카이브와 동일한 디렉토리 안에", "위치 지정…",
                "아카이브 그대로 유지", "휴지통으로 아카이브 이동", "Finder에서 압축 해제된 항목 나타내기"],
            "th": ["บันทึกไฟล์ที่ขยายไปยัง:", "หลังจากขยาย:", "สร้างโฟลเดอร์:", "ในไดเรกทอรีเดียวกับที่เก็บถาวร", "เข้าใน…", "ปล่อยที่เก็บถาวรไว้ตามเดิม", "ย้ายที่เก็บถาวรไปยังถังขยะ", "แสดงรายการที่ขยายแล้วใน Finder"],
            "vi": ["Lưu (các) tệp đã giải nén vào:", "Sau khi giải nén:", "Tạo thư mục:", "Trong cùng thư mục với tệp lưu trữ", "trong…", "Giữ nguyên tệp lưu trữ", "Chuyển tệp lưu trữ vào Thùng rác", "Hiển thị mục đã giải nén trong Finder"],
            "id": ["Simpan file yang diperluas ke:", "Setelah memperluas:", "Buat folder:", "Di direktori yang sama dengan arsip", "ke…", "Biarkan arsip tetap seperti semula", "Pindahkan arsip ke Tong Sampah", "Tampilkan item yang diperluas di Finder"],
            "ms": ["Simpan fail dikembangkan ke dalam:", "Selepas mengembangkan:", "Cipta folder:", "Dalam direktori yang sama dengan arkib", "ke dalam…", "Biarkan arkib tanpa perubahan", "Alihkan arkib ke Sampah", "Tunjukkan item dikembangkan dalam Finder"],
            "hi": ["विस्तारित फ़ाइलें इसमें सहेजें :", "विस्तारण के बाद :", "फ़ोल्डर बनाएँ :", "आर्काइव वाली डाइरेक्टरी में", "इसमें…", "आर्काइव को वैसा ही रहने दें", "आर्काइव को रद्दी में मूव करें", "Finder में विस्तारित आइटम दिखाएँ"],
            "ru": ["Сохранить разархив. файл(ы):", "После разархивирования:", "Создавать папку:", "В той же папке, что и архив", "в…", "Оставить архив без изменений", "Переместить архив в Корзину", "Показать разархивированные объекты в Finder"],
            "nl": ["Bewaar uitgepakte bestanden in:", "Na uitpakken:", "Maak map aan:", "In dezelfde map als het archief", "in…", "Laat het archief ongewijzigd", "Verplaats het archief naar de prullenmand", "Toon uitgepakte onderdelen in Finder"],
            "pl": ["Zachowaj rozpakowane pliki:", "Po rozpakowaniu:", "Twórz folder:", "W tym samym katalogu co archiwum", "w…", "Pozostaw archiwum bez zmian", "Przenieś archiwum do Kosza", "Pokaż rozpakowane rzeczy w Finderze"],
            "tr": ["Çıkarılan dosyaları şuraya kaydet:", "Çıkardıktan sonra:", "Klasör yarat:", "Arşivle aynı dizinde", "şuraya…", "Arşivi olduğu gibi bırak", "Arşivi Çöp Sepeti’ne taşı", "Çıkarılan öğeleri Finder’da göster"],
            "sv": ["Spara expanderade filer i:", "Efter expandering:", "Skapa mapp:", "I samma mapp som arkivet", "i…", "Lämna arkivet oförändrat", "Flytta arkivet till papperskorgen", "Visa expanderade objekt i Finder"],
            "da": ["Gem dekomprimerede arkiver i:", "Efter dekomprimering:", "Opret mappe:", "I samme mappe som det komprimerede arkiv", "i…", "Lad det komprimerede arkiv være uændret", "Flyt det komprimerede arkiv til papirkurven", "Vis dekomprimerede emner i Finder"],
            "nb": ["Lagre filer som er pakket ut, i:", "Etter utpakking:", "Opprett mappe:", "I samme mappe som arkivet", "i…", "La arkivet være uendret", "Flytt arkivet til papirkurven", "Vis utpakkede objekter i Finder"],
            "fi": ["Tallenna puretut tiedostot sijaintiin:", "Purkamisen jälkeen:", "Luo kansio:", "Arkiston kanssa samassa kansiossa", "sijaintiin…", "Jätä arkisto ennalleen", "Siirrä arkisto roskakoriin", "Näytä puretut kohteet Finderissa"],
            "uk": ["Зберігати розпаковані файли:", "Після розпакування:", "Створювати папку:", "У тій самій папці, що й архів", "у папці…", "Залишити архів без змін", "Перемістити архів у Смітник", "Показати розпаковані елементи у Finder"],
            "cs": ["Uložit rozbalené soubory do:", "Po rozbalení:", "Vytvořit složku:", "Ve stejné složce jako archiv", "do složky…", "Ponechat archiv beze změny", "Přesunout archiv do koše", "Zobrazit rozbalené položky ve Finderu"],
            "pt-PT": ["Guardar ficheiro(s) descomprimido(s) em:", "Após descomprimir:", "Criar pasta:", "Na mesma pasta que o arquivo", "em…", "Manter o arquivo inalterado", "Mover o arquivo para o Lixo", "Mostrar elementos descomprimidos no Finder"]
        ]
        for language in LocalizationAcceptance.languages {
            let suite = try ArchivePreferencesTestDefaults()
            let store = ArchivePreferencesStore(defaults: suite.defaults)
            let bundle = try LocalizationAcceptance.bundle(language)
            let controller = PreferencesWindowController(store: store, bundle: bundle)
            defer { controller.close() }
            let values = try XCTUnwrap(expected[language])
            controller.tabController.selectedTabViewItemIndex = 2
            let pane = try XCTUnwrap(controller.tabController.tabViewItems[2].viewController?.view)
            func labels(in view: NSView) -> [String] {
                (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap { labels(in: $0) }
            }
            let visibleLabels = labels(in: pane).map(LocalizationAcceptance.normalizedTitle)
            for expected in values[0...2].map(LocalizationAcceptance.normalizedTitle) {
                XCTAssertTrue(visibleLabels.contains(expected), "\(language): \(expected)")
            }
            XCTAssertEqual(controller.extractionDestinationPopup.itemTitles.map(LocalizationAcceptance.normalizedTitle),
                           values[3...4].map(LocalizationAcceptance.normalizedTitle), language)
            XCTAssertEqual(controller.afterExpansionPopup.itemTitles.map(LocalizationAcceptance.normalizedTitle),
                           values[5...6].map(LocalizationAcceptance.normalizedTitle), language)
            XCTAssertEqual(LocalizationAcceptance.normalizedTitle(controller.revealsExtractedItemsInFinderCheckbox.title),
                           LocalizationAcceptance.normalizedTitle(values[7]), language)
            XCTAssertTrue(controller.revealsExtractedItemsInFinderCheckbox.isDescendant(of: pane))
            XCTAssertFalse(store.preferences.revealsExtractedItemsInFinder)
            for enabled in [true, false] {
                controller.revealsExtractedItemsInFinderCheckbox.state = enabled ? .on : .off
                sendAction(controller.revealsExtractedItemsInFinderCheckbox)
                XCTAssertEqual(ArchivePreferencesStore(defaults: suite.defaults).preferences.revealsExtractedItemsInFinder, enabled, language)
            }
        }
    }
}
