import Foundation
import Synchronization

/// 単一ファイルでも rename から文書の同期完了までは終了期限と取消しを越える。
nonisolated final class ArchiveSavePublication: Sendable {
    // 即時編集の子 Task も、保存と同じ公開境界を共有する。
    static let current = TaskLocal<ArchiveSavePublication?>(wrappedValue: nil)
    private struct State {
        var lease: VolumePublishCriticalSection.Lease?
        var published = false
    }
    private let state = Mutex(State())
    private let cancellationLock = NSRecursiveLock()
    let counter: VolumePublishCriticalSection
    init(counter: VolumePublishCriticalSection = .shared) { self.counter = counter }
    var hasPublishedBoundary: Bool { state.withLock { $0.published } }
    func enter(progress: Progress) throws {
        try cancellationLock.withLock {
            try state.withLock {
                $0.lease = try counter.enter { try ArchiveImportPlan.checkCancellation(progress) }
                $0.published = true
                progress.isCancellable = false
            }
        }
    }
    func enterSplitBoundary() throws {
        try cancellationLock.withLock {
            try state.withLock {
                $0.lease = try counter.enter()
                $0.published = true
            }
        }
    }
    func cancelBeforePublication(progress: Progress, cancel: () -> Void) {
        // 子 Task の取消しハンドラが再入しても、公開境界とは直列にする。
        cancellationLock.withLock {
            guard !hasPublishedBoundary, progress.isCancellable else { return }
            if !progress.isCancelled { progress.cancel() }
            cancel()
        }
    }

    @MainActor func watchCancellation(progress: Progress, cancel: @escaping @Sendable () -> Void) -> ArchiveProgressCancellation {
        ArchiveProgressCancellation(progress: progress, publication: self) { _ in cancel() }
    }

    func finish() { state.withLock { $0.lease = nil } }
}
