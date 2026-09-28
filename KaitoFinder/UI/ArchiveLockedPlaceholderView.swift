import AppKit

/// パスワード付きアーカイブで一覧の代わりに表示する画面。解除ボタンの target と action は呼び出し側が設定する。
final class ArchiveLockedPlaceholderView: NSView {
    let unlockButton: NSButton

    init(bundle: Bundle) {
        unlockButton = NSButton(title: String(localized: "ロックを解除…", bundle: bundle), target: nil, action: nil)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("archive.locked-placeholder")
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        unlockButton.bezelStyle = .rounded
        let lock = NSImageView()
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 56, weight: .regular))
        lock.contentTintColor = .secondaryLabelColor
        lock.imageScaling = .scaleProportionallyDown
        // SF Symbolsの整列余白をスタックの外へ出さず、画像全体をこの領域に収める。
        let symbolView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        lock.frame = symbolView.bounds
        lock.autoresizingMask = [.width, .height]
        symbolView.addSubview(lock)
        let title = NSTextField(wrappingLabelWithString: String(localized: "このアーカイブはロックされています", bundle: bundle))
        title.font = NSFontManager.shared.convert(.preferredFont(forTextStyle: .title2), toHaveTrait: .boldFontMask)
        title.alignment = .center
        let subtitle = NSTextField(wrappingLabelWithString: String(localized: "パスワードを入力すると内容を表示できます。", bundle: bundle))
        subtitle.font = .preferredFont(forTextStyle: .body)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        let stack = NSStackView(views: [symbolView, title, subtitle, unlockButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for label in [title, subtitle] {
            label.preferredMaxLayoutWidth = 420
            label.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 80),
            symbolView.heightAnchor.constraint(equalToConstant: 80),
            stack.widthAnchor.constraint(equalToConstant: 428),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }
}
