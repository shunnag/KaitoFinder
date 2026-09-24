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
    private final class Panel: NSPanel {
        var isRevealed = false
        override var canBecomeKey: Bool { isRevealed && super.canBecomeKey }
    }
    static let revealDelay: Duration = .milliseconds(500)
    private static let pendingSheets = NSMapTable<NSWindow, ExtractionProgressSheet>.weakToWeakObjects()
    let progress: Progress
    private let bundle: Bundle
    let indicator = NSProgressIndicator()
    let titleLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var updateTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private let delay: Duration
    private var revealDeadline: ContinuousClock.Instant?
    private var isPresenting = false
    private weak var parentWindow: NSWindow?
    private var inputMonitor: Any?
    // 呼び出し側が処理中の項目を特定できる場合だけ表示する。
    var detail: String { didSet { refresh() } }

    init(progress: Progress, title: String? = nil, detail: String = "", bundle: Bundle = .main,
         revealDelay: Duration = ExtractionProgressSheet.revealDelay) {
        self.progress = progress
        self.bundle = bundle
        self.detail = detail
        delay = revealDelay
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title ?? ArchiveProgressOperation.expanding.title(bundle: bundle)
        panel.contentMinSize = NSSize(width: 420, height: 150)
        panel.autorecalculatesKeyViewLoop = true
        panel.animationBehavior = .none
        panel.alphaValue = 0
        panel.setAccessibilityElement(false)
        super.init(window: panel)
        titleLabel.stringValue = panel.title
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        detailLabel.font = statusLabel.font
        detailLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, detailLabel] {
            label.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
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
        let statusRow = NSStackView(views: [statusLabel, detailLabel])
        statusRow.orientation = .vertical
        statusRow.alignment = .leading
        statusRow.spacing = 2
        statusRow.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.setViews([titleLabel, barRow, statusRow], in: .leading)
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
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4),
            statusLabel.widthAnchor.constraint(equalTo: statusRow.widthAnchor, constant: -4),
            detailLabel.widthAnchor.constraint(equalTo: statusRow.widthAnchor, constant: -4),
            indicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    isolated deinit {
        revealTask?.cancel()
        updateTask?.cancel()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }

    func begin(on parent: NSWindow) {
        guard window != nil, !isPresenting else { return }
        isPresenting = true
        parentWindow = parent
        Self.pendingSheets.setObject(self, forKey: parent)
        refresh()
        // 透明なシートでも key が移るため、接続前は入力だけを止める。
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.blockedInputEvents) { [weak parent] event in
            let blocked = MainActor.assumeIsolated {
                guard let parent, event.window === parent else { return false }
                return Self.consumePendingInput(event, on: parent)
            }
            return blocked ? nil : event
        }
        scheduleReveal(standalone: false)
        startUpdating()
    }

    static let blockedInputEvents: NSEvent.EventTypeMask = [
        .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .magnify, .rotate, .swipe, .smartMagnify
    ]

    static func hasPendingSheet(on window: NSWindow?) -> Bool {
        window.map { pendingSheets.object(forKey: $0) != nil } ?? false
    }

    static func consumePendingInput(_ event: NSEvent, on window: NSWindow) -> Bool {
        guard let sheet = pendingSheets.object(forKey: window),
              blockedInputEvents.contains(.init(rawValue: 1 << event.type.rawValue)) else { return false }
        if event.type == .keyDown, event.keyCode == 53 { sheet.cancelExtraction(nil) }
        return true
    }

    private func stopBlockingInput() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        if let parentWindow, Self.pendingSheets.object(forKey: parentWindow) === self {
            Self.pendingSheets.removeObject(forKey: parentWindow)
        }
    }

    func beginStandalone() {
        guard let window, !isPresenting else { return }
        isPresenting = true
        refresh()
        window.level = .floating
        window.center()
        scheduleReveal(standalone: true)
        startUpdating()
    }

    private func scheduleReveal(standalone: Bool) {
        // 入力シートから戻る場合も、最初の開始時刻からの待ち時間を使う。
        let deadline = revealDeadline ?? ContinuousClock.now.advanced(by: delay)
        revealDeadline = deadline
        if deadline <= .now { reveal(standalone: standalone); return }
        revealTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.reveal(standalone: standalone)
        }
    }

    private func reveal(standalone: Bool) {
        guard isPresenting, let window else { return }
        guard standalone || parentWindow != nil else { finish(); return }
        stopBlockingInput()
        (window as? Panel)?.isRevealed = true
        window.setAccessibilityElement(true)
        window.alphaValue = 1
        if standalone { showWindow(nil) }
        else { parentWindow?.beginSheet(window); window.makeKey() }
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
        isPresenting = false
        stopBlockingInput()
        parentWindow = nil
        revealTask?.cancel()
        revealTask = nil
        updateTask?.cancel()
        updateTask = nil
        indicator.stopAnimation(nil)
        if let window {
            (window as? Panel)?.isRevealed = false
            window.alphaValue = 0
            window.setAccessibilityElement(false)
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
    }

    func refresh() {
        let indeterminate = progress.totalUnitCount <= 0 || progress.isIndeterminate
        indicator.isIndeterminate = indeterminate
        if indeterminate { indicator.startAnimation(nil) }
        else { indicator.stopAnimation(nil) }
        indicator.doubleValue = progress.fractionCompleted
        let completed = (progress.userInfo[.fileCompletedCountKey] as? NSNumber)?.int64Value ?? progress.completedUnitCount
        let total = (progress.userInfo[.fileTotalCountKey] as? NSNumber)?.int64Value ?? progress.totalUnitCount
        let count = String(localized: "\(completed) / \(total)項目", bundle: bundle)
        statusLabel.stringValue = count
        statusLabel.isHidden = indeterminate
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
        guard let window, let content = window.contentView else { return }
        let width = max(420, content.bounds.width)
        content.layoutSubtreeIfNeeded()
        // タイトルと項目名は一行で中央を省略し、件数を別の行に表示する。
        let height = max(150, ceil(stack.fittingSize.height) + 48)
        if content.bounds.size != NSSize(width: width, height: height) {
            window.setContentSize(NSSize(width: width, height: height))
        }
    }

    @objc func cancelExtraction(_ sender: Any?) {
        guard progress.isCancellable else { return }
        progress.cancel()
    }
}
