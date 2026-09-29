import AppKit

/// 設定画面と表示オプションのグリッド行。ラベルと操作部品を一組にする。
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

    /// 折り返すチェックボックスを一行に置く。チェックの領域を差し引いた幅で、日英どちらの長い文言も折り返す。
    static func checkbox(_ button: NSButton, width: CGFloat) -> [NSView] {
        button.cell?.wraps = true
        button.cell?.lineBreakMode = .byWordWrapping
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        let size = button.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)) ?? .zero
        button.heightAnchor.constraint(equalToConstant: ceil(size.height)).isActive = true
        return [button, NSGridCell.emptyContentView]
    }
}
