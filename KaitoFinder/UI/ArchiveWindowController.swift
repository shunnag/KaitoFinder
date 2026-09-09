import AppKit
import UniformTypeIdentifiers

final class ArchiveWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {
    private var archiveSession: ArchiveSession?
    private var generation: UInt64 = 0
    private let promiseOwner = UUID()
    private var extractionTask: Task<Void, Never>?
    private var extractionProgress: Progress?
    private let outlineView = NSOutlineView()
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
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        scrollView.documentView = outlineView
        window.contentView = scrollView
    }

    required init?(coder: NSCoder) { nil }

    func display(_ root: EntryNode, session: ArchiveSession? = nil, generation: UInt64 = 0) {
        archiveSession = session
        self.generation = generation
        self.root = root
        sortedChildren.removeAll()
        outlineView.reloadData()
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
                    let alert = NSAlert()
                    alert.messageText = String(localized: "項目を取り出せませんでした")
                    alert.informativeText = String(describing: error)
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
            self?.extractionTask = nil
            self?.extractionProgress = nil
        }
    }

    func cancelExtraction() {
        extractionProgress?.cancel()
        extractionTask?.cancel()
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
