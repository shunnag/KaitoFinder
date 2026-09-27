import AppKit

enum ArchiveFormRow {
    static func make(_ title: String, control: NSView) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.alignment = .left
        if label.intrinsicContentSize.width > 260 {
            label.usesSingleLineMode = false
            label.cell?.wraps = true
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            label.preferredMaxLayoutWidth = 260
        }
        control.setAccessibilityLabel(title)
        return [label, control]
    }
}
