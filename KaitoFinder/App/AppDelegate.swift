import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documentController: NSDocumentController!

    static func main() {
        // umask の取得中に他の worker がファイルを作らないよう、AppKit 起動前に確定する。
        _ = ExtractionPermissions.processMask
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        do { try ExtractionTemporaryDirectory().sweepOnLaunch() }
        catch { NSLog("一時展開領域の掃除に失敗しました: %@", String(describing: error)) }
        documentController = NSDocumentController.shared
        NSApp.mainMenu = makeMenu()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 実行ファイルへ直接渡したパスも、通常の文書オープン経路へ流す。
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil else { return }
        for argument in CommandLine.arguments.dropFirst() where !argument.hasPrefix("-") {
            let url = URL(fileURLWithPath: argument)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            documentController.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "KaitoFinder")
        appMenu.addItem(withTitle: String(localized: "KaitoFinderについて"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "KaitoFinderを終了"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileMenu = NSMenu(title: String(localized: "ファイル"))
        let open = fileMenu.addItem(withTitle: String(localized: "開く…"),
                                   action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "O")
        open.target = documentController
        fileMenu.addItem(withTitle: String(localized: "開く（読み取り専用のコピー）"),
                         action: #selector(ArchiveWindowController.openEntry(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: String(localized: "クイックルック"),
                         action: #selector(ArchiveWindowController.togglePreviewPanel(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: String(localized: "閉じる"),
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "選択した項目を取り出す…"),
                         action: #selector(ArchiveWindowController.extractSelected(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: String(localized: "すべて取り出す…"),
                         action: #selector(ArchiveWindowController.extractAll(_:)), keyEquivalent: "")
        let editMenu = NSMenu(title: String(localized: "編集"))
        editMenu.addItem(withTitle: String(localized: "コピー"),
                         action: #selector(ArchiveWindowController.copy(_:)), keyEquivalent: "c")
        let windowMenu = NSMenu(title: String(localized: "ウインドウ"))
        windowMenu.addItem(withTitle: String(localized: "しまう"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "拡大／縮小"),
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        for submenu in [appMenu, fileMenu, editMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        return menu
    }
}
