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
                                       zipSkipsCompressedTypes: false, tarGzipLevel: 2, tarPreservesOwnerIDs: true,
                                       extractionDestination: .ask, folderPolicy: .never, trashesArchiveAfterExtraction: true,
                                       revealsExtractedItemsInFinder: true)
        store.preferences = saved
        let model = PreferencesViewModel(store: ArchivePreferencesStore(defaults: suite.defaults))
        XCTAssertEqual(model.preferences, saved)
        XCTAssertEqual(model.defaultFormatIndex, 2)
        XCTAssertEqual(model.zipMethodIndex, 1)
        XCTAssertEqual(model.extractionDestinationIndex, 1)
        XCTAssertEqual(model.folderPolicyIndex, 2)
        XCTAssertEqual(model.afterExpansionIndex, 1)
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
        controller.afterExpansionPopup.selectItem(at: 1)
        sendAction(controller.afterExpansionPopup)
        XCTAssertTrue(store.preferences.trashesArchiveAfterExtraction)
        controller.revealsExtractedItemsInFinderCheckbox.state = .on
        sendAction(controller.revealsExtractedItemsInFinderCheckbox)
        XCTAssertTrue(store.preferences.revealsExtractedItemsInFinder)
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

    func testSettingsStringsHaveAllTenTranslations() throws {
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
                "아카이브 그대로 유지", "휴지통으로 아카이브 이동", "Finder에서 압축 해제된 항목 나타내기"]
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
            let grid = try XCTUnwrap(pane.subviews.first as? NSGridView)
            let labels = (0..<3).compactMap { (grid.cell(atColumnIndex: 0, rowIndex: $0).contentView as? NSTextField)?.stringValue }
            XCTAssertEqual(labels.map(LocalizationAcceptance.normalizedTitle), values[0...2].map(LocalizationAcceptance.normalizedTitle), language)
            XCTAssertEqual(controller.extractionDestinationPopup.itemTitles.map(LocalizationAcceptance.normalizedTitle),
                           values[3...4].map(LocalizationAcceptance.normalizedTitle), language)
            XCTAssertEqual(controller.afterExpansionPopup.itemTitles.map(LocalizationAcceptance.normalizedTitle),
                           values[5...6].map(LocalizationAcceptance.normalizedTitle), language)
            XCTAssertEqual(LocalizationAcceptance.normalizedTitle(controller.revealsExtractedItemsInFinderCheckbox.title),
                           LocalizationAcceptance.normalizedTitle(values[7]), language)
            XCTAssertNil(grid.cell(atColumnIndex: 0, rowIndex: 3).contentView)
            XCTAssertTrue(grid.cell(atColumnIndex: 1, rowIndex: 3).contentView === controller.revealsExtractedItemsInFinderCheckbox)
            XCTAssertFalse(store.preferences.revealsExtractedItemsInFinder)
            for enabled in [true, false] {
                controller.revealsExtractedItemsInFinderCheckbox.state = enabled ? .on : .off
                sendAction(controller.revealsExtractedItemsInFinderCheckbox)
                XCTAssertEqual(ArchivePreferencesStore(defaults: suite.defaults).preferences.revealsExtractedItemsInFinder, enabled, language)
            }
        }
    }
}
