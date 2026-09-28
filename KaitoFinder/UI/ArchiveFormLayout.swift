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

/// NSAlert は初期フレームからアクセサリの領域を決める。解除・設定・保存で同じ規則を使う。
enum ArchiveAccessoryLayout {
    static func stack(_ views: [NSView], width: CGFloat? = nil, detachesHiddenViews: Bool = false) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = detachesHiddenViews
        if let width { stack.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return stack
    }

    static func size(_ view: NSView) {
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
    }
}

typealias ArchivePasswordLayout = ArchiveAccessoryLayout
