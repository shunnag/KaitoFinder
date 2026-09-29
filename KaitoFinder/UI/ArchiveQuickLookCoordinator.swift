import AppKit
import QuickLookUI

/// Quick Look の表示項目と抽出、パネルの制御期間を同期する。
@MainActor final class ArchiveQuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private weak var previewPanel: QLPreviewPanel?
    private var previewMonitor: Task<Void, Never>?
    private(set) var isActive = false
    private let materializationController: () -> ArchiveMaterializationController?
    private let previewItems: () -> [ArchivePreviewItem]
    private let readableSelection: () -> [ArchivePreviewItem]?
    private let controller: () -> AnyObject?
    private let canPreview: () -> Bool
    private let didBecomeKey: () -> Void
    private let forwardKey: (NSEvent) -> Bool
    private var materialization: ArchiveMaterializationController? { materializationController() }

    init(materialization: @escaping () -> ArchiveMaterializationController?,
         previewItems: @escaping () -> [ArchivePreviewItem],
         selection: @escaping () -> [ArchivePreviewItem]?,
         controller: @escaping () -> AnyObject?,
         canPreview: @escaping () -> Bool, didBecomeKey: @escaping () -> Void,
         forwardKey: @escaping (NSEvent) -> Bool) {
        materializationController = materialization
        self.previewItems = previewItems
        readableSelection = selection
        self.controller = controller
        self.canPreview = canPreview
        self.didBecomeKey = didBecomeKey
        self.forwardKey = forwardKey
        super.init()
    }

    func acceptsControl() -> Bool { canPreview() }

    func togglePreviewPanel(_ sender: Any?) {
        if let panel = previewPanel, panel.isVisible { closePreview(); return }
        guard let items = readableSelection() else { return }
        if let first = items.first, first.capability.needsUnlocking, first.previewItemURL == nil, let materialization {
            // 解除を取り消した時に空の QL パネルを残さない。準備完了後に responder を渡す。
            materialization.setSelection(items)
            materialization.display(index: 0) { [weak self] _ in self?.showPreviewPanel(nil) }
        } else { showPreviewPanel(sender) }
    }

    private func showPreviewPanel(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.makeKeyAndOrderFront(sender)
        panel.updateController()
        if previewPanel === panel { updatePreviewSelection(reportingFailures: true); startPreviewMonitoring(panel) }
    }

    func takePreviewControl(_ panel: QLPreviewPanel) {
        previewPanel = panel
        panel.dataSource = self
        panel.delegate = self
        updatePreviewSelection()
        startPreviewMonitoring(panel)
    }

    /// Quick Look パネルの表示項目と開閉を確かめる間隔。
    private nonisolated static let previewPollInterval: Duration = .milliseconds(50)

    private func startPreviewMonitoring(_ panel: QLPreviewPanel) {
        previewMonitor?.cancel()
        // QLPreviewPanel に index 変更の delegate はない。先読み要求の index は採用せず、
        // 公開プロパティを監視する。orderOut による終了も拾い、KVO 通知の有無に依存しない。
        previewMonitor = Task { [weak self, weak panel] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.previewPollInterval)
                guard !Task.isCancelled, let self, let panel, self.previewPanel === panel else { return }
                if panel.isVisible { self.synchronizePreview(panel) }
                else {
                    self.isActive = false
                    self.materialization?.cancel()
                    return
                }
            }
        }
    }

    func releasePreviewControl(_ panel: QLPreviewPanel) {
        guard previewPanel === panel else { return }
        previewMonitor?.cancel()
        previewMonitor = nil
        if isActive { materialization?.setSelection([]) }
        isActive = false
        panel.dataSource = nil
        panel.delegate = nil
        previewPanel = nil
    }

    func closePreview() {
        isActive = false
        previewMonitor?.cancel()
        previewMonitor = nil
        materialization?.cancel()
        if let panel = previewPanel { panel.orderOut(nil) }
    }

    private func updatePreviewSelection(reportingFailures: Bool = false) {
        guard let panel = previewPanel else { return }
        isActive = true
        materialization?.updatePreviewSelection(previewItems(), reportingFailures: reportingFailures)
        panel.reloadData()
        if materialization?.items.isEmpty == false { panel.currentPreviewItemIndex = 0 }
        synchronizePreview(panel)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { materialization?.items.count ?? 0 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        // QL は選択全体を先読みできる。この照会の index で抽出してはいけない。
        Task { @MainActor [weak self, weak panel] in
            guard let self, let panel, self.previewPanel === panel else { return }
            self.synchronizePreview(panel)
        }
        return materialization?.item(at: index)
    }

    private func synchronizePreview(_ panel: QLPreviewPanel) {
        guard isActive, previewPanel === panel, panel.isVisible, panel.currentController as AnyObject? === controller() else { return }
        let index = panel.currentPreviewItemIndex
        guard materialization?.currentIndex != index else { return }
        materialization?.display(index: index) { [weak self, weak panel] item in
            guard let self, let panel, self.isActive, self.previewPanel === panel, panel.isVisible,
                  panel.currentController as AnyObject? === self.controller(),
                  panel.currentPreviewItemIndex == index,
                  self.materialization?.item(at: index) === item else { return }
            QLPreviewPanel.shared().refreshCurrentPreviewItem()
        }
    }

    func selectionDidChange() {
        if previewPanel?.isVisible == true { updatePreviewSelection() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        didBecomeKey()
    }

    func windowWillClose(_ notification: Notification) {
        if let panel = notification.object as? QLPreviewPanel, previewPanel === panel {
            materialization?.cancel()
            materialization?.setSelection([])
        }
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.charactersIgnoringModifiers == " " { closePreview(); return true }
        if event.type == .keyDown,
           event.charactersIgnoringModifiers == "\u{f700}" || event.charactersIgnoringModifiers == "\u{f701}",
           event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
            // 単一選択では panel が矢印を飲み込むので、Finder と同じく一覧へ渡して選択を動かす。
            // 複数選択は panel 内の項目移動のまま。
            return forwardKey(event)
        }
        return false
    }
}
