import AppKit
import UniformTypeIdentifiers
import QuickLookUI

final class ArchiveWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuItemValidation, NSMenuDelegate, NSToolbarDelegate, NSToolbarItemValidation,
    NSWindowDelegate {
    nonisolated static let frameAutosaveName = "ArchiveWindow"
    nonisolated static let columnsAutosaveName = "ArchiveColumns"
    nonisolated static let toolbarAutosaveName = "ArchiveToolbar"
    static let viewOptionsDidChange = Notification.Name("ArchiveViewOptionsDidChange")
    var canChangeViewOptions: Bool { !isLocked }

    private let bundle: Bundle
    private let preferencesStore: ArchivePreferencesStore
    private var showsHiddenFiles: Bool
    private var requestedShowsHiddenFiles: Bool
    private var keepsFoldersOnTop: Bool
    private var folderOpening: ArchivePreferences.FolderOpening
    private var listIconSize: ArchivePreferences.ListIconSize
    private var listTextSize: Int
    private var displayGeneration: UInt64 = 0
    private var defaultRowHeight: CGFloat = 0
    let kindResolver: ArchiveKindResolver
    // 非表示になったフォルダの展開状態も、再表示まで保持する。
    private var hiddenExpandedPaths: Set<String> = []
    private var hasPositionedWindow = false
    private var archiveSession: ArchiveSession?
    private var generation: UInt64 = 0
    private let renameIndex = ArchiveRenameIndex()
    var renameIndexTask: Task<Void, Never>? { renameIndex.task }
    #if DEBUG
    private(set) var treeDisplayedAt: ContinuousClock.Instant?
    var renameIndexReadyAt: ContinuousClock.Instant? { renameIndex.readyAt }
    #endif
    var renameIndexIsReady: Bool { renameIndex.isPrepared && archiveSession?.generation == generation }
    var renameOccupancy: ArchivePathOccupancy.Overlay? {
        guard listLoading.token == nil, archiveSession?.generation == generation else { return nil }
        return renameIndex.preparedOccupancy ?? root.editOccupancy
    }
    private let listLoading: ArchiveListLoadingIndicator
    #if DEBUG
    var listLoadingTokenForTesting: UUID? { listLoading.token }
    #endif
    var listLoadingIndicator: NSProgressIndicator { listLoading.view }
    var isListLoadingVisible: Bool { listLoading.isVisible }
    private let promiseOwner = UUID()
    private(set) var draggedNodes: [EntryNode] = []
    private(set) var extractionTask: Task<Void, Never>?
    // 展開先の選択を差し替え、解決済みの対象をパネルなしで検証できるようにする。
    var extractionDestinationHandler: (([EntryNode]) -> Void)?
    private var extractionProgress: Progress?
    private var extractionCancellation: ArchiveProgressCancellation?
    private(set) var extractionSheet: ExtractionProgressSheet?
    private let passwordPresenter = ArchivePasswordPresenter()
    private let conflictPresenter = ArchiveConflictPresenter()
    var conflictPrompt: ArchiveConflictPrompt? { conflictPresenter.prompt }
    var passwordPrompt: ArchivePasswordPrompt? { passwordPresenter.prompt }
    private(set) var unlockTask: Task<Void, Never>?
    let lockedPlaceholder: ArchiveLockedPlaceholderView
    var unlockButton: NSButton { lockedPlaceholder.unlockButton }
    private var isLocked = false
    let statusBar = NSTextField(wrappingLabelWithString: "")
    private(set) var deletionConfirmation: NSAlert?
    private(set) var failureAlert: NSAlert?
    private(set) var conversionConfirmation: NSAlert?
    private(set) var creationController: ArchiveCreationController?
    private(set) var passwordEditor: ArchivePasswordEditor?
    private(set) var editProgressSheet: ExtractionProgressSheet?
    let capabilityNotice = NSTextField(wrappingLabelWithString: "")
    private let renameValidationNotice = NSTextField(wrappingLabelWithString: "")
    let outlineView = ArchiveOutlineView()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: ArchiveToolbarItem.search.identifier)
    var searchField: NSSearchField { searchItem.searchField }
    let pathControl = NSPathControl()
    private(set) var thumbnailProvider: ArchiveThumbnailProvider?
    private(set) var filterQuery = ""
    private(set) var requestedFilterQuery = ""
    private var entryFilter: EntryTreeFilter?
    var filterConfiguration: EntryTreeFilter.Configuration { .init(query: requestedFilterQuery, showsHiddenFiles: requestedShowsHiddenFiles) }
    nonisolated static let asyncFilterThreshold = 20_000
    /// 完成した絞り込みを保留しているあいだ、適用できるかを確かめ直す間隔。
    private nonisolated static let filterHoldPollInterval: Duration = .milliseconds(100)
    private enum FilterReason { case query, hiddenFiles }
    private enum FilterDecision { case discard, hold, apply }
    private struct FilterRequest {
        let token: UUID
        let root: EntryNode
        let generation: UInt64
        let configuration: EntryTreeFilter.Configuration
        let reason: FilterReason
        var task: Task<Void, Never>?
        var revealTask: Task<Void, Never>?
    }
    private var filterRequest: FilterRequest?
    var isFilterPendingVisible: Bool { listLoading.isFilterPending }
    #if DEBUG
    nonisolated enum FilterExecution: Sendable { case automatic, synchronous, asynchronous }
    nonisolated static let filterExecution = TaskLocal<FilterExecution>(wrappedValue: .automatic)
    nonisolated enum NavigationEvent: Sendable, Equatable {
        case navigated(from: String, to: String, history: History)
        case fellBack(from: String, to: String)
    }
    nonisolated static let navigationObserver = TaskLocal<(@MainActor @Sendable (NavigationEvent) -> Void)?>(wrappedValue: nil)
    var addFilesPanelForTesting: ((@escaping ([URL]) -> Void) -> Void)?
    private(set) var filterTaskForTesting: Task<Void, Never>?
    private(set) var filterSwapCountForTesting = 0
    private(set) var filterApplyCountForTesting = 0
    private(set) var preparedFilterMissesForTesting = 0
    func setDraggedNodesForTesting(_ nodes: [EntryNode]) { draggedNodes = nodes }
    #endif
    private var unfilteredViewState: ArchiveViewState?
    private var materialization: ArchiveMaterializationController?
    let previewSidebar: ArchivePreviewSidebar
    private let previewSplitController = NSSplitViewController()
    private let previewSplitItem: NSSplitViewItem
    private var previewVisibilityObservation: NSKeyValueObservation?
    var showsPreviewSidebar: Bool { !previewSplitItem.isCollapsed }
    private lazy var quickLook = ArchiveQuickLookCoordinator(
        materialization: { [weak self] in self?.materialization },
        previewItems: { [weak self] in self?.previewItems() ?? [] },
        selection: { [weak self] in self?.readableSelection() },
        controller: { [weak self] in self },
        canPreview: { [weak self] in self?.archiveSession != nil && self?.materialization != nil },
        didBecomeKey: { [weak self] in (self?.document as? ArchiveDocument)?.checkDeferredIdentityWhenKey() })
    private var materializationSheet: ExtractionProgressSheet?
    private let openWithMenu: NSMenu
    private var root: EntryNode
    private var currentFolder: EntryNode
    private var displayedRoot: EntryNode
    private(set) var currentFolderPath = ""
    private var navigationHistory = ArchiveNavigationHistory()
    var backStack: [String] { navigationHistory.backStack }
    var forwardStack: [String] { navigationHistory.forwardStack }
    var folderViewStates: [String: ArchiveViewState] { navigationHistory.folderViewStates }
    typealias History = ArchiveNavigationHistory.Direction
    private var sortedChildren: [ObjectIdentifier: [EntryNode]] = [:]
    private var restoringSort = false
    private var hasShownWindow = false
    private let formatter: ArchiveEntryFormatter

    // MARK: - 初期化

    init(bundle: Bundle = .main, preferencesStore: ArchivePreferencesStore = .shared) {
        self.bundle = bundle
        self.preferencesStore = preferencesStore
        let root = EntryNode.tree(from: [])
        self.root = root
        currentFolder = root
        displayedRoot = root
        folderOpening = preferencesStore.preferences.folderOpening
        listIconSize = preferencesStore.preferences.listIconSize
        listTextSize = preferencesStore.preferences.listTextSize
        let kindResolver = ArchiveKindResolver(bundle: bundle)
        self.kindResolver = kindResolver
        formatter = ArchiveEntryFormatter(bundle: bundle, kindResolver: kindResolver)
        previewSidebar = ArchivePreviewSidebar(bundle: bundle, kindResolver: kindResolver)
        previewSplitItem = NSSplitViewItem(viewController: previewSidebar)
        showsHiddenFiles = preferencesStore.preferences.showsHiddenFiles
        requestedShowsHiddenFiles = preferencesStore.preferences.showsHiddenFiles
        keepsFoldersOnTop = preferencesStore.preferences.keepsFoldersOnTop
        lockedPlaceholder = ArchiveLockedPlaceholderView(bundle: bundle)
        listLoading = ArchiveListLoadingIndicator(bundle: bundle)
        openWithMenu = NSMenu(title: String(localized: "このアプリケーションで開く", bundle: bundle))
        let window = ArchiveDocumentWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        listLoading.didChange = { [weak self] in self?.updateStatusBar() }
        outlineView.permitsInteraction = { [weak self] in self?.operationInFlight != true }
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)),
                                               name: ArchivePreferencesStore.didChange, object: preferencesStore)
        window.minSize = NSSize(width: 600, height: 300)
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.delegate = self
        window.autorecalculatesKeyViewLoop = true
        window.initialFirstResponder = outlineView
        window.tabbingIdentifier = "KaitoFinder.archive"
        window.tabbingMode = .automatic
        window.tab.accessoryView = ArchiveTabSpringLoading(window: window)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = true
        outlineView.style = .fullWidth
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.columnAutoresizingStyle = .noColumnAutoresizing
        outlineView.rowSizeStyle = .default
        defaultRowHeight = outlineView.rowHeight
        applyListSizing()
        configureColumns()
        let columnsMenu = NSMenu(title: String(localized: "列", bundle: bundle))
        columnsMenu.delegate = self
        outlineView.headerView?.menu = columnsMenu
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickEntry(_:))
        outlineView.previewSelection = { [weak self] in self?.togglePreviewPanel(nil) }
        outlineView.deleteSelection = { [weak self] in self?.deleteEntries(nil) }
        outlineView.renameSelection = { [weak self] in self?.renameEntry(nil) }
        outlineView.openSelection = { [weak self] in self?.openEntry(nil) }
        outlineView.selectEnclosingFolder = { [weak self] in self?.goToEnclosingFolder(nil) }
        outlineView.renamesOnClick = preferencesStore.preferences.renamesOnClick
        outlineView.renameValidationChanged = { [weak self] reason in
            self?.renameValidationNotice.stringValue = reason ?? ""
            self?.renameValidationNotice.isHidden = reason == nil
        }
        configureEntryContextMenus()
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outlineView.registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL])
        scrollView.documentView = outlineView
        unlockButton.target = self
        unlockButton.action = #selector(unlockArchive(_:))
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
        searchItem.label = ArchiveToolbarItem.search.label(bundle: bundle)
        searchItem.paletteLabel = searchItem.label
        searchItem.toolTip = searchItem.label
        searchItem.isBordered = true
        searchItem.target = self
        searchField.placeholderString = String(localized: "検索", bundle: bundle)
        searchField.setAccessibilityLabel(String(localized: "検索", bundle: bundle))
        searchField.target = self
        searchField.action = #selector(filterEntries(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier(Self.toolbarAutosaveName))
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
        statusBar.setContentHuggingPriority(.required, for: .vertical)
        pathControl.setContentHuggingPriority(.required, for: .vertical)
        footer.setHuggingPriority(.required, for: .vertical)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        pathControl.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let listController = NSViewController()
        listController.view = scrollView
        let listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = 280
        previewSplitItem.minimumThickness = 260
        previewSplitItem.maximumThickness = 520
        previewSplitItem.canCollapse = true
        previewSplitItem.canCollapseFromWindowResize = false
        // 一覧より幅を保ちつつ、ユーザーの divider drag の優先度を超えない。
        previewSplitItem.holdingPriority = NSLayoutConstraint.Priority(251)
        previewSplitItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        previewSplitItem.isCollapsed = true
        previewSplitController.splitView.isVertical = true
        previewSplitController.splitView.dividerStyle = .thin
        previewSplitController.addSplitViewItem(listItem)
        previewSplitController.addSplitViewItem(previewSplitItem)
        let splitView = previewSplitController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(splitView)
        content.addSubview(separator)
        content.addSubview(lockedPlaceholder)
        content.addSubview(footer)
        content.addSubview(statusBar)
        content.addSubview(listLoadingIndicator)
        content.addSubview(pathControl)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: pathControl.topAnchor, constant: -4),
            pathControl.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            pathControl.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            pathControl.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -6),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 38),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -38),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            listLoadingIndicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            listLoadingIndicator.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            listLoadingIndicator.widthAnchor.constraint(equalToConstant: 16),
            listLoadingIndicator.heightAnchor.constraint(equalToConstant: 16),
            lockedPlaceholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            lockedPlaceholder.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            lockedPlaceholder.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            lockedPlaceholder.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])
        let contentController = NSViewController()
        contentController.view = content
        contentController.addChild(previewSplitController)
        window.contentViewController = contentController
        previewVisibilityObservation = previewSplitItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.previewSidebarVisibilityDidChange() }
        }
    }

    required init?(coder: NSCoder) { nil }

    /// 列の目録から表の列を作る。並べ順の既定と、列の幅・表示の自動保存もここで決める。
    private func configureColumns() {
        for definition in ArchiveColumn.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.rawValue))
            column.title = definition.title(bundle: bundle)
            column.width = definition.width
            column.minWidth = 60
            column.resizingMask = [.userResizingMask]
            column.sortDescriptorPrototype = NSSortDescriptor(key: definition.rawValue, ascending: true)
            // 保存データにない追加列だけが既定値を使い、既存列は後で AppKit が復元する。
            column.isHidden = definition.hiddenByDefault
            if definition.hiddenByDefault && definition.isNumeric { column.headerCell.alignment = .right }
            outlineView.addTableColumn(column)
            if definition == .name { outlineView.outlineTableColumn = column }
        }
        outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        outlineView.autosaveName = Self.columnsAutosaveName
        outlineView.autosaveTableColumns = true
        outlineView.outlineTableColumn?.isHidden = false
    }

    /// 行の文脈メニューと空き領域のメニューを組み、一覧に付ける。
    private func configureEntryContextMenus() {
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
        ArchiveMenuSymbols.apply(to: menu)
        ArchiveMenuSymbols.apply(to: blankAreaMenu)
    }

    // MARK: - ツールバー（NSToolbarDelegate）

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ArchiveToolbarItem.defaultOrder
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar).filter { $0 != .space } + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier == searchItem.itemIdentifier { return searchItem }
        guard let kind = ArchiveToolbarItem(rawValue: itemIdentifier.rawValue) else { return nil }
        if kind == .navigation {
            let item = ArchiveNavigationToolbarItemGroup(controller: self, bundle: bundle)
            item.validate()
            return item
        }
        guard let symbol = kind.symbol, let action = kind.action else { return nil }
        let label = kind.label(bundle: bundle)
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
        if let navigation = item as? ArchiveNavigationToolbarItemGroup {
            navigation.validate()
            return navigation.subitems.contains(where: \.isEnabled)
        }
        guard !isLocked else { return false }
        let menuItem = NSMenuItem(title: item.label, action: item.action, keyEquivalent: "")
        let enabled = validateMenuItem(menuItem)
        item.toolTip = menuItem.toolTip ?? item.label
        return enabled
    }

    // MARK: - プレビューサイドバー

    @objc func togglePreviewSidebar(_ sender: Any?) {
        guard archiveSession != nil, !isLocked, !operationInFlight else { return }
        // ウインドウの大きさを変えず、一覧との境界だけを切り替える。
        previewSplitItem.isCollapsed.toggle()
    }

    private func previewSidebarVisibilityDidChange() {
        if showsPreviewSidebar { updatePreviewSidebar() }
        else {
            if let responder = window?.firstResponder as? NSView,
               previewSidebar.isViewLoaded, responder.isDescendant(of: previewSidebar.view) {
                window?.makeFirstResponder(outlineView)
            }
            previewSidebar.reset()
        }
        window?.toolbar?.validateVisibleItems()
    }

    private func updatePreviewSidebar() {
        guard showsPreviewSidebar, !isLocked, let session = archiveSession else { return }
        if !canReadEntries { previewSidebar.reset(); return }
        previewSidebar.display(selectedNodes, session: session, generation: generation)
    }

    // MARK: - ウインドウの表示

    static func cascadeReferenceWindow(excluding window: NSWindow) -> NSWindow? {
        NSApp.orderedWindows.first(where: {
            $0.windowController is ArchiveWindowController && $0.isVisible && $0 !== window
                && !($0.tabGroup?.windows.contains { $0 === window } ?? false)
        })
    }

    override func showWindow(_ sender: Any?) {
        if !hasShownWindow {
            hasShownWindow = true
            // Finder の関連付け、開く、履歴はすべて NSDocument のこの入口を通る。
            // 表示直前に読むので、文書の読み込み中に変更した設定も反映する。
            window?.tabbingMode = switch preferencesStore.preferences.openingBehavior {
            case .system: .automatic
            case .newTab: .preferred
            case .newWindow: .disallowed
            }
        }
        if let window, !window.isVisible, !hasPositionedWindow {
            hasPositionedWindow = true
            if let reference = Self.cascadeReferenceWindow(excluding: window) {
                let next = reference.cascadeTopLeft(from: .zero)
                window.cascadeTopLeft(from: next)
            }
        }
        super.showWindow(sender)
        // 新規表示の方針だけを変える。既存ウインドウの手動結合や、後から開く
        // タブの受け入れを .disallowed のまま妨げない。
        window?.tabbingMode = .automatic
        if (document as? ArchiveDocument)?.isPasswordLocked == true { unlockArchive(sender) }
    }

    // MARK: - ロックとパスワードの入力

    func displayLocked() {
        defer { NotificationCenter.default.post(name: Self.viewOptionsDidChange, object: self) }
        cancelFilterWork()
        display(EntryNode.tree(from: []))
        currentFolder = root
        currentFolderPath = ""
        navigationHistory.clear()
        pathControl.pathItems = []
        isLocked = true
        previewSplitItem.isCollapsed = true
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
                if !(error is CancellationError), !Task.isCancelled { self.reportFailure(ArchiveErrorText.describe(error, bundle: self.bundle)) }
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
                    else { self.reportFailure(ArchiveErrorText.describe(error, bundle: self.bundle)); return }
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

    // MARK: - 操作の取消しと後始末

    private func watchCancellation(_ progress: Progress, task: Task<Void, Never>?) -> ArchiveProgressCancellation {
        ArchiveProgressCancellation(progress: progress) { _ in task?.cancel() }
    }

    /// 操作の Task が終わったときに、取消しの監視・進捗・Task を外す。操作ごとの片付けは呼び出し側に残す。
    private func clearOperation() {
        extractionCancellation?.invalidate()
        extractionCancellation = nil
        extractionProgress = nil
        extractionTask = nil
    }

    // MARK: - 一覧の読み込みと表示

    @discardableResult func beginListLoading() -> UUID {
        let token = listLoading.begin()
        renameIndex.cancel()
        #if DEBUG
        treeDisplayedAt = nil
        #endif
        return token
    }

    func isCurrentListLoading(_ token: UUID) -> Bool { listLoading.isCurrent(token) }

    func finishListLoading(_ token: UUID) { listLoading.finish(token) }

    func cancelListWork() {
        cancelFilterWork()
        listLoading.cancel()
        renameIndex.cancel()
    }

    private func prepareRenameIndex(for root: EntryNode, session: ArchiveSession, generation: UInt64) {
        // 木は弱参照で持ち、退役した木の解放を索引の準備が妨げないようにする。
        renameIndex.prepare(for: root, session: session, generation: generation) { [weak self, weak root] in
            guard let self, let root else { return false }
            return self.root === root && self.archiveSession === session && self.generation == generation
        }
    }

    func display(_ root: EntryNode, session: ArchiveSession? = nil, generation: UInt64 = 0,
                 materializationController: ArchiveMaterializationController? = nil, preparedFilter: EntryTreeFilter? = nil,
                 indexingRenames: Bool = false, loadingToken: UUID? = nil) {
        cancelFilterWork()
        #if DEBUG
        let span = ArchiveStageDiagnostics.begin(.display)
        defer { span?.end() }
        #endif
        if let loadingToken, isCurrentListLoading(loadingToken) { renameIndex.cancel() }
        else { cancelListWork() }
        var state = captureViewState()
        if requestedFilterQuery != filterQuery {
            if filterQuery.isEmpty { unfilteredViewState = state }
            if !requestedFilterQuery.isEmpty { state.collapsedPaths.removeAll() }
        }
        showsHiddenFiles = requestedShowsHiddenFiles
        thumbnailProvider?.cancelAll()
        thumbnailProvider = nil
        outlineView.cancelRenaming()
        closePreview()
        // 古い行を閉じ終わるまで、root・フィルタ・子一覧を差し替えない。
        outlineView.collapseItem(nil, collapseChildren: true)
        let nextMaterialization = session.map { session in
            materializationController ?? (document as? ArchiveDocument)?.materializationController()
                ?? ArchiveMaterializationController(session: session)
        }
        previewSidebar.reset()
        if materialization !== nextMaterialization {
            previewSidebar.configure(materialization: nextMaterialization?.makeIndependentController())
            materialization?.close()
        }
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
        renameValidation = nil
        var retired = Optional((self.root, entryFilter, sortedChildren))
        defer { ArchiveBackgroundRelease.release(&retired) }
        self.root = root
        resolveCurrentFolder()
        kindResolver.resetNodes()
        refreshCapabilityNotice(session: session)
        if let session, let controller = nextMaterialization {
            installSessionCallbacks(session, controller: controller)
            materialization = controller
            rebuildThumbnailProvider()
        } else { materialization = nil }
        let prepared = preparedFilter.flatMap { $0.isBuilt(for: root, configuration: filterConfiguration) ? $0 : nil }
        #if DEBUG
        if prepared == nil, preparedFilter != nil || !requestedFilterQuery.isEmpty { preparedFilterMissesForTesting += 1 }
        #endif
        reloadFilteredEntries(restoring: state, prepared: prepared, collapsesExistingItems: false, applying: requestedFilterQuery)
        updatePathControl()
        updatePreviewSidebar()
        window?.toolbar?.validateVisibleItems()
        #if DEBUG
        treeDisplayedAt = .now
        #endif
        NotificationCenter.default.post(name: Self.viewOptionsDidChange, object: self)
        ArchiveReservationDiagnostics.record(.treeDisplayed)
        if indexingRenames, let session { prepareRenameIndex(for: root, session: session, generation: generation) }
    }

    /// 表示するセッションと、その取り出しを受け持つ controller の通知を、このウインドウにつなぐ。
    private func installSessionCallbacks(_ session: ArchiveSession, controller: ArchiveMaterializationController) {
        session.setCapabilitiesObserver { [weak self, weak session] in
            guard let self, let session, self.archiveSession === session else { return }
            self.refreshCapabilityNotice(session: session)
            self.window?.toolbar?.validateVisibleItems()
        }
        session.setPasswordPrompt { [weak self, weak session] challenge in
            guard let self, let session, self.archiveSession === session else { throw CancellationError() }
            guard let document = self.document as? ArchiveDocument else {
                return try await self.requestPassword(challenge)
            }
            return try await document.password(for: session, challenge: challenge) {
                try await self.requestPasswordResponse(challenge)
            }
        }
        controller.started = { [weak self] item, progress in
            guard let self else { return }
            guard item.requiresProgress, let window = self.window else { return }
            let sheet = ExtractionProgressSheet(progress: progress, detail: item.payload.path, bundle: bundle)
            // 進捗シートが key window になっても、QL の responder chain を文書へ戻す。
            sheet.nextResponder = self
            self.materializationSheet = sheet
            sheet.begin(on: window)
        }
        controller.finished = { [weak self] in
            self?.materializationSheet?.finish()
            self?.materializationSheet = nil
        }
        controller.failed = { [weak self] reason in self?.reportFailure(reason) }
    }

    /// 表示範囲の上下に何行ぶん、サムネールを先に作るか。
    private nonisolated static let thumbnailPrefetchRows = 3

    private func rebuildThumbnailProvider() {
        thumbnailProvider?.cancelAll()
        thumbnailProvider = nil
        if let session = archiveSession, let controller = materialization, let worker = controller.entryMaterializer {
            let provider = ArchiveThumbnailProvider(materializer: worker, session: session, generation: generation,
                                                    kindResolver: kindResolver, pointSize: listIconSize.pointSize)
            provider.isVisible = { [weak self] node in
                guard let outline = self?.outlineView else { return false }
                let row = outline.row(forItem: node)
                let rows = outline.rows(in: outline.visibleRect)
                return row >= 0 && rows.length > 0 && row >= max(0, rows.location - Self.thumbnailPrefetchRows)
                    && row < min(outline.numberOfRows, NSMaxRange(rows) + Self.thumbnailPrefetchRows)
            }
            if (document as? ArchiveDocument)?.saveBehavior == .onSave {
                provider.canRead = { [weak self] _ in self?.canReadEntries == true }
            }
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
    }

    private func applyListSizing() {
        if listIconSize == .small, listTextSize == 13 {
            outlineView.rowHeight = defaultRowHeight
            outlineView.rowSizeStyle = .default
        } else {
            outlineView.rowSizeStyle = .custom
            outlineView.rowHeight = max(listIconSize.pointSize + 4,
                ceil(NSFont.systemFont(ofSize: CGFloat(listTextSize)).boundingRectForFont.height) + 6)
        }
    }

    var selectedNodes: [EntryNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? EntryNode }
    }

    private var canReadEntries: Bool {
        guard let document = document as? ArchiveDocument, document.saveBehavior == .onSave else { return true }
        return !document.isDeferredSaveRunning
    }

    func refreshCapabilityNotice(session: ArchiveSession?) {
        let onSave = (document as? ArchiveDocument)?.saveBehavior == .onSave
        let editNotice = session?.capabilities.mode.flatMap { mode in
            session?.capabilities.editNotice(options: preferencesStore.preferences.writerOptions(for: mode.outputFormat), onSave: onSave)
        }
        var notice = session?.capabilities.readOnlyReason ?? editNotice ?? ""
        if let document = document as? ArchiveDocument, document.saveBehavior == .onSave {
            if session?.capabilities.readOnlyReason == nil, let split = document.splitArchiveNotice(bundle: bundle) { notice = split }
            let count = document.pendingChanges.count
            if count > 0 || document.isDocumentEdited {
                if !notice.isEmpty { notice += "\n" }
                notice += String(localized: "未保存の変更\(count)件", bundle: bundle)
            }
        }
        if let extra = (document as? ArchiveDocument)?.splitSaveNotice { notice += (notice.isEmpty ? "" : "\n") + extra }
        capabilityNotice.stringValue = notice
        capabilityNotice.isHidden = notice.isEmpty
    }

    // MARK: - フォルダの移動

    private func pathNodes(to node: EntryNode) -> [EntryNode] {
        var components: [EntryNode] = []
        var current = node
        while current !== root {
            guard let parent = current.parent else { return [] }
            components.append(current)
            current = parent
        }
        return components.reversed()
    }

    private func outlineAncestors(of node: EntryNode) -> [EntryNode]? {
        guard node !== displayedRoot else { return nil }
        var ancestors: [EntryNode] = []
        var parent = node.parent
        while let ancestor = parent {
            if ancestor === displayedRoot { return ancestors.reversed() }
            ancestors.append(ancestor)
            parent = ancestor.parent
        }
        return nil
    }

    private func directoryNode(at path: String) -> EntryNode? {
        guard !path.isEmpty else { return root }
        return root.nodes(at: path).first { $0.isDirectory && (showsHiddenFiles || !$0.isHidden) }
    }

    private func resolveCurrentFolder() {
        let original = currentFolderPath
        var path = original
        while directoryNode(at: path) == nil {
            path = ArchivePath.components(path).dropLast().joined(separator: "/")
        }
        currentFolder = directoryNode(at: path)!
        currentFolderPath = path
        #if DEBUG
        if original != path { Self.navigationObserver.get()?(.fellBack(from: original, to: path)) }
        #endif
    }

    @discardableResult
    func navigate(to node: EntryNode, selecting: EntryNode? = nil, history: History) -> Bool {
        guard folderOpening == .enter, !operationInFlight, !isLocked, node.isDirectory,
              node === root || !pathNodes(to: node).isEmpty, showsHiddenFiles || !node.isHidden,
              outlineView.commitRenaming(), !operationInFlight else { return false }
        if !requestedFilterQuery.isEmpty || !filterQuery.isEmpty { setFilterQuery("") }
        if node === currentFolder {
            outlineView.deselectAll(nil)
            outlineView.scroll(.zero)
            updatePathControl()
            return true
        }
        let from = currentFolderPath
        navigationHistory.remember(from, state: captureViewState())
        navigationHistory.record(leaving: from, direction: history)
        closePreview()
        outlineView.cancelPendingClickRename()
        outlineView.collapseItem(nil, collapseChildren: true)
        currentFolder = node
        currentFolderPath = node.path
        displayedRoot = node
        outlineView.reloadData()
        if history != .push, let state = navigationHistory.state(for: node.path) {
            navigationHistory.touch(node.path)
            restoreViewState(state)
        } else {
            outlineView.deselectAll(nil)
            outlineView.scroll(.zero)
            if let selecting, outlineAncestors(of: selecting) != nil {
                restoreViewState(ArchiveViewState(selectedPaths: [selecting.path], expandedPaths: [], topPath: selecting.path))
            }
        }
        updatePathControl()
        updatePreviewSidebar()
        window?.toolbar?.validateVisibleItems()
        #if DEBUG
        Self.navigationObserver.get()?(.navigated(from: from, to: node.path, history: history))
        #endif
        return true
    }

    @objc func goBack(_ sender: Any?) { navigateHistory(.back) }
    @objc func goForward(_ sender: Any?) { navigateHistory(.forward) }

    private func navigateHistory(_ history: History) {
        guard folderOpening == .enter, !operationInFlight, !isLocked,
              outlineView.commitRenaming(), !operationInFlight else { return }
        while let path = navigationHistory.peek(history) {
            if let node = directoryNode(at: path) {
                guard navigate(to: node, history: history) else { return }
                navigationHistory.pop(history)
                window?.toolbar?.validateVisibleItems()
                return
            }
            navigationHistory.pop(history)
        }
        window?.toolbar?.validateVisibleItems()
        NSSound.beep()
    }

    @objc func goToEnclosingFolder(_ sender: Any?) {
        if folderOpening == .expand { selectEnclosingFolder(); return }
        guard currentFolder !== root, let parent = currentFolder.parent else { return }
        navigate(to: parent, selecting: currentFolder, history: .push)
    }

    @objc func navigateFromToolbar(_ sender: Any?) {
        let index = (sender as? NSToolbarItemGroup)?.selectedIndex ?? (sender as? NSSegmentedControl)?.selectedSegment
        if index == 0 { goBack(sender) }
        else if index == 1 { goForward(sender) }
    }

    func navigationEnabled(_ action: Selector) -> Bool {
        guard archiveSession != nil, !isLocked, !operationInFlight else { return false }
        switch action {
        case #selector(goBack(_:)): return !backStack.isEmpty
        case #selector(goForward(_:)): return !forwardStack.isEmpty
        case #selector(goToEnclosingFolder(_:)):
            return folderOpening == .enter ? currentFolder !== root : !selectedNodes.isEmpty
        default: return false
        }
    }

    private func relocateCurrentFolder(to node: EntryNode) {
        let state = filterQuery.isEmpty ? captureViewState() : nil
        currentFolder = node
        currentFolderPath = node.path
        if let state { reloadFilteredEntries(restoring: state, expandsMatches: false) }
    }

    private func followCurrentFolder(from original: String, moves: [(String, String)]) {
        guard folderOpening == .enter else { return }
        func moved(_ path: String) -> String {
            for (source, destination) in moves {
                if let result = ArchivePath.replacingPrefix(of: path, from: source, to: destination) { return result }
            }
            return path
        }
        let path = moved(original)
        guard path != original, let node = directoryNode(at: path) else { return }
        relocateCurrentFolder(to: node)
        navigationHistory.remap(moved)
    }

    private func missingImportFolderReason(_ folder: String) -> String {
        String(localized: "追加先フォルダが見つからないか、ファイルと衝突しています: \(folder)。", bundle: bundle)
    }

    // MARK: - パスバーとステータスバー

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
        let components = pathNodes(to: selectedNodes.first ?? displayedRoot)
        pathControl.pathItems = [archive] + components.map { node in
            let item = NSPathControlItem()
            item.title = node.name
            item.representedObject = node
            item.image = icon(for: node)
            return item
        }
    }

    private func updateStatusBar() {
        if isListLoadingVisible {
            statusBar.stringValue = String(localized: "項目を読み込んでいます…", bundle: bundle)
            return
        }
        if isFilterPendingVisible {
            statusBar.stringValue = String(localized: "検索しています…", bundle: bundle)
            return
        }
        let selected = selectedNodes
        // 親と子を同時に選択しても、展開後のサイズは二重に加算しない。
        let selectedRoots = selectionRoots(selected)
        var size: UInt64? = 0
        for node in selectedRoots {
            guard let total = size, let bytes = node.size else { size = nil; break }
            let sum = total.addingReportingOverflow(bytes)
            size = sum.overflow ? nil : sum.partialValue
        }
        statusBar.stringValue = ArchiveStatusBarText.text(totalCount: entryFilter?.totalCount ?? 0, totalSize: entryFilter?.totalSize,
            filteredCount: filterQuery.isEmpty ? nil : entryFilter?.matchingCount,
            selectedCount: selected.count, selectedSize: size, bundle: bundle)
    }

    @objc private func selectClickedPathItem(_ sender: NSPathControl) {
        if let item = sender.clickedPathItem { selectPathItem(item) }
    }

    func selectPathItem(_ item: NSPathControlItem) {
        guard !operationInFlight else { return }
        guard let node = item.representedObject as? EntryNode else {
            if folderOpening == .enter, currentFolder !== root {
                navigate(to: root, selecting: pathNodes(to: currentFolder).first, history: .push)
                return
            }
            outlineView.deselectAll(nil)
            return
        }
        if folderOpening == .enter, filterQuery.isEmpty {
            let components = pathNodes(to: currentFolder)
            if let index = components.firstIndex(where: { $0 === node }) {
                navigate(to: node, selecting: components.dropFirst(index + 1).first, history: .push)
                return
            }
        }
        guard let ancestors = outlineAncestors(of: node) else { return }
        for ancestor in ancestors { outlineView.expandItem(ancestor) }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: - 検索と表示設定

    @objc func filterEntries(_ sender: NSSearchField) {
        guard !operationInFlight else { sender.stringValue = requestedFilterQuery; return }
        setFilterQuery(sender.stringValue)
    }

    @objc private func preferencesDidChange(_ notification: Notification) {
        let preferences = preferencesStore.preferences
        refreshCapabilityNotice(session: (document as? ArchiveDocument)?.session)
        outlineView.renamesOnClick = preferences.renamesOnClick
        if folderOpening != preferences.folderOpening {
            folderOpening = preferences.folderOpening
            if folderOpening == .expand {
                relocateCurrentFolder(to: root)
                navigationHistory.clear()
            }
            window?.toolbar?.validateVisibleItems()
        }
        let visibilityChanged = requestedShowsHiddenFiles != preferences.showsHiddenFiles
        let sortingChanged = keepsFoldersOnTop != preferences.keepsFoldersOnTop
        let iconSizeChanged = listIconSize != preferences.listIconSize
        let sizingChanged = iconSizeChanged || listTextSize != preferences.listTextSize
        guard visibilityChanged || sortingChanged || sizingChanged else { return }
        // 表示範囲だけの変更は requestFilter が状態を採る。サイズ用の再読込だけ先に復元する。
        let state = sizingChanged || !visibilityChanged ? captureViewState() : nil
        keepsFoldersOnTop = preferences.keepsFoldersOnTop
        outlineView.cancelRenaming()
        if sortingChanged { sortedChildren.removeAll() }
        if sizingChanged {
            listIconSize = preferences.listIconSize
            listTextSize = preferences.listTextSize
            displayGeneration &+= 1
            applyListSizing()
            if iconSizeChanged { rebuildThumbnailProvider() }
        }
        if let state {
            outlineView.reloadData()
            restoreViewState(state)
        }
        if visibilityChanged {
            closePreview()
            requestedShowsHiddenFiles = preferences.showsHiddenFiles
            cancelFilterWork()
            requestFilter(reason: requestedFilterQuery == filterQuery ? .hiddenFiles : .query)
        }
    }

    func setFilterQuery(_ query: String) {
        guard query != requestedFilterQuery else { return }
        // 未確定の不正な名前を reload で捨てない。ソートと同じ確定規則を使う。
        guard outlineView.commitRenaming() else { searchField.stringValue = requestedFilterQuery; return }
        requestedFilterQuery = query
        searchField.stringValue = query
        cancelFilterWork()
        guard query != filterQuery || requestedShowsHiddenFiles != showsHiddenFiles else { return }
        requestFilter(reason: .query)
    }

    func cancelFilterWork() {
        filterRequest?.task?.cancel()
        finishFilterWork()
    }

    private func finishFilterWork(token: UUID? = nil) {
        if let token, filterRequest?.token != token { return }
        filterRequest?.revealTask?.cancel()
        filterRequest = nil
        listLoading.update(filterPending: false)
    }

    private func requestFilter(reason: FilterReason) {
        let root = self.root, configuration = filterConfiguration
        var asynchronous = !configuration.query.isEmpty && root.nodeCount >= Self.asyncFilterThreshold
        #if DEBUG
        switch Self.filterExecution.get() {
        case .automatic: break
        case .synchronous: asynchronous = false
        case .asynchronous: asynchronous = !configuration.query.isEmpty
        }
        #endif
        guard asynchronous else {
            applyFilter(EntryTreeFilter(root: root, query: configuration.query, showsHiddenFiles: configuration.showsHiddenFiles),
                        configuration: configuration, reason: reason)
            return
        }
        ArchiveStageDiagnostics.measure(.filterRequest) {
            let token = UUID()
            filterRequest = FilterRequest(token: token, root: root, generation: generation, configuration: configuration, reason: reason)
            closePreview()
            let revealAt = ContinuousClock.now + ArchiveProgressTiming.revealDelay
            filterRequest?.revealTask = Task { [weak self] in
                do { try await Task.sleep(until: revealAt, clock: .continuous) }
                catch { return }
                guard let self, self.filterRequest?.token == token else { return }
                self.listLoading.update(filterPending: true)
            }
            let task = Task(priority: .userInitiated) { [weak self, root, configuration, token] in
                var result = await EntryTreeFilter.build(root: root, configuration: configuration)
                defer {
                    self?.finishFilterWork(token: token)
                    ArchiveBackgroundRelease.release(&result)
                }
                while !Task.isCancelled, result != nil {
                    switch self?.filterDecision(for: result!, token: token) ?? .discard {
                    case .discard: return
                    case .apply: self?.applyRequestedFilter(&result, token: token); return
                    case .hold: try? await Task.sleep(for: Self.filterHoldPollInterval)
                    }
                }
            }
            filterRequest?.task = task
            #if DEBUG
            filterTaskForTesting = task
            #endif
        }
    }

    private func filterDecision(for result: EntryTreeFilter, token: UUID) -> FilterDecision {
        guard let request = filterRequest, request.token == token, request.root === root,
              result.isBuilt(for: root, configuration: request.configuration), request.configuration == filterConfiguration,
              request.generation == generation, !isLocked else { return .discard }
        if outlineView.isRenaming || operationInFlight || !draggedNodes.isEmpty || quickLook.isActive
            || window?.attachedSheet != nil || outlineView.isTrackingMenu { return .hold }
        return .apply
    }

    private func applyRequestedFilter(_ result: inout EntryTreeFilter?, token: UUID) {
        guard let request = filterRequest, request.token == token, let filter = result else { return }
        finishFilterWork(token: token)
        ArchiveStageDiagnostics.measure(.filterSwap) {
            applyFilter(filter, configuration: request.configuration, reason: request.reason)
        }
        result = nil
        #if DEBUG
        filterSwapCountForTesting += 1
        #endif
    }

    private func applyFilter(_ filter: EntryTreeFilter, configuration: EntryTreeFilter.Configuration, reason: FilterReason) {
        let state = captureViewState()
        var restored = state
        if reason == .query {
            if filterQuery.isEmpty { unfilteredViewState = state }
            restored = configuration.query.isEmpty ? (unfilteredViewState ?? state) : state
            restored.collapsedPaths.removeAll()
            if configuration.query.isEmpty { unfilteredViewState = nil }
        }
        showsHiddenFiles = configuration.showsHiddenFiles
        resolveCurrentFolder()
        closePreview()
        reloadFilteredEntries(restoring: restored, expandsMatches: reason == .query, prepared: filter, applying: configuration.query)
    }

    private func reloadFilteredEntries(restoring state: ArchiveViewState, expandsMatches: Bool = true,
                                       prepared: EntryTreeFilter? = nil, collapsesExistingItems: Bool = true, applying query: String? = nil) {
        // 古い子一覧で先に閉じ、展開済みの全行を reload しない。
        if collapsesExistingItems { outlineView.collapseItem(nil, collapseChildren: true) }
        if let query { filterQuery = query }
        displayedRoot = filterQuery.isEmpty ? currentFolder : root
        var retired = entryFilter
        entryFilter = prepared ?? EntryTreeFilter(root: root, query: filterQuery, showsHiddenFiles: showsHiddenFiles)
        ArchiveBackgroundRelease.release(&retired)
        #if DEBUG
        filterApplyCountForTesting += 1
        #endif
        sortedChildren.removeAll()
        outlineView.reloadData()
        if expandsMatches, !filterQuery.isEmpty { outlineView.expandItem(nil, expandChildren: true) }
        restoreViewState(state)
        updatePreviewSidebar()
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: - ドラッグ元（NSOutlineViewDataSource）

    private func selectionRoots(_ nodes: [EntryNode]) -> [EntryNode] {
        // 選択された親フォルダが子も運ぶので、子の URL を重ねない。
        let selected = Set(nodes.map(ObjectIdentifier.init))
        return nodes.filter { node in
            var parent = node.parent
            while let ancestor = parent {
                if selected.contains(ObjectIdentifier(ancestor)) { return false }
                parent = ancestor.parent
            }
            return true
        }
    }

    private func payloads(for nodes: [EntryNode], session: ArchiveSession) -> [ArchiveEntryPayload] {
        ArchiveEntryPayload.payloads(for: selectionRoots(nodes), session: session, generation: generation)
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? EntryNode, let session = archiveSession, !operationInFlight else { return nil }
        // provider ごとに全選択を走査すると、大量選択で二乗になる。祖先だけを調べる。
        if outlineView.isRowSelected(outlineView.row(forItem: node)) {
            var ancestor = node.parent
            while let parent = ancestor {
                if outlineView.isRowSelected(outlineView.row(forItem: parent)) { return nil }
                ancestor = parent.parent
            }
        }
        do {
            let promise = try FilePromiseRegistry.shared.register(
                payload: ArchiveEntryPayload(node: node, session: session, generation: generation), session: session, owner: promiseOwner)
            return promise.provider
        } catch {
            NSLog("ドラッグ項目を作成できません: %@", String(describing: error))
            return nil
        }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        self.outlineView.cancelPendingClickRename()
        draggedNodes = selectionRoots(draggedItems as? [EntryNode] ?? [])
        FilePromiseRegistry.shared.beganPending(sessionID: session.draggingSequenceNumber, owner: promiseOwner)
        configureDragImages(session)
    }

    /// 既定のドラッグ画像は各行のセルビューから作られ、画面外の行ではセルが配置されないまま描かれて崩れる。
    /// pasteboard の項目（writer を返した行と同じ順序 = draggedNodes）ごとにアイコンと名前だけで組み立て直し、
    /// 複数項目は Finder と同じく重ねて表示する。サムネイルは生成済みのものだけを使う。
    private func configureDragImages(_ session: NSDraggingSession) {
        let nodes = draggedNodes
        guard !nodes.isEmpty else { return }
        if nodes.count > 1 { session.draggingFormation = .stack }
        var index = 0
        session.enumerateDraggingItems(options: [], for: outlineView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            defer { index += 1 }
            guard index < nodes.count else { return }
            let node = nodes[index]
            let image = self.thumbnailProvider?.cachedThumbnail(for: node) ?? self.icon(for: node)
            let name = node.name
            var frame = item.draggingFrame
            let height = frame.height > 0 ? frame.height : self.outlineView.rowHeight
            let font = NSFont.systemFont(ofSize: CGFloat(self.listTextSize))
            let iconSize = self.listIconSize.pointSize
            frame.size = NSSize(width: ArchiveDragImage.layout(name: name, height: height, font: font, iconSize: iconSize).width,
                                height: height)
            item.draggingFrame = frame
            item.imageComponentsProvider = { ArchiveDragImage.components(icon: image, name: name, height: height, font: font, iconSize: iconSize) }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedNodes = []
        FilePromiseRegistry.shared.ended(sessionID: session.draggingSequenceNumber)
    }

    // MARK: - メニューの検証と操作の可否

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // 列の表示切替は実行中の処理と干渉しないため、処理中も選べる。
        if menuItem.action == #selector(toggleColumn(_:)) { return validateColumnMenuItem(menuItem) }
        guard !operationInFlight else {
            menuItem.toolTip = String(localized: "別の操作が完了するまでお待ちください。", bundle: bundle)
            return false
        }
        if (document as? ArchiveDocument)?.saveBehavior == .onSave {
            // 項目を読む操作は、保存後の読み直しが終わるまで止める。
            let readingActions = [#selector(copy(_:)), #selector(extractSelected(_:)), #selector(openEntry(_:)),
                                  #selector(openWithEntry(_:)), #selector(togglePreviewPanel(_:)),
                                  #selector(extractAll(_:)), #selector(extractFromToolbar(_:))]
            if readingActions.contains(where: { $0 == menuItem.action }), !canReadEntries { return false }
        }
        switch menuItem.action {
        case #selector(goBack(_:)), #selector(goForward(_:)), #selector(goToEnclosingFolder(_:)):
            return !(window?.firstResponder is NSText) && navigationEnabled(menuItem.action!)
        case #selector(togglePreviewSidebar(_:)):
            menuItem.title = showsPreviewSidebar ? String(localized: "プレビューを非表示", bundle: bundle)
                : String(localized: "プレビューを表示", bundle: bundle)
            menuItem.state = showsPreviewSidebar ? .on : .off
            menuItem.toolTip = menuItem.title
            return archiveSession != nil && !isLocked && !operationInFlight
        case #selector(setArchivePassword(_:)), #selector(changeArchivePassword(_:)), #selector(removeArchivePassword(_:)):
            guard let session = archiveSession, !isLocked else { menuItem.toolTip = nil; return false }
            menuItem.toolTip = session.passwordFormat == nil
                ? String(localized: "この形式は暗号化できません。別名で保存で ZIP か 7z にしてください。", bundle: bundle)
                : session.capabilities.readOnlyReason
            guard document is ArchiveDocument, !operationInFlight, session.passwordFormat != nil,
                  session.capabilities.canEdit else { return false }
            if let document = document as? ArchiveDocument, document.saveBehavior == .onSave,
               let output = document.pendingChanges.outputEncryption {
                return menuItem.action == #selector(setArchivePassword(_:)) ? output.password == nil : output.password != nil
            }
            return menuItem.action == #selector(setArchivePassword(_:))
                ? !session.hasEncryptedEntries : session.hasEncryptedEntries && session.hasKnownPassword
        case #selector(saveArchiveAs(_:)):
            return archiveSession != nil && archiveSession?.requiresSplitRecovery != true && !isLocked && document is ArchiveDocument && !operationInFlight
        case #selector(newFolder(_:)):
            menuItem.toolTip = editRefusal
            return archiveSession != nil && document is ArchiveDocument && editRefusal == nil && !outlineView.isRenaming
        case #selector(deleteEntries(_:)), #selector(renameEntry(_:)):
            menuItem.toolTip = editRefusal
            let count = outlineView.numberOfSelectedRows
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
        case #selector(openEntry(_:)):
            let reason = selectionOpenRefusal(skippingDirectories: true)
            menuItem.toolTip = reason
            return archiveSession != nil && outlineView.numberOfSelectedRows > 0 && reason == nil
                && !operationInFlight && !outlineView.isRenaming
        case #selector(openWithEntry(_:)), #selector(togglePreviewPanel(_:)):
            let reason = selectionOpenRefusal()
            menuItem.toolTip = reason
            return archiveSession != nil && outlineView.numberOfSelectedRows > 0 && reason == nil && extractionTask == nil
        case #selector(copy(_:)), #selector(extractSelected(_:)):
            return archiveSession != nil && outlineView.numberOfSelectedRows > 0 && extractionTask == nil
        case #selector(extractAll(_:)), #selector(extractFromToolbar(_:)):
            return archiveSession != nil && !root.children.isEmpty && extractionTask == nil
        case #selector(revealArchiveInFinder(_:)):
            return archiveURL != nil
        default: return true
        }
    }

    /// 終了時に残骸を作り得る仕事だけ。パスワード入力や確認シートは含めない。
    var hasWorkInFlight: Bool { extractionTask != nil || creationController != nil }

    var operationInFlight: Bool {
        extractionTask != nil || creationController != nil || passwordEditor != nil || deletionConfirmation != nil || conversionConfirmation != nil || passwordPrompt != nil || unlockTask != nil
            || materializationSheet != nil
            || (document?.undoManager as? ArchiveUndoManager)?.isSuspended == true
    }

    private var editRefusal: String? {
        // 追加・削除・改名とも、モデルと同じ編集可否を使う。
        if let session = archiveSession, !session.capabilities.canEdit {
            return session.capabilities.readOnlyReason ?? String(localized: "このアーカイブは変更できません。", bundle: bundle)
        }
        return operationInFlight ? String(localized: "別の操作が完了するまでお待ちください。", bundle: bundle) : nil
    }

    private func canPerformEdit(_ action: Selector) -> Bool {
        validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }

    private var archiveURL: URL? { (document as? ArchiveDocument)?.fileURL ?? archiveSession?.sourceURL }

    @objc func revealArchiveInFinder(_ sender: Any?) {
        guard !operationInFlight, let url = archiveURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 新規フォルダ・削除・改名・移動

    @objc func newFolder(_ sender: Any?) {
        guard canPerformEdit(#selector(newFolder(_:))), let document = document as? ArchiveDocument,
              let window else { return }
        let fromBlankArea = (sender as? NSMenuItem)?.menu === outlineView.blankAreaMenu && outlineView.clickedRow == -1
        let folder = fromBlankArea ? displayedFolder
            : ArchiveDropTarget.folder(for: selectedNodes.first.map(ArchiveDropTarget.Row.init), blankArea: displayedFolder)
        guard folder.isEmpty || directoryNode(at: folder) != nil else {
            reportEditFailure(missingImportFolderReason(folder))
            return
        }
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
                self?.clearOperation()
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
        extractionCancellation = watchCancellation(progress, task: extractionTask)
    }

    private func renameCreatedFolder(at path: String) {
        let target = ArchiveViewState(selectedPaths: [path], expandedPaths: [], topPath: nil).resolve(in: root).selected.first
        guard let target else { return }
        // 新しい名前が検索に一致しなくても、作成した場所で直ちに改名できるようにする。
        if (!filterQuery.isEmpty && entryFilter?.contains(target) == false) || requestedFilterQuery != filterQuery { setFilterQuery("") }
        var state = captureViewState()
        state.selectedPaths = [path]
        let parents = ArchivePath.components(path).dropLast()
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
        if document.canUndoNextMutation || document.isImmediateSplitMutation {
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

    private(set) var renameValidation: ArchiveRenameValidation?

    @objc func renameEntry(_ sender: Any?) {
        guard canPerformEdit(#selector(renameEntry(_:))), let node = selectedNodes.first else { return }
        closePreview()
        let expectedGeneration = generation
        // 純粋なプラン構築で、仮想フォルダとの衝突や子孫のパス長も commit 前に検査する。
        let entries = root.archiveEntries
        let selection = ArchiveEditSelection(node)
        let prepared = (document as? ArchiveDocument)?.pendingEditor?.prepared
        let validation = ArchiveRenameValidation(selection: selection, entries: entries,
            format: archiveSession?.reservationFormat ?? .zip, state: prepared, occupancy: renameOccupancy)
        renameValidation = validation
        let expectedRevision = prepared?.revision
        let expectedSession = archiveSession.map(ObjectIdentifier.init)
        outlineView.beginRenaming(node, validate: { [weak self, bundle] name in
            guard let self else { return String(localized: "アーカイブが閉じられています。", bundle: bundle) }
            if let reason = self.editRefusal { return reason }
            guard self.generation == expectedGeneration, self.archiveSession?.generation == expectedGeneration,
                  self.archiveSession.map(ObjectIdentifier.init) == expectedSession else {
                return String(localized: "選択した項目が変更されています。アーカイブを開き直してください。", bundle: bundle)
            }
            do {
                if let expectedRevision,
                   (self.document as? ArchiveDocument)?.pendingChanges.revision != expectedRevision {
                    throw ArchiveEditError.staleSelection
                }
                _ = try validation.plan(for: name)
                return nil
            } catch { return self.editFailureReason(error) }
        }, commit: { [weak self] name in
            guard let self, self.generation == expectedGeneration,
                  self.archiveSession?.generation == expectedGeneration else { return }
            if node.name.utf8.elementsEqual(name.utf8) { return }
            let validated: ArchiveValidatedRename?
            if let expectedRevision, let expectedSession, let plan = try? validation.plan(for: name) {
                validated = .init(plan: plan, generation: expectedGeneration, revision: expectedRevision, session: expectedSession)
            } else { validated = nil }
            self.startEdit([node], name: name,
                state: self.viewStateAfterRenaming(self.captureViewState(), node: node, to: name), validatedRename: validated)
        })
    }

    private func startEdit(_ nodes: [EntryNode], name: String?, state: ArchiveViewState, validatedRename: ArchiveValidatedRename? = nil) {
        guard let window, let document = document as? ArchiveDocument,
              archiveSession?.capabilities.canEdit == true, !operationInFlight else { return }
        let originalFolderPath = currentFolderPath
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
                self?.clearOperation()
            }
            do {
                let result: ArchiveEditResult
                if let name, let node = nodes.first {
                    result = try await document.rename(node, to: name, progress: progress, validated: validatedRename)
                } else {
                    result = try await document.remove(nodes, progress: progress)
                }
                if result.published, let self {
                    if let name, let node = nodes.first {
                        let parent = ArchivePath.components(node.path).dropLast().joined(separator: "/")
                        let renamed = (parent.isEmpty ? name : parent + "/" + name).precomposedStringWithCanonicalMapping
                        self.followCurrentFolder(from: originalFolderPath, moves: [(node.path, renamed)])
                    }
                    if let name, let node = nodes.first, let unfiltered = self.unfilteredViewState {
                        self.unfilteredViewState = self.viewStateAfterRenaming(unfiltered, node: node, to: name)
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
        extractionCancellation = watchCancellation(progress, task: extractionTask)
    }

    private func startMove(nodes: [EntryNode], to folder: String) -> Bool {
        guard let window, let document = document as? ArchiveDocument, !nodes.isEmpty,
              let session = archiveSession, session.capabilities.canEdit, !operationInFlight else { return false }
        let originalFolderPath = currentFolderPath
        var originalState = captureViewState()
        originalState.selectedPaths = Set(nodes.map(\.path))
        closePreview()
        materialization?.cancel()
        let progress = Progress(totalUnitCount: 0)
        extractionProgress = progress
        let sheet = ExtractionProgressSheet(progress: progress, title: ArchiveProgressOperation.moving.title(bundle: bundle),
            detail: nodes.count == 1 ? nodes[0].name : "", bundle: bundle)
        editProgressSheet = sheet
        sheet.begin(on: window)
        extractionTask = Task { [weak self] in
            let visibility = Self.resumeProgressAfterConflicts(sheet, on: window)
            defer {
                visibility.cancel()
                sheet.finish()
                self?.editProgressSheet = nil
                self?.clearOperation()
            }
            do {
                guard let resolver = self?.conflictResolver(on: window, session: session, sheet: sheet) else { throw CancellationError() }
                let result = try await document.move(nodes, to: folder, progress: progress,
                    resolveConflict: resolver)
                if result.published, let self {
                    let depth = ArchivePath.components(folder).count + 1
                    let renamed = Set(result.renamedPaths.map { ArchivePath.components($0).prefix(depth).joined(separator: "/") })
                    let moved = nodes.filter { node in
                        let leaf = ArchivePath.components(node.path).last ?? ""
                        let path = folder.isEmpty ? leaf : folder + "/" + leaf
                        return renamed.contains(path)
                    }
                    self.followCurrentFolder(from: originalFolderPath, moves: moved.map {
                        ($0.path, (folder.isEmpty ? $0.name : folder + "/" + $0.name).precomposedStringWithCanonicalMapping)
                    })
                    var state = self.viewStateAfterMoving(originalState, nodes: moved, to: folder)
                    let parts = ArchivePath.components(folder)
                    for count in 1..<(parts.count + 1) { state.expandedPaths.insert(parts.prefix(count).joined(separator: "/")) }
                    if let unfiltered = self.unfilteredViewState {
                        self.unfilteredViewState = self.viewStateAfterMoving(unfiltered, nodes: moved, to: folder)
                    }
                    // 親の名前だけが検索に一致していた場合も、移動した項目を選択できるようにする。
                    if (!self.filterQuery.isEmpty &&
                        state.resolve(in: self.root).selected.contains(where: { self.entryFilter?.contains($0) == false }))
                        || self.requestedFilterQuery != self.filterQuery {
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
        extractionCancellation = watchCancellation(progress, task: extractionTask)
        return true
    }

    private func editFailureReason(_ error: any Error) -> String {
        switch error as? ArchiveEditError {
        case .archiveChanged:
            String(localized: "アーカイブが変更されています。開き直してください。", bundle: bundle)
        case .splitArchive:
            ArchiveCapabilities(refusal: .splitArchive).readOnlyReason(bundle: bundle)!
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
        case nil: ArchiveErrorText.describe(error, bundle: bundle)
        }
    }

    private func reportEditFailure(_ reason: String, published: Bool = false) {
        guard let window else { return }
        let alert = Self.makeEditFailureAlert(reason, published: published, bundle: bundle)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    func reportDeferredReloadFailure(_ reason: String) { reportEditFailure(reason, published: true) }

    static func makeEditFailureAlert(_ reason: String, published: Bool = false, bundle: Bundle = .main) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = published ? String(localized: "項目を変更しましたが、アーカイブを読み直せませんでした", bundle: bundle)
            : String(localized: "項目を変更できませんでした", bundle: bundle)
        alert.informativeText = ArchiveAlertText.informativeText(reason, bundle: bundle)
        return alert
    }

    // MARK: - 表示状態の保存と復元

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

    private func viewStateAfterRenaming(_ original: ArchiveViewState, node: EntryNode, to name: String) -> ArchiveViewState {
        let parent = ArchivePath.components(node.path).dropLast().joined(separator: "/")
        let path = (parent.isEmpty ? name : parent + "/" + name).precomposedStringWithCanonicalMapping
        return original.mappingPaths { ArchivePath.replacingPrefix(of: $0, from: node.path, to: path) ?? $0 }
    }

    private func viewStateAfterMoving(_ original: ArchiveViewState, nodes: [EntryNode], to folder: String) -> ArchiveViewState {
        let moves = nodes.map { node in
            (source: node.path, destination: (folder.isEmpty ? node.name : folder + "/" + node.name)
                .precomposedStringWithCanonicalMapping)
        }
        return original.mappingPaths { old in
            for move in moves {
                if let path = ArchivePath.replacingPrefix(of: old, from: move.source, to: move.destination) { return path }
            }
            return old
        }
    }

    private func captureViewState() -> ArchiveViewState {
        let visible = outlineView.rows(in: outlineView.visibleRect)
        let top = visible.location < outlineView.numberOfRows ? outlineView.item(atRow: visible.location) as? EntryNode : nil
        var expanded = showsHiddenFiles ? [] : hiddenExpandedPaths
        var collapsed: Set<String> = []
        for node in root.directoryNodes {
            if outlineView.isItemExpanded(node) { expanded.insert(node.path) }
            else if !filterQuery.isEmpty, outlineView.row(forItem: node) >= 0 { collapsed.insert(node.path) }
        }
        if showsHiddenFiles {
            hiddenExpandedPaths = Set(expanded.filter { path in
                ArchivePath.components(path).contains { EntryNode.isHiddenName(String($0)) }
            })
        }
        return ArchiveViewState(selectedPaths: Set(selectedNodes.map(\.path)), expandedPaths: expanded, topPath: top?.path,
                                selectedEntryIndices: Set(selectedNodes.compactMap { $0.entry?.pendingID == nil ? $0.entry?.index : nil }),
                                selectedPendingIDs: Set(selectedNodes.compactMap { $0.entry?.pendingID }), generation: generation,
                                scrollX: outlineView.enclosingScrollView?.contentView.bounds.origin.x ?? 0, collapsedPaths: collapsed)
    }

    private func restoreViewState(_ state: ArchiveViewState) {
        let resolved = state.resolve(in: root, currentGeneration: generation)
        for node in resolved.expanded where outlineAncestors(of: node) != nil && entryFilter?.contains(node) != false {
            outlineView.expandItem(node)
        }
        let selected = resolved.selected.filter { outlineAncestors(of: $0) != nil && entryFilter?.contains($0) != false }
        for node in selected {
            for ancestor in outlineAncestors(of: node) ?? [] where entryFilter?.contains(ancestor) != false {
                outlineView.expandItem(ancestor)
            }
        }
        let selectedAncestors = Set(selected.flatMap { outlineAncestors(of: $0) ?? [] }.map(ObjectIdentifier.init))
        for node in resolved.collapsed where outlineAncestors(of: node) != nil && !selectedAncestors.contains(ObjectIdentifier(node)) {
            outlineView.collapseItem(node)
        }
        outlineView.selectRowIndexes(IndexSet(selected.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 }), byExtendingSelection: false)
        if let top = resolved.top, outlineAncestors(of: top) != nil {
            let row = outlineView.row(forItem: top)
            if row >= 0 { outlineView.scroll(NSPoint(x: state.scrollX, y: outlineView.rect(ofRow: row).minY)) }
        }
        // 行番号の集合が同じでも、ソート後は先頭の選択項目が変わり得る。
        updatePathControl()
    }

    // MARK: - 追加とドロップ先（NSOutlineViewDataSource）

    private var displayedFolder: String { displayedRoot.path }

    @objc func paste(_ sender: Any?) {
        guard archiveSession != nil, !operationInFlight else { return }
        startImport(urls: ArchiveIncomingPasteboard.readPaste(AppKitArchivePasteboard(pasteboard: .general)), incoming: nil, folder: displayedFolder)
    }

    @objc func addFiles(_ sender: Any?) {
        guard archiveSession != nil, !operationInFlight, let window else { return }
        let folder = displayedFolder
        let complete: ([URL]) -> Void = { [weak self] urls in
            self?.startImport(urls: urls, incoming: nil, folder: folder)
        }
        #if DEBUG
        if let addFilesPanelForTesting { addFilesPanelForTesting(complete); return }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "追加", bundle: bundle)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            complete(panel.urls)
        }
    }

    private func dropFolder(_ item: Any?) -> String {
        ArchiveDropTarget.folder(for: (item as? EntryNode).map(ArchiveDropTarget.Row.init), blankArea: displayedFolder)
    }

    var canReceiveTabDrag: Bool { archiveSession != nil && !isLocked && !operationInFlight }

    // AppKit に返す操作とハイライト先を一緒に決める。別ウインドウは従来の promise copy。
    private func dropDecision(isLocal: Bool, draggedNodes: [EntryNode], hovered: EntryNode?, mask: NSDragOperation,
                              hasFiles: Bool) -> (operation: NSDragOperation, folder: EntryNode?) {
        guard let session = archiveSession else { return ([], nil) }
        if isLocal {
            switch ArchiveDropTarget.localOperation(dragged: draggedNodes.map(ArchiveDropTarget.Row.init),
                target: ArchiveDropTarget.folder(for: hovered.map(ArchiveDropTarget.Row.init), blankArea: displayedFolder), mask: mask,
                capabilities: session.capabilities, busy: operationInFlight) {
            case .move: return (.move, ArchiveDropTarget.node(for: hovered, in: root))
            case .copy:
                guard canReadEntries else { return ([], nil) }
            case .none: return ([], nil)
            }
        }
        guard ArchiveDropTarget.accepts(capabilities: session.capabilities, offersCopy: mask.contains(.copy),
                                        hasFiles: hasFiles, busy: operationInFlight) else { return ([], nil) }
        return (.copy, session.capabilities.canEdit ? ArchiveDropTarget.node(for: hovered, in: root) : nil)
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
            case .copy:
                guard canReadEntries else { return false }
            case .none: return false
            }
        }
        guard info.draggingSourceOperationMask.contains(.copy) else { return false }
        let pasteboard = info.draggingPasteboard
        do {
            switch ArchiveIncomingPasteboard.readDrop(AppKitArchivePasteboard(pasteboard: pasteboard)) {
            case .promises(let receivers):
                guard !receivers.isEmpty else { return false }
                let source = (info.draggingSource as? NSView)?.window?.windowController as? ArchiveWindowController
                let paths = source.map { $0.draggedNodes.map(\.path) }
                let incoming = try ArchiveIncomingFiles(receivers: receivers, originalPaths: paths)
                let sourceDocument = source?.document as? ArchiveDocument
                startImport(urls: [], incoming: incoming, folder: dropFolder(item), incomingLocation: sourceDocument?.fileURL?.lastPathComponent)
            case .fileURLs(let urls):
                guard !urls.isEmpty else { return false }
                startImport(urls: urls, incoming: nil, folder: dropFolder(item))
            case .none: return false
            }
            return true
        } catch { reportImportFailure(ArchiveErrorText.describe(error, bundle: bundle)); return false }
    }

    // MARK: - 追加の実行と形式の変換

    func startImport(urls: [URL], incoming: ArchiveIncomingFiles?, folder: String, incomingLocation: String? = nil) {
        guard let window, let session = archiveSession, !operationInFlight,
              incoming != nil || !urls.isEmpty else { return }
        guard folder.isEmpty || directoryNode(at: folder) != nil else {
            reportImportFailure(missingImportFolderReason(folder))
            return
        }
        if !session.capabilities.canEdit {
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
        editProgressSheet = sheet
        sheet.begin(on: window)
        extractionTask = Task { [weak self] in
            let visibility = Self.resumeProgressAfterConflicts(sheet, on: window)
            defer {
                withExtendedLifetime(incoming) {}
                visibility.cancel()
                sheet.finish()
                self?.editProgressSheet = nil
                self?.clearOperation()
            }
            do {
                let sources: [URL]
                if let incoming { sources = try await incoming.receive(progress: progress, format: session.reservationFormat) }
                else { sources = urls }
                guard let resolver = self?.conflictResolver(on: window, session: session, sheet: sheet,
                                                          incoming: incoming, incomingLocation: incomingLocation) else { throw CancellationError() }
                let result = try await document.append(urls: sources, to: folder, progress: progress,
                    resolveConflict: resolver)
                // 非同期の圧縮が完了するまで、受信ファイルを保持する。
                withExtendedLifetime(incoming) {}
                sheet.finish()
                if let reason = result.reloadFailure {
                    self?.reportImportFailure(reason, added: true)
                } else if !result.failures.isEmpty {
                    self?.reportImportFailure(ArchiveFailureReport.describe(result.failures, name: \.name, reason: \.reason))
                }
            } catch {
                sheet.finish()
                if !(error is CancellationError), let self { self.reportImportFailure(ArchiveErrorText.describe(error, bundle: self.bundle)) }
            }
        }
        extractionCancellation = watchCancellation(progress, task: extractionTask)
    }

    private func conflictResolver(on window: NSWindow, session: ArchiveSession, sheet: ExtractionProgressSheet,
                                  incoming: ArchiveIncomingFiles? = nil,
                                  incomingLocation: String? = nil) -> ArchiveImportConflict.Resolver {
        { [weak self] conflict in
            guard let self else { throw CancellationError() }
            sheet.finish()
            func location(_ item: ArchiveConflictItem) -> String? {
                guard case .file(let url) = item.source, let path = incoming?.originalPath(for: url) else { return nil }
                return incomingLocation.map { $0 + "/" + path } ?? path
            }
            return try await self.conflictPresenter.response(to: conflict, on: window, session: session,
                existingLocation: location(conflict.existing), incomingLocation: location(conflict.incoming),
                canUndo: (self.document as? ArchiveDocument)?.canUndoNextMutation ?? false, bundle: self.bundle)
        }
    }

    /// 衝突の確認シートが閉じ、進捗シートを出し直せるかを確かめる間隔。
    private nonisolated static let conflictSheetPollInterval: Duration = .milliseconds(80)

    private static func resumeProgressAfterConflicts(_ sheet: ExtractionProgressSheet, on window: NSWindow) -> Task<Void, Never> {
        Task {
            // 件数は全回答の後に確定する。複数の確認シートの間で進捗を点滅させない。
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.conflictSheetPollInterval) } catch { return }
                if sheet.progress.totalUnitCount > 0, window.attachedSheet == nil || window.attachedSheet === sheet.window {
                    if sheet.window?.sheetParent == nil, !sheet.progress.isCancelled { sheet.begin(on: window) }
                    return
                }
            }
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
        let creator = ArchiveCreationController(store: preferencesStore)
        creationController = creator
        extractionTask = Task { [weak self] in
            defer {
                // 保存先の入力中も、作成が完了するまで受信済みのファイルを消さない。
                withExtendedLifetime(incoming) {}
                self?.creationController = nil
                self?.clearOperation()
            }
            do {
                // パスワードの入力と全 entry の検証を、保存パネルや圧縮の前に済ませる。
                let existing = try await ArchiveCreationController.existingArchive(from: session, progress: progress)
                let sources: [URL]
                if let incoming { sources = try await incoming.receive(progress: progress, format: nil) }
                else { sources = urls }
                try await creator.createAndOpen(sources: sources, existing: existing, on: window, progress: progress)
            } catch {
                if !(error is CancellationError), !Task.isCancelled { ArchiveCreationController.presentFailure(error) }
            }
        }
        extractionCancellation = watchCancellation(progress, task: extractionTask)
    }

    // MARK: - 別名で保存とパスワードの変更

    @objc func saveArchiveAs(_ sender: Any?) {
        guard outlineView.commitRenaming(), canPerformEdit(#selector(saveArchiveAs(_:))) else { return }
        let progress = Progress(totalUnitCount: 0)
        extractionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                extractionTask = nil
                extractionCancellation?.invalidate()
                extractionCancellation = nil
            }
            do { try await saveArchiveAs(using: ArchiveCreationController(store: preferencesStore), progress: progress) }
            catch {
                if !(error is CancellationError), !Task.isCancelled { ArchiveCreationController.presentFailure(error) }
            }
        }
        extractionCancellation = watchCancellation(progress, task: extractionTask)
    }

    @objc func setArchivePassword(_ sender: Any?) { presentPasswordEditor(.set, selector: #selector(setArchivePassword(_:))) }
    @objc func changeArchivePassword(_ sender: Any?) { presentPasswordEditor(.change, selector: #selector(changeArchivePassword(_:))) }
    @objc func removeArchivePassword(_ sender: Any?) { presentPasswordEditor(.remove, selector: #selector(removeArchivePassword(_:))) }

    private func presentPasswordEditor(_ action: ArchivePasswordAction, selector: Selector) {
        guard outlineView.commitRenaming(), canPerformEdit(selector), let session = archiveSession,
              let format = session.passwordFormat, let window, let document = document as? ArchiveDocument else { return }
        closePreview()
        materialization?.cancel()
        let progress = Progress(totalUnitCount: 0)
        extractionProgress = progress
        extractionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                passwordEditor?.fields?.clear()
                passwordEditor = nil
                editProgressSheet?.finish()
                editProgressSheet = nil
                clearOperation()
            }
            do {
                // 既知の鍵も CRC / HMAC まで検証してから変更する。
                _ = try await session.preparedPassword(progress: progress)
                try Task.checkCancellation()
                let editor = ArchivePasswordEditor(action: action, format: format, archiveName: document.displayName,
                                                   settings: await document.deferredEncryptionSettings(), canUndo: document.canUndoNextMutation, bundle: bundle)
                passwordEditor = editor
                let response: NSApplication.ModalResponse = await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        guard !Task.isCancelled else { continuation.resume(returning: .alertSecondButtonReturn); return }
                        editor.alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                        if let field = editor.fields?.passwordField { editor.alert.window.makeFirstResponder(field) }
                    }
                } onCancel: {
                    Task { @MainActor [weak self] in
                        if let alert = self?.passwordEditor?.alert, let parent = alert.window.sheetParent {
                            parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
                        }
                    }
                }
                guard response == .alertFirstButtonReturn else { return }
                try Task.checkCancellation()
                try editor.fields?.validate()
                let settings = editor.fields?.settings ?? ArchiveEncryptionSettings()
                editor.fields?.clear()
                passwordEditor = nil
                let sheet = ExtractionProgressSheet(progress: progress,
                    title: String(localized: "アーカイブを書き直し中…", bundle: bundle), detail: document.displayName, bundle: bundle)
                editProgressSheet = sheet
                sheet.begin(on: window)
                let result = try await document.updatePassword(action, settings: settings, progress: progress)
                sheet.finish()
                if let reason = result.reloadFailure { reportEditFailure(reason, published: true) }
            } catch {
                editProgressSheet?.finish()
                if !(error is CancellationError), !Task.isCancelled { reportEditFailure(editFailureReason(error)) }
            }
        }
        extractionCancellation = watchCancellation(progress, task: extractionTask)
    }

    // 実際の保存・文書切り替えを共有し、テストでは保存先の選択だけを差し替える。
    func saveArchiveAs(using creator: ArchiveCreationController, progress: Progress = Progress()) async throws {
        guard let window, let session = archiveSession, let document = document as? ArchiveDocument,
              !isLocked, creationController == nil else { throw CancellationError() }
        closePreview()
        materialization?.cancel()
        creationController = creator
        extractionProgress = progress
        defer { creationController = nil; extractionProgress = nil }
        if document.saveBehavior == .onSave {
            try await document.savePendingAs(using: creator, on: window, progress: progress)
            return
        }
        try await document.synchronizeDeferredLocation()
        document.configureSplitCreation(creator)
        let existing = try await ArchiveCreationController.existingArchive(from: session, progress: progress)
        guard let destination = try await creator.create(sources: [], existing: existing, on: window, progress: progress) else { return }
        try await document.switchBackingFile(to: destination, password: creator.createdEncryption.password)
        document.adoptSplitCreationNotice(creator)
    }

    func prepareForBackingFileSwitch() {
        cancelListWork()
        closePreview()
        materialization?.cancel()
        thumbnailProvider?.cancelAll()
        thumbnailProvider = nil
    }

    // MARK: - 追加の失敗の報告

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

    // MARK: - コピーと展開

    @objc func copy(_ sender: Any?) {
        guard !operationInFlight else { return }
        guard let session = archiveSession, extractionTask == nil, !selectedNodes.isEmpty,
              canReadEntries else { return }
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
        guard !operationInFlight, let session = archiveSession, let window, !nodes.isEmpty, canReadEntries else { return }
        if let extractionDestinationHandler { extractionDestinationHandler(nodes); return }
        let items = payloads(for: nodes, session: session)
        let entryCount = ExtractionSelection(nodes: nodes).entries.count
        let panel = ArchiveBatchExtractionController.makeDestinationPanel(bundle: bundle)
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
            defer {
                self?.extractionSheet = nil
                self?.clearOperation()
            }
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
                if !(error is CancellationError), !Task.isCancelled, let self {
                    self.reportFailure(ArchiveErrorText.describe(error, bundle: self.bundle))
                }
            }
        }
        extractionCancellation = watchCancellation(progress, task: extractionTask)
    }

    func cancelExtraction() {
        previewSidebar.close()
        thumbnailProvider?.cancelAll()
        outlineView.cancelRenaming()
        unlockTask?.cancel()
        passwordPresenter.cancel()
        conflictPresenter.cancel()
        if let editor = passwordEditor, let parent = editor.alert.window.sheetParent {
            parent.endSheet(editor.alert.window, returnCode: .alertSecondButtonReturn)
        }
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
        if extractionProgress?.isCancellable != false {
            extractionProgress?.cancel()
            extractionTask?.cancel()
        }
        extractionSheet?.finish()
        creationController?.savePanel?.cancel()
        creationController?.progressSheet?.finish()
    }

    private func reportFailure(_ reason: String, title: String? = nil) {
        guard let window else { return }
        let alert = Self.makeFailureAlert(reason, title: title, bundle: bundle)
        failureAlert = alert
        alert.beginSheetModal(for: window) { [weak self] _ in
            if self?.failureAlert === alert { self?.failureAlert = nil }
        }
    }

    static func makeFailureAlert(_ reason: String, title: String? = nil, bundle: Bundle = .main) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title ?? String(localized: "項目を展開できませんでした", bundle: bundle)
        alert.informativeText = ArchiveAlertText.informativeText(reason, bundle: bundle)
        return alert
    }

    // MARK: - 開く

    func selectionOpenRefusal(skippingDirectories: Bool = false) -> String? {
        guard let session = archiveSession else { return nil }
        for row in outlineView.selectedRowIndexes {
            guard let node = outlineView.item(atRow: row) as? EntryNode,
                  !skippingDirectories || !node.isDirectory else { continue }
            let capability = EntryReadCapability(entry: node.entry, isDirectory: node.isDirectory, format: session.format)
            if !capability.canOpen { return capability.reason }
        }
        return nil
    }

    private func previewItems() -> [ArchivePreviewItem] {
        guard let session = archiveSession, canReadEntries else { return [] }
        return selectedNodes.map { node in
            let payload = ArchiveEntryPayload(node: node, session: session, generation: generation)
            if let cached = materialization?.cachedItem(for: payload) { return cached }
            return ArchivePreviewItem(payload: payload,
                capability: EntryReadCapability(entry: node.entry, isDirectory: node.isDirectory, format: session.format),
                requiresProgress: ArchiveCopyOut.requiresProgress(ExtractionSelection(entries: node.entry.map { [$0] } ?? [])))
        }
    }

    private func readableSelection(skippingDirectories: Bool = false) -> [ArchivePreviewItem]? {
        let items = previewItems().filter { !skippingDirectories || !$0.payload.isDirectory }
        guard !items.isEmpty, !operationInFlight else { return nil }
        if let item = items.first(where: { !$0.capability.canOpen }), let reason = item.capability.reason {
            reportFailure("\(item.payload.path): \(reason)")
            return nil
        }
        return items
    }

    @objc func doubleClickEntry(_ sender: Any?) {
        guard !operationInFlight, outlineView.clickedRow >= 0,
              let node = outlineView.item(atRow: outlineView.clickedRow) as? EntryNode else { return }
        if node.isDirectory {
            if folderOpening == .enter { navigate(to: node, history: .push); return }
            if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) }
            else { outlineView.expandItem(node) }
        } else {
            outlineView.selectRowIndexes(IndexSet(integer: outlineView.clickedRow), byExtendingSelection: false)
            openEntry(sender)
        }
    }

    @objc func openEntry(_ sender: Any?) {
        guard !operationInFlight, !outlineView.isRenaming else { return }
        if folderOpening == .enter, selectedNodes.count == 1, let node = selectedNodes.first, node.isDirectory {
            navigate(to: node, history: .push)
            return
        }
        for node in selectedNodes where node.isDirectory { outlineView.expandItem(node) }
        openSelection(application: nil, skippingDirectories: true)
    }

    private func selectEnclosingFolder() {
        guard !operationInFlight, !outlineView.isRenaming, let node = selectedNodes.first,
              let parent = outlineView.parent(forItem: node) as? EntryNode else { return }
        let row = outlineView.row(forItem: parent)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    @objc func openWithEntry(_ sender: Any?) {
        guard let application = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        openSelection(application: application)
    }

    private func openSelection(application: URL?, skippingDirectories: Bool = false) {
        guard let items = readableSelection(skippingDirectories: skippingDirectories), let materialization else { return }
        closePreview()
        materialization.setSelection(items)
        openNext(index: 0, application: application)
    }

    private func openNext(index: Int, application: URL?) {
        guard let materialization, materialization.item(at: index) != nil else { return }
        materialization.display(index: index) { [weak self] item in
            guard let self, let url = item.previewItemURL else { return }
            if let application {
                NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { [weak self, bundle = self.bundle] _, error in
                    if let error {
                        let reason = ArchiveErrorText.describe(error, bundle: bundle)
                        Task { @MainActor [weak self] in
                            self?.reportFailure(reason, title: String(localized: "項目を開けませんでした", bundle: bundle))
                        }
                    }
                }
            } else if ArchiveOpenPanelDelegate.acceptsArchive(url,
                archiveTypes: ArchiveBatchExtractionController.archiveContentTypes()) {
                // 書庫内の書庫は同じアプリで開き、一時コピーの変更不可理由を表示する。
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
                    if let error, let self {
                        self.reportFailure(error.localizedDescription,
                                           title: String(localized: "項目を開けませんでした", bundle: self.bundle))
                    }
                }
            } else if !NSWorkspace.shared.open(url) {
                self.reportFailure(String(localized: "この項目を開くアプリケーションが見つからないか、起動できませんでした。", bundle: self.bundle),
                                   title: String(localized: "項目を開けませんでした", bundle: self.bundle))
            }
            self.openNext(index: index + 1, application: application)
        }
    }

    // MARK: - 列と「このアプリケーションで開く」のメニュー（NSMenuDelegate）

    @objc func toggleColumn(_ sender: NSMenuItem) {
        guard let column = toggleableColumn(for: sender) else { return }
        column.isHidden.toggle()
        sender.state = column.isHidden ? .off : .on
        NotificationCenter.default.post(name: Self.viewOptionsDidChange, object: self)
    }

    private func toggleableColumn(for item: NSMenuItem) -> NSTableColumn? {
        guard let key = item.representedObject as? String, key != "name" else { return nil }
        return outlineView.tableColumn(withIdentifier: .init(key))
    }

    func validateColumnMenuItem(_ item: NSMenuItem) -> Bool {
        guard let column = toggleableColumn(for: item) else { item.state = .off; return false }
        item.state = column.isHidden ? .off : .on
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === outlineView.headerView?.menu {
            ArchiveColumn.populate(menu, bundle: bundle, table: outlineView, target: self, action: #selector(toggleColumn(_:)))
            return
        }
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

    // MARK: - Quick Look

    @objc func togglePreviewPanel(_ sender: Any?) {
        quickLook.togglePreviewPanel(sender)
    }

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        // SDK の NSObject カテゴリには隔離注釈がない。AppKit の responder 呼出しは main thread。
        MainActor.assumeIsolated { quickLook.acceptsControl() }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.takePreviewControl(panel) }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook.releasePreviewControl(panel) }
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLook.previewPanel(panel, previewItemAt: index)
    }

    private func closePreview() { quickLook.closePreview() }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        outlineView.cancelClickRenameIfSelectionChanged()
        updatePathControl()
        updatePreviewSidebar()
        materialization?.cancel()
        quickLook.selectionDidChange()
    }

    // MARK: - ウインドウの通知（NSWindowDelegate）

    func windowDidBecomeKey(_ notification: Notification) {
        (document as? ArchiveDocument)?.checkDeferredIdentityWhenKey()
    }

    func windowWillClose(_ notification: Notification) {
        if let closingWindow = notification.object as? NSWindow, closingWindow === window {
            cancelListWork()
            cancelExtraction()
        }
        // Quick Look の panel が閉じる通知も同じ delegate に届く。coordinator が自分の panel なら実体化を止める。
        quickLook.windowWillClose(notification)
    }

    // MARK: - 一覧のデータと行の表示（NSOutlineViewDataSource / NSOutlineViewDelegate）

    private func children(of item: Any?) -> [EntryNode] {
        let node = (item as? EntryNode) ?? displayedRoot
        let id = ObjectIdentifier(node)
        if let cached = sortedChildren[id] { return cached }
        let descriptors = outlineView.sortDescriptors
        let children = ArchiveEntrySort.sorted(entryFilter?.children(of: node) ?? node.children,
            descriptors: descriptors, foldersOnTop: keepsFoldersOnTop, kindResolver: kindResolver)
        sortedChildren[id] = children
        return children
    }

    private func icon(for node: EntryNode) -> NSImage { kindResolver.icon(for: node) }

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
        defer { NotificationCenter.default.post(name: Self.viewOptionsDidChange, object: self) }
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
        guard let node = item as? EntryNode, let column = tableColumn, !column.isHidden else { return nil }
        let key = column.identifier.rawValue
        guard let definition = ArchiveColumn(rawValue: key) else { return nil }
        let cell = outlineView.makeView(withIdentifier: column.identifier, owner: self) as? ArchiveEntryCellView
            ?? ArchiveEntryCellView(column: definition)
        cell.apply(iconSize: listIconSize.pointSize, textSize: listTextSize, generation: displayGeneration)
        cell.textField?.stringValue = formatter.text(for: node, column: definition)
        if key == "name" {
            cell.imageView?.image = thumbnailProvider?.thumbnail(for: node) ?? icon(for: node)
        }
        return cell
    }
}
