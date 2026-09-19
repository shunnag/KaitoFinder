import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// 文書の一時領域を借りるが、Quick Look パネルとは要求・取消し・表示寿命を共有しない。
final class ArchivePreviewSidebar: NSViewController {
    enum State { case empty, unavailable, locked, awaitingLoad, loading, ready, failed }

    // 矢印キーだけで巨大な一時コピーや solid ブロックの再展開を行わない。明示操作で読む。
    static let automaticPreviewLimit: UInt64 = 64 * 1024 * 1024

    private let bundle: Bundle
    private(set) var state: State = .empty
    private(set) var materialization: ArchiveMaterializationController?
    private(set) var previewView: QLPreviewView?
    private(set) var selectedItem: ArchivePreviewItem?
    private let previewContainer = NSView()
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let symbol = NSImageView()
    private let symbolContainer = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    private let spinner = NSProgressIndicator()
    private let actionButton = NSButton()
    private let placeholder = NSStackView()
    private let messageScrollView = NSScrollView()

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        background.material = .contentBackground
        background.blendingMode = .withinWindow
        view = background
        view.identifier = NSUserInterfaceItemIdentifier("archive.preview-sidebar")
        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [nameLabel, detailLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        heading.setHuggingPriority(.required, for: .vertical)
        heading.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        let divider = NSBox()
        divider.boxType = .separator
        for child in [heading, divider, previewContainer] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            heading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            nameLabel.widthAnchor.constraint(equalTo: heading.widthAnchor, constant: -4),
            detailLabel.widthAnchor.constraint(equalTo: heading.widthAnchor, constant: -4),
            divider.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            previewContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            previewContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            previewContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        symbol.contentTintColor = .tertiaryLabelColor
        symbol.imageScaling = .scaleProportionallyDown
        symbol.frame = symbolContainer.bounds
        symbol.autoresizingMask = [.width, .height]
        symbolContainer.addSubview(symbol)
        symbolContainer.widthAnchor.constraint(equalToConstant: 40).isActive = true
        symbolContainer.heightAnchor.constraint(equalToConstant: 40).isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(performPreviewAction(_:))
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 12
        placeholder.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        for child in [symbolContainer, spinner, messageLabel, actionButton] { placeholder.addArrangedSubview(child) }
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        let messageContent = ArchivePreviewMessageContent()
        messageContent.translatesAutoresizingMaskIntoConstraints = false
        messageScrollView.hasVerticalScroller = true
        messageScrollView.autohidesScrollers = true
        messageScrollView.drawsBackground = false
        messageScrollView.documentView = messageContent
        messageScrollView.frame = previewContainer.bounds
        messageScrollView.autoresizingMask = [.width, .height]
        previewContainer.addSubview(messageScrollView)
        messageContent.addSubview(placeholder)
        let preferredHeight = messageContent.heightAnchor.constraint(equalTo: messageScrollView.contentView.heightAnchor)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            messageContent.widthAnchor.constraint(equalTo: messageScrollView.contentView.widthAnchor),
            messageContent.heightAnchor.constraint(greaterThanOrEqualTo: messageScrollView.contentView.heightAnchor),
            preferredHeight,
            placeholder.leadingAnchor.constraint(equalTo: messageContent.leadingAnchor, constant: 20),
            placeholder.trailingAnchor.constraint(equalTo: messageContent.trailingAnchor, constant: -20),
            placeholder.centerYAnchor.constraint(equalTo: messageContent.centerYAnchor),
            placeholder.topAnchor.constraint(greaterThanOrEqualTo: messageContent.topAnchor, constant: 16),
            placeholder.bottomAnchor.constraint(lessThanOrEqualTo: messageContent.bottomAnchor, constant: -16),
            messageLabel.widthAnchor.constraint(equalTo: placeholder.widthAnchor, constant: -4)
        ])
        reset()
    }

    func configure(materialization: ArchiveMaterializationController?) {
        reset()
        self.materialization?.close()
        self.materialization = materialization
        materialization?.started = { [weak self] _, _ in
            guard let self else { return }
            self.showMessage(String(localized: "プレビューを読み込んでいます…", bundle: self.bundle),
                             state: .loading, symbol: "doc", action: true)
        }
        materialization?.finished = { [weak self] in
            guard let self, self.state == .loading else { return }
            self.showMessage(String(localized: "キャンセルされました", bundle: self.bundle),
                             state: .failed, symbol: "doc", action: true)
        }
        materialization?.failed = { [weak self] reason in
            self?.showMessage(reason, state: .failed, symbol: "exclamationmark.triangle", action: true)
        }
    }

    func display(_ nodes: [EntryNode], session: ArchiveSession, generation: UInt64) {
        loadViewIfNeeded()
        let item = nodes.count == 1 ? nodes.first.map { node in
            ArchivePreviewItem(payload: ArchiveEntryPayload(node: node, archiveURL: session.sourceURL, generation: generation),
                capability: EntryReadCapability(entry: node.entry, isDirectory: node.isDirectory, format: session.format, bundle: bundle),
                requiresProgress: false)
        } : nil
        // 同じ選択の再通知やソートで、動画・ページ位置や読み込みを巻き戻さない。
        if let item, item.payload == selectedItem?.payload { return }
        reset()
        guard let item, let node = nodes.first else { return }
        selectedItem = item
        nameLabel.stringValue = node.name
        nameLabel.toolTip = node.path
        let type = node.isDirectory ? UTType.folder : UTType(filenameExtension: (node.name as NSString).pathExtension)
        var details = [type?.localizedDescription].compactMap { $0 }
        if let size = node.size, let count = Int64(exactly: size), !node.isDirectory {
            details.append(ByteCountFormatter.string(fromByteCount: count, countStyle: .file))
        }
        detailLabel.stringValue = details.joined(separator: " · ")
        if let reason = item.capability.reason {
            showMessage(reason, state: .unavailable, symbol: node.isDirectory ? "folder" : "doc.badge.ellipsis")
        } else if item.capability.needsUnlocking && materialization?.cachedItem(for: item.payload) == nil {
            showMessage(String(localized: "パスワードを入力すると内容を表示できます。", bundle: bundle),
                        state: .locked, symbol: "lock", action: true)
        } else if (node.entry?.solidGroup ?? -1) >= 0 || node.size == nil || node.size! > Self.automaticPreviewLimit {
            showMessage(String(localized: "大きなファイルです。プレビューを表示するには読み込みが必要です。", bundle: bundle),
                        state: .awaitingLoad, symbol: "doc.badge.ellipsis", action: true)
        } else {
            loadSelection()
        }
    }

    /// 非表示にした時点で抽出と再生を止める。公開済みコピーは文書を閉じるまで再利用できる。
    func reset() {
        selectedItem = nil
        materialization?.setSelection([])
        closePreviewView()
        guard isViewLoaded else { state = .empty; return }
        nameLabel.stringValue = String(localized: "プレビュー", bundle: bundle)
        nameLabel.toolTip = nil
        detailLabel.stringValue = ""
        showMessage(String(localized: "ファイルを1つ選択するとプレビューが表示されます。", bundle: bundle),
                    state: .empty, symbol: "doc.viewfinder")
    }

    func close() {
        reset()
        materialization?.close()
        materialization = nil
    }

    private func closePreviewView() {
        previewView?.previewItem = nil
        previewView?.close()
        previewView?.removeFromSuperview()
        previewView = nil
    }

    private func showMessage(_ message: String, state: State, symbol: String, action: Bool = false) {
        self.state = state
        closePreviewView()
        messageScrollView.isHidden = false
        messageLabel.stringValue = message
        messageLabel.toolTip = message
        self.symbol.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 32, weight: .regular))
        messageScrollView.documentView?.scroll(.zero)
        symbolContainer.isHidden = state == .loading
        spinner.isHidden = state != .loading
        if state == .loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        actionButton.isHidden = !action
        actionButton.title = state == .loading ? String(localized: "キャンセル", bundle: bundle)
            : state == .locked ? String(localized: "ロックを解除…", bundle: bundle)
            : String(localized: "プレビューを表示", bundle: bundle)
    }

    @objc private func performPreviewAction(_ sender: Any?) {
        if state == .loading { materialization?.cancel() }
        else { loadSelection() }
    }

    private func loadSelection() {
        guard let selectedItem, selectedItem.capability.canPreview, let materialization else { return }
        materialization.setSelection([selectedItem])
        materialization.display(index: 0) { [weak self] item in
            guard let self, self.selectedItem?.payload == item.payload else { return }
            self.state = .ready
            self.spinner.stopAnimation(nil)
            self.messageScrollView.isHidden = true
            let preview = QLPreviewView(frame: self.previewContainer.bounds, style: .compact)!
            preview.autoresizingMask = [.width, .height]
            preview.autostarts = false
            self.previewContainer.addSubview(preview)
            self.previewView = preview
            preview.previewItem = item
        }
    }

}

private final class ArchivePreviewMessageContent: NSView {
    override var isFlipped: Bool { true }
}
