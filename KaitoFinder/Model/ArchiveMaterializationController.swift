import Foundation

/// パネルや NSWorkspace を知らない状態機械。選択・表示 index・要求寿命をここで管理する。
final class ArchiveMaterializationController {
    typealias Materialize = @Sendable (ArchiveEntryPayload, Progress) async throws -> URL
    private let materialize: Materialize
    private let dispose: @Sendable () async -> Void
    private var cache: [ArchiveEntryPayload: ArchivePreviewItem] = [:]
    private var cleanupTask: Task<Void, Never>?
    private var closed = false
    private var reportsFailures = true
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

    init(dispose: @escaping @Sendable () async -> Void = {}, materialize: @escaping Materialize) {
        self.materialize = materialize
        self.dispose = dispose
    }

    convenience init(session: ArchiveSession, temporaryDirectory: ExtractionTemporaryDirectory = ExtractionTemporaryDirectory()) {
        let worker = EntryMaterializer(session: session, temporaryDirectory: temporaryDirectory)
        self.init(dispose: { await worker.close() }) { payload, progress in
            try await worker.materialize(payload, progress: progress)
        }
    }

    func cachedItem(for payload: ArchiveEntryPayload) -> ArchivePreviewItem? { cache[payload] }

    func setSelection(_ items: [ArchivePreviewItem], reportingFailures: Bool = true) {
        guard !closed else { return }
        cancel()
        reportsFailures = reportingFailures
        self.items = items.map { cache[$0.payload] ?? $0 }
    }

    /// パネルを開いたままの選択変更は、読めない行を空の表示にして通知を積まない。
    func updatePreviewSelection(_ items: [ArchivePreviewItem], reportingFailures: Bool = false) {
        setSelection(items.allSatisfy { $0.capability.canPreview } ? items : [], reportingFailures: reportingFailures)
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
        if let reason = item.capability.reason {
            if reportsFailures { failed?("\(item.payload.path): \(reason)") }
            return
        }
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
                self.cache[item.payload] = item
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
                if self.reportsFailures, !(error is CancellationError), !progress.isCancelled, !Task.isCancelled {
                    let reason = (error as? EntryReadCapability.Refusal)?.message() ?? String(describing: error)
                    self.failed?("\(item.payload.path): \(reason)")
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

    @discardableResult func close() -> Task<Void, Never> {
        if let cleanupTask { return cleanupTask }
        closed = true
        cancel()
        items = []
        let urls = cache.values.compactMap(\.previewItemURL)
        cache.removeAll()
        let draining = drainingTask
        drainingTask = nil
        let dispose = dispose
        let cleanup = Task {
            // 取消しを無視して遅れて返る結果の破棄まで待ち、動いている writer と削除を競合させない。
            await draining?.value
            for url in urls { await EntryMaterializer.discard(url) }
            await dispose()
        }
        cleanupTask = cleanup
        return cleanup
    }
}
