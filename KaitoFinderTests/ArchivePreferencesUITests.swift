import AppKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePreferencesUITests: XCTestCase {
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
        for (index, method) in PreferencesViewModel.zipMethods.enumerated() {
            model.selectZipMethod(at: index)
            expected.zipMethod = method
            check()
        }
        for level in 1...9 {
            model.changeZipLevel(to: level)
            expected.zipLevel = level
            check()
            XCTAssertEqual(model.zipLevelLabel, String(level))
            model.changeTarGzipLevel(to: 10 - level)
            expected.tarGzipLevel = 10 - level
            check()
            XCTAssertEqual(model.tarGzipLevelLabel, String(10 - level))
        }
        for enabled in [true, false] {
            model.changeZipSkipsCompressedTypes(to: enabled)
            expected.zipSkipsCompressedTypes = enabled
            check()
            model.changeTarPreservesOwnerIDs(to: enabled)
            expected.tarPreservesOwnerIDs = enabled
            check()
            model.changeTrashesArchiveAfterExtraction(to: enabled)
            expected.trashesArchiveAfterExtraction = enabled
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
                                       zipSkipsCompressedTypes: false, tarGzipLevel: 2, tarPreservesOwnerIDs: true,
                                       extractionDestination: .ask, folderPolicy: .never, trashesArchiveAfterExtraction: true)
        store.preferences = saved
        let model = PreferencesViewModel(store: ArchivePreferencesStore(defaults: suite.defaults))
        XCTAssertEqual(model.preferences, saved)
        XCTAssertEqual(model.defaultFormatIndex, 2)
        XCTAssertEqual(model.zipMethodIndex, 1)
        XCTAssertEqual(model.extractionDestinationIndex, 1)
        XCTAssertEqual(model.folderPolicyIndex, 2)
        XCTAssertEqual(model.zipLevelLabel, "8")
        XCTAssertEqual(model.tarGzipLevelLabel, "2")
        for (input, expected) in [(Int.min, 1), (0, 1), (42, 9), (Int.max, 9)] {
            model.changeZipLevel(to: input)
            model.changeTarGzipLevel(to: input)
            XCTAssertEqual(store.preferences.zipLevel, expected)
            XCTAssertEqual(store.preferences.tarGzipLevel, expected)
            XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveZipLevel"), expected)
            XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveTarGzipLevel"), expected)
            XCTAssertEqual(model.zipLevelLabel, String(expected))
            XCTAssertEqual(model.tarGzipLevelLabel, String(expected))
        }
        let before = store.preferences
        for index in [-1, 99] {
            model.selectDefaultFormat(at: index)
            model.selectZipMethod(at: index)
            model.selectExtractionDestination(at: index)
            model.selectFolderPolicy(at: index)
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
        controller.defaultFormatPopup.selectItem(at: 4)
        sendAction(controller.defaultFormatPopup)
        XCTAssertEqual(store.preferences.defaultFormat, .lha)
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
        controller.tarPreservesOwnerIDsCheckbox.state = .on
        sendAction(controller.tarPreservesOwnerIDsCheckbox)
        XCTAssertTrue(store.preferences.tarPreservesOwnerIDs)
        controller.extractionDestinationPopup.selectItem(at: 1)
        sendAction(controller.extractionDestinationPopup)
        XCTAssertEqual(store.preferences.extractionDestination, .ask)
        controller.folderPolicyPopup.selectItem(at: 2)
        sendAction(controller.folderPolicyPopup)
        XCTAssertEqual(store.preferences.folderPolicy, .never)
        controller.trashesArchiveAfterExtractionCheckbox.state = .on
        sendAction(controller.trashesArchiveAfterExtractionCheckbox)
        XCTAssertTrue(store.preferences.trashesArchiveAfterExtraction)
        // 保存パネルなど、別の入口で保存した変更も開いたままの画面へ同期する。
        store.preferences = ArchivePreferences()
        XCTAssertEqual(controller.defaultFormatPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.zipMethodPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.zipLevelSlider.integerValue, 6)
        XCTAssertEqual(controller.zipLevelLabel.stringValue, "6")
        XCTAssertTrue(controller.zipLevelSlider.isEnabled)
        XCTAssertEqual(controller.zipSkipsCompressedTypesCheckbox.state, .on)
        XCTAssertEqual(controller.tarGzipLevelSlider.integerValue, 6)
        XCTAssertEqual(controller.tarGzipLevelLabel.stringValue, "6")
        XCTAssertEqual(controller.tarPreservesOwnerIDsCheckbox.state, .off)
        XCTAssertEqual(controller.extractionDestinationPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(controller.folderPolicyPopup.indexOfSelectedItem, 1)
        XCTAssertEqual(controller.trashesArchiveAfterExtractionCheckbox.state, .off)
    }

    @MainActor func testSavePanelAndSettingsShareDefaultFormat() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let model = PreferencesViewModel(store: store)
        model.selectDefaultFormat(at: 2)
        let save = ArchiveSavePanel(sources: [URL(fileURLWithPath: "/tmp/preferences.txt")], store: store)
        XCTAssertEqual(save.controller.format, store.preferences.defaultFormat)
        XCTAssertEqual(save.formatPopup.indexOfSelectedItem, 2)
        save.formatPopup.selectItem(at: 3)
        sendAction(save.formatPopup)
        XCTAssertEqual(store.preferences.defaultFormat, .sevenZip)
        XCTAssertEqual(model.defaultFormatIndex, 3)
        XCTAssertEqual(suite.defaults.string(forKey: "ArchiveCreationFormat"), "7z")
        XCTAssertEqual(ArchiveSavePanelController(defaults: suite.defaults).format, .sevenZip)
    }

    @MainActor func testSettingsMenuCommandCommaAndWindowControllerReuse() throws {
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
        delegate.showPreferences(nil)
        let first = try XCTUnwrap(delegate.preferencesWindowController), window = try XCTUnwrap(first.window)
        defer { first.close() }
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.title, String(localized: "設定"))
        XCTAssertEqual(window.frameAutosaveName, "Preferences")
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(first.tabController.tabStyle, .toolbar)
        XCTAssertEqual(first.tabController.tabViewItems.map(\.label),
                       [String(localized: "一般"), String(localized: "圧縮"), String(localized: "展開")])
        first.close()
        delegate.showPreferences(nil)
        XCTAssertTrue(delegate.preferencesWindowController === first)
        XCTAssertTrue(delegate.preferencesWindowController?.window === window)
        XCTAssertTrue(window.isVisible)
    }

    func testSettingsStringsHaveEnglishAndJapaneseTranslations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("KaitoFinder/Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let source = try String(contentsOf: root.appendingPathComponent("KaitoFinder/UI/PreferencesWindowController.swift"), encoding: .utf8)
        let expression = try NSRegularExpression(pattern: #"String\(localized: "([^"]+)""#)
        let keys = expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map {
            String(source[Range($0.range(at: 1), in: source)!])
        } + ["設定…"]
        XCTAssertGreaterThan(Set(keys).count, 20)
        for key in Set(keys) {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for language in ["en", "ja"] {
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
}
