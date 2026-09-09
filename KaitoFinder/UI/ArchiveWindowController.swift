import AppKit
import UniformTypeIdentifiers
import QuickLookUI

final class ArchiveWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuItemValidation, NSMenuDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var archiveSession: ArchiveSession?
    private var generation: UInt64 = 0
    private let promiseOwner = UUID()
    private var extractionTask: Task<Void, Never>?
    private var extractionProgress: Progress?
    private let outlineView = ArchiveOutlineView()
    private var materialization: ArchiveMaterializationController?
    private weak var previewPanel: QLPreviewPanel?
    private var previewMonitor: Task<Void, Never>?
    private var previewActive = false
    private var materializationSheet: ExtractionProgressSheet?
    private let openWithMenu = NSMenu(title: String(localized: "このアプリケーションで開く"))
    private var root = EntryNode.tree(from: [])
    private var sortedChildren: [ObjectIdentifier: [EntryNode]] = [:]
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

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.minSize = NSSize(width: 600, height: 300)
        window.center()
        window.setFrameAutosaveName("ArchiveWindow")
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
            ("name", String(localized: "名前"), 300),
            ("size", String(localized: "サイズ"), 110),
            ("compressedSize", String(localized: "圧縮サイズ"), 110),
            ("date", String(localized: "変更日"), 180),
            ("kind", String(localized: "種類"), 140),
            ("method", String(localized: "圧縮方式"), 100),
            ("encrypted", String(localized: "暗号化"), 80)
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
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "開く（読み取り専用のコピー）"),
                     action: #selector(openEntry(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "クイックルック"),
                     action: #selector(togglePreviewPanel(_:)), keyEquivalent: "")
        let openWith = menu.addItem(withTitle: openWithMenu.title, action: #selector(openWithEntry(_:)), keyEquivalent: "")
        openWith.submenu = openWithMenu
        for item in menu.items { item.target = self }
        openWithMenu.delegate = self
        outlineView.menu = menu
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        scrollView.documentView = outlineView
        let notice = NSTextField(wrappingLabelWithString: String(localized:
            "プレビュー・外部アプリで開く項目は読み取り専用の一時コピーです。変更は書庫に保存されません。"))
        notice.textColor = .secondaryLabelColor
        notice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let content = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        notice.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        content.addSubview(notice)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -6),
            notice.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            notice.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            notice.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6)
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { nil }

    func display(_ root: EntryNode, session: ArchiveSession? = nil, generation: UInt64 = 0) {
        closePreview()
        materialization?.close()
        archiveSession = session
        self.generation = generation
        self.root = root
        sortedChildren.removeAll()
        outlineView.reloadData()
        if let session {
            let worker = EntryMaterializer(session: session)
            let controller = ArchiveMaterializationController { payload, progress in
                try await worker.materialize(payload, progress: progress)
            }
            controller.started = { [weak self] item, progress in
                guard let self, item.requiresProgress, let window = self.window else { return }
                let sheet = ExtractionProgressSheet(progress: progress)
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
            materialization = controller
        } else { materialization = nil }
    }

    private var selectedNodes: [EntryNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? EntryNode }
    }

    private func payloads(for nodes: [EntryNode], session: ArchiveSession) -> [ArchiveEntryPayload] {
        // 選択された親フォルダが子も運ぶので、子の URL を重ねない。
        let selected = Set(nodes.map(ObjectIdentifier.init))
        return nodes.filter { node in
            var parent = outlineView.parent(forItem: node) as? EntryNode
            while let ancestor = parent {
                if selected.contains(ObjectIdentifier(ancestor)) { return false }
                parent = outlineView.parent(forItem: ancestor) as? EntryNode
            }
            return true
        }.map { ArchiveEntryPayload(node: $0, archiveURL: session.sourceURL, generation: generation) }
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
        FilePromiseRegistry.shared.beganPending(sessionID: session.draggingSequenceNumber, owner: promiseOwner)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        FilePromiseRegistry.shared.ended(sessionID: session.draggingSequenceNumber)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openEntry(_:)), #selector(openWithEntry(_:)), #selector(togglePreviewPanel(_:)):
            let items = previewItems()
            let reason = items.first(where: { !$0.capability.canOpen })?.capability.reason
            menuItem.toolTip = reason
            return !items.isEmpty && reason == nil && extractionTask == nil
        case #selector(copy(_:)), #selector(extractSelected(_:)):
            return archiveSession != nil && !selectedNodes.isEmpty && extractionTask == nil
        case #selector(extractAll(_:)):
            return archiveSession != nil && !root.children.isEmpty && extractionTask == nil
        default: return true
        }
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

    private func chooseDestination(for nodes: [EntryNode]) {
        guard let session = archiveSession, let window, extractionTask == nil, !nodes.isEmpty else { return }
        let items = payloads(for: nodes, session: session)
        let entryCount = ExtractionSelection(nodes: nodes).entries.count
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "取り出す")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.startExtraction(items, session: session, destination: destination, showProgress: true, entryCount: entryCount)
        }
    }

    private func startExtraction(_ items: [ArchiveEntryPayload], session: ArchiveSession,
                                 destination: URL?, showProgress: Bool, entryCount: Int) {
        guard let window, extractionTask == nil else { return }
        let progress = Progress(totalUnitCount: Int64(entryCount))
        extractionProgress = progress
        let sheet = showProgress ? ExtractionProgressSheet(progress: progress) : nil
        sheet?.begin(on: window)
        // シートの表示後に worker を起動する。小さい copy も UI actor で stream を読まない。
        extractionTask = Task { [weak self] in
            do {
                if let destination {
                    let result = try await ExtractionService.extract(items, from: session, to: destination, progress: progress)
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
        }
    }

    func cancelExtraction() {
        closePreview()
        materialization?.close()
        extractionProgress?.cancel()
        extractionTask?.cancel()
    }

    private func reportFailure(_ reason: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "項目を取り出せませんでした")
        alert.informativeText = reason
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func previewItems() -> [ArchivePreviewItem] {
        guard let session = archiveSession else { return [] }
        return selectedNodes.map { node in
            let payload = ArchiveEntryPayload(node: node, archiveURL: session.sourceURL, generation: generation)
            if let cached = materialization?.items.first(where: { $0.payload == payload }) { return cached }
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
            } else if !NSWorkspace.shared.open(url) {
                self.reportFailure(String(localized: "この項目を開くアプリケーションが見つからないか、起動できませんでした"))
            }
            self.openNext(index: index + 1, application: application)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openWithMenu else { return }
        menu.removeAllItems()
        guard let items = readableSelection(), let item = items.first, let materialization else { return }
        // URL による handler 照会には実体が必要。サブメニューを要求した時だけ一項目を作る。
        let loading = menu.addItem(withTitle: String(localized: "アプリケーションを調べています…"), action: nil, keyEquivalent: "")
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
                menu.addItem(withTitle: String(localized: "対応するアプリケーションが見つかりません"), action: nil, keyEquivalent: "")
            }
        }
    }

    @objc func togglePreviewPanel(_ sender: Any?) {
        if let panel = previewPanel, panel.isVisible { closePreview(); return }
        guard readableSelection() != nil, let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(sender)
        panel.updateController()
        if previewPanel === panel { updatePreviewSelection(); startPreviewMonitoring(panel) }
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
        if previewActive { materialization?.close() }
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

    private func updatePreviewSelection() {
        guard let panel = previewPanel else { return }
        previewActive = true
        materialization?.setSelection(previewItems())
        panel.reloadData()
        if materialization?.items.isEmpty == false { panel.currentPreviewItemIndex = 0 }
        synchronizePreview(panel)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
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
        let children = node.children.sorted { lhs, rhs in
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
            if node.isDirectory { return String(localized: "フォルダ") }
            if node.entry?.kind == .hardlink { return String(localized: "ハードリンク") }
            return type(for: node).localizedDescription ?? String(localized: "書類")
        case "method": return node.entry?.methodDescription ?? "—"
        case "encrypted":
            guard let entry = node.entry else { return "—" }
            return entry.isEncrypted ? String(localized: "はい") : String(localized: "いいえ")
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
        sortedChildren.removeAll()
        outlineView.reloadData()
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
            let type = type(for: node)
            if icons[type] == nil { icons[type] = NSWorkspace.shared.icon(for: type) }
            cell.imageView?.image = icons[type]
        }
        return cell
    }
}
