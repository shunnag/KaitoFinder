import AppKit

final class ArchiveOutlineView: NSOutlineView, NSTextFieldDelegate {
    let blankAreaMenu = NSMenu()
    var previewSelection: (() -> Void)?
    var deleteSelection: (() -> Void)?
    var renameSelection: (() -> Void)?
    var openSelection: (() -> Void)?
    var selectEnclosingFolder: (() -> Void)?
    var renameValidationChanged: ((String?) -> Void)?
    var renamesOnClick = true {
        didSet { if !renamesOnClick { cancelPendingClickRename() } }
    }
    private var clickRenameTask: Task<Void, Never>?
    private var clickMonitor: Any?
    private var clickRenameCandidate: (item: EntryNode, row: Int, rect: NSRect)?
    private(set) var renameField: NSTextField?
    private var renameItem: EntryNode?
    private var renameRecovery: Task<Void, Never>?
    private var originalName = ""
    private var validateRename: ((String) -> String?)?
    private var commitRename: ((String) -> Void)?

    var isRenaming: Bool { renameField != nil }

    isolated deinit {
        clickRenameTask?.cancel()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        cancelPendingClickRename()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        if let newWindow {
            // Observe without overriding mouseDown/mouseUp: overriding those
            // methods disables NSTableView's native gesture/drag handling on
            // newer macOS versions. Always return the event unchanged.
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [
                .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown,
                .leftMouseDragged, .keyDown, .flagsChanged, .scrollWheel
            ]) { [weak self] event in
                MainActor.assumeIsolated { self?.observeClickRenameEvent(event) }
                return event
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(cancelPendingClickRename), name: name, object: newWindow)
            }
            NotificationCenter.default.addObserver(self, selector: #selector(cancelPendingClickRename),
                                                   name: NSMenu.didBeginTrackingNotification, object: nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { cancelPendingClickRename() }
        return resigned
    }

    override func reloadData() {
        cancelPendingClickRename()
        super.reloadData()
    }

    override func reloadItem(_ item: Any?, reloadChildren: Bool) {
        cancelPendingClickRename()
        super.reloadItem(item, reloadChildren: reloadChildren)
    }

    // The field fills the name column. Only its rendered filename, not the icon,
    // disclosure triangle, or unused column space, starts a rename.
    private func filenameRect(at row: Int) -> NSRect? {
        guard let column = outlineTableColumn, let index = tableColumns.firstIndex(of: column),
              let cell = view(atColumn: index, row: row, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return nil }
        var rect = field.bounds
        rect.size.width = min(rect.width, field.intrinsicContentSize.width)
        return convert(rect, from: field)
    }

    private func observeClickRenameEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp {
            if let candidate = clickRenameCandidate, event.window === window, event.clickCount == 1,
               candidate.rect.contains(convert(event.locationInWindow, from: nil)) {
                scheduleClickRename()
            } else { cancelPendingClickRename() }
            return
        }
        cancelPendingClickRename()
        guard event.type == .leftMouseDown, event.window === window, !isHiddenOrHasHiddenAncestor else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if renamesOnClick, !isRenaming, window?.isKeyWindow == true, NSApp.isActive,
           event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
           row >= 0, selectedRowIndexes == IndexSet(integer: row),
           let item = item(atRow: row) as? EntryNode, let rect = filenameRect(at: row), rect.contains(point) {
            clickRenameCandidate = (item, row, rect)
        }
    }

    private func scheduleClickRename() {
        guard clickRenameTask == nil, let candidate = clickRenameCandidate else { return }
        clickRenameTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) }
            catch { return }
            guard let self else { return }
            self.cancelPendingClickRename()
            let (item, row, rect) = candidate
            guard self.renamesOnClick, !self.isRenaming, self.window?.isKeyWindow == true,
                  NSApp.isActive, self.window?.attachedSheet == nil,
                  self.window?.firstResponder === self,
                  self.selectedRowIndexes == IndexSet(integer: row),
                  self.item(atRow: row) as? EntryNode === item,
                  self.filenameRect(at: row) == rect, self.visibleRect.intersects(rect) else { return }
            self.renameSelection?()
        }
    }

    func cancelClickRenameIfSelectionChanged() {
        guard let candidate = clickRenameCandidate else { return }
        if selectedRowIndexes != IndexSet(integer: candidate.row)
            || item(atRow: candidate.row) as? EntryNode !== candidate.item {
            cancelPendingClickRename()
        }
    }

    @objc func cancelPendingClickRename() {
        clickRenameTask?.cancel()
        clickRenameTask = nil
        clickRenameCandidate = nil
    }

    func handleEntryKey(_ characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        cancelPendingClickRename()
        guard !isRenaming else { return false }
        let modifiers = modifiers.intersection([.command, .shift, .option, .control])
        if modifiers == .command, characters == "\u{7f}" || characters == "\u{8}" {
            deleteSelection?()
        } else if modifiers.isEmpty, characters == "\r" || characters == "\n" {
            renameSelection?()
        } else if modifiers.isEmpty, characters == " " {
            previewSelection?()
        } else if modifiers == .command, characters == "\u{f701}" {
            openSelection?()
        } else if modifiers == .command, characters == "\u{f700}" {
            selectEnclosingFolder?()
        } else { return false }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleEntryKey(event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags) { return }
        super.keyDown(with: event)
    }

    func beginRenaming(_ item: EntryNode, validate: @escaping (String) -> String?,
                       commit: @escaping (String) -> Void) {
        cancelPendingClickRename()
        guard !isRenaming, window != nil, let column = outlineTableColumn else { return }
        let row = row(forItem: item)
        guard row >= 0, let columnIndex = tableColumns.firstIndex(of: column) else { return }
        scrollRowToVisible(row)
        layoutSubtreeIfNeeded()
        guard let cell = view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        originalName = item.name
        renameItem = item
        renameField = field
        validateRename = validate
        commitRename = commit
        prepareRenameField(field)
        // editor の準備は AppKit に任せ、非 key window での一時的な nil を取消しと見なさない。
        editColumn(columnIndex, row: row, with: nil, select: true)
        if let editor = field.currentEditor() as? NSTextView {
            editor.setSelectedRange(Self.renameSelectionRange(name: item.name, isDirectory: item.isDirectory))
        }
    }

    static func renameSelectionRange(name: String, isDirectory: Bool) -> NSRange {
        let filename = name as NSString
        let stem = filename.deletingPathExtension
        let length = !isDirectory && !filename.pathExtension.isEmpty && !stem.isEmpty
            ? stem.utf16.count : filename.length
        return NSRange(location: 0, length: length)
    }

    private func prepareRenameField(_ field: NSTextField) {
        field.delegate = self
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.drawsBackground = true
        field.lineBreakMode = .byClipping
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        guard control === renameField else { return true }
        return renameValidationReason(fieldEditor.string) == nil
    }

    private func renameValidationReason(_ name: String) -> String? {
        let reason = validateRename?(name)
        renameField?.toolTip = reason
        renameValidationChanged?(reason)
        return reason
    }

    func commitRenaming() -> Bool {
        guard let field = renameField else { return true }
        guard let editor = field.currentEditor(), renameValidationReason(editor.string) == nil else { return false }
        window?.makeFirstResponder(self)
        return !isRenaming
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === renameField else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelRenaming()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            // Return は終了通知を待たず、実際に入力中の文字列を検査する。
            guard renameValidationReason(textView.string) == nil else { return true }
            window?.makeFirstResponder(self)
            return true
        default: return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === renameField else { return }
        let editor = (notification.userInfo?["NSFieldEditor"] as? NSTextView) ?? (field.currentEditor() as? NSTextView)
        let name = editor?.string ?? field.stringValue
        if let reason = renameValidationReason(name) {
            let selection = editor?.selectedRange() ?? NSRange(location: 0, length: 0)
            // editColumn 経由の focus 移動は textShouldEndEditing を呼ばない場合がある。
            // 終了処理が editor を外し終えてから入力を戻し、モデルへは渡さない。
            renameRecovery?.cancel()
            renameRecovery = Task { @MainActor [weak self, weak field] in
                guard !Task.isCancelled, let self, let field, self.renameField === field else { return }
                self.renameRecovery = nil
                self.restoreRenaming(name: name, selection: selection, reason: reason)
            }
            return
        }
        let commit = commitRename
        finishRenaming(field)
        commit?(name)
    }

    private func restoreRenaming(name: String, selection: NSRange, reason: String) {
        guard let item = renameItem, let column = outlineTableColumn,
              let columnIndex = tableColumns.firstIndex(of: column), window != nil else { return }
        var ancestors: [Any] = []
        var ancestor = parent(forItem: item)
        while let parent = ancestor {
            ancestors.append(parent)
            ancestor = self.parent(forItem: parent)
        }
        for parent in ancestors.reversed() { expandItem(parent) }
        let row = row(forItem: item)
        guard row >= 0 else { cancelRenaming(); return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollRowToVisible(row)
        guard let cell = view(atColumn: columnIndex, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { cancelRenaming(); return }
        if let previous = renameField, previous !== field { restoreLabel(previous) }
        renameField = field
        prepareRenameField(field)
        field.stringValue = name
        editColumn(columnIndex, row: row, with: nil, select: true)
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = name
            let location = min(selection.location, name.utf16.count)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, name.utf16.count - location)))
        }
        field.toolTip = reason
        renameValidationChanged?(reason)
    }

    func cancelRenaming() {
        cancelPendingClickRename()
        guard let field = renameField else { return }
        // reload と Escape は確定させない。abort の前に delegate と commit を外し、
        // controlTextDidEndEditing からの書き込みを防ぐ。
        finishRenaming(field)
        field.abortEditing()
        field.stringValue = originalName
        window?.makeFirstResponder(self)
    }

    private func finishRenaming(_ field: NSTextField) {
        renameRecovery?.cancel()
        renameRecovery = nil
        renameItem = nil
        renameField = nil
        validateRename = nil
        commitRename = nil
        restoreLabel(field)
        renameValidationChanged?(nil)
    }

    private func restoreLabel(_ field: NSTextField) {
        field.delegate = nil
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = nil
        field.stringValue = originalName
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if !commitRenaming() { return nil }
        return contextMenu(forRow: row(at: convert(event.locationInWindow, from: nil)))
    }

    func contextMenu(forRow row: Int) -> NSMenu? {
        cancelPendingClickRename()
        if row == -1 { return blankAreaMenu }
        if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menu
    }
}
