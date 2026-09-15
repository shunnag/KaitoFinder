import AppKit

/// 操作名を一か所で翻訳し、単独パネルとシートで同じ表記を使う。
nonisolated enum ArchiveProgressOperation {
    case expanding, adding, moving, deleting, renaming, creatingFolder, creatingArchive
    case expandingArchive(String), expandingArchives(Int)

    func title(bundle: Bundle = .main) -> String {
        switch self {
        case .expanding: String(localized: "項目を展開中…", bundle: bundle)
        case .adding: String(localized: "項目を追加中…", bundle: bundle)
        case .moving: String(localized: "項目を移動中…", bundle: bundle)
        case .deleting: String(localized: "項目を削除中…", bundle: bundle)
        case .renaming: String(localized: "名称を変更中…", bundle: bundle)
        case .creatingFolder: String(localized: "フォルダを作成中…", bundle: bundle)
        case .creatingArchive: String(localized: "アーカイブを作成中…", bundle: bundle)
        case .expandingArchive(let name): String(localized: "“\(name)”を展開中…", bundle: bundle)
        case .expandingArchives(let count): String(localized: "\(count)個のアーカイブを展開中…", bundle: bundle)
        }
    }
}

final class ExtractionProgressSheet: NSWindowController {
    let progress: Progress
    private let bundle: Bundle
    private let indicator = NSProgressIndicator()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private var updateTask: Task<Void, Never>?
    // 呼び出し側が処理中の項目を特定できる場合だけ表示する。
    var detail: String { didSet { refresh() } }

    init(progress: Progress, title: String? = nil, detail: String = "", bundle: Bundle = .main) {
        self.progress = progress
        self.bundle = bundle
        self.detail = detail
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title ?? ArchiveProgressOperation.expanding.title(bundle: bundle)
        panel.contentMinSize = NSSize(width: 420, height: 150)
        super.init(window: panel)
        titleLabel.stringValue = panel.title
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        let cancel = NSButton(title: String(localized: "キャンセル", bundle: bundle), target: self, action: #selector(cancelExtraction(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.setContentHuggingPriority(.required, for: .horizontal)
        cancel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let barRow = NSStackView(views: [indicator, cancel])
        barRow.alignment = .centerY
        barRow.spacing = 12
        stack.setViews([titleLabel, barRow, statusLabel], in: .leading)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        // ラベルの整列矩形の外側にも余白を確保する。
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            barRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4),
            indicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        refresh()
        parent.beginSheet(window)
        startUpdating()
    }

    func beginStandalone() {
        guard let window else { return }
        refresh()
        window.level = .floating
        window.center()
        showWindow(nil)
        startUpdating()
    }

    private func startUpdating() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    func finish() {
        updateTask?.cancel()
        updateTask = nil
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
    }

    func refresh() {
        indicator.doubleValue = progress.fractionCompleted
        let count = String(localized: "\(progress.completedUnitCount) / \(progress.totalUnitCount)項目", bundle: bundle)
        statusLabel.stringValue = detail.isEmpty ? count : count + "\n" + detail
        guard let window, let content = window.contentView else { return }
        let width = max(420, content.bounds.width)
        for label in [titleLabel, statusLabel] { label.preferredMaxLayoutWidth = width - 52 }
        content.layoutSubtreeIfNeeded()
        // 長い名前は省略せずに折り返し、必要な高さだけパネルを伸ばす。
        let height = max(150, ceil(stack.fittingSize.height) + 48)
        if content.bounds.size != NSSize(width: width, height: height) {
            window.setContentSize(NSSize(width: width, height: height))
        }
    }

    @objc func cancelExtraction(_ sender: Any?) { progress.cancel() }
}
