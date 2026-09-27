import AppKit

final class ArchiveEntryCellView: NSTableCellView {
    private let iconWidth: NSLayoutConstraint?
    private let iconHeight: NSLayoutConstraint?
    private let usesMonospacedDigits: Bool
    private(set) var displayGeneration: UInt64?

    init(column: ArchiveColumn) {
        let icon = column == .name ? NSImageView() : nil
        iconWidth = icon?.widthAnchor.constraint(equalToConstant: ArchivePreferences.ListIconSize.small.pointSize)
        iconHeight = icon?.heightAnchor.constraint(equalToConstant: ArchivePreferences.ListIconSize.small.pointSize)
        usesMonospacedDigits = column.usesMonospacedDigits
        super.init(frame: .zero)
        identifier = .init(column.rawValue)
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.alignment = column.isNumeric ? .right : .left
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        var leading = leadingAnchor
        var padding: CGFloat = 4
        if let icon, let iconWidth, let iconHeight {
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor), iconWidth, iconHeight
            ])
            leading = icon.trailingAnchor
            padding = 6
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: padding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(iconSize: CGFloat, textSize: Int, generation: UInt64) {
        guard displayGeneration != generation else { return }
        displayGeneration = generation
        iconWidth?.constant = iconSize
        iconHeight?.constant = iconSize
        textField?.font = usesMonospacedDigits
            ? .monospacedDigitSystemFont(ofSize: CGFloat(textSize), weight: .regular)
            : .systemFont(ofSize: CGFloat(textSize))
    }
}
