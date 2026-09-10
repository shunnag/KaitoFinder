import AppKit

final class ArchiveOutlineView: NSOutlineView, NSTextFieldDelegate {
    var previewSelection: (() -> Void)?
    var deleteSelection: (() -> Void)?
    var renameSelection: (() -> Void)?
    var renameValidationChanged: ((String?) -> Void)?
    private(set) var renameField: NSTextField?
    private var renameItem: EntryNode?
    private var renameRecovery: Task<Void, Never>?
    private var originalName = ""
    private var validateRename: ((String) -> String?)?
    private var commitRename: ((String) -> Void)?

    var isRenaming: Bool { renameField != nil }

    func handleEntryKey(_ characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !isRenaming else { return false }
        let modifiers = modifiers.intersection([.command, .shift, .option, .control])
        if modifiers == .command, characters == "\u{7f}" || characters == "\u{8}" {
            deleteSelection?()
        } else if modifiers.isEmpty, characters == "\r" || characters == "\n" {
            renameSelection?()
        } else { return false }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if handleEntryKey(event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags) { return }
        // Space は通常のキーイベント。Force Touch の quickLookWithEvent: は使わない。
        if event.charactersIgnoringModifiers == " " {
            previewSelection?()
        } else {
            super.keyDown(with: event)
        }
    }

    func beginRenaming(_ item: EntryNode, validate: @escaping (String) -> String?,
                       commit: @escaping (String) -> Void) {
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
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return row >= 0 ? super.menu(for: event) : nil
    }
}
