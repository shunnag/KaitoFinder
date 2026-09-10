import AppKit
import UniformTypeIdentifiers
import QuickLookUI

final class ArchivePasswordPrompt {
    let alert = NSAlert()
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    let challenge: ArchivePasswordChallenge
    var waiters: [UUID: CheckedContinuation<String, any Error>] = [:]

    init(challenge: ArchivePasswordChallenge, bundle: Bundle = .main) {
        self.challenge = challenge
        alert.messageText = String(localized: "書庫のロックを解除", bundle: bundle)
        alert.informativeText = challenge.message(bundle: bundle)
        alert.addButton(withTitle: String(localized: "ロックを解除", bundle: bundle))
        alert.addButton(withTitle: String(localized: "キャンセル", bundle: bundle))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        field.placeholderString = String(localized: "パスワード", bundle: bundle)
        alert.accessoryView = field
    }
}

final class ArchiveWindowController: NSWindowController, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuItemValidation, NSMenuDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var archiveSession: ArchiveSession?
    private var generation: UInt64 = 0
    private let promiseOwner = UUID()
    private(set) var extractionTask: Task<Void, Never>?
    private var extractionProgress: Progress?
    private var extractionCancellation: Task<Void, Never>?
    private(set) var extractionSheet: ExtractionProgressSheet?
    private(set) var passwordPrompt: ArchivePasswordPrompt?
    private(set) var unlockTask: Task<Void, Never>?
    private let unlockButton = NSButton(title: String(localized: "ロックを解除"), target: nil, action: nil)
    private(set) var deletionConfirmation: NSAlert?
    private(set) var editProgressSheet: ExtractionProgressSheet?
    private let capabilityNotice = NSTextField(wrappingLabelWithString: "")
    private let renameValidationNotice = NSTextField(wrappingLabelWithString: "")
    let outlineView = ArchiveOutlineView()
    private var materialization: ArchiveMaterializationController?
    private weak var previewPanel: QLPreviewPanel?
    private var previewMonitor: Task<Void, Never>?
    private var previewActive = false
    private var materializationSheet: ExtractionProgressSheet?
    private var materializationCancellation: Task<Void, Never>?
    private let openWithMenu = NSMenu(title: String(localized: "このアプリケーションで開く"))
    private var root = EntryNode.tree(from: [])
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
        outlineView.deleteSelection = { [weak self] in self?.deleteEntries(nil) }
        outlineView.renameSelection = { [weak self] in self?.renameEntry(nil) }
        outlineView.renameValidationChanged = { [weak self] reason in
            self?.renameValidationNotice.stringValue = reason ?? ""
            self?.renameValidationNotice.isHidden = reason == nil
        }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "開く（読み取り専用のコピー）"),
                     action: #selector(openEntry(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "クイックルック"),
                     action: #selector(togglePreviewPanel(_:)), keyEquivalent: "")
        let openWith = menu.addItem(withTitle: openWithMenu.title, action: #selector(openWithEntry(_:)), keyEquivalent: "")
        openWith.submenu = openWithMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "削除"), action: #selector(deleteEntries(_:)), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "名称変更"), action: #selector(renameEntry(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        openWithMenu.delegate = self
        outlineView.menu = menu
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        outlineView.registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL])
        scrollView.documentView = outlineView
        let notice = NSTextField(wrappingLabelWithString: String(localized:
            "プレビュー・外部アプリで開く項目は読み取り専用の一時コピーです。変更は書庫に保存されません。"))
        notice.textColor = .secondaryLabelColor
        notice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        unlockButton.target = self
        unlockButton.action = #selector(unlockArchive(_:))
        unlockButton.isHidden = true
        let footer = NSStackView(views: [unlockButton, renameValidationNotice, capabilityNotice, notice])
        footer.orientation = .vertical
        footer.alignment = .leading
        capabilityNotice.textColor = .secondaryLabelColor
        capabilityNotice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        renameValidationNotice.textColor = .systemRed
        renameValidationNotice.isHidden = true
        let content = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6)
        ])
        window.contentView = content
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if (document as? ArchiveDocument)?.isPasswordLocked == true { unlockArchive(sender) }
    }

    func displayLocked() {
        display(EntryNode.tree(from: []))
        capabilityNotice.stringValue = String(localized: "この書庫はロックされています。パスワードを入力すると一覧を表示できます")
        unlockButton.isHidden = false
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
            while !Task.isCancelled {
                do {
                    let password = try await self.requestPassword(challenge)
                    try await document.unlock(password: password)
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
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, let window else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let prompt = passwordPrompt {
                    prompt.waiters[id] = continuation
                    return
                }
                let prompt = ArchivePasswordPrompt(challenge: challenge)
                passwordPrompt = prompt
                prompt.waiters[id] = continuation
                // 親 window に進捗と入力の二枚を積まない。入力後は同じ進捗を再開する。
                materializationSheet?.finish()
                extractionSheet?.finish()
                prompt.alert.window.nextResponder = self
                prompt.alert.beginSheetModal(for: window) { [weak self, weak prompt] response in
                    guard let self, let prompt, self.passwordPrompt === prompt else { return }
                    self.finishPasswordPrompt(prompt, password: response == .alertFirstButtonReturn ? prompt.field.stringValue : nil)
                }
                prompt.alert.window.makeFirstResponder(prompt.field)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPasswordRequest(id) }
        }
    }

    private func cancelPasswordRequest(_ id: UUID) {
        guard let prompt = passwordPrompt else { return }
        prompt.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if prompt.waiters.isEmpty { finishPasswordPrompt(prompt, password: nil) }
    }

    private func finishPasswordPrompt(_ prompt: ArchivePasswordPrompt, password: String?) {
        guard passwordPrompt === prompt else { return }
        passwordPrompt = nil
        prompt.field.stringValue = ""
        if let parent = prompt.alert.window.sheetParent { parent.endSheet(prompt.alert.window) }
        prompt.alert.window.orderOut(nil)
        let waiters = Array(prompt.waiters.values)
        prompt.waiters.removeAll()
        if let password {
            if let window {
                for sheet in [materializationSheet, extractionSheet].compactMap({ $0 }) where !sheet.progress.isCancelled {
                    sheet.begin(on: window)
                }
            }
            for waiter in waiters { waiter.resume(returning: password) }
        } else {
            for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        }
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
        outlineView.cancelRenaming()
        closePreview()
        if materialization !== materializationController { materialization?.close() }
        archiveSession = session
        unlockButton.isHidden = true
        self.generation = generation
        self.root = root
        sortedChildren.removeAll()
        outlineView.reloadData()
        restoreViewState(state)
        capabilityNotice.stringValue = session?.capabilities.readOnlyReason ?? String(localized: "ファイルやフォルダをドラッグ、またはペーストして追加できます")
        if let session {
            session.setPasswordPrompt { [weak self, weak session] challenge in
                guard let self, let session, self.archiveSession === session else { throw CancellationError() }
                return try await self.requestPassword(challenge)
            }
            let controller = materializationController ?? ArchiveMaterializationController(session: session)
            controller.started = { [weak self, weak controller] item, progress in
                guard let self else { return }
                self.materializationCancellation = self.watchCancellation(progress) { [weak controller] in controller?.cancel() }
                guard item.requiresProgress, let window = self.window else { return }
                let sheet = ExtractionProgressSheet(progress: progress)
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
        } else { materialization = nil }
    }

    var selectedNodes: [EntryNode] {
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
        case #selector(deleteEntries(_:)), #selector(renameEntry(_:)):
            menuItem.toolTip = editRefusal
            let count = selectedNodes.count
            return archiveSession != nil && document is ArchiveDocument && editRefusal == nil
                && !outlineView.isRenaming && count > 0
                && (menuItem.action != #selector(renameEntry(_:)) || count == 1)
        case #selector(paste(_:)):
            menuItem.toolTip = archiveSession?.capabilities.readOnlyReason
            return archiveSession?.capabilities.canAppend == true && extractionTask == nil
                && ArchiveIncomingPasteboard.canPaste(AppKitArchivePasteboard(pasteboard: .general))
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

    private var operationInFlight: Bool {
        extractionTask != nil || deletionConfirmation != nil || passwordPrompt != nil || unlockTask != nil
            || (document?.undoManager as? ArchiveUndoManager)?.isSuspended == true
    }

    private var editRefusal: String? {
        // モデルと同じ ZIP updater の門番を使う。canDelete / canRename は未使用の予約値。
        if let session = archiveSession, !session.capabilities.canAppend {
            return session.capabilities.readOnlyReason ?? String(localized: "この書庫は変更できません")
        }
        return operationInFlight ? String(localized: "別の操作が完了するまでお待ちください") : nil
    }

    private func canPerformEdit(_ action: Selector) -> Bool {
        validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
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
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "選択した項目を削除しますか？")
        alert.informativeText = String(localized: "この削除は取り消せません。")
        alert.addButton(withTitle: String(localized: "削除"))
        alert.addButton(withTitle: String(localized: "キャンセル"))
        deletionConfirmation = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.deletionConfirmation === alert else { return }
            self.deletionConfirmation = nil
            guard response == .alertFirstButtonReturn, self.generation == expectedGeneration,
                  self.archiveSession?.generation == expectedGeneration else { return }
            self.startEdit(nodes, name: nil, state: state)
        }
    }

    @objc func renameEntry(_ sender: Any?) {
        guard canPerformEdit(#selector(renameEntry(_:))), let node = selectedNodes.first else { return }
        closePreview()
        let expectedGeneration = generation
        // 純粋なプラン構築で、仮想フォルダとの衝突や子孫のパス長も commit 前に検査する。
        let entries = ExtractionSelection(nodes: [root]).entries
        let selection = ArchiveEditSelection(node)
        outlineView.beginRenaming(node, validate: { [weak self] name in
            guard let self else { return String(localized: "書庫が閉じられています") }
            if let reason = self.editRefusal { return reason }
            guard self.generation == expectedGeneration, self.archiveSession?.generation == expectedGeneration else {
                return String(localized: "選択した項目が変更されています。書庫を開き直してください")
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
            ? String(localized: "項目を削除しています") : String(localized: "名称を変更しています"))
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

    private func editFailureReason(_ error: any Error) -> String {
        switch error as? ArchiveEditError {
        case .collision:
            String(localized: "同じ名前の項目が既にあります。別の名前を入力してください。")
        case .invalidName:
            String(localized: "この名前は使えません。空の名前、予約文字、長すぎる名前を避けてください。")
        case .staleSelection:
            String(localized: "選択した項目が変更されています。書庫を開き直してください")
        case .indexMismatch:
            String(localized: "選択した項目と書庫内の項目が一致しません。書庫を開き直してください")
        case .conflictingSelection:
            String(localized: "同じ項目への変更が重複しています")
        case nil: error.localizedDescription
        }
    }

    private func reportEditFailure(_ reason: String, published: Bool = false) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = published ? String(localized: "項目を変更しましたが、書庫を読み直せませんでした")
            : String(localized: "項目を変更できませんでした")
        alert.informativeText = reason
        alert.beginSheetModal(for: window, completionHandler: nil)
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
        for node in resolved.expanded { outlineView.expandItem(node) }
        outlineView.selectRowIndexes(IndexSet(resolved.selected.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 }), byExtendingSelection: false)
        if let top = resolved.top {
            let row = outlineView.row(forItem: top)
            if row >= 0 { outlineView.scroll(NSPoint(x: 0, y: outlineView.rect(ofRow: row).minY)) }
        }
    }

    // 現在は書庫 root を表示する outline。選択と表示フォルダは混同しない。
    private var displayedFolder: String { root.path }

    @objc func paste(_ sender: Any?) {
        guard let session = archiveSession, extractionTask == nil else { return }
        guard session.capabilities.canAppend else {
            reportImportFailure(session.capabilities.readOnlyReason ?? "この書庫は変更できません")
            return
        }
        startImport(urls: ArchiveIncomingPasteboard.readPaste(AppKitArchivePasteboard(pasteboard: .general)), incoming: nil, folder: displayedFolder)
    }

    private func dropFolder(_ item: Any?) -> String {
        ArchiveDropTarget.folder(for: (item as? EntryNode).map(ArchiveDropTarget.Row.init))
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let session = archiveSession,
              ArchiveDropTarget.accepts(capabilities: session.capabilities,
                offersCopy: info.draggingSourceOperationMask.contains(.copy),
                hasFiles: ArchiveIncomingPasteboard.representation(AppKitArchivePasteboard(pasteboard: info.draggingPasteboard)) != .none,
                busy: extractionTask != nil) else { return [] }
        let row = outlineView.row(at: outlineView.convert(info.draggingLocation, from: nil))
        let hovered = row >= 0 ? outlineView.item(atRow: row) as? EntryNode : nil
        let folder = ArchiveDropTarget.node(for: hovered, in: root)
        outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let session = archiveSession, session.capabilities.canAppend,
              info.draggingSourceOperationMask.contains(.copy), extractionTask == nil else { return false }
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
        guard let window, let document = document as? ArchiveDocument, extractionTask == nil,
              incoming != nil || !urls.isEmpty else { return }
        closePreview()
        materialization?.cancel()
        let progress = Progress(totalUnitCount: 0)
        extractionProgress = progress
        let sheet = ExtractionProgressSheet(progress: progress, title: String(localized: "項目を追加しています"))
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

    private func reportImportFailure(_ reason: String, added: Bool = false) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = added ? String(localized: "項目を追加しましたが、書庫を読み直せませんでした")
            : String(localized: "項目を追加できませんでした")
        alert.informativeText = reason
        alert.beginSheetModal(for: window, completionHandler: nil)
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

    func startExtraction(_ items: [ArchiveEntryPayload], session: ArchiveSession,
                                 destination: URL?, showProgress: Bool, entryCount: Int) {
        guard let window, extractionTask == nil else { return }
        let progress = Progress(totalUnitCount: Int64(entryCount))
        extractionProgress = progress
        let sheet = showProgress ? ExtractionProgressSheet(progress: progress) : nil
        extractionSheet = sheet
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
            self?.extractionSheet = nil
            self?.extractionCancellation?.cancel()
            self?.extractionCancellation = nil
        }
        extractionCancellation = watchCancellation(progress) { [weak self] in self?.extractionTask?.cancel() }
    }

    func cancelExtraction() {
        outlineView.cancelRenaming()
        unlockTask?.cancel()
        if let prompt = passwordPrompt { finishPasswordPrompt(prompt, password: nil) }
        if let alert = deletionConfirmation {
            deletionConfirmation = nil
            window?.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        }
        closePreview()
        materialization?.close()
        extractionProgress?.cancel()
        extractionTask?.cancel()
        extractionSheet?.finish()
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
            let type = type(for: node)
            if icons[type] == nil { icons[type] = NSWorkspace.shared.icon(for: type) }
            cell.imageView?.image = icons[type]
        }
        return cell
    }
}
