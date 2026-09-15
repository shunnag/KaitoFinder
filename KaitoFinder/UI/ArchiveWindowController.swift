import AppKit
import UniformTypeIdentifiers
import QuickLookUI

// NSPathControlItem は representedObject を持たず、SDK はサブクラス化も認めていない。
// URL を書庫内パスに偽装せず、表示中の node 自体を項目に結び付ける。
@MainActor extension NSPathControlItem {
    private static var representedObjectKey: UInt8 = 0

    var representedObject: Any? {
        get { objc_getAssociatedObject(self, &Self.representedObjectKey) }
        set { objc_setAssociatedObject(self, &Self.representedObjectKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// Finderの項目数表記を、表示の更新と文字列テストで共有する。
nonisolated enum ArchiveStatusBarText {
    static func text(totalCount: Int, totalSize: UInt64?, filteredCount: Int? = nil,
                     selectedCount: Int = 0, selectedSize: UInt64? = nil, bundle: Bundle = .main,
                     locale: Locale = .current) -> String {
        func size(_ bytes: UInt64?) -> String {
            guard let bytes, let signed = Int64(exactly: bytes) else { return String(localized: "—", bundle: bundle) }
            return ByteCountFormatter.string(fromByteCount: signed, countStyle: .file)
        }
        if selectedCount > 0 {
            // 選択数とサイズの引数番号を、すべての言語で揃える。
            return String(format: String(localized: "%1$lld項目を選択中(%3$@)", bundle: bundle),
                          locale: locale, Int64(selectedCount), Int64(filteredCount ?? totalCount), size(selectedSize))
        }
        // 数値の挿入にもロケールを渡し、件数の桁区切りをFinderと揃える。
        if let filteredCount {
            return String(format: String(localized: "%lld/%lld項目", bundle: bundle), locale: locale,
                          Int64(filteredCount), Int64(totalCount))
        }
        return String(format: String(localized: "%lld項目、%@", bundle: bundle), locale: locale,
                      Int64(totalCount), size(totalSize))
    }
}

final class ArchiveWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuItemValidation, NSMenuDelegate, NSToolbarDelegate, NSToolbarItemValidation,
    QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let bundle: Bundle
    private var archiveSession: ArchiveSession?
    private var generation: UInt64 = 0
    private let promiseOwner = UUID()
    private(set) var draggedNodes: [EntryNode] = []
    private(set) var extractionTask: Task<Void, Never>?
    // 展開先の選択を差し替え、解決済みの対象をパネルなしで検証できるようにする。
    var extractionDestinationHandler: (([EntryNode]) -> Void)?
    private var extractionProgress: Progress?
    private var extractionCancellation: Task<Void, Never>?
    private(set) var extractionSheet: ExtractionProgressSheet?
    private let passwordPresenter = ArchivePasswordPresenter()
    var passwordPrompt: ArchivePasswordPrompt? { passwordPresenter.prompt }
    private(set) var unlockTask: Task<Void, Never>?
    let unlockButton: NSButton
    let lockedPlaceholder = NSView()
    private var isLocked = false
    let statusBar = NSTextField(wrappingLabelWithString: "")
    private(set) var deletionConfirmation: NSAlert?
    private(set) var conversionConfirmation: NSAlert?
    private(set) var creationController: ArchiveCreationController?
    private(set) var editProgressSheet: ExtractionProgressSheet?
    let capabilityNotice = NSTextField(wrappingLabelWithString: "")
    private let renameValidationNotice = NSTextField(wrappingLabelWithString: "")
    let outlineView = ArchiveOutlineView()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: NSToolbarItem.Identifier("search"))
    var searchField: NSSearchField { searchItem.searchField }
    let pathControl = NSPathControl()
    private(set) var thumbnailProvider: ArchiveThumbnailProvider?
    private(set) var filterQuery = ""
    private var entryFilter: EntryTreeFilter?
    private var unfilteredViewState: ArchiveViewState?
    private var materialization: ArchiveMaterializationController?
    private weak var previewPanel: QLPreviewPanel?
    private var previewMonitor: Task<Void, Never>?
    private var previewActive = false
    private var materializationSheet: ExtractionProgressSheet?
    private var materializationCancellation: Task<Void, Never>?
    private let openWithMenu: NSMenu
    private var root = EntryNode.tree(from: [])
    private var parents: [ObjectIdentifier: EntryNode] = [:]
    private var sortedChildren: [ObjectIdentifier: [EntryNode]] = [:]
    private var restoringSort = false
    private var icons: [UTType: NSImage] = [:]
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        unlockButton = NSButton(title: String(localized: "ロックを解除…", bundle: bundle), target: nil, action: nil)
        openWithMenu = NSMenu(title: String(localized: "このアプリケーションで開く", bundle: bundle))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 600, height: 300)
        window.center()
        window.setFrameAutosaveName("ArchiveWindow")
        window.delegate = self
        window.tabbingIdentifier = "KaitoFinder.archive"
        window.tabbingMode = .automatic
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        outlineView.style = .fullWidth
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.rowSizeStyle = .default
        let columns: [(String, String, CGFloat)] = [
            ("name", String(localized: "名前", bundle: bundle), 300),
            ("size", String(localized: "サイズ", bundle: bundle), 110),
            ("compressedSize", String(localized: "圧縮サイズ", bundle: bundle), 110),
            ("date", String(localized: "変更日", bundle: bundle), 180),
            ("kind", String(localized: "種類", bundle: bundle), 140),
            ("method", String(localized: "圧縮方式", bundle: bundle), 100),
            ("encrypted", String(localized: "暗号化", bundle: bundle), 80)
        ]
        for (key, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = width
            column.minWidth = 60
            column.resizingMask = [.userResizingMask]
            column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
            outlineView.addTableColumn(column)
            if key == "name" { outlineView.outlineTableColumn = column }
        }
        outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        outlineView.autosaveName = "ArchiveColumns"
        outlineView.autosaveTableColumns = true
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickEntry(_:))
        outlineView.previewSelection = { [weak self] in self?.togglePreviewPanel(nil) }
        outlineView.deleteSelection = { [weak self] in self?.deleteEntries(nil) }
        outlineView.renameSelection = { [weak self] in self?.renameEntry(nil) }
        outlineView.renameValidationChanged = { [weak self] reason in
            self?.renameValidationNotice.stringValue = reason ?? ""
            self?.renameValidationNotice.isHidden = reason == nil
        }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "開く", bundle: bundle),
                     action: #selector(openEntry(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "クイックルック", bundle: bundle),
                     action: #selector(togglePreviewPanel(_:)), keyEquivalent: "")
        let openWith = menu.addItem(withTitle: openWithMenu.title, action: #selector(openWithEntry(_:)), keyEquivalent: "")
        openWith.submenu = openWithMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "新規フォルダ", bundle: bundle), action: #selector(newFolder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "削除", bundle: bundle), action: #selector(deleteEntries(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "名称変更", bundle: bundle), action: #selector(renameEntry(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        openWithMenu.delegate = self
        outlineView.menu = menu
        let blankAreaMenu = outlineView.blankAreaMenu
        blankAreaMenu.addItem(withTitle: String(localized: "新規フォルダ", bundle: bundle), action: #selector(newFolder(_:)), keyEquivalent: "")
        blankAreaMenu.addItem(withTitle: String(localized: "ペースト", bundle: bundle), action: #selector(paste(_:)), keyEquivalent: "")
        blankAreaMenu.addItem(.separator())
        blankAreaMenu.addItem(withTitle: String(localized: "すべて展開…", bundle: bundle), action: #selector(extractAll(_:)), keyEquivalent: "")
        blankAreaMenu.addItem(.separator())
        blankAreaMenu.addItem(withTitle: String(localized: "新規アーカイブ…", bundle: bundle), action: #selector(AppDelegate.newArchive(_:)), keyEquivalent: "")
        blankAreaMenu.addItem(withTitle: String(localized: "アーカイブをFinderに表示", bundle: bundle), action: #selector(revealArchiveInFinder(_:)), keyEquivalent: "")
        for item in blankAreaMenu.items where !item.isSeparatorItem && item.action != #selector(AppDelegate.newArchive(_:)) {
            item.target = self
        }
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outlineView.registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL])
        scrollView.documentView = outlineView
        unlockButton.target = self
        unlockButton.action = #selector(unlockArchive(_:))
        unlockButton.bezelStyle = .rounded
        lockedPlaceholder.identifier = NSUserInterfaceItemIdentifier("archive.locked-placeholder")
        lockedPlaceholder.isHidden = true
        let lock = NSImageView()
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 56, weight: .regular))
        lock.contentTintColor = .secondaryLabelColor
        lock.imageScaling = .scaleProportionallyDown
        // SF Symbolsの整列余白をスタックの外へ出さず、画像全体をこの領域に収める。
        let symbolView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        lock.frame = symbolView.bounds
        lock.autoresizingMask = [.width, .height]
        symbolView.addSubview(lock)
        let title = NSTextField(wrappingLabelWithString: String(localized: "このアーカイブはロックされています", bundle: bundle))
        title.font = NSFontManager.shared.convert(.preferredFont(forTextStyle: .title2), toHaveTrait: .boldFontMask)
        title.alignment = .center
        let subtitle = NSTextField(wrappingLabelWithString: String(localized: "パスワードを入力すると内容を表示できます。", bundle: bundle))
        subtitle.font = .preferredFont(forTextStyle: .body)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        let placeholderStack = NSStackView(views: [symbolView, title, subtitle, unlockButton])
        placeholderStack.orientation = .vertical
        placeholderStack.alignment = .centerX
        placeholderStack.spacing = 12
        placeholderStack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        placeholderStack.translatesAutoresizingMaskIntoConstraints = false
        lockedPlaceholder.addSubview(placeholderStack)
        for label in [title, subtitle] {
            label.preferredMaxLayoutWidth = 420
            label.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 80),
            symbolView.heightAnchor.constraint(equalToConstant: 80),
            placeholderStack.widthAnchor.constraint(equalToConstant: 428),
            placeholderStack.centerXAnchor.constraint(equalTo: lockedPlaceholder.centerXAnchor),
            placeholderStack.centerYAnchor.constraint(equalTo: lockedPlaceholder.centerYAnchor)
        ])
        let footer = NSStackView(views: [renameValidationNotice, capabilityNotice])
        footer.identifier = NSUserInterfaceItemIdentifier("archive.footer")
        footer.orientation = .vertical
        footer.alignment = .leading
        // ラベルの整列用余白もスタックの表示領域に収める。
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        capabilityNotice.identifier = NSUserInterfaceItemIdentifier("archive.capability-notice")
        capabilityNotice.textColor = .secondaryLabelColor
        capabilityNotice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        capabilityNotice.isHidden = true
        renameValidationNotice.textColor = .systemRed
        renameValidationNotice.isHidden = true
        let content = NSView()
        searchItem.label = String(localized: "検索", bundle: bundle)
        searchItem.paletteLabel = searchItem.label
        searchItem.toolTip = searchItem.label
        searchItem.isBordered = true
        searchItem.target = self
        searchField.placeholderString = String(localized: "検索", bundle: bundle)
        searchField.setAccessibilityLabel(String(localized: "検索", bundle: bundle))
        searchField.target = self
        searchField.action = #selector(filterEntries(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        let toolbar = NSToolbar(identifier: "ArchiveToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.action = #selector(selectClickedPathItem(_:))
        statusBar.identifier = NSUserInterfaceItemIdentifier("archive.status")
        statusBar.alignment = .center
        statusBar.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusBar.textColor = .secondaryLabelColor
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        lockedPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        content.addSubview(lockedPlaceholder)
        content.addSubview(footer)
        content.addSubview(statusBar)
        content.addSubview(pathControl)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: pathControl.topAnchor),
            pathControl.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pathControl.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pathControl.heightAnchor.constraint(equalToConstant: 22),
            pathControl.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -6),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            lockedPlaceholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            lockedPlaceholder.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            lockedPlaceholder.topAnchor.constraint(equalTo: scrollView.topAnchor),
            lockedPlaceholder.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { nil }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("extract"), NSToolbarItem.Identifier("addFiles"), NSToolbarItem.Identifier("newFolder"),
         NSToolbarItem.Identifier("delete"), NSToolbarItem.Identifier("quickLook"), .flexibleSpace, searchItem.itemIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == searchItem.itemIdentifier { return searchItem }
        let label: String, symbol: String, action: Selector
        switch itemIdentifier.rawValue {
        case "extract":
            label = String(localized: "展開", bundle: bundle)
            symbol = "square.and.arrow.up"
            action = #selector(extractFromToolbar(_:))
        case "addFiles":
            label = String(localized: "追加…", bundle: bundle)
            symbol = "plus"
            action = #selector(addFiles(_:))
        case "newFolder":
            label = String(localized: "新規フォルダ", bundle: bundle)
            symbol = "folder.badge.plus"
            action = #selector(newFolder(_:))
        case "delete":
            label = String(localized: "削除", bundle: bundle)
            symbol = "trash"
            action = #selector(deleteEntries(_:))
        case "quickLook":
            label = String(localized: "クイックルック", bundle: bundle)
            symbol = "eye"
            action = #selector(togglePreviewPanel(_:))
        default: return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard !isLocked else { return false }
        let menuItem = NSMenuItem(title: item.label, action: item.action, keyEquivalent: "")
        let enabled = validateMenuItem(menuItem)
        item.toolTip = menuItem.toolTip ?? item.label
        return enabled
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if (document as? ArchiveDocument)?.isPasswordLocked == true { unlockArchive(sender) }
    }

    func displayLocked() {
        display(EntryNode.tree(from: []))
        pathControl.pathItems = []
        isLocked = true
        lockedPlaceholder.isHidden = false
        outlineView.enclosingScrollView?.isHidden = true
        statusBar.isHidden = true
        searchField.isEnabled = false
        searchItem.isEnabled = false
        unlockButton.keyEquivalent = "\r"
        window?.defaultButtonCell = unlockButton.cell as? NSButtonCell
        window?.toolbar?.validateVisibleItems()
    }

    @objc func unlockArchive(_ sender: Any?) {
        guard let document = document as? ArchiveDocument, document.isPasswordLocked, unlockTask == nil else { return }
        unlockButton.isEnabled = false
        unlockTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.unlockTask = nil
                self.unlockButton.isEnabled = true
            }
            var challenge = ArchivePasswordChallenge.required
            do {
                if try await document.unlockUsingRememberedPassword() { return }
            } catch {
                if !(error is CancellationError), !Task.isCancelled { self.reportFailure(String(describing: error)) }
                return
            }
            while !Task.isCancelled {
                do {
                    let generation = await document.passwordVault.generation()
                    let response = try await self.requestPasswordResponse(challenge)
                    try await document.unlock(password: response.password, remember: response.remember,
                                              vaultGeneration: generation)
                    return
                } catch {
                    if error is CancellationError || Task.isCancelled { return }
                    if let next = ArchivePasswordChallenge(error) { challenge = next }
                    else { self.reportFailure(String(describing: error)); return }
                }
            }
        }
    }

    // 同期 PasswordProvider には UI を渡さない。worker が await する間だけ sheet を持ち、
    // 複数の promise は同じ入力を待つ。取消しは要求ごとに continuation を回収する。
    func requestPassword(_ challenge: ArchivePasswordChallenge) async throws -> String {
        try await requestPasswordResponse(challenge).password
    }

    private func requestPasswordResponse(_ challenge: ArchivePasswordChallenge) async throws -> ArchivePasswordResponse {
        guard let window else { throw CancellationError() }
        return try await passwordPresenter.response(to: challenge, on: window, bundle: bundle, nextResponder: self,
            willPresent: { [weak self] in
                // 親ウインドウに進捗と入力の二枚を積まない。入力後は同じ進捗を再開する。
                self?.materializationSheet?.finish()
                self?.extractionSheet?.finish()
            }, didAccept: { [weak self] in
                guard let self, let window = self.window else { return }
                for sheet in [self.materializationSheet, self.extractionSheet].compactMap({ $0 }) where !sheet.progress.isCancelled {
                    sheet.begin(on: window)
                }
            })
    }

    private func watchCancellation(_ progress: Progress, cancel: @escaping () -> Void) -> Task<Void, Never> {
        Task {
            // 既存の進捗 UI は Progress を取り消す。入力待ちと検証の Task にも取消しを届ける。
            while !Task.isCancelled {
                if progress.isCancelled { cancel(); return }
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
            }
        }
    }

    func display(_ root: EntryNode, session: ArchiveSession? = nil, generation: UInt64 = 0,
                 materializationController: ArchiveMaterializationController? = nil) {
        let state = captureViewState()
        thumbnailProvider?.cancelAll()
        thumbnailProvider = nil
        outlineView.cancelRenaming()
        closePreview()
        let nextMaterialization = session.map { session in
            materializationController ?? (document as? ArchiveDocument)?.materializationController()
                ?? ArchiveMaterializationController(session: session)
        }
        if materialization !== nextMaterialization { materialization?.close() }
        archiveSession = session
        isLocked = false
        lockedPlaceholder.isHidden = true
        outlineView.enclosingScrollView?.isHidden = false
        statusBar.isHidden = false
        searchField.isEnabled = true
        searchItem.isEnabled = true
        unlockButton.keyEquivalent = ""
        window?.defaultButtonCell = nil
        self.generation = generation
        self.root = root
        parents.removeAll()
        var pending = [root]
        while let parent = pending.popLast() {
            for child in parent.children { parents[ObjectIdentifier(child)] = parent }
            pending.append(contentsOf: parent.children)
        }
        capabilityNotice.stringValue = session?.capabilities.readOnlyReason ?? session?.capabilities.rewriteNotice ?? ""
        capabilityNotice.isHidden = capabilityNotice.stringValue.isEmpty
        if let session, let controller = nextMaterialization {
            session.setPasswordPrompt { [weak self, weak session] challenge in
                guard let self, let session, self.archiveSession === session else { throw CancellationError() }
                guard let document = self.document as? ArchiveDocument else {
                    return try await self.requestPassword(challenge)
                }
                return try await document.password(for: session, challenge: challenge) {
                    try await self.requestPasswordResponse(challenge)
                }
            }
            controller.started = { [weak self, weak controller] item, progress in
                guard let self else { return }
                self.materializationCancellation = self.watchCancellation(progress) { [weak controller] in controller?.cancel() }
                guard item.requiresProgress, let window = self.window else { return }
                let sheet = ExtractionProgressSheet(progress: progress, detail: item.payload.path, bundle: bundle)
                // 進捗シートが key window になっても、QL の responder chain を文書へ戻す。
                sheet.nextResponder = self
                self.materializationSheet = sheet
                sheet.begin(on: window)
            }
            controller.finished = { [weak self] in
                self?.materializationCancellation?.cancel()
                self?.materializationCancellation = nil
                self?.materializationSheet?.finish()
                self?.materializationSheet = nil
            }
            controller.failed = { [weak self] reason in self?.reportFailure(reason) }
            materialization = controller
            if let worker = controller.entryMaterializer {
                let provider = ArchiveThumbnailProvider(materializer: worker, session: session, generation: generation)
                provider.didProduce = { [weak self, weak provider] node in
                    guard let self, let provider, self.thumbnailProvider === provider else { return }
                    let row = self.outlineView.row(forItem: node)
                    let column = self.outlineView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
                    guard row >= 0, column >= 0 else { return }
                    self.outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
                }
                controller.cancelBackgroundWorkOnClose { [weak provider] in provider?.cancelAll() }
                thumbnailProvider = provider
            }
        } else { materialization = nil }
        reloadFilteredEntries(restoring: state)
        updatePathControl()
        window?.toolbar?.validateVisibleItems()
    }

    var selectedNodes: [EntryNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? EntryNode }
    }

    private func pathNodes(to node: EntryNode) -> [EntryNode] {
        var components: [EntryNode] = []
        var current = node
        while current !== root {
            guard let parent = parents[ObjectIdentifier(current)] else { return [] }
            components.append(current)
            current = parent
        }
        return components.reversed()
    }

    private func updatePathControl() {
        updateStatusBar()
        let archive = NSPathControlItem()
        if let url = (document as? ArchiveDocument)?.fileURL ?? archiveSession?.sourceURL {
            archive.title = url.lastPathComponent
            archive.image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            archive.title = String(localized: "アーカイブ", bundle: bundle)
            archive.image = NSWorkspace.shared.icon(for: .archive)
        }
        let components = selectedNodes.first.map(pathNodes(to:)) ?? []
        pathControl.pathItems = [archive] + components.map { node in
            let item = NSPathControlItem()
            item.title = node.name
            item.representedObject = node
            item.image = icon(for: node)
            return item
        }
    }

    private func updateStatusBar() {
        var nodes: [EntryNode] = [], pending = root.children
        while let node = pending.popLast() {
            nodes.append(node)
            pending.append(contentsOf: node.children)
        }
        let selected = selectedNodes
        let selectedIDs = Set(selected.map(ObjectIdentifier.init))
        // 親と子を同時に選択しても、展開後のサイズは二重に加算しない。
        let selectedRoots = selected.filter { node in
            var ancestor = parents[ObjectIdentifier(node)]
            while let parent = ancestor {
                if selectedIDs.contains(ObjectIdentifier(parent)) { return false }
                ancestor = parents[ObjectIdentifier(parent)]
            }
            return true
        }
        var size: UInt64? = 0
        for node in selectedRoots {
            guard let total = size, let bytes = node.size else { size = nil; break }
            let sum = total.addingReportingOverflow(bytes)
            size = sum.overflow ? nil : sum.partialValue
        }
        statusBar.stringValue = ArchiveStatusBarText.text(totalCount: nodes.count, totalSize: root.size,
            filteredCount: filterQuery.isEmpty ? nil : nodes.filter { entryFilter?.contains($0) != false }.count,
            selectedCount: selected.count, selectedSize: size, bundle: bundle)
    }

    @objc private func selectClickedPathItem(_ sender: NSPathControl) {
        if let item = sender.clickedPathItem { selectPathItem(item) }
    }

    func selectPathItem(_ item: NSPathControlItem) {
        guard let node = item.representedObject as? EntryNode else {
            outlineView.deselectAll(nil)
            return
        }
        let components = pathNodes(to: node)
        guard !components.isEmpty else { return }
        for ancestor in components.dropLast() { outlineView.expandItem(ancestor) }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    @objc func filterEntries(_ sender: NSSearchField) { setFilterQuery(sender.stringValue) }

    func setFilterQuery(_ query: String) {
        guard query != filterQuery else { return }
        // 未確定の不正な名前を reload で捨てない。ソートと同じ確定規則を使う。
        guard outlineView.commitRenaming() else { searchField.stringValue = filterQuery; return }
        let state = captureViewState()
        if filterQuery.isEmpty { unfilteredViewState = state }
        filterQuery = query
        searchField.stringValue = query
        let restored = query.isEmpty ? (unfilteredViewState ?? state) : state
        if query.isEmpty { unfilteredViewState = nil }
        closePreview()
        reloadFilteredEntries(restoring: restored)
    }

    private func reloadFilteredEntries(restoring state: ArchiveViewState) {
        entryFilter = EntryTreeFilter(root: root, query: filterQuery)
        sortedChildren.removeAll()
        outlineView.reloadData()
        // 同じ node を使う reload は展開状態を保持するため、検索中の自動展開も明示的に戻す。
        outlineView.collapseItem(nil, collapseChildren: true)
        if !filterQuery.isEmpty { outlineView.expandItem(nil, expandChildren: true) }
        restoreViewState(state)
    }

    private func payloads(for nodes: [EntryNode], session: ArchiveSession) -> [ArchiveEntryPayload] {
        // 選択された親フォルダが子も運ぶので、子の URL を重ねない。
        let selected = Set(nodes.map(ObjectIdentifier.init))
        let roots = nodes.filter { node in
            var parent = outlineView.parent(forItem: node) as? EntryNode
            while let ancestor = parent {
                if selected.contains(ObjectIdentifier(ancestor)) { return false }
                parent = outlineView.parent(forItem: ancestor) as? EntryNode
            }
            return true
        }
        return ArchiveEntryPayload.payloads(for: roots, archiveURL: session.sourceURL, generation: generation)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? EntryNode, let session = archiveSession else { return nil }
        do {
            let promise = try FilePromiseRegistry.shared.register(
                payload: ArchiveEntryPayload(node: node, archiveURL: session.sourceURL, generation: generation), session: session, owner: promiseOwner)
            return promise.provider
        } catch {
            NSLog("ドラッグ項目を作成できません: %@", String(describing: error))
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        draggedNodes = draggedItems as? [EntryNode] ?? []
        FilePromiseRegistry.shared.beganPending(sessionID: session.draggingSequenceNumber, owner: promiseOwner)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedNodes = []
        FilePromiseRegistry.shared.ended(sessionID: session.draggingSequenceNumber)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newFolder(_:)):
            menuItem.toolTip = editRefusal
            return archiveSession != nil && document is ArchiveDocument && editRefusal == nil && !outlineView.isRenaming
        case #selector(deleteEntries(_:)), #selector(renameEntry(_:)):
            menuItem.toolTip = editRefusal
            let count = selectedNodes.count
            return archiveSession != nil && document is ArchiveDocument && editRefusal == nil
                && !outlineView.isRenaming && count > 0
                && (menuItem.action != #selector(renameEntry(_:)) || count == 1)
        case #selector(paste(_:)):
            menuItem.toolTip = archiveSession?.capabilities.readOnlyReason
            return archiveSession != nil && !operationInFlight
                && ArchiveIncomingPasteboard.canPaste(AppKitArchivePasteboard(pasteboard: .general))
        case #selector(addFiles(_:)):
            menuItem.toolTip = archiveSession?.capabilities.readOnlyReason
            return archiveSession != nil && !operationInFlight
        case #selector(openEntry(_:)), #selector(openWithEntry(_:)), #selector(togglePreviewPanel(_:)):
            let items = previewItems()
            let reason = items.first(where: { !$0.capability.canOpen })?.capability.reason
            menuItem.toolTip = reason
            return !items.isEmpty && reason == nil && extractionTask == nil
        case #selector(copy(_:)), #selector(extractSelected(_:)):
            return archiveSession != nil && !selectedNodes.isEmpty && extractionTask == nil
        case #selector(extractAll(_:)), #selector(extractFromToolbar(_:)):
            return archiveSession != nil && !root.children.isEmpty && extractionTask == nil
        case #selector(revealArchiveInFinder(_:)):
            return archiveURL != nil
        default: return true
        }
    }

    var operationInFlight: Bool {
        extractionTask != nil || deletionConfirmation != nil || conversionConfirmation != nil || passwordPrompt != nil || unlockTask != nil
            || (document?.undoManager as? ArchiveUndoManager)?.isSuspended == true
    }

    private var editRefusal: String? {
        // モデルと同じ ZIP updater の門番を使う。canDelete / canRename は未使用の予約値。
        if let session = archiveSession, !session.capabilities.canAppend {
            return session.capabilities.readOnlyReason ?? String(localized: "このアーカイブは変更できません。", bundle: bundle)
        }
        return operationInFlight ? String(localized: "別の操作が完了するまでお待ちください。", bundle: bundle) : nil
    }

    private func canPerformEdit(_ action: Selector) -> Bool {
        validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    private var archiveURL: URL? { (document as? ArchiveDocument)?.fileURL ?? archiveSession?.sourceURL }

    @objc func revealArchiveInFinder(_ sender: Any?) {
        guard let url = archiveURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func newFolder(_ sender: Any?) {
        guard canPerformEdit(#selector(newFolder(_:))), let document = document as? ArchiveDocument,
              let window else { return }
        // 現在のフォルダはまだないため、先頭の選択から作成先を求める。ナビゲーション導入時に見直す。
        let folder = ArchiveDropTarget.folder(for: selectedNodes.first.map(ArchiveDropTarget.Row.init))
        closePreview()
        materialization?.cancel()
        let progress = Progress(totalUnitCount: 0)
        extractionProgress = progress
        let sheet = ExtractionProgressSheet(progress: progress, title: ArchiveProgressOperation.creatingFolder.title(bundle: bundle), bundle: bundle)
        editProgressSheet = sheet
        sheet.begin(on: window)
        extractionTask = Task { [weak self] in
            var createdPath: String?
            defer {
                sheet.finish()
                self?.editProgressSheet = nil
                self?.extractionProgress = nil
                self?.extractionTask = nil
                if !Task.isCancelled, let createdPath { self?.renameCreatedFolder(at: createdPath) }
            }
            do {
                let result = try await document.createFolder(in: folder, progress: progress)
                if let reason = result.reloadFailure {
                    sheet.finish()
                    self?.reportEditFailure(reason, published: true)
                } else { createdPath = result.addedPaths.first.map { String($0.dropLast()) } }
            } catch {
                sheet.finish()
                if !(error is CancellationError), !Task.isCancelled, let self {
                    self.reportEditFailure(self.editFailureReason(error))
                }
            }
        }
    }

    private func renameCreatedFolder(at path: String) {
        let target = ArchiveViewState(selectedPaths: [path], expandedPaths: [], topPath: nil).resolve(in: root).selected.first
        guard let target else { return }
        // 新しい名前が検索に一致しなくても、作成した場所で直ちに改名できるようにする。
        if entryFilter?.contains(target) == false { setFilterQuery("") }
        var state = captureViewState()
        state.selectedPaths = [path]
        let parents = path.split(separator: "/").dropLast()
        for count in 1..<(parents.count + 1) {
            state.expandedPaths.insert(parents.prefix(count).joined(separator: "/"))
        }
        restoreViewState(state)
        renameEntry(nil)
    }

    @objc func deleteEntries(_ sender: Any?) {
        guard canPerformEdit(#selector(deleteEntries(_:))), let document = document as? ArchiveDocument,
              let window else { return }
        let nodes = selectedNodes
        let state = viewStateAfterRemoving(nodes)
        if document.canUndoNextMutation {
            startEdit(nodes, name: nil, state: state)
            return
        }
        let expectedGeneration = generation
        let alert = Self.makeDeletionConfirmation(bundle: bundle)
        deletionConfirmation = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.deletionConfirmation === alert else { return }
            self.deletionConfirmation = nil
            guard response == .alertFirstButtonReturn, self.generation == expectedGeneration,
                  self.archiveSession?.generation == expectedGeneration else { return }
            self.startEdit(nodes, name: nil, state: state)
        }
    }

    static func makeDeletionConfirmation(bundle: Bundle = .main) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "選択した項目を削除しますか？", bundle: bundle)
        alert.informativeText = String(localized: "この削除は取り消せません。", bundle: bundle)
        alert.addButton(withTitle: String(localized: "削除", bundle: bundle))
        alert.addButton(withTitle: String(localized: "キャンセル", bundle: bundle))
        return alert
    }

    @objc func renameEntry(_ sender: Any?) {
        guard canPerformEdit(#selector(renameEntry(_:))), let node = selectedNodes.first else { return }
        closePreview()
        let expectedGeneration = generation
        // 純粋なプラン構築で、仮想フォルダとの衝突や子孫のパス長も commit 前に検査する。
        let entries = ExtractionSelection(nodes: [root]).entries
        let selection = ArchiveEditSelection(node)
        outlineView.beginRenaming(node, validate: { [weak self, bundle] name in
            guard let self else { return String(localized: "アーカイブが閉じられています。", bundle: bundle) }
            if let reason = self.editRefusal { return reason }
            guard self.generation == expectedGeneration, self.archiveSession?.generation == expectedGeneration else {
                return String(localized: "選択した項目が変更されています。アーカイブを開き直してください。", bundle: bundle)
            }
            do {
                _ = try ArchiveEditPlan.build(removing: [], renaming: [.init(selection: selection, name: name)], existing: entries)
                return nil
            } catch { return self.editFailureReason(error) }
        }, commit: { [weak self] name in
            guard let self, self.generation == expectedGeneration,
                  self.archiveSession?.generation == expectedGeneration else { return }
            if node.name.utf8.elementsEqual(name.utf8) { return }
            self.startEdit([node], name: name, state: self.viewStateAfterRenaming(node, to: name))
        })
    }

    private func startEdit(_ nodes: [EntryNode], name: String?, state: ArchiveViewState) {
        guard let window, let document = document as? ArchiveDocument,
              archiveSession?.capabilities.canAppend == true, !operationInFlight else { return }
        closePreview()
        materialization?.cancel()
        let progress = Progress(totalUnitCount: 0)
        extractionProgress = progress
        let sheet = ExtractionProgressSheet(progress: progress, title: name == nil
            ? ArchiveProgressOperation.deleting.title(bundle: bundle) : ArchiveProgressOperation.renaming.title(bundle: bundle),
            detail: nodes.count == 1 ? nodes[0].name : "", bundle: bundle)
        editProgressSheet = sheet
        sheet.begin(on: window)
        extractionTask = Task { [weak self] in
            defer {
                sheet.finish()
                self?.editProgressSheet = nil
                self?.extractionProgress = nil
                self?.extractionTask = nil
            }
            do {
                let result: ArchiveEditResult
                if let name, let node = nodes.first {
                    result = try await document.rename(node, to: name, progress: progress)
                } else {
                    result = try await document.remove(nodes, progress: progress)
                }
                if result.published { self?.restoreViewState(state) }
                if let reason = result.reloadFailure {
                    sheet.finish()
                    self?.reportEditFailure(reason, published: true)
                }
            } catch {
                sheet.finish()
                if !(error is CancellationError), !Task.isCancelled, let self {
                    self.reportEditFailure(self.editFailureReason(error))
                }
            }
        }
    }

    private func startMove(nodes: [EntryNode], to folder: String) -> Bool {
        guard let window, let document = document as? ArchiveDocument, !nodes.isEmpty,
              archiveSession?.capabilities.canAppend == true, !operationInFlight else { return false }
        let state = viewStateAfterMoving(nodes, to: folder)
        closePreview()
        materialization?.cancel()
        let progress = Progress(totalUnitCount: 0)
        extractionProgress = progress
        let sheet = ExtractionProgressSheet(progress: progress, title: ArchiveProgressOperation.moving.title(bundle: bundle),
            detail: nodes.count == 1 ? nodes[0].name : "", bundle: bundle)
        editProgressSheet = sheet
        sheet.begin(on: window)
        extractionTask = Task { [weak self] in
            defer {
                sheet.finish()
                self?.editProgressSheet = nil
                self?.extractionProgress = nil
                self?.extractionTask = nil
            }
            do {
                let result = try await document.move(nodes, to: folder, progress: progress)
                if result.published, let self {
                    // 親の名前だけが検索に一致していた場合も、移動した項目を選択できるようにする。
                    if state.resolve(in: self.root).selected.contains(where: { self.entryFilter?.contains($0) == false }) {
                        self.setFilterQuery("")
                    }
                    self.restoreViewState(state)
                }
                if let reason = result.reloadFailure {
                    sheet.finish()
                    self?.reportEditFailure(reason, published: true)
                }
            } catch {
                sheet.finish()
                if !(error is CancellationError), !Task.isCancelled, let self {
                    self.reportEditFailure(self.editFailureReason(error))
                }
            }
        }
        return true
    }

    private func editFailureReason(_ error: any Error) -> String {
        switch error as? ArchiveEditError {
        case .archiveChanged:
            String(localized: "アーカイブが変更されています。開き直してください。", bundle: bundle)
        case .collision:
            String(localized: "同じ名前の項目が既にあります。別の名前を入力してください。", bundle: bundle)
        case .invalidName:
            String(localized: "この名前は使えません。空の名前、予約文字、長すぎる名前を避けてください。", bundle: bundle)
        case .staleSelection:
            String(localized: "選択した項目が変更されています。アーカイブを開き直してください。", bundle: bundle)
        case .indexMismatch:
            String(localized: "選択した項目とアーカイブ内の項目が一致しません。アーカイブを開き直してください。", bundle: bundle)
        case .conflictingSelection:
            String(localized: "同じ項目への変更が重複しています。", bundle: bundle)
        case .sameLocation:
            String(localized: "同じ場所です。", bundle: bundle)
        case .destinationInsideSource:
            String(localized: "フォルダを自分自身の中へは移動できません。", bundle: bundle)
        case .missingFolder:
            String(localized: "移動先のフォルダが見つかりません。", bundle: bundle)
        case nil: error.localizedDescription
        }
    }

    private func reportEditFailure(_ reason: String, published: Bool = false) {
        guard let window else { return }
        let alert = Self.makeEditFailureAlert(reason, published: published, bundle: bundle)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    static func makeEditFailureAlert(_ reason: String, published: Bool = false, bundle: Bundle = .main) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = published ? String(localized: "項目を変更しましたが、アーカイブを読み直せませんでした", bundle: bundle)
            : String(localized: "項目を変更できませんでした", bundle: bundle)
        alert.informativeText = ArchiveAlertText.informativeText(reason, bundle: bundle)
        return alert
    }

    private func viewStateAfterRemoving(_ nodes: [EntryNode]) -> ArchiveViewState {
        var state = captureViewState()
        let removed = Set(ExtractionSelection(nodes: nodes).entries.map(\.index))
        func survives(_ node: EntryNode) -> Bool {
            ExtractionSelection(nodes: [node]).entries.contains { !removed.contains($0.index) }
        }
        state.selectedPaths = []
        var anchor = nodes.first
        while let node = anchor {
            let parent = outlineView.parent(forItem: node) as? EntryNode
            let siblings = children(of: parent)
            if let index = siblings.firstIndex(where: { $0 === node }) {
                let candidates = Array(siblings.dropFirst(index + 1)) + siblings.prefix(index).reversed()
                if let next = candidates.first(where: survives) {
                    state.selectedPaths = [next.path]
                    break
                }
            }
            if let parent, survives(parent) {
                state.selectedPaths = [parent.path]
                break
            }
            // 最後の子を消した仮想フォルダも消えるため、存在する祖先まで辿る。
            anchor = parent
        }
        return state
    }

    private func viewStateAfterRenaming(_ node: EntryNode, to name: String) -> ArchiveViewState {
        var state = captureViewState()
        let parent = node.path.split(separator: "/").dropLast().joined(separator: "/")
        let path = (parent.isEmpty ? name : parent + "/" + name).precomposedStringWithCanonicalMapping
        func renamed(_ old: String) -> String {
            if old == node.path { return path }
            if old.hasPrefix(node.path + "/") { return path + old.dropFirst(node.path.count) }
            return old
        }
        state.selectedPaths = [path]
        state.expandedPaths = Set(state.expandedPaths.map(renamed))
        state.topPath = state.topPath.map(renamed)
        return state
    }

    private func viewStateAfterMoving(_ nodes: [EntryNode], to folder: String) -> ArchiveViewState {
        var state = captureViewState()
        let moves = nodes.map { node in
            (source: node.path, destination: (folder.isEmpty ? node.name : folder + "/" + node.name)
                .precomposedStringWithCanonicalMapping)
        }
        func moved(_ old: String) -> String {
            for move in moves {
                if old == move.source { return move.destination }
                if old.hasPrefix(move.source + "/") { return move.destination + old.dropFirst(move.source.count) }
            }
            return old
        }
        state.selectedPaths = Set(moves.map(\.destination))
        state.expandedPaths = Set(state.expandedPaths.map(moved))
        state.topPath = state.topPath.map(moved)
        let parts = folder.split(separator: "/")
        for count in 1..<(parts.count + 1) {
            state.expandedPaths.insert(parts.prefix(count).joined(separator: "/"))
        }
        return state
    }

    private func captureViewState() -> ArchiveViewState {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        let top = visible.location < outlineView.numberOfRows ? outlineView.item(atRow: visible.location) as? EntryNode : nil
        var expanded = Set<String>()
        var pending = root.children
        while let node = pending.popLast() {
            if node.isDirectory, outlineView.isItemExpanded(node) { expanded.insert(node.path) }
            pending.append(contentsOf: node.children)
        }
        return ArchiveViewState(selectedPaths: Set(selectedNodes.map(\.path)), expandedPaths: expanded, topPath: top?.path)
    }

    private func restoreViewState(_ state: ArchiveViewState) {
        let resolved = state.resolve(in: root)
        for node in resolved.expanded where entryFilter?.contains(node) != false { outlineView.expandItem(node) }
        outlineView.selectRowIndexes(IndexSet(resolved.selected.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 }), byExtendingSelection: false)
        if let top = resolved.top {
            let row = outlineView.row(forItem: top)
            if row >= 0 { outlineView.scroll(NSPoint(x: 0, y: outlineView.rect(ofRow: row).minY)) }
        }
        // 行番号の集合が同じでも、ソート後は先頭の選択項目が変わり得る。
        updatePathControl()
    }

    // 現在は書庫 root を表示する outline。選択と表示フォルダは混同しない。
    private var displayedFolder: String { root.path }

    @objc func paste(_ sender: Any?) {
        guard archiveSession != nil, !operationInFlight else { return }
        startImport(urls: ArchiveIncomingPasteboard.readPaste(AppKitArchivePasteboard(pasteboard: .general)), incoming: nil, folder: displayedFolder)
    }

    @objc func addFiles(_ sender: Any?) {
        guard archiveSession != nil, !operationInFlight, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "追加", bundle: bundle)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            self.startImport(urls: panel.urls, incoming: nil, folder: self.displayedFolder)
        }
    }

    private func dropFolder(_ item: Any?) -> String {
        ArchiveDropTarget.folder(for: (item as? EntryNode).map(ArchiveDropTarget.Row.init))
    }

    // AppKit に返す操作とハイライト先を一緒に決める。別ウインドウは従来の promise copy。
    private func dropDecision(isLocal: Bool, draggedNodes: [EntryNode], hovered: EntryNode?, mask: NSDragOperation,
                              hasFiles: Bool) -> (operation: NSDragOperation, folder: EntryNode?) {
        guard let session = archiveSession else { return ([], nil) }
        if isLocal {
            switch ArchiveDropTarget.localOperation(dragged: draggedNodes.map(ArchiveDropTarget.Row.init),
                target: ArchiveDropTarget.folder(for: hovered.map(ArchiveDropTarget.Row.init)), mask: mask,
                capabilities: session.capabilities, busy: operationInFlight) {
            case .move: return (.move, ArchiveDropTarget.node(for: hovered, in: root))
            case .copy: break
            case .none: return ([], nil)
            }
        }
        guard ArchiveDropTarget.accepts(capabilities: session.capabilities, offersCopy: mask.contains(.copy),
                                        hasFiles: hasFiles, busy: operationInFlight) else { return ([], nil) }
        return (.copy, session.capabilities.canAppend ? ArchiveDropTarget.node(for: hovered, in: root) : nil)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let row = outlineView.row(at: outlineView.convert(info.draggingLocation, from: nil))
        let hovered = row >= 0 ? outlineView.item(atRow: row) as? EntryNode : nil
        let decision = dropDecision(isLocal: (info.draggingSource as AnyObject?) === outlineView,
            draggedNodes: draggedNodes, hovered: hovered, mask: info.draggingSourceOperationMask,
            hasFiles: ArchiveIncomingPasteboard.representation(AppKitArchivePasteboard(pasteboard: info.draggingPasteboard)) != .none)
        guard !decision.operation.isEmpty else { return [] }
        outlineView.setDropItem(decision.folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return decision.operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let session = archiveSession, !operationInFlight else { return false }
        if (info.draggingSource as AnyObject?) === outlineView {
            let folder = dropFolder(item)
            switch ArchiveDropTarget.localOperation(dragged: draggedNodes.map(ArchiveDropTarget.Row.init),
                target: folder, mask: info.draggingSourceOperationMask, capabilities: session.capabilities, busy: operationInFlight) {
            case .move: return startMove(nodes: draggedNodes, to: folder)
            case .copy: break
            case .none: return false
            }
        }
        guard info.draggingSourceOperationMask.contains(.copy) else { return false }
        let pasteboard = info.draggingPasteboard
        do {
            switch ArchiveIncomingPasteboard.readDrop(AppKitArchivePasteboard(pasteboard: pasteboard)) {
            case .promises(let receivers):
                guard !receivers.isEmpty else { return false }
                let incoming = try ArchiveIncomingFiles(receivers: receivers)
                startImport(urls: [], incoming: incoming, folder: dropFolder(item))
            case .fileURLs(let urls):
                guard !urls.isEmpty else { return false }
                startImport(urls: urls, incoming: nil, folder: dropFolder(item))
            case .none: return false
            }
            return true
        } catch { reportImportFailure(String(describing: error)); return false }
    }

    private func startImport(urls: [URL], incoming: ArchiveIncomingFiles?, folder: String) {
        guard let window, let session = archiveSession, !operationInFlight,
              incoming != nil || !urls.isEmpty else { return }
        if !session.capabilities.canAppend {
            offerConversion(urls: urls, incoming: incoming, session: session)
            return
        }
        guard let document = document as? ArchiveDocument else { return }
        closePreview()
        materialization?.cancel()
        let progress = Progress(totalUnitCount: 0)
        extractionProgress = progress
        let sheet = ExtractionProgressSheet(progress: progress, title: ArchiveProgressOperation.adding.title(bundle: bundle),
            detail: urls.count == 1 ? urls[0].lastPathComponent : "", bundle: bundle)
        sheet.begin(on: window)
        extractionTask = Task { [weak self] in
            do {
                let sources: [URL]
                if let incoming { sources = try await incoming.receive(progress: progress) }
                else { sources = urls }
                let result = try await document.append(urls: sources, to: folder, progress: progress)
                // 非同期の圧縮が完了するまで、受信ファイルを保持する。
                withExtendedLifetime(incoming) {}
                sheet.finish()
                if let reason = result.reloadFailure {
                    self?.reportImportFailure(reason, added: true)
                } else if !result.failures.isEmpty {
                    self?.reportImportFailure(result.failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n"))
                }
            } catch {
                sheet.finish()
                if !(error is CancellationError) { self?.reportImportFailure(String(describing: error)) }
            }
            self?.extractionTask = nil
            self?.extractionProgress = nil
        }
    }

    private func offerConversion(urls: [URL], incoming: ArchiveIncomingFiles?, session: ArchiveSession) {
        guard let window else { return }
        closePreview()
        materialization?.cancel()
        let expectedGeneration = generation
        let alert = ArchiveConversionNotice.makeAlert(formatName: ArchiveConversionNotice.formatName(for: session),
            entries: ExtractionSelection(nodes: [root]).entries, bundle: bundle)
        conversionConfirmation = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.conversionConfirmation === alert else { return }
            self.conversionConfirmation = nil
            guard response == .alertFirstButtonReturn, self.archiveSession === session,
                  self.generation == expectedGeneration, session.generation == expectedGeneration else { return }
            self.startConversion(urls: urls, incoming: incoming, session: session)
        }
    }

    private func startConversion(urls: [URL], incoming: ArchiveIncomingFiles?, session: ArchiveSession) {
        guard let window, !operationInFlight else { return }
        let progress = Progress(totalUnitCount: 0)
        extractionProgress = progress
        let creator = ArchiveCreationController()
        creationController = creator
        extractionTask = Task { [weak self] in
            defer {
                // 保存先の入力中も、作成が完了するまで受信済みのファイルを消さない。
                withExtendedLifetime(incoming) {}
                self?.creationController = nil
                self?.extractionTask = nil
                self?.extractionProgress = nil
                self?.extractionCancellation?.cancel()
                self?.extractionCancellation = nil
            }
            do {
                // パスワードの入力と全 entry の検証を、保存パネルや圧縮の前に済ませる。
                let password = try await session.preparedPassword()
                let snapshot = await session.snapshot()
                try ArchiveImportPlan.checkCancellation(progress)
                let sources: [URL]
                if let incoming { sources = try await incoming.receive(progress: progress) }
                else { sources = urls }
                let existing = ArchiveCreationPlan.Existing(url: session.sourceURL, password: password, entries: snapshot.entries)
                try await creator.createAndOpen(sources: sources, existing: existing, on: window, progress: progress)
            } catch {
                if !(error is CancellationError), !Task.isCancelled { ArchiveCreationController.presentFailure(error) }
            }
        }
        extractionCancellation = watchCancellation(progress) { [weak self] in self?.extractionTask?.cancel() }
    }

    private func reportImportFailure(_ reason: String, added: Bool = false) {
        guard let window else { return }
        let alert = Self.makeImportFailureAlert(reason, added: added, bundle: bundle)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    static func makeImportFailureAlert(_ reason: String, added: Bool = false, bundle: Bundle = .main) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = added ? String(localized: "項目を追加しましたが、アーカイブを読み直せませんでした", bundle: bundle)
            : String(localized: "項目を追加できませんでした", bundle: bundle)
        alert.informativeText = ArchiveAlertText.informativeText(reason, bundle: bundle)
        return alert
    }

    @objc func copy(_ sender: Any?) {
        guard let session = archiveSession, extractionTask == nil, !selectedNodes.isEmpty else { return }
        let nodes = selectedNodes
        let items = payloads(for: nodes, session: session)
        let selection = ExtractionSelection(nodes: nodes)
        startExtraction(items, session: session, destination: nil,
                        showProgress: ArchiveCopyOut.requiresProgress(selection), entryCount: selection.entries.count)
    }

    @objc func extractSelected(_ sender: Any?) { chooseDestination(for: selectedNodes) }
    @objc func extractAll(_ sender: Any?) { chooseDestination(for: root.children) }

    @objc func extractFromToolbar(_ sender: Any?) {
        if selectedNodes.isEmpty { extractAll(sender) }
        else { extractSelected(sender) }
    }

    private func chooseDestination(for nodes: [EntryNode]) {
        guard let session = archiveSession, let window, extractionTask == nil, !nodes.isEmpty else { return }
        if let extractionDestinationHandler { extractionDestinationHandler(nodes); return }
        let items = payloads(for: nodes, session: session)
        let entryCount = ExtractionSelection(nodes: nodes).entries.count
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "展開", bundle: bundle)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.startExtraction(items, session: session, destination: destination, showProgress: true, entryCount: entryCount)
        }
    }

    func startExtraction(_ items: [ArchiveEntryPayload], session: ArchiveSession,
                                 destination: URL?, showProgress: Bool, entryCount: Int,
                                 didWrite: (@Sendable (Int) -> Void)? = nil) {
        guard let window, extractionTask == nil else { return }
        let progress = Progress(totalUnitCount: Int64(entryCount))
        extractionProgress = progress
        let sheet = showProgress ? ExtractionProgressSheet(progress: progress,
            title: ArchiveProgressOperation.expandingArchive(session.sourceURL.lastPathComponent).title(bundle: bundle),
            detail: items.count == 1 ? items[0].path : "", bundle: bundle) : nil
        extractionSheet = sheet
        sheet?.begin(on: window)
        // シートの表示後に worker を起動する。小さい copy も UI actor で stream を読まない。
        extractionTask = Task { [weak self] in
            do {
                if let destination {
                    let result = try await ExtractionService.extract(items, from: session, to: destination,
                                                                     progress: progress, didWrite: didWrite)
                    try ArchiveCopyOut.check(result)
                } else {
                    _ = try await ArchiveCopyOut.copy(items, from: session, to: .general, progress: progress)
                }
                sheet?.finish()
            } catch {
                sheet?.finish()
                if !(error is CancellationError), !Task.isCancelled {
                    self?.reportFailure(String(describing: error))
                }
            }
            self?.extractionTask = nil
            self?.extractionProgress = nil
            self?.extractionSheet = nil
            self?.extractionCancellation?.cancel()
            self?.extractionCancellation = nil
        }
        extractionCancellation = watchCancellation(progress) { [weak self] in self?.extractionTask?.cancel() }
    }

    func cancelExtraction() {
        thumbnailProvider?.cancelAll()
        outlineView.cancelRenaming()
        unlockTask?.cancel()
        passwordPresenter.cancel()
        if let alert = deletionConfirmation {
            deletionConfirmation = nil
            window?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        }
        if let alert = conversionConfirmation {
            conversionConfirmation = nil
            window?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        }
        closePreview()
        materialization?.close()
        extractionProgress?.cancel()
        extractionTask?.cancel()
        extractionSheet?.finish()
        creationController?.savePanel?.panel.cancel(nil)
        creationController?.progressSheet?.finish()
    }

    private func reportFailure(_ reason: String) {
        guard let window else { return }
        let alert = Self.makeFailureAlert(reason, bundle: bundle)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    static func makeFailureAlert(_ reason: String, bundle: Bundle = .main) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "項目を展開できませんでした", bundle: bundle)
        alert.informativeText = ArchiveAlertText.informativeText(reason, bundle: bundle)
        return alert
    }

    private func previewItems() -> [ArchivePreviewItem] {
        guard let session = archiveSession else { return [] }
        return selectedNodes.map { node in
            let payload = ArchiveEntryPayload(node: node, archiveURL: session.sourceURL, generation: generation)
            if let cached = materialization?.cachedItem(for: payload) { return cached }
            return ArchivePreviewItem(payload: payload,
                capability: EntryReadCapability(entry: node.entry, isDirectory: node.isDirectory, format: session.format),
                requiresProgress: ArchiveCopyOut.requiresProgress(ExtractionSelection(entries: node.entry.map { [$0] } ?? [])))
        }
    }

    private func readableSelection() -> [ArchivePreviewItem]? {
        let items = previewItems()
        guard !items.isEmpty, extractionTask == nil else { return nil }
        if let item = items.first(where: { !$0.capability.canOpen }), let reason = item.capability.reason {
            reportFailure("\(item.payload.path): \(reason)")
            return nil
        }
        return items
    }

    @objc func doubleClickEntry(_ sender: Any?) {
        guard outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? EntryNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) }
            else { outlineView.expandItem(node) }
        } else {
            outlineView.selectRowIndexes(IndexSet(integer: outlineView.clickedRow), byExtendingSelection: false)
            openEntry(sender)
        }
    }

    @objc func openEntry(_ sender: Any?) { openSelection(application: nil) }

    @objc func openWithEntry(_ sender: Any?) {
        guard let application = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        openSelection(application: application)
    }

    private func openSelection(application: URL?) {
        guard let items = readableSelection(), let materialization else { return }
        closePreview()
        materialization.setSelection(items)
        openNext(index: 0, application: application)
    }

    private func openNext(index: Int, application: URL?) {
        guard let materialization, materialization.item(at: index) != nil else { return }
        materialization.display(index: index) { [weak self] item in
            guard let self, let url = item.previewItemURL else { return }
            if let application {
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { [weak self] _, error in
                    if let error {
                        let reason = String(describing: error)
                        Task { @MainActor [weak self] in self?.reportFailure(reason) }
                    }
                }
            } else if let type = UTType(filenameExtension: url.pathExtension),
                      ArchiveBatchExtractionController.archiveContentTypes().contains(where: { type.conforms(to: $0) }) {
                // 書庫内の書庫は同じアプリで開き、一時コピーの変更不可理由を表示する。
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
                    if let error { self?.reportFailure(error.localizedDescription) }
                }
            } else if !NSWorkspace.shared.open(url) {
                self.reportFailure(String(localized: "この項目を開くアプリケーションが見つからないか、起動できませんでした。", bundle: self.bundle))
            }
            self.openNext(index: index + 1, application: application)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openWithMenu else { return }
        menu.removeAllItems()
        guard let items = readableSelection(), let item = items.first, let materialization else { return }
        // URL による handler 照会には実体が必要。サブメニューを要求した時だけ一項目を作る。
        let loading = menu.addItem(withTitle: String(localized: "アプリケーションを調べています…", bundle: bundle), action: nil, keyEquivalent: "")
        loading.isEnabled = false
        closePreview()
        materialization.setSelection([item])
        materialization.display(index: 0) { [weak self, weak menu] item in
            guard let self, let menu, let url = item.previewItemURL else { return }
            menu.removeAllItems()
            let applications = NSWorkspace.shared.urlsForApplications(toOpen: url)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for application in applications {
                let action = menu.addItem(withTitle: FileManager.default.displayName(atPath: application.path),
                    action: #selector(self.openWithEntry(_:)), keyEquivalent: "")
                action.target = self
                action.representedObject = application
            }
            if applications.isEmpty {
                menu.addItem(withTitle: String(localized: "対応するアプリケーションが見つかりません", bundle: self.bundle), action: nil, keyEquivalent: "")
            }
        }
    }

    @objc func togglePreviewPanel(_ sender: Any?) {
        if let panel = previewPanel, panel.isVisible { closePreview(); return }
        guard let items = readableSelection() else { return }
        if let first = items.first, first.capability.needsUnlocking, first.previewItemURL == nil, let materialization {
            // 解除を取り消した時に空の QL パネルを残さない。準備完了後に responder を渡す。
            materialization.setSelection(items)
            materialization.display(index: 0) { [weak self] _ in self?.showPreviewPanel(nil) }
        } else { showPreviewPanel(sender) }
    }

    private func showPreviewPanel(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(sender)
        panel.updateController()
        if previewPanel === panel { updatePreviewSelection(reportingFailures: true); startPreviewMonitoring(panel) }
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        // SDK の NSObject カテゴリには隔離注釈がない。AppKit の responder 呼出しは main thread。
        MainActor.assumeIsolated { archiveSession != nil && materialization != nil }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { takePreviewControl(panel) }
    }

    private func takePreviewControl(_ panel: QLPreviewPanel) {
        previewPanel = panel
        panel.dataSource = self
        panel.delegate = self
        updatePreviewSelection()
        startPreviewMonitoring(panel)
    }

    private func startPreviewMonitoring(_ panel: QLPreviewPanel) {
        previewMonitor?.cancel()
        // QLPreviewPanel に index 変更の delegate はない。先読み要求の index は採用せず、
        // 公開プロパティを監視する。orderOut による終了も拾い、KVO 通知の有無に依存しない。
        previewMonitor = Task { [weak self, weak panel] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, let panel, self.previewPanel === panel else { return }
                if panel.isVisible { self.synchronizePreview(panel) }
                else {
                    self.previewActive = false
                    self.materialization?.cancel()
                    return
                }
            }
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { releasePreviewControl(panel) }
    }

    private func releasePreviewControl(_ panel: QLPreviewPanel) {
        guard previewPanel === panel else { return }
        previewMonitor?.cancel()
        previewMonitor = nil
        if previewActive { materialization?.setSelection([]) }
        previewActive = false
        panel.dataSource = nil
        panel.delegate = nil
        previewPanel = nil
    }

    private func closePreview() {
        previewActive = false
        previewMonitor?.cancel()
        previewMonitor = nil
        materialization?.cancel()
        if let panel = previewPanel { panel.orderOut(nil) }
    }

    private func updatePreviewSelection(reportingFailures: Bool = false) {
        guard let panel = previewPanel else { return }
        previewActive = true
        materialization?.updatePreviewSelection(previewItems(), reportingFailures: reportingFailures)
        panel.reloadData()
        if materialization?.items.isEmpty == false { panel.currentPreviewItemIndex = 0 }
        synchronizePreview(panel)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updatePathControl()
        materialization?.cancel()
        if previewPanel?.isVisible == true { updatePreviewSelection() }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { materialization?.items.count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // QL は選択全体を先読みできる。この照会の index で抽出してはいけない。
        Task { @MainActor [weak self, weak panel] in
            guard let self, let panel, self.previewPanel === panel else { return }
            self.synchronizePreview(panel)
        }
        return materialization?.item(at: index)
    }

    private func synchronizePreview(_ panel: QLPreviewPanel) {
        guard previewActive, previewPanel === panel, panel.isVisible, panel.currentController as AnyObject? === self else { return }
        let index = panel.currentPreviewItemIndex
        guard materialization?.currentIndex != index else { return }
        materialization?.display(index: index) { [weak self, weak panel] item in
            guard let self, let panel, self.previewActive, self.previewPanel === panel, panel.isVisible,
                  panel.currentController as AnyObject? === self,
                  panel.currentPreviewItemIndex == index,
                  self.materialization?.item(at: index) === item else { return }
            QLPreviewPanel.shared().refreshCurrentPreviewItem()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow, closingWindow === window { cancelExtraction() }
        if let panel = notification.object as? QLPreviewPanel, previewPanel === panel { materialization?.close() }
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.charactersIgnoringModifiers == " " { closePreview(); return true }
        return false
    }

    private func children(of item: Any?) -> [EntryNode] {
        let node = (item as? EntryNode) ?? root
        let id = ObjectIdentifier(node)
        if let cached = sortedChildren[id] { return cached }
        let children = (entryFilter?.children(of: node) ?? node.children).sorted { lhs, rhs in
            for descriptor in outlineView.sortDescriptors {
                let result = compare(lhs, rhs, key: descriptor.key ?? "name")
                if result != .orderedSame {
                    return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
                }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        sortedChildren[id] = children
        return children
    }

    private func compare(_ lhs: EntryNode, _ rhs: EntryNode, key: String) -> ComparisonResult {
        switch key {
        case "size": return compareOptional(lhs.size, rhs.size)
        case "compressedSize": return compareOptional(lhs.compressedSize, rhs.compressedSize)
        case "date": return compareOptional(lhs.entry?.modificationDate, rhs.entry?.modificationDate)
        case "encrypted": return compareOptional(lhs.entry.map { $0.isEncrypted ? 1 : 0 }, rhs.entry.map { $0.isEncrypted ? 1 : 0 })
        default: return text(for: lhs, key: key).localizedStandardCompare(text(for: rhs, key: key))
        }
    }

    private func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedAscending
        case (_, nil): return .orderedDescending
        case let (lhs?, rhs?):
            return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
    }

    private func type(for node: EntryNode) -> UTType {
        if node.isDirectory { return .folder }
        if node.entry?.kind == .symlink { return .symbolicLink }
        return UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data
    }

    private func icon(for node: EntryNode) -> NSImage {
        let type = type(for: node)
        if let image = icons[type] { return image }
        let image = NSWorkspace.shared.icon(for: type)
        icons[type] = image
        return image
    }

    private func formattedSize(_ size: UInt64?) -> String {
        guard let size, let signed = Int64(exactly: size) else { return "—" }
        return byteFormatter.string(fromByteCount: signed)
    }

    private func text(for node: EntryNode, key: String) -> String {
        switch key {
        case "name": return node.name
        case "size": return formattedSize(node.size)
        case "compressedSize": return formattedSize(node.compressedSize)
        case "date": return node.entry?.modificationDate.map { dateFormatter.string(from: $0) } ?? "—"
        case "kind":
            if node.isDirectory { return String(localized: "フォルダ", bundle: bundle) }
            if node.entry?.kind == .hardlink { return String(localized: "ハードリンク", bundle: bundle) }
            return type(for: node).localizedDescription ?? String(localized: "書類", bundle: bundle)
        case "method": return node.entry?.methodDescription ?? "—"
        case "encrypted":
            guard let entry = node.entry else { return "—" }
            return entry.isEncrypted ? String(localized: "はい", bundle: bundle) : String(localized: "いいえ", bundle: bundle)
        default: return ""
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? EntryNode)?.isDirectory == true
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !restoringSort else { return }
        // 列ヘッダへのクリックでも確定を試し、不正な入力のまま cell を作り直さない。
        if !self.outlineView.commitRenaming() {
            restoringSort = true
            outlineView.sortDescriptors = oldDescriptors
            restoringSort = false
            return
        }
        let state = captureViewState()
        sortedChildren.removeAll()
        outlineView.reloadData()
        restoreViewState(state)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? EntryNode, let column = tableColumn else { return nil }
        let key = column.identifier.rawValue
        let cell: NSTableCellView
        if let reused = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = column.identifier
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            var leading = cell.leadingAnchor
            var padding: CGFloat = 4
            if key == "name" {
                let icon = NSImageView()
                icon.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(icon)
                cell.imageView = icon
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    icon.widthAnchor.constraint(equalToConstant: 16),
                    icon.heightAnchor.constraint(equalToConstant: 16)
                ])
                leading = icon.trailingAnchor
                padding = 6
            }
            label.alignment = ["size", "compressedSize"].contains(key) ? .right : .left
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leading, constant: padding),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = text(for: node, key: key)
        if key == "name" {
            cell.imageView?.image = thumbnailProvider?.thumbnail(for: node) ?? icon(for: node)
        }
        return cell
    }
}
