import AppKit
import Darwin

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var documentController: NSDocumentController!
    private let passwordVault: ArchivePasswordVault
    private let preferencesStore: ArchivePreferencesStore
    private let softwareUpdater: any SoftwareUpdating
    private(set) var preferencesWindowController: PreferencesWindowController?
    private(set) var welcomeWindowController: WelcomeWindowController?
    private(set) var forgetPasswordsTask: Task<Void, Never>?
    private(set) var archiveCreationTask: Task<Void, Never>?
    private(set) var creationOpenPanel: NSOpenPanel?
    private(set) var batchExtractionTask: Task<Void, Never>?
    private(set) var batchExtractionOpenPanel: NSOpenPanel?
    private(set) var batchExtractionController: ArchiveBatchExtractionController?
    // Servicesの入力経路をパネルなしで検証するための実行境界。
    var batchExtractionHandler: (([URL]) async -> Void)?
    // 終了の確認と返答を、実際のアラートやプロセス終了なしで検証するための境界。
    var terminationDocuments: (() -> [ArchiveDocument])?
    var terminationPromiseRegistry: FilePromiseRegistry = .shared
    var stagingRegistry: StagingRegistry = .shared
    var cleanupRegistry: DocumentCleanupRegistry = .shared
    var pendingWorkRegistry: PendingWorkRegistry = .shared
    var recoverableWorkIndex: RecoverableWorkIndex = .shared
    var volumePublishCriticalSection: VolumePublishCriticalSection = .shared
    // テストホストでは台帳の注入前に実ユーザーの作業領域を回収しない。
    var sweepsPendingWorkAtLaunch: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        && ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil
    var quitConfirmation: (() -> Bool)?
    var terminationReply: ((Bool) -> Void)?
    var terminationGracePeriod: Duration = .seconds(10)
    private(set) var terminationTask: Task<Void, Never>?
    private var terminationDeadline: Task<Void, Never>?
    private var terminationReplied = false
    private var terminationAwaitingCriticalSection = false
    private var criticalSectionObserver: UUID?

    override convenience init() { self.init(passwordVault: .shared) }

    init(passwordVault: ArchivePasswordVault = .shared, preferencesStore: ArchivePreferencesStore = .shared,
         softwareUpdater: any SoftwareUpdating = SoftwareUpdateController.shared) {
        self.passwordVault = passwordVault
        self.preferencesStore = preferencesStore
        self.softwareUpdater = softwareUpdater
        super.init()
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(store: preferencesStore, softwareUpdater: softwareUpdater)
        }
        preferencesWindowController?.showWindow(sender)
        preferencesWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func showWelcome(_ sender: Any?) {
        if welcomeWindowController == nil {
            welcomeWindowController = WelcomeWindowController(store: preferencesStore,
                createAction: { [weak self] in self?.newArchive(nil) },
                canCreate: { [weak self] in self.map { $0.archiveCreationTask == nil && $0.creationOpenPanel == nil } ?? false },
                createDropAction: { [weak self] sources, parent in
                    guard let self, self.creationOpenPanel == nil else { return }
                    self.startArchiveCreation(sources: sources, on: parent)
                })
        }
        welcomeWindowController?.showWindow(sender)
        welcomeWindowController?.window?.makeKeyAndOrderFront(sender)
    }

    nonisolated static func shouldShowWelcome(argumentsHadFiles: Bool, hasDocuments: Bool, preference: Bool) -> Bool {
        !argumentsHadFiles && !hasDocuments && preference
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        showWelcome(sender)
        return false
    }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/shunnag/KaitoFinder")!)
    }

    @objc func toggleHiddenFiles(_ sender: Any?) { preferencesStore.preferences.showsHiddenFiles.toggle() }

    @objc func checkForUpdates(_ sender: Any?) { softwareUpdater.checkForUpdates() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(checkForUpdates(_:)):
            return softwareUpdater.canCheckForUpdates
        case #selector(newArchive(_:)):
            return archiveCreationTask == nil && creationOpenPanel == nil
        case #selector(extractArchivesFromMenu(_:)):
            return batchExtractionTask == nil && batchExtractionOpenPanel == nil
        case #selector(forgetArchivePasswords(_:)):
            return forgetPasswordsTask == nil
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = preferencesStore.preferences.showsHiddenFiles ? .on : .off
        default: break
        }
        return true
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
        // 最初の instance が shared になるため、NSApplication やメニューの生成より先に置く。
        let documentController = ArchiveDocumentController()
        precondition(NSDocumentController.shared === documentController)
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime((delegate, documentController)) {
            application.run()
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.raiseFileDescriptorLimit()
        startLaunchSweeps()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(volumeDidMount(_:)),
            name: NSWorkspace.didMountNotification, object: nil)
        documentController = NSDocumentController.shared
        NSApp.servicesProvider = self
        NSApp.mainMenu = makeMenu()
    }

    nonisolated static func raiseFileDescriptorLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            NSLog("RLIMIT_NOFILE の取得に失敗しました: %d", errno)
            return
        }
        // 分割巻は reader ごとに fd を持つ。既に十分高い上限は下げない。
        let target = min(limit.rlim_max, rlim_t(OPEN_MAX))
        guard limit.rlim_cur < target else { return }
        limit.rlim_cur = target
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            NSLog("RLIMIT_NOFILE の引き上げに失敗しました: %d", errno)
        }
    }

    @discardableResult func startLaunchSweeps() -> Task<Void, Never> {
        let extractionSweep = ExtractionTemporaryDirectory().startLaunchSweep()
        guard sweepsPendingWorkAtLaunch else { return extractionSweep }
        let pending = pendingWorkRegistry.startLaunchSweep(), index = recoverableWorkIndex, staging = stagingRegistry
        return Task { @MainActor in
            await VolumePublishRecoveryQueue.shared.recover(index: index)
            let recovered = await Task.detached(priority: .utility) {
                do { return try staging.sweep() }
                catch { NSLog("保存前の退避領域を回収できません: %@", String(describing: error)); return [URL]() }
            }.value
            await pending.value
            await extractionSweep.value
            if !recovered.isEmpty {
                let alert = NSAlert()
                alert.messageText = String(localized: "未保存の項目をゴミ箱に移動しました")
                alert.informativeText = String(localized: "前回保存されなかった退避フォルダ\(recovered.count)個をゴミ箱に移動しました。")
                alert.addButton(withTitle: String(localized: "閉じる"))
                alert.addButton(withTitle: String(localized: "Finderで表示"))
                if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting(recovered) }
            }
        }
    }

    @objc private func volumeDidMount(_ notification: Notification) {
        guard sweepsPendingWorkAtLaunch, let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        let index = recoverableWorkIndex
        VolumePublishRecoveryQueue.shared.schedule(index: index, mountedVolume: volume)
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let documents = terminationDocuments?()
            ?? NSDocumentController.shared.documents.compactMap { $0 as? ArchiveDocument }
        let promises = terminationPromiseRegistry
        let busy = documents.contains(where: \.hasWorkInFlight) || archiveCreationTask != nil
            || (batchExtractionTask != nil && batchExtractionController?.destinationPanel == nil)
            || promises.hasActiveWrites || volumePublishCriticalSection.count > 0
        if busy, !(quitConfirmation ?? Self.confirmQuit)() { return .terminateCancel }
        let needsCleanup = busy || documents.contains(where: \.needsTerminationCleanup) || cleanupRegistry.hasPendingCleanup
        if !needsCleanup, volumePublishCriticalSection.closeIfIdle() { return .terminateNow }

        archiveCreationTask?.cancel()
        batchExtractionTask?.cancel()
        promises.cancelActiveWrites()
        let creation = archiveCreationTask, batch = batchExtractionTask
        terminationReplied = false
        terminationAwaitingCriticalSection = false
        if let criticalSectionObserver { volumePublishCriticalSection.removeObserver(criticalSectionObserver) }
        criticalSectionObserver = volumePublishCriticalSection.observeZero { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.terminationAwaitingCriticalSection else { return }
                self.finishTermination()
            }
        }
        // Task group は取消しに反応しない後始末も暗黙に待つため、独立した Task で上限を設ける。
        terminationTask = Task { @MainActor [weak self] in
            for document in documents { await document.prepareForTermination() }
            await creation?.value
            await batch?.value
            await promises.waitUntilNoActiveWrites()
            await self?.cleanupRegistry.waitUntilEmpty()
            self?.finishTermination()
        }
        terminationDeadline = Task { @MainActor [weak self, grace = terminationGracePeriod] in
            try? await Task.sleep(for: grace)
            self?.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard !terminationReplied else { return }
        // 10 秒の期限でも、gate を退役させた公開を途中で打ち切らない。
        guard volumePublishCriticalSection.closeIfIdle() else {
            terminationAwaitingCriticalSection = true
            return
        }
        terminationAwaitingCriticalSection = false
        terminationReplied = true
        if let criticalSectionObserver {
            volumePublishCriticalSection.removeObserver(criticalSectionObserver)
            self.criticalSectionObserver = nil
        }
        terminationDeadline?.cancel()
        (terminationReply ?? { NSApp.reply(toApplicationShouldTerminate: $0) })(true)
    }

    @MainActor static func confirmQuit() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "KaitoFinderを終了してもよろしいですか？")
        alert.informativeText = ArchiveAlertText.informativeText(VolumePublishCriticalSection.shared.count > 0
            ? String(localized: "分割アーカイブを書き込み中です。書き込みが完了してから終了します。その他の進行中の操作は取り消されます。")
            : String(localized: "操作が進行中です。終了すると進行中の展開や変更は取り消され、途中まで書き出した項目は削除されます。"))
        alert.addButton(withTitle: String(localized: "終了"))
        alert.addButton(withTitle: String(localized: "キャンセル")).keyEquivalent = "\u{1b}"
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

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
        uniqueFileURLs(from: pasteboard)
    }

    private static func uniqueFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var seen = Set<String>()
        return urls.filter { url in
            url.isFileURL && seen.insert(url.standardizedFileURL.resolvingSymlinksInPath().path).inserted
        }
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

    private func startArchiveCreation(sources: [URL], on parent: NSWindow? = nil) {
        guard !sources.isEmpty, archiveCreationTask == nil else { return }
        archiveCreationTask = Task {
            defer { archiveCreationTask = nil }
            do { try await ArchiveCreationController(store: preferencesStore).createAndOpen(sources: sources, on: parent) }
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
        uniqueFileURLs(from: pasteboard)
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
        softwareUpdater.start()
        let hadFiles = openLaunchArguments(Array(CommandLine.arguments.dropFirst())) { NSApp.presentError($0) }
        // LaunchServices の起動時 open が文書を登録する機会を待ってから判断する。
        DispatchQueue.main.async { [weak self] in
            guard let self, Self.shouldShowWelcome(argumentsHadFiles: hadFiles,
                hasDocuments: !NSDocumentController.shared.documents.isEmpty,
                preference: self.preferencesStore.preferences.showsWelcomeWindowAtLaunch) else { return }
            self.showWelcome(nil)
        }
    }

    func openLaunchArguments(_ arguments: [String], present: (NSError) -> Void) -> Bool {
        var argumentsHadFiles = false
        for argument in arguments where !argument.hasPrefix("-") {
            let url = URL(fileURLWithPath: argument)
            guard FileManager.default.fileExists(atPath: url.path) else {
                present(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError,
                                userInfo: [NSFilePathErrorKey: url.path, NSURLErrorKey: url]))
                continue
            }
            argumentsHadFiles = true
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        return argumentsHadFiles
    }

    private func makeRecentDocumentsMenu(bundle: Bundle) -> NSMenu {
        // タイトルと「メニューを消去」だけでは履歴メニューとして認識されない。
        // Xcode 標準の recentDocuments 接続を nib から読み込み、履歴の更新・再オープンを
        // NSDocumentController に任せる。リソースの所在と言語選択の bundle は分ける。
        var objects: NSArray?
        guard let nib = NSNib(nibNamed: "RecentDocumentsMenu", bundle: Bundle(for: AppDelegate.self)),
              nib.instantiate(withOwner: nil, topLevelObjects: &objects),
              let menu = objects?.compactMap({ $0 as? NSMenu }).first,
              let clear = menu.items.first(where: { $0.action == #selector(NSDocumentController.clearRecentDocuments(_:)) }) else {
            preconditionFailure("RecentDocumentsMenu.nib is missing or invalid")
        }
        menu.title = String(localized: "最近使った項目を開く", bundle: bundle)
        clear.title = String(localized: "メニューを消去", bundle: bundle)
        return menu
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
        let updates = appMenu.addItem(withTitle: String(localized: "アップデートを確認…", bundle: bundle),
                                     action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updates.target = self
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
        recent.submenu = makeRecentDocumentsMenu(bundle: bundle)
        fileMenu.addItem(withTitle: String(localized: "開く", bundle: bundle),
                         action: #selector(ArchiveWindowController.openEntry(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: String(localized: "クイックルック", bundle: bundle),
                         action: #selector(ArchiveWindowController.togglePreviewPanel(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: String(localized: "閉じる", bundle: bundle),
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: String(localized: "保存", bundle: bundle),
                         action: #selector(ArchiveDocument.saveArchiveDocument(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: String(localized: "別名で保存…", bundle: bundle),
                                      action: #selector(ArchiveWindowController.saveArchiveAs(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: String(localized: "最後に保存した状態に戻す", bundle: bundle),
                         action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: String(localized: "パスワードを設定…", bundle: bundle),
                         action: #selector(ArchiveWindowController.setArchivePassword(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: String(localized: "パスワードを変更…", bundle: bundle),
                         action: #selector(ArchiveWindowController.changeArchivePassword(_:)), keyEquivalent: "")
        fileMenu.addItem(withTitle: String(localized: "パスワードを削除", bundle: bundle),
                         action: #selector(ArchiveWindowController.removeArchivePassword(_:)), keyEquivalent: "")
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
        let viewMenu = NSMenu(title: String(localized: "表示", bundle: bundle))
        let preview = viewMenu.addItem(withTitle: String(localized: "プレビューを表示", bundle: bundle),
                                      action: #selector(ArchiveWindowController.togglePreviewSidebar(_:)), keyEquivalent: "p")
        preview.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(.separator())
        let hidden = viewMenu.addItem(withTitle: String(localized: "隠しファイルを表示", bundle: bundle),
                                      action: #selector(toggleHiddenFiles(_:)), keyEquivalent: ".")
        hidden.keyEquivalentModifierMask = [.command, .shift]
        hidden.target = self
        hidden.state = preferencesStore.preferences.showsHiddenFiles ? .on : .off
        let windowMenu = NSMenu(title: String(localized: "ウインドウ", bundle: bundle))
        let welcome = windowMenu.addItem(withTitle: String(localized: "ようこそKaitoFinderへ", bundle: bundle),
                                        action: #selector(showWelcome(_:)), keyEquivalent: "1")
        welcome.keyEquivalentModifierMask = [.command, .shift]
        welcome.target = self
        windowMenu.addItem(.separator())
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
        ArchiveMenuSymbols.apply(to: fileMenu)
        ArchiveMenuSymbols.apply(to: editMenu)
        ArchiveMenuSymbols.apply(to: viewMenu)
        for submenu in [appMenu, fileMenu, editMenu, viewMenu, windowMenu, helpMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
        return menu
    }
}
