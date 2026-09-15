import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documentController: NSDocumentController!
    private let passwordVault: ArchivePasswordVault
    private let preferencesStore: ArchivePreferencesStore
    private(set) var preferencesWindowController: PreferencesWindowController?
    private(set) var forgetPasswordsTask: Task<Void, Never>?
    private(set) var archiveCreationTask: Task<Void, Never>?
    private(set) var creationOpenPanel: NSOpenPanel?
    private(set) var batchExtractionTask: Task<Void, Never>?
    private(set) var batchExtractionOpenPanel: NSOpenPanel?
    private(set) var batchExtractionController: ArchiveBatchExtractionController?
    // Servicesの入力経路をパネルなしで検証するための実行境界。
    var batchExtractionHandler: (([URL]) async -> Void)?

    override convenience init() { self.init(passwordVault: .shared) }

    init(passwordVault: ArchivePasswordVault = .shared, preferencesStore: ArchivePreferencesStore = .shared) {
        self.passwordVault = passwordVault
        self.preferencesStore = preferencesStore
        super.init()
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(store: preferencesStore)
        }
        preferencesWindowController?.showWindow(sender)
        preferencesWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/shunnag/KaitoFinder")!)
    }

    @objc func forgetArchivePasswords(_ sender: Any?) {
        guard forgetPasswordsTask == nil else { return }
        forgetPasswordsTask = Task {
            defer { forgetPasswordsTask = nil }
            if !(await passwordVault.forgetAll()) {
                let alert = NSAlert()
                alert.messageText = String(localized: "記憶したパスワードを削除できませんでした")
                alert.runModal()
            }
        }
    }

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
        ExtractionTemporaryDirectory().startLaunchSweep()
        documentController = NSDocumentController.shared
        NSApp.servicesProvider = self
        NSApp.mainMenu = makeMenu()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    @objc func newArchive(_ sender: Any?) {
        guard archiveCreationTask == nil, creationOpenPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "選択")
        panel.message = String(localized: "アーカイブにする項目を選んでください")
        creationOpenPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            self.creationOpenPanel = nil
            if response == .OK { self.startArchiveCreation(sources: panel.urls) }
        }
    }

    static func filesToCompress(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(\.isFileURL)
    }

    @objc func compressFiles(_ pboard: NSPasteboard, userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let sources = Self.filesToCompress(from: pboard)
        guard !sources.isEmpty else {
            error.pointee = String(localized: "アーカイブにする項目を選んでください") as NSString
            return
        }
        guard archiveCreationTask == nil, creationOpenPanel == nil else {
            error.pointee = String(localized: "別の操作が完了するまでお待ちください。") as NSString
            return
        }
        NSApp.activate()
        startArchiveCreation(sources: sources)
    }

    private func startArchiveCreation(sources: [URL]) {
        guard !sources.isEmpty, archiveCreationTask == nil else { return }
        archiveCreationTask = Task {
            defer { archiveCreationTask = nil }
            do { try await ArchiveCreationController(store: preferencesStore).createAndOpen(sources: sources) }
            catch {
                if !(error is CancellationError) { ArchiveCreationController.presentFailure(error) }
            }
        }
    }

    @objc func extractArchivesFromMenu(_ sender: Any?) {
        guard batchExtractionTask == nil, batchExtractionOpenPanel == nil else { return }
        let panel = ArchiveBatchExtractionController.makeArchivePanel()
        batchExtractionOpenPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            self.batchExtractionOpenPanel = nil
            if response == .OK { self.startBatchExtraction(archives: panel.urls) }
        }
    }

    static func archivesToExtract(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(\.isFileURL)
    }

    @objc func extractArchives(_ pboard: NSPasteboard, userData: String,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard batchExtractionTask == nil, batchExtractionOpenPanel == nil else {
            error.pointee = String(localized: "別の操作が完了するまでお待ちください。") as NSString
            return
        }
        let archives = Self.archivesToExtract(from: pboard)
        guard !archives.isEmpty else {
            error.pointee = String(localized: "展開するアーカイブを選んでください。") as NSString
            return
        }
        NSApp.activate()
        startBatchExtraction(archives: archives)
    }

    private func startBatchExtraction(archives: [URL]) {
        guard !archives.isEmpty, batchExtractionTask == nil else { return }
        batchExtractionTask = Task {
            if let batchExtractionHandler {
                await batchExtractionHandler(archives)
                batchExtractionTask = nil
                return
            }
            let controller = ArchiveBatchExtractionController(store: preferencesStore, passwordVault: passwordVault)
            batchExtractionController = controller
            defer { batchExtractionTask = nil; batchExtractionController = nil }
            await controller.extract(archives: archives)
        }
    }

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

    func makeMenu(bundle: Bundle = .main) -> NSMenu {
        let menu = NSMenu()
        let appMenu = NSMenu(title: String(localized: "KaitoFinder", bundle: bundle))
        appMenu.addItem(withTitle: String(localized: "KaitoFinderについて", bundle: bundle),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let preferences = appMenu.addItem(withTitle: String(localized: "設定…", bundle: bundle),
                                          action: #selector(showPreferences(_:)), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(.separator())
        let services = appMenu.addItem(withTitle: String(localized: "サービス", bundle: bundle), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: services.title)
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "KaitoFinderを非表示", bundle: bundle),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: String(localized: "ほかを非表示", bundle: bundle),
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "すべてを表示", bundle: bundle),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "KaitoFinderを終了", bundle: bundle),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileMenu = NSMenu(title: String(localized: "ファイル", bundle: bundle))
        let create = fileMenu.addItem(withTitle: String(localized: "新規アーカイブ…", bundle: bundle),
                                     action: #selector(newArchive(_:)), keyEquivalent: "n")
        create.target = self
        let extract = fileMenu.addItem(withTitle: String(localized: "アーカイブを展開…", bundle: bundle),
                                      action: #selector(extractArchivesFromMenu(_:)), keyEquivalent: "")
        extract.target = self
        let open = fileMenu.addItem(withTitle: String(localized: "開く…", bundle: bundle),
                                   action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "O")
        open.target = documentController
        let recent = fileMenu.addItem(withTitle: String(localized: "最近使った項目を開く", bundle: bundle), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: recent.title)
        recentMenu.addItem(withTitle: String(localized: "メニューを消去", bundle: bundle),
                           action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recent.submenu = recentMenu
        fileMenu.addItem(withTitle: String(localized: "開く", bundle: bundle),
                         action: #selector(ArchiveWindowController.openEntry(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: String(localized: "クイックルック", bundle: bundle),
                         action: #selector(ArchiveWindowController.togglePreviewPanel(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: String(localized: "閉じる", bundle: bundle),
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(.separator())
        let newFolder = fileMenu.addItem(withTitle: String(localized: "新規フォルダ", bundle: bundle),
                                         action: #selector(ArchiveWindowController.newFolder(_:)), keyEquivalent: "n")
        newFolder.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "選択した項目を展開…", bundle: bundle),
                         action: #selector(ArchiveWindowController.extractSelected(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: String(localized: "すべて展開…", bundle: bundle),
                         action: #selector(ArchiveWindowController.extractAll(_:)), keyEquivalent: "")
        let editMenu = NSMenu(title: String(localized: "編集", bundle: bundle))
        editMenu.addItem(withTitle: String(localized: "取り消す", bundle: bundle), action: #selector(ArchiveDocument.undo(_:)), keyEquivalent: "z")
        editMenu.addItem(withTitle: String(localized: "やり直す", bundle: bundle), action: #selector(ArchiveDocument.redo(_:)), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "コピー", bundle: bundle),
                         action: #selector(ArchiveWindowController.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "ペースト", bundle: bundle),
                         action: #selector(ArchiveWindowController.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "すべてを選択", bundle: bundle),
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(withTitle: String(localized: "削除", bundle: bundle),
                         action: #selector(ArchiveWindowController.deleteEntries(_:)), keyEquivalent: "\u{7f}")
        editMenu.addItem(withTitle: String(localized: "名称変更", bundle: bundle),
                         action: #selector(ArchiveWindowController.renameEntry(_:)), keyEquivalent: "")
        editMenu.addItem(.separator())
        let forget = editMenu.addItem(withTitle: String(localized: "記憶したパスワードをすべて削除", bundle: bundle),
                                      action: #selector(forgetArchivePasswords(_:)), keyEquivalent: "")
        // 文書がないときや保管庫が読めないときも、アプリ全体の削除を利用できる。
        forget.target = self
        let windowMenu = NSMenu(title: String(localized: "ウインドウ", bundle: bundle))
        windowMenu.addItem(withTitle: String(localized: "しまう", bundle: bundle),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "拡大/縮小", bundle: bundle),
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: String(localized: "すべてを手前に移動", bundle: bundle),
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let helpMenu = NSMenu(title: String(localized: "ヘルプ", bundle: bundle))
        let help = helpMenu.addItem(withTitle: String(localized: "KaitoFinderヘルプ", bundle: bundle),
                                    action: #selector(showHelp(_:)), keyEquivalent: "")
        help.target = self
        for submenu in [appMenu, fileMenu, editMenu, windowMenu, helpMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
        return menu
    }
}
