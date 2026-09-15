import AppKit
import XCTest
@testable import KaitoFinder

nonisolated final class WordingAcceptanceTests: XCTestCase {
    func testCatalogKeysFollowWordingRulesAndHaveEnglishAndJapanese() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("KaitoFinder/Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let spacing = try NSRegularExpression(pattern:
            #"[\p{Han}\p{Hiragana}\p{Katakana}] [A-Za-z]|[A-Za-z] [\p{Han}\p{Hiragana}\p{Katakana}]"#)
        // 数値と単位の間、および取り消しの区切りの空白は、この正規表現に該当しない。
        for allowed in ["4 GiB", "取り消す — %@", "やり直す — %@", "SFX ZIP"] {
            XCTAssertNil(spacing.firstMatch(in: allowed, range: NSRange(allowed.startIndex..., in: allowed)))
        }
        XCTAssertFalse(strings.isEmpty)
        for (key, value) in strings {
            XCTAssertFalse(key.contains("書庫"), key)
            XCTAssertFalse(key.contains("／"), key)
            XCTAssertNil(spacing.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)), key)
            let entry = try XCTUnwrap(value as? [String: Any], key)
            let translations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for language in ["en", "ja"] {
                let translation = try XCTUnwrap(translations[language] as? [String: Any], "\(language): \(key)")
                let unit = try XCTUnwrap(translation["stringUnit"] as? [String: String], key)
                let text = try XCTUnwrap(unit["value"], key)
                XCTAssertFalse(text.isEmpty, key)
                XCTAssertEqual(unit["state"], "translated", key)
                if language == "ja" {
                    XCTAssertEqual(text, key)
                    XCTAssertFalse(text.contains("書庫"), key)
                    XCTAssertFalse(text.contains("／"), key)
                    XCTAssertNil(spacing.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), key)
                }
            }
        }
        for (language, title) in [("ja", "KaitoFinderで圧縮"), ("en", "Compress with KaitoFinder")] {
            let data = try Data(contentsOf: root.appendingPathComponent("KaitoFinder/Resources/\(language).lproj/ServicesMenu.strings"))
            let services = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            XCTAssertEqual(services, ["KaitoFinderで圧縮": title])
        }
    }

    @MainActor func testStandardMenusHaveLocalizedTitlesActionsShortcutsAndApplicationBindings() throws {
        let application = NSApplication.shared
        let previousServices = application.servicesMenu
        let previousWindows = application.windowsMenu
        let previousHelp = application.helpMenu
        defer {
            application.servicesMenu = previousServices
            application.windowsMenu = previousWindows
            application.helpMenu = previousHelp
        }
        let appBundle = Bundle(for: ArchiveDocument.self)
        for language in ["ja", "en"] {
            let bundle = try XCTUnwrap(Bundle(url: XCTUnwrap(appBundle.url(forResource: language, withExtension: "lproj"))))
            let delegate = AppDelegate(), menu = delegate.makeMenu(bundle: bundle)
            func title(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: bundle) }
            let submenus = menu.items.compactMap(\.submenu)
            XCTAssertEqual(submenus.map(\.title), ["KaitoFinder", title("ファイル"), title("編集"), title("ウインドウ"), title("ヘルプ")])
            let app = try XCTUnwrap(submenus.first)
            XCTAssertEqual(app.items.map(\.title), [title("KaitoFinderについて"), "", title("設定…"), "", title("サービス"), "",
                                                  title("KaitoFinderを隠す"), title("ほかを隠す"), title("すべてを表示"), "", title("KaitoFinderを終了")])
            for index in [1, 3, 5, 9] { XCTAssertTrue(app.items[index].isSeparatorItem) }
            let services = try XCTUnwrap(app.item(withTitle: title("サービス"))?.submenu)
            XCTAssertEqual(services.title, title("サービス"))
            // テスト host では起動時に据えたメニューを AppKit が保持し、言語ごとの再構築では差し替わらない。
            // 結び付けの存在だけを確かめる(実アプリでは同一性を lldb で確認済み)。
            XCTAssertNotNil(application.servicesMenu)
            func check(_ item: NSMenuItem?, _ action: Selector, _ key: String,
                       _ modifiers: NSEvent.ModifierFlags = [.command]) throws {
                let item = try XCTUnwrap(item)
                XCTAssertEqual(item.action, action, item.title)
                XCTAssertEqual(item.keyEquivalent, key, item.title)
                XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, item.title)
                XCTAssertNil(item.target, item.title)
            }
            try check(app.item(withTitle: title("KaitoFinderを隠す")), #selector(NSApplication.hide(_:)), "h")
            try check(app.item(withTitle: title("ほかを隠す")), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            try check(app.item(withTitle: title("すべてを表示")), #selector(NSApplication.unhideAllApplications(_:)), "")
            try check(app.item(withTitle: title("KaitoFinderを終了")), #selector(NSApplication.terminate(_:)), "q")

            let file = try XCTUnwrap(menu.item(withTitle: title("ファイル"))?.submenu)
            let recent = try XCTUnwrap(file.item(withTitle: title("最近使った項目を開く")))
            XCTAssertEqual(file.index(of: recent), file.indexOfItem(withTitle: title("開く…")) + 1)
            let recentMenu = try XCTUnwrap(recent.submenu)
            let clear = try XCTUnwrap(recentMenu.items.last)
            XCTAssertEqual(clear.title, title("メニューを消去"))
            try check(clear, #selector(NSDocumentController.clearRecentDocuments(_:)), "")
            try check(file.item(withTitle: title("開く")), #selector(ArchiveWindowController.openEntry(_:)), "o")

            let edit = try XCTUnwrap(menu.item(withTitle: title("編集"))?.submenu)
            let selectAll = try XCTUnwrap(edit.item(withTitle: title("すべてを選択")))
            try check(selectAll, #selector(NSText.selectAll(_:)), "a")
            XCTAssertEqual(edit.index(of: selectAll), edit.indexOfItem(withTitle: title("ペースト")) + 1)
            XCTAssertEqual(edit.indexOfItem(withTitle: title("削除")), edit.index(of: selectAll) + 1)

            let window = try XCTUnwrap(menu.item(withTitle: title("ウインドウ"))?.submenu)
            XCTAssertNotNil(application.windowsMenu)
            let bringAll = try XCTUnwrap(window.item(withTitle: title("すべてを手前に移動")))
            try check(bringAll, #selector(NSApplication.arrangeInFront(_:)), "")
            XCTAssertEqual(window.index(of: bringAll), window.indexOfItem(withTitle: title("拡大/縮小")) + 1)

            let helpMenu = try XCTUnwrap(menu.item(withTitle: title("ヘルプ"))?.submenu)
            XCTAssertTrue(application.helpMenu === helpMenu)
            let help = try XCTUnwrap(helpMenu.item(withTitle: title("KaitoFinderヘルプ")))
            XCTAssertEqual(help.action, #selector(AppDelegate.showHelp(_:)))
            XCTAssertTrue(help.target === delegate)
            XCTAssertEqual(help.keyEquivalent, "")
        }
    }
}
