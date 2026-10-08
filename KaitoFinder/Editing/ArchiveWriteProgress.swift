import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization

/// 1 回の直列の編集操作の進捗。byte の進捗は各枠の予算に対する割合としてだけ使い、項目数に byte の予算は含めない。
nonisolated final class ArchiveWriteProgress: Sendable {
    struct Plan: Sendable {
        var counted: Int
        var additions: [UInt64]
        var itemCount: Int
        var carriedBytes: UInt64
        var changesExisting: Bool
        var countsCarriedItems = false
    }

    enum Branch: Sendable {
        case writer(GyoshukuKit.ArchiveFormat)
        case updater(GyoshukuKit.ArchiveFormat, processesAdditionsAtCommit: Bool)
        case rewriter(GyoshukuKit.ArchiveFormat, readsAdditionsDuringCommit: Bool)
    }

    enum Slot: Sendable, Hashable { case addition(Int), finishAdditions, commit }

    #if DEBUG
    static let didCreditForTesting = TaskLocal<(@Sendable (Slot, Int64, Int64) -> Void)?>(wrappedValue: nil)
    enum Lifecycle: Sendable { case began, reset, published }
    // PROBE-PROGRESS 用の正確な始点と終点。公開前の検証にかかる時間も含む。
    static let lifecycleForTesting = TaskLocal<(@Sendable (Lifecycle) -> Void)?>(wrappedValue: nil)
    #endif

    struct Snapshot: Sendable {
        let completed: Int64
        let total: Int64
        let items: Int
    }

    private struct State {
        var additions: [Int64] = []
        var finish: Int64 = 0
        var commit: Int64 = 0
        var counted: Int64 = 0
        var completed: Int64 = 0
        var total: Int64 = 1
        var items = 0
        var carried = 0
        var lastFinishedAddition = -1
        var active: Slot?
        var credited: Int64 = 0
        var begun = false

        var snapshot: Snapshot { .init(completed: completed, total: total, items: items) }

        func budget(_ slot: Slot) -> Int64 {
            switch slot {
            case .addition(let index): additions[index]
            case .finishAdditions: finish
            case .commit: commit
            }
        }

        mutating func enter(_ slot: Slot) {
            guard active != slot else { return }
            if let active { completed += budget(active) - credited }
            active = slot
            credited = 0
        }
    }

    private let progress: Progress
    private let plan: Plan
    private let state: Mutex<State>

    init(progress: Progress, plan: Plan) {
        precondition(plan.counted >= 0 && plan.itemCount >= 0)
        self.progress = progress
        self.plan = plan
        let total = Int64(clamping: Self.sum([UInt64(plan.counted), UInt64(plan.additions.count), 1]))
        state = Mutex(State(total: total))
        progress.completedUnitCount = 0
        progress.totalUnitCount = total
        progress.setUserInfoObject(plan.itemCount, forKey: .fileTotalCountKey)
        progress.setUserInfoObject(0, forKey: .fileCompletedCountKey)
    }

    var snapshot: Snapshot { state.withLock { $0.snapshot } }

    func begin(_ branch: Branch, archiveBytes: UInt64, options: WriterOptions) {
        let next = state.withLock { value -> Snapshot in
            precondition(!value.begun && value.completed == 0)
            let format: GyoshukuKit.ArchiveFormat
            let deferred: Bool
            let drains: Bool
            var commit: UInt64 = 0
            let added = Self.sum(plan.additions)
            switch branch {
            case .writer(let f):
                (format, deferred, drains) = (f, false, true)
            case .updater(let f, let atCommit):
                (format, deferred, drains) = (f, false, !atCommit && [.zip, .lha, .sevenZip].contains(f))
                let existing = plan.changesExisting ? archiveBytes : 0
                commit = max(1_000, (f.isTarFamily && f != .tar || f == .lha) ? Self.sum([added, existing]) : existing)
            case .rewriter(let f, let reads):
                (format, deferred, drains) = (f, reads, false)
                let pending = min(Self.sum([plan.carriedBytes, added]), options.maximumPendingInputBytes(for: f))
                commit = max(1_000, Self.sum([plan.carriedBytes, reads ? added : 0, pending]))
            }
            // メタデータ上の合計が Int64 で表せないほど大きくても、公開の分を残しておく。
            var available = Int64.max - 1
            func allocate(_ bytes: UInt64) -> Int64 {
                let units = min(available, Int64(clamping: bytes))
                available -= units
                return units
            }
            value.counted = allocate(UInt64(plan.counted))
            value.additions = plan.additions.map { allocate(deferred ? 1 : max(1, $0)) }
            value.finish = allocate(drains && added > 0 ? max(1, min(added, options.maximumPendingInputBytes(for: format))) : 0)
            value.commit = allocate(commit)
            value.total = Int64.max - available
            value.begun = true
            return value.snapshot
        }
        progress.totalUnitCount = next.total
        #if DEBUG
        Self.lifecycleForTesting.get()?(.began)
        #endif
    }

    func addition(_ index: Int) -> (ArchiveUpdater.CommitProgress) throws -> Void {
        { try self.credit(.addition(index), completed: $0.completedBytes, total: $0.totalBytes) }
    }

    var finishAdditions: (ArchiveUpdater.CommitProgress) throws -> Void {
        { try self.credit(.finishAdditions, completed: $0.completedBytes, total: $0.totalBytes) }
    }

    var commit: (ArchiveUpdater.CommitProgress) throws -> Void {
        { try self.credit(.commit, completed: $0.completedBytes, total: $0.totalBytes) }
    }

    func credit(_ slot: Slot, completed: UInt64, total: UInt64) throws {
        try ArchiveImportPlan.checkCancellation(progress)
        let next = update { value in
            value.enter(slot)
            let budget = value.budget(slot)
            let units: Int64
            // Double(Int64.max) は切り上がって Int64 の範囲外になるため、その値を Int64 へ変換しない。
            if total == 0 || completed >= total { units = budget }
            else {
                let mapped = Double(budget) * (Double(completed) / Double(total))
                units = mapped >= Double(budget) ? budget : Int64(mapped)
            }
            let credited = max(value.credited, units)
            value.completed += credited - value.credited
            value.credited = credited
        }
        #if DEBUG
        Self.didCreditForTesting.get()?(slot, next.completed, next.total)
        #endif
    }

    func didFinishAddition(_ index: Int) {
        update { value in
            guard index > value.lastFinishedAddition else { return }
            value.enter(.addition(index))
            value.completed += value.budget(.addition(index)) - value.credited
            value.credited = value.budget(.addition(index))
            value.lastFinishedAddition = index
            value.items = min(plan.itemCount, value.items + 1)
        }
    }

    func didCount(_ n: Int = 1) {
        precondition(n >= 0)
        update { value in
            let units = min(value.counted, Int64(n))
            value.completed += units
            value.counted -= units
            value.items = min(plan.itemCount, value.items + n)
        }
    }

    func didCarry(_ done: Int, _ total: Int) {
        guard plan.countsCarriedItems else { return }
        update { value in
            let next = max(value.carried, min(done, total))
            value.items = min(plan.itemCount, value.items + next - value.carried)
            value.carried = next
        }
    }

    func didPublish() {
        update { value in
            value.completed = value.total
            value.items = plan.itemCount
        }
        #if DEBUG
        Self.lifecycleForTesting.get()?(.published)
        #endif
    }

    func reset() {
        state.withLock { $0 = State(total: $0.total) }
        progress.completedUnitCount = 0
        progress.setUserInfoObject(0, forKey: .fileCompletedCountKey)
        #if DEBUG
        Self.lifecycleForTesting.get()?(.reset)
        #endif
    }

    @discardableResult private func update(_ body: (inout State) -> Void) -> Snapshot {
        let (before, after) = state.withLock { value in
            let before = value.snapshot
            body(&value)
            assert(value.completed >= before.completed && value.completed <= value.total)
            return (before, value.snapshot)
        }
        // GyoshukuKit は editor の thread で同期的に呼ぶ。KVO や hook をまたいで state のロックを持たない。
        if after.completed != before.completed { progress.completedUnitCount = after.completed }
        if after.items != before.items { progress.setUserInfoObject(after.items, forKey: .fileCompletedCountKey) }
        return after
    }

    static func sum<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt64 {
        bytes.reduce(0) { partial, value in
            let next = partial.addingReportingOverflow(value)
            return next.overflow ? .max : next.partialValue
        }
    }

    static func carriedBytes(_ entries: [ArchiveEntry], removing: [Int] = []) -> UInt64 {
        let removed = Set(removing)
        return sum(entries.lazy.filter { !removed.contains($0.index) && $0.pendingID == nil }.map { $0.uncompressedSize ?? 0 })
    }
}
