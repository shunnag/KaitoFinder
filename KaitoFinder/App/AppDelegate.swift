import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documentController: NSDocumentController!

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
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
                                   action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        open.target = documentController
        fileMenu.addItem(withTitle: String(localized: "閉じる"),
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowMenu = NSMenu(title: String(localized: "ウインドウ"))
        windowMenu.addItem(withTitle: String(localized: "しまう"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "拡大／縮小"),
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        for submenu in [appMenu, fileMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        return menu
    }
}
