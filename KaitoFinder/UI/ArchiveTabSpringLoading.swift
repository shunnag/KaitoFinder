import AppKit

/// 公開の tab accessory を足場にし、標準タブ全体にドラッグ専用の領域を重ねる。
/// 通常の hit testing と accessibility は AppKit のタブへ通す。
final class ArchiveTabSpringLoading: NSView {
    private let destination: ArchiveTabDragDestination

    init(window: NSWindow) {
        destination = ArchiveTabDragDestination(target: window)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 0), heightAnchor.constraint(equalToConstant: 0)])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attachDestination() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attachDestination() }

    private func attachDestination() {
        var ancestor = superview
        while let view = ancestor, view.accessibilityRole() != .radioButton { ancestor = view.superview }
        guard window != nil, let tab = ancestor else { destination.removeFromSuperview(); return }
        guard destination.superview !== tab else { return }
        destination.removeFromSuperview()
        destination.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(destination)
        NSLayoutConstraint.activate([
            destination.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
            destination.trailingAnchor.constraint(equalTo: tab.trailingAnchor),
            destination.topAnchor.constraint(equalTo: tab.topAnchor),
            destination.bottomAnchor.constraint(equalTo: tab.bottomAnchor)
        ])
    }
}

private final class ArchiveTabDragDestination: NSView, NSSpringLoadingDestination {
    private weak var target: NSWindow?
    private var hoverTimer: Timer?
    private var draggingInfo: (any NSDraggingInfo)?

    init(target: NSWindow) {
        self.target = target
        super.init(frame: .zero)
        setAccessibilityElement(false)
        registerForDraggedTypes(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + [.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ info: any NSDraggingInfo) -> NSDragOperation {
        return draggingUpdated(info)
    }
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingUpdated(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard canActivate(for: info) else { cancelHover(); return [] }
        let startsHover = draggingInfo?.draggingSequenceNumber != info.draggingSequenceNumber
        if startsHover { cancelHover() }
        draggingInfo = info
        if startsHover {
            let timer = Timer(timeInterval: 0.6, target: self, selector: #selector(activateHoveredTab), userInfo: nil, repeats: false)
            hoverTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { cancelHover() }
    override func draggingEnded(_ sender: any NSDraggingInfo) { cancelHover() }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { cancelHover(); return false }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview !== superview { cancelHover() }
        super.viewWillMove(toSuperview: newSuperview)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelHover() }
    }

    private func cancelHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        draggingInfo = nil
    }

    @objc private func activateHoveredTab() {
        guard let info = draggingInfo else { cancelHover(); return }
        activate(for: info)
    }

    private func activate(for info: any NSDraggingInfo) {
        let destination = canActivate(for: info) ? target : nil
        cancelHover()
        if let destination { destination.tabGroup?.selectedWindow = destination }
    }

    func springLoadingEntered(_ info: any NSDraggingInfo) -> NSSpringLoadingOptions { springLoadingUpdated(info) }

    func springLoadingUpdated(_ info: any NSDraggingInfo) -> NSSpringLoadingOptions {
        // ホバーは静止中も動く common-mode timer、Force Touch は標準の機構を使う。
        canActivate(for: info) ? [.enabled, .noHover] : .disabled
    }

    private func canActivate(for info: any NSDraggingInfo) -> Bool {
        guard let target, let group = target.tabGroup, group.windows.count > 1,
              window?.tabGroup === group, info.draggingDestinationWindow === window,
              bounds.contains(convert(info.draggingLocation, from: nil)),
              group.isTabBarVisible, !group.isOverviewVisible, group.selectedWindow !== target,
              group.selectedWindow?.attachedSheet == nil, target.attachedSheet == nil,
              (target.windowController as? ArchiveWindowController)?.canReceiveTabDrag == true,
              info.draggingSourceOperationMask.contains(.copy),
              ArchiveIncomingPasteboard.representation(AppKitArchivePasteboard(pasteboard: info.draggingPasteboard)) != .none
        else { return false }
        return true
    }

    func springLoadingActivated(_ activated: Bool, draggingInfo info: any NSDraggingInfo) {
        if activated { activate(for: info) }
    }

    func springLoadingHighlightChanged(_ info: any NSDraggingInfo) {}
}
