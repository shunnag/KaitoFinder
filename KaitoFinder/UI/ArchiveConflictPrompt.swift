import AppKit
import KaitoKit
import QuickLookUI
import UniformTypeIdentifiers

/// 確認中は比較だけを行い、回答をモデルへ返す。書庫の更新は全回答の後。
final class ArchiveConflictPrompt: NSObject {
    let alert = NSAlert()
    let conflict: ArchiveImportConflict
    let applyToRemaining: NSButton
    let compareButton: NSButton
    private let session: ArchiveSession
    private let bundle: Bundle
    private(set) var preview: ArchiveConflictPreview?

    init(conflict: ArchiveImportConflict, session: ArchiveSession, existingLocation: String? = nil,
         incomingLocation: String? = nil, canUndo: Bool = true, bundle: Bundle = .main) {
        self.conflict = conflict
        self.session = session
        self.bundle = bundle
        applyToRemaining = NSButton(checkboxWithTitle: String(localized: "残りのファイルにも適用", bundle: bundle), target: nil, action: nil)
        compareButton = NSButton(title: String(localized: "内容を比較…", bundle: bundle), target: nil, action: nil)
        super.init()
        let name = conflict.incoming.name
        alert.messageText = String(localized: "“\(name)”を置き換えますか？", bundle: bundle)
        let count = conflict.remainingCount
        alert.informativeText = String(localized: "同名の項目: 残り\(count)件", bundle: bundle)
        if conflict.existing.kind == .directory || conflict.incoming.kind == .directory {
            alert.informativeText += "\n" + String(localized: "フォルダは中の項目もすべて置き換えられます。", bundle: bundle)
        }
        if !canUndo { alert.informativeText += "\n" + String(localized: "この操作は取り消せません。", bundle: bundle) }
        alert.addButton(withTitle: String(localized: "置き換える", bundle: bundle))
        alert.addButton(withTitle: String(localized: "スキップ", bundle: bundle))
        alert.addButton(withTitle: String(localized: "キャンセル", bundle: bundle))
        alert.buttons[0].hasDestructiveAction = true
        // Return を習慣的に押しても置き換えない。明示的なクリックかキー操作で選ぶ。
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.buttons[2].keyEquivalent = "\u{1b}"
        let cards = NSStackView(views: [
            Self.card(conflict.existing, title: String(localized: "既存の項目", bundle: bundle), location: existingLocation, bundle: bundle),
            Self.card(conflict.incoming, title: String(localized: "新しい項目", bundle: bundle),
                      location: incomingLocation, bundle: bundle)
        ])
        cards.distribution = .fillEqually
        cards.alignment = .top
        cards.spacing = 16
        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 16
        accessory.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: accessory.widthAnchor).isActive = true
        compareButton.target = self
        compareButton.action = #selector(compareContents(_:))
        if conflict.existing.source != nil || conflict.incoming.source != nil { accessory.addArrangedSubview(compareButton) }
        applyToRemaining.state = .off
        if conflict.allowsBatchChoice && count > 1 { accessory.addArrangedSubview(applyToRemaining) }
        accessory.widthAnchor.constraint(equalToConstant: 540).isActive = true
        accessory.layoutSubtreeIfNeeded()
        accessory.setFrameSize(accessory.fittingSize)
        alert.accessoryView = accessory
        alert.window.autorecalculatesKeyViewLoop = true
        alert.window.initialFirstResponder = alert.buttons[1]
    }

    private static func card(_ item: ArchiveConflictItem, title: String, location: String? = nil, bundle: Bundle) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.fillColor = .controlBackgroundColor
        box.cornerRadius = 10
        box.contentViewMargins = .zero
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        let filename = label(item.name)
        filename.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let type = item.kind == .directory ? UTType.folder : UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: type))
        icon.imageScaling = .scaleProportionallyDown
        let nameRow = NSStackView(views: [icon, filename])
        nameRow.spacing = 8
        nameRow.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)
        icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let kind: String
        switch item.kind {
        case .directory: kind = String(localized: "フォルダ", bundle: bundle)
        case .file: kind = type.localizedDescription ?? String(localized: "ファイル", bundle: bundle)
        default: kind = String(localized: "リンクまたは特殊な項目", bundle: bundle)
        }
        let bytes = item.size.flatMap(Int64.init(exactly:)).map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? String(localized: "—", bundle: bundle)
        let size = item.kind == .directory || item.entryCount > 1
            ? String(format: String(localized: "%lld項目、%@", bundle: bundle), Int64(item.entryCount), bytes) : bytes
        let date = DateFormatter()
        date.locale = bundle.bundleURL.pathExtension == "lproj"
            ? Locale(identifier: bundle.bundleURL.deletingPathExtension().lastPathComponent) : .current
        date.dateStyle = .medium
        date.timeStyle = .short
        let modified = item.modificationDate.map(date.string(from:)) ?? String(localized: "—", bundle: bundle)
        let metadata = NSGridView(views: [
            [label(String(localized: "種類", bundle: bundle)), label(kind)],
            [label(String(localized: "サイズ", bundle: bundle)), label(size)],
            [label(String(localized: "変更日", bundle: bundle)), label(modified)]
        ])
        metadata.columnSpacing = 10
        metadata.rowSpacing = 6
        metadata.xPlacement = .leading
        metadata.rowAlignment = .firstBaseline
        metadata.column(at: 0).width = (0..<3).compactMap {
            metadata.cell(atColumnIndex: 0, rowIndex: $0).contentView?.intrinsicContentSize.width
        }.max() ?? 0
        metadata.column(at: 1).xPlacement = .fill
        metadata.column(at: 0).leadingPadding = 2
        metadata.column(at: 1).trailingPadding = 2
        for row in 0..<3 {
            (metadata.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField)?.textColor = .secondaryLabelColor
        }
        let locationLabel = label(location ?? item.location)
        locationLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, nameRow, metadata, locationLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = box.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4),
            metadata.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4),
            locationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4)
        ])
        return box
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    @objc func compareContents(_ sender: Any?) {
        if let window = preview?.window, window.isVisible { window.makeKeyAndOrderFront(nil); return }
        preview = ArchiveConflictPreview(conflict: conflict, session: session, bundle: bundle)
        preview?.show(on: alert.window)
    }

    func closePreview() { preview?.close(); preview = nil }
}

final class ArchiveConflictPresenter {
    private(set) var prompt: ArchiveConflictPrompt?
    private var continuation: CheckedContinuation<ArchiveConflictDecision, any Error>?

    func response(to conflict: ArchiveImportConflict, on window: NSWindow, session: ArchiveSession,
                  existingLocation: String? = nil,
                  incomingLocation: String? = nil, canUndo: Bool = true, bundle: Bundle = .main) async throws -> ArchiveConflictDecision {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let prompt = ArchiveConflictPrompt(conflict: conflict, session: session, existingLocation: existingLocation,
                                                   incomingLocation: incomingLocation, canUndo: canUndo, bundle: bundle)
                self.prompt = prompt
                self.continuation = continuation
                prompt.alert.beginSheetModal(for: window) { [weak self, weak prompt] response in
                    guard let self, let prompt, self.prompt === prompt else { return }
                    let choice: ArchiveConflictDecision.Choice?
                    switch response {
                    case .alertFirstButtonReturn: choice = .replace
                    case .alertSecondButtonReturn: choice = .skip
                    default: choice = nil
                    }
                    self.finish(choice.map { .init(choice: $0, applyToRemaining: prompt.applyToRemaining.state == .on) })
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    func cancel() { finish(nil) }

    private func finish(_ decision: ArchiveConflictDecision?) {
        guard let prompt else { return }
        self.prompt = nil
        let continuation = self.continuation
        self.continuation = nil
        prompt.closePreview()
        if let parent = prompt.alert.window.sheetParent { parent.endSheet(prompt.alert.window) }
        prompt.alert.window.orderOut(nil)
        if let decision { continuation?.resume(returning: decision) }
        else { continuation?.resume(throwing: CancellationError()) }
    }
}

/// Quick Look を左右に並べる。書庫側だけ読み取り専用の一時コピーへ展開する。
final class ArchiveConflictPreview: NSWindowController, NSWindowDelegate {
    private let materializer: EntryMaterializer
    private let progress = Progress()
    private var task: Task<Void, Never>?
    private var previews: [QLPreviewView] = []
    private(set) var loadedURLs: [URL?] = [nil, nil]
    private let conflict: ArchiveImportConflict
    private let bundle: Bundle

    init(conflict: ArchiveImportConflict, session: ArchiveSession, bundle: Bundle) {
        self.conflict = conflict
        self.bundle = bundle
        materializer = EntryMaterializer(session: session)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = String(localized: "内容の比較", bundle: bundle)
        panel.minSize = NSSize(width: 640, height: 360)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show(on parent: NSWindow) {
        guard let window, let content = window.contentView else { return }
        let columns = NSStackView()
        columns.distribution = .fillEqually
        columns.spacing = 16
        columns.translatesAutoresizingMaskIntoConstraints = false
        var statuses: [NSTextField] = []
        for title in [String(localized: "既存の項目", bundle: bundle), String(localized: "新しい項目", bundle: bundle)] {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            let preview = QLPreviewView(frame: .zero, style: .normal)!
            preview.autostarts = false
            let status = NSTextField(wrappingLabelWithString: String(localized: "プレビューを読み込んでいます…", bundle: bundle))
            status.textColor = .secondaryLabelColor
            let column = NSStackView(views: [heading, preview, status])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 10
            preview.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            status.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            columns.addArrangedSubview(column)
            previews.append(preview)
            statuses.append(status)
        }
        content.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            columns.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            columns.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            columns.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        window.center()
        parent.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        task = Task { [self] in
            for (index, item) in [conflict.existing, conflict.incoming].enumerated() {
                do {
                    try ArchiveImportPlan.checkCancellation(progress)
                    guard let source = item.source else {
                        statuses[index].stringValue = String(localized: "プレビューを表示できません。", bundle: bundle)
                        continue
                    }
                    let url: URL
                    switch source {
                    case .file(let file): url = file
                    case .archive(let payload): url = try await materializer.materialize(payload, progress: progress)
                    }
                    try ArchiveImportPlan.checkCancellation(progress)
                    loadedURLs[index] = url
                    previews[index].previewItem = url as NSURL
                    statuses[index].stringValue = item.name
                } catch {
                    if !Task.isCancelled { statuses[index].stringValue = ArchiveErrorText.describe(error, bundle: bundle) }
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        progress.cancel()
        task?.cancel()
        window?.parent?.removeChildWindow(window!)
        let task = task, materializer = materializer
        self.task = nil
        Task { await task?.value; await materializer.close() }
    }
}
