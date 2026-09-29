import AppKit

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
