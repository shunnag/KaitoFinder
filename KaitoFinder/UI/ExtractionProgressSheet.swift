import AppKit

final class ExtractionProgressSheet: NSWindowController {
    let progress: Progress
    private let indicator = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "")
    private var updateTask: Task<Void, Never>?

    init(progress: Progress, title: String = String(localized: "項目を取り出しています")) {
        self.progress = progress
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title
        super.init(window: panel)
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        let cancel = NSButton(title: String(localized: "キャンセル"), target: self, action: #selector(cancelExtraction(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [status, indicator, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor),
            indicator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func begin(on parent: NSWindow) {
        guard let window else { return }
        refresh()
        parent.beginSheet(window)
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
        if let window { window.sheetParent?.endSheet(window) }
    }

    private func refresh() {
        indicator.doubleValue = progress.fractionCompleted
        status.stringValue = String(localized: "\(progress.completedUnitCount) / \(progress.totalUnitCount) 項目")
    }

    @objc func cancelExtraction(_ sender: Any?) { progress.cancel() }
}
