import Foundation

/// 改名の検証に使う名前の占有索引を背景で準備する。表示中の木・セッション・世代にだけ結び付け、
/// 一覧が差し替わったら捨てる。
final class ArchiveRenameIndex {
    private(set) var task: Task<Void, Never>?
    private(set) var preparedOccupancy: ArchivePathOccupancy.Overlay?
    private(set) var isPrepared = false
    #if DEBUG
    private(set) var readyAt: ContinuousClock.Instant?
    #endif

    /// isStillCurrent は索引の完成時に呼び、表示中の木・セッション・世代が準備を始めたときと同じかを答える。
    func prepare(for root: EntryNode, session: ArchiveSession, generation: UInt64,
                 isStillCurrent: @escaping @MainActor () -> Bool) {
        let entries = root.archiveEntries, format = session.reservationFormat
        task = Task { [weak self] in
            var occupancy: ArchivePathOccupancy.Overlay?
            let snapshot = await session.snapshot()
            if !session.usesPendingReading, snapshot.generation == generation, snapshot.entries.count == entries.count {
                occupancy = await session.prepareNameIndex(generation: generation)?.overlay
            } else { occupancy = await EntryNode.buildRenameOccupancy(from: entries, format: format) }
            defer { ArchiveBackgroundRelease.release(&occupancy) }
            // 公開済みの木は変更せず、同じ木・セッション・世代にだけ結び付ける。
            guard !Task.isCancelled, let self, isStillCurrent(), session.generation == generation else { return }
            self.preparedOccupancy = occupancy
            self.isPrepared = true
            self.task = nil
            #if DEBUG
            self.readyAt = .now
            #endif
            ArchiveReservationDiagnostics.record(.renameIndexReady)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isPrepared = false
        #if DEBUG
        readyAt = nil
        #endif
        ArchiveBackgroundRelease.release(&preparedOccupancy)
    }
}
