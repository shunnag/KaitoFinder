import AppKit

final class ExtractionProgressSheet: NSWindowController {
    let progress: Progress
    private let bundle: Bundle
    private let indicator = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private var updateTask: Task<Void, Never>?

    init(progress: Progress, title: String? = nil, bundle: Bundle = .main) {
        self.progress = progress
        self.bundle = bundle
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title ?? String(localized: "項目を展開しています", bundle: bundle)
        super.init(window: panel)
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        let cancel = NSButton(title: String(localized: "キャンセル", bundle: bundle), target: self, action: #selector(cancelExtraction(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [status, indicator, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        // 状態ラベルの整列用余白を含め、進捗バーも内側に収める。
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor),
            indicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4)
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

    private func refresh() {
        indicator.doubleValue = progress.fractionCompleted
        status.stringValue = String(localized: "\(progress.completedUnitCount) / \(progress.totalUnitCount)項目", bundle: bundle)
    }

    @objc func cancelExtraction(_ sender: Any?) { progress.cancel() }
}
