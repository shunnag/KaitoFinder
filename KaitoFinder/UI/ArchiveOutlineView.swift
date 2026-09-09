import AppKit

final class ArchiveOutlineView: NSOutlineView {
    var previewSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Space は通常のキーイベント。Force Touch の quickLookWithEvent: は使わない。
        if event.charactersIgnoringModifiers == " " {
            previewSelection?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return row >= 0 ? super.menu(for: event) : nil
    }
}
