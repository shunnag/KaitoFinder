import AppKit
import XCTest
@testable import KaitoFinder

/// AppDelegate が言語の bundle ごとに組み立てる実際の NSMenu について、項目の文言・並び・action・target・shortcut と
/// NSApplication への結び付けを確かめる。文字列カタログそのものの網羅は WordingAcceptanceTests が見る。
/// 言語ごとの bundle と文言の正規化には LocalizationAcceptance（Support/）を使う。書き換えた NSApplication のメニューは
/// 各テストが元に戻す（preserveApplicationMenus、または defer での復元）。
nonisolated final class MenuWordingTests: XCTestCase {
    @MainActor func testJapaneseMenuCorrectionsAndNamedProgressTitle() throws {
        preserveApplicationMenus()
        let bundle = try LocalizationAcceptance.bundle("ja")
        let menu = AppDelegate().makeMenu(bundle: bundle)
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        for title in ["KaitoFinderを非表示", "ほかを非表示", "すべてを表示", "サービス"] {
            XCTAssertNotNil(appMenu.item(withTitle: title), title)
        }
        XCTAssertNil(appMenu.item(withTitle: "KaitoFinderを隠す"))
        XCTAssertNil(appMenu.item(withTitle: "ほかを隠す"))
        XCTAssertEqual(ArchiveProgressOperation.expandingArchive("旅行の写真.zip").title(bundle: bundle), "“旅行の写真.zip”を展開中…")
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
        for language in LocalizationAcceptance.languages {
            let bundle = try XCTUnwrap(Bundle(url: XCTUnwrap(appBundle.url(forResource: language, withExtension: "lproj"))))
            let delegate = AppDelegate(), menu = delegate.makeMenu(bundle: bundle)
            func title(_ key: String.LocalizationValue) -> String {
                LocalizationAcceptance.normalizedTitle(String(localized: key, bundle: bundle))
            }
            func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
                menu.items.first { LocalizationAcceptance.normalizedTitle($0.title) == LocalizationAcceptance.normalizedTitle(title) }
            }
            func index(_ menu: NSMenu, _ title: String) -> Int {
                item(menu, title).map { menu.index(of: $0) } ?? -1
            }
            let submenus = menu.items.compactMap(\.submenu)
            let goTitle = LocalizationAcceptance.normalizedTitle(String(localized: "移動", table: "GoMenu", bundle: bundle))
            XCTAssertEqual(submenus.map { LocalizationAcceptance.normalizedTitle($0.title) },
                           ["KaitoFinder", title("ファイル"), title("編集"), title("表示"), goTitle, title("ウインドウ"), title("ヘルプ")])
            let app = try XCTUnwrap(submenus.first)
            XCTAssertEqual(app.items.map { LocalizationAcceptance.normalizedTitle($0.title) },
                           [title("KaitoFinderについて"), "", title("設定…"), title("アップデートを確認…"), "", title("サービス"), "",
                                                  title("KaitoFinderを非表示"), title("ほかを非表示"), title("すべてを表示"), "", title("KaitoFinderを終了")])
            for index in [1, 4, 6, 10] { XCTAssertTrue(app.items[index].isSeparatorItem) }
            let update = try XCTUnwrap(item(app, title("アップデートを確認…")))
            XCTAssertEqual(update.action, #selector(AppDelegate.checkForUpdates(_:)))
            XCTAssertTrue(update.target === delegate)
            XCTAssertEqual(update.keyEquivalent, "")
            let services = try XCTUnwrap(item(app, title("サービス"))?.submenu)
            XCTAssertEqual(LocalizationAcceptance.normalizedTitle(services.title), title("サービス"))
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
            try check(item(app, title("KaitoFinderを非表示")), #selector(NSApplication.hide(_:)), "h")
            try check(item(app, title("ほかを非表示")), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            try check(item(app, title("すべてを表示")), #selector(NSApplication.unhideAllApplications(_:)), "")
            try check(item(app, title("KaitoFinderを終了")), #selector(NSApplication.terminate(_:)), "q")

            let file = try XCTUnwrap(item(menu, title("ファイル"))?.submenu)
            let recent = try XCTUnwrap(item(file, title("最近使った項目を開く")))
            XCTAssertEqual(file.index(of: recent), index(file, title("開く…")) + 1)
            let recentMenu = try XCTUnwrap(recent.submenu)
            let clear = try XCTUnwrap(recentMenu.items.last)
            XCTAssertEqual(LocalizationAcceptance.normalizedTitle(clear.title), title("メニューを消去"))
            try check(clear, #selector(NSDocumentController.clearRecentDocuments(_:)), "")
            try check(item(file, title("開く")), #selector(ArchiveWindowController.openEntry(_:)), "o")
            let view = try XCTUnwrap(item(menu, title("表示"))?.submenu)
            let options = try XCTUnwrap(item(view, title("表示オプションを表示")))
            XCTAssertTrue(options === view.items.last)
            XCTAssertTrue(view.items[view.items.count - 2].isSeparatorItem)
            XCTAssertEqual(options.action, #selector(AppDelegate.toggleViewOptions(_:)))
            XCTAssertTrue(options.target === delegate)
            XCTAssertEqual(options.keyEquivalent, "j")
            XCTAssertEqual(options.keyEquivalentModifierMask, [.command])
            let go = try XCTUnwrap(item(menu, goTitle)?.submenu)
            XCTAssertEqual(go.items.map { LocalizationAcceptance.normalizedTitle($0.title) },
                           [title("戻る"), title("進む"), "", title("内包フォルダ")])
            XCTAssertTrue(go.items[2].isSeparatorItem)
            try check(item(go, title("戻る")), #selector(ArchiveWindowController.goBack(_:)), "[")
            try check(item(go, title("進む")), #selector(ArchiveWindowController.goForward(_:)), "]")
            try check(item(go, title("内包フォルダ")), #selector(ArchiveWindowController.goToEnclosingFolder(_:)), "\u{f700}")

            let edit = try XCTUnwrap(item(menu, title("編集"))?.submenu)
            let selectAll = try XCTUnwrap(item(edit, title("すべてを選択")))
            try check(selectAll, #selector(NSText.selectAll(_:)), "a")
            XCTAssertEqual(edit.index(of: selectAll), index(edit, title("ペースト")) + 1)
            XCTAssertEqual(index(edit, title("削除")), edit.index(of: selectAll) + 1)

            let window = try XCTUnwrap(item(menu, title("ウインドウ"))?.submenu)
            XCTAssertNotNil(application.windowsMenu)
            let welcome = try XCTUnwrap(item(window, title("ようこそKaitoFinderへ")))
            XCTAssertEqual(welcome.action, #selector(AppDelegate.showWelcome(_:)))
            XCTAssertTrue(welcome.target === delegate)
            XCTAssertEqual(welcome.keyEquivalent, "1")
            XCTAssertEqual(welcome.keyEquivalentModifierMask, [.command, .shift])
            if language == "ja" { XCTAssertEqual(welcome.title, "ようこそKaitoFinderへ") }
            let bringAll = try XCTUnwrap(item(window, title("すべてを手前に移動")))
            try check(bringAll, #selector(NSApplication.arrangeInFront(_:)), "")
            XCTAssertEqual(window.index(of: bringAll), index(window, title("拡大/縮小")) + 1)

            let helpMenu = try XCTUnwrap(item(menu, title("ヘルプ"))?.submenu)
            XCTAssertTrue(application.helpMenu === helpMenu)
            let help = try XCTUnwrap(item(helpMenu, title("KaitoFinderヘルプ")))
            XCTAssertEqual(help.action, #selector(AppDelegate.showHelp(_:)))
            XCTAssertTrue(help.target === delegate)
            XCTAssertEqual(help.keyEquivalent, "")
        }
    }
}
