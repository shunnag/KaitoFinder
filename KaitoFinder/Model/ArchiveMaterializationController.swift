import Foundation

/// パネルや NSWorkspace を知らない状態機械。選択・表示 index・要求寿命をここで管理する。
final class ArchiveMaterializationController {
    typealias Materialize = @Sendable (ArchiveEntryPayload, Progress) async throws -> URL
    private let materialize: Materialize
    private(set) var items: [ArchivePreviewItem] = []
    private(set) var currentIndex: Int?
    private(set) var task: Task<Void, Never>?
    private var drainingTask: Task<Void, Never>?
    private var progress: Progress?
    private var revision: UInt64 = 0
    private var ready: ((ArchivePreviewItem) -> Void)?
    var started: ((ArchivePreviewItem, Progress) -> Void)?
    var finished: (() -> Void)?
    var failed: ((String) -> Void)?

    init(materialize: @escaping Materialize) { self.materialize = materialize }

    func setSelection(_ items: [ArchivePreviewItem]) {
        cancel()
        self.items = items
    }

    func item(at index: Int) -> ArchivePreviewItem? {
        items.indices.contains(index) ? items[index] : nil
    }

    func display(index: Int, ready: @escaping (ArchivePreviewItem) -> Void) {
        guard let item = item(at: index) else { cancel(); return }
        if currentIndex == index {
            self.ready = ready
            if item.previewItemURL != nil { ready(item) }
            return
        }
        cancel()
        currentIndex = index
        self.ready = ready
        if let reason = item.capability.reason { failed?("\(item.payload.path): \(reason)"); return }
        if item.previewItemURL != nil { ready(item); return }
        let token = revision
        let progress = Progress(totalUnitCount: 1)
        self.progress = progress
        started?(item, progress)
        let materialize = self.materialize
        let predecessor = drainingTask
        task = Task { [weak self] in
            do {
                // solid 群の取消しが read 内で停止するまで、次の reader を走らせない。
                await predecessor?.value
                if progress.isCancelled || Task.isCancelled { throw CancellationError() }
                let url = try await materialize(item.payload, progress)
                guard let self, self.revision == token, !progress.isCancelled, !Task.isCancelled else {
                    await EntryMaterializer.discard(url)
                    // Cancel ボタンは Progress のみを変更するため、同じ要求ならシートを閉じる。
                    if let self, self.revision == token { self.cancel() }
                    return
                }
                item.publish(url)
                self.task = nil
                self.drainingTask = nil
                self.progress = nil
                self.finished?()
                self.ready?(item)
            } catch {
                guard let self, self.revision == token else { return }
                self.task = nil
                self.progress = nil
                self.finished?()
                if !(error is CancellationError), !progress.isCancelled, !Task.isCancelled {
                    self.failed?("\(item.payload.path): \(error)")
                }
            }
        }
    }

    func cancel() {
        revision &+= 1
        progress?.cancel()
        task?.cancel()
        if let task { drainingTask = task }
        task = nil
        progress = nil
        currentIndex = nil
        ready = nil
        finished?()
    }

    func close() { setSelection([]) }
}
