import Foundation
import Synchronization

nonisolated final class ArchiveProgressCancellation: Sendable {
    private let action: Mutex<(@Sendable (Progress) -> Void)?>

    @MainActor init(progress: Progress, publication: ArchiveSavePublication? = nil,
                    cancel: @escaping @Sendable (Progress) -> Void) {
        action = Mutex(cancel)
        let previous = progress.cancellationHandler
        // Save As の親子が同じ Progress を使う。終了済みの登録は弱参照だけ残す。
        progress.cancellationHandler = { [weak self, weak progress] in
            guard let progress else { return }
            let cancel = {
                previous?()
                self?.cancel(progress)
            }
            // 親 Task への取消しも、公開境界と同じロックの内側で届ける。
            if let publication { publication.cancelBeforePublication(progress: progress, cancel: cancel) }
            else { cancel() }
        }
        if progress.isCancelled {
            if let publication { publication.cancelBeforePublication(progress: progress) { self.cancel(progress) } }
            else { self.cancel(progress) }
        }
    }

    private func cancel(_ progress: Progress) {
        let callback = action.withLock { value in
            let callback = value
            value = nil
            return callback
        }
        if progress.isCancellable { callback?(progress) }
    }

    func invalidate() { action.withLock { $0 = nil } }
}

/// アプリ全体の取消し検査。Progress の取消しと Task の取消しの両方を見る。
/// `ArchiveImportPlan.checkCancellation(_:)` は既存の呼び出し向けの転送。
nonisolated extension Progress {
    func checkCancellation() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }
}
