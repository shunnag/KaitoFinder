import AppKit
import QuartzCore
import UniformTypeIdentifiers

private final class WelcomeSymbolView: NSImageView {
    // SF Symbol のベースライン用余白によって、固定のアイコン枠が拡張されるのを防ぐ。
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
}

/// ファイルの受け入れ、クリック、キーボード、VoiceOver を同じ操作へ結び付ける。
final class WelcomeDropZoneView: NSView {
    enum Kind { case open, create }

    let kind: Kind
    let headingLabel: NSTextField
    let captionLabel: NSTextField
    let symbolView: NSImageView = WelcomeSymbolView()
    var canAcceptDrop: () -> Bool = { true }
    private let archiveTypes: [UTType]
    private let clickAction: () -> Void
    private let dropAction: ([URL]) -> Void
    private var tracking: NSTrackingArea?
    private var mouseDownLocation: NSPoint?
    private var mouseMovedSignificantly = false
    private var isHovered = false
    private var isReceivingDrag = false
    private(set) var isDragHighlighted = false

    init(kind: Kind, bundle: Bundle = .main,
         archiveTypes: [UTType] = ArchiveBatchExtractionController.archiveContentTypes(),
         clickAction: @escaping () -> Void, dropAction: @escaping ([URL]) -> Void) {
        self.kind = kind
        self.archiveTypes = archiveTypes
        self.clickAction = clickAction
        self.dropAction = dropAction
        let heading = kind == .open ? String(localized: "アーカイブを開く", bundle: bundle)
            : String(localized: "アーカイブを作成", bundle: bundle)
        let caption = kind == .open ? String(localized: "アーカイブをここにドロップ、またはクリックして選択", bundle: bundle)
            : String(localized: "ファイルやフォルダをここにドロップ、またはクリックして選択", bundle: bundle)
        headingLabel = NSTextField(wrappingLabelWithString: heading)
        captionLabel = NSTextField(wrappingLabelWithString: caption)
        super.init(frame: .zero)
        identifier = .init(kind == .open ? "welcome.open" : "welcome.create")
        wantsLayer = true
        focusRingType = .exterior
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(heading)
        setAccessibilityHelp(caption)
        setAccessibilityChildren([])

        symbolView.image = NSImage(systemSymbolName: kind == .open ? "archivebox" : "doc.badge.plus",
                                   accessibilityDescription: nil)
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        symbolView.contentTintColor = .secondaryLabelColor
        symbolView.imageScaling = .scaleProportionallyDown
        headingLabel.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .bold)
        captionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        captionLabel.textColor = .secondaryLabelColor
        for label in [headingLabel, captionLabel] {
            label.alignment = .center
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.preferredMaxLayoutWidth = 272
        }
        let content = NSStackView(views: [symbolView, headingLabel, captionLabel])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 10
        content.setCustomSpacing(8, after: headingLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
            symbolView.widthAnchor.constraint(equalToConstant: 52),
            symbolView.heightAnchor.constraint(equalToConstant: 52),
            // ラベルの alignment rect 外側にある描画余白も、親ビュー内へ収める。
            headingLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -4),
            captionLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -4)
        ])
        // 一行の訳も二行分を確保し、左右のアイコンと見出しの高さをそろえる。
        let lineHeight = NSLayoutManager().defaultLineHeight(for: captionLabel.font!)
        captionLabel.heightAnchor.constraint(equalToConstant: ceil(lineHeight) * 2 + 2).isActive = true
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { isHovered = false; updateAppearance() }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownLocation = event.locationInWindow
        mouseMovedSignificantly = false
    }

    override func mouseDragged(with event: NSEvent) {
        if let start = mouseDownLocation, distance(from: start, to: event.locationInWindow) > 4 {
            mouseMovedSignificantly = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard let start = mouseDownLocation, !mouseMovedSignificantly,
              distance(from: start, to: event.locationInWindow) <= 4,
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        clickAction()
    }

    private func distance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }

    override func keyDown(with event: NSEvent) {
        if [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? ""),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if !event.isARepeat { clickAction() }
        } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool { clickAction(); return true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    private var borderPath: NSBezierPath {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 16, yRadius: 16)
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { borderPath.fill() }

    override func draw(_ dirtyRect: NSRect) {
        let path = borderPath
        let hover = isHovered && !isReceivingDrag
        let fill = isDragHighlighted ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.quaternaryLabelColor.withAlphaComponent(hover ? 0.12 : 0.06)
        fill.setFill()
        path.fill()
        (isDragHighlighted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.lineWidth = 2
        if !isDragHighlighted { path.setLineDash([6, 5], count: 2, phase: 0) }
        path.stroke()
    }

    private func updateAppearance() {
        let accented = isDragHighlighted || (isHovered && !isReceivingDrag)
        symbolView.contentTintColor = accented ? .controlAccentColor : .secondaryLabelColor
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
            .applying(.init(hierarchicalColor: accented ? .controlAccentColor : .secondaryLabelColor))
        needsDisplay = true
    }

    private func setDragHighlight(_ highlighted: Bool) {
        if isDragHighlighted != highlighted, let layer {
            let scale: CGFloat = highlighted ? 1.02 : 1
            // NSView のレイアウト寸法を変えず、レイヤーの中心を基準に拡大する。
            let offsetX = bounds.width * (0.5 - layer.anchorPoint.x)
            let offsetY = bounds.height * (0.5 - layer.anchorPoint.y)
            let transform = CATransform3DMakeAffineTransform(CGAffineTransform(translationX: offsetX, y: offsetY)
                .scaledBy(x: scale, y: scale).translatedBy(x: -offsetX, y: -offsetY))
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let animation = CABasicAnimation(keyPath: "transform")
                animation.fromValue = layer.presentation()?.transform ?? layer.transform
                animation.toValue = transform
                animation.duration = 0.12
                layer.add(animation, forKey: "welcome.drag")
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = transform
            CATransaction.commit()
        }
        isDragHighlighted = highlighted
        updateAppearance()
    }

    private func acceptedURLs(from info: any NSDraggingInfo) -> [URL]? {
        guard info.draggingSourceOperationMask.contains(.copy),
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL], accepts(urls) else { return nil }
        return urls
    }

    /// ペーストボードの取得と分け、実在ファイルの型・混在の判定だけでも検証できる。
    func accepts(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        if kind == .open {
            return urls.allSatisfy { url in
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey]),
                      values.isDirectory == false, let type = values.contentType else { return false }
                return archiveTypes.contains { type.conforms(to: $0) }
            }
        }
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        isReceivingDrag = true
        let accepted = canAcceptDrop() && acceptedURLs(from: sender) != nil
        setDragHighlight(accepted)
        return accepted ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { finishDrag() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { finishDrag() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canAcceptDrop() && acceptedURLs(from: sender) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { finishDrag() }
        guard canAcceptDrop(), let urls = acceptedURLs(from: sender) else { return false }
        dropAction(urls)
        return true
    }

    private func finishDrag() {
        isReceivingDrag = false
        setDragHighlight(false)
    }
}
