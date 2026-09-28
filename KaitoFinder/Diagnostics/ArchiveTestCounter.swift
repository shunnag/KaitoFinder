#if DEBUG
import Synchronization

nonisolated final class ArchiveTestCounter: Sendable {
    private let storage = Atomic<Int>(0)
    var value: Int { storage.load(ordering: .relaxed) }
    func increment() { storage.wrappingAdd(1, ordering: .relaxed) }
}

/// テストが製品コードの経路の回数を数えるための TaskLocal。nil のままなら製品コードは何もしない。
/// 各カウンタを増やす製品側の場所:
/// - `editPlanKeys`: `ArchiveEditPlan.key(_:)`（Editing/ArchiveEditPlan.swift）
/// - `slowRepresentability`: `ArchiveSaveReplayPlan.validateRepresentability`（Editing/ArchiveSaveReplayPlan.swift）
/// - `mainThreadFilters`: main thread で計算した `EntryTreeFilter`（Model/Listing/EntryTree.swift）
/// - `splitInputHashes`: 分割入力の全文 hash（SplitVolumes/ArchiveVolumeInput.swift）
/// - `asciiNameMatches`: Foundation を使わずに決めた `EntryNameMatcher.matches`（Model/Listing/EntryNameMatcher.swift）
nonisolated enum ArchiveTestCounters {
    static let editPlanKeys = TaskLocal<ArchiveTestCounter?>(wrappedValue: nil)
    static let slowRepresentability = TaskLocal<ArchiveTestCounter?>(wrappedValue: nil)
    static let mainThreadFilters = TaskLocal<ArchiveTestCounter?>(wrappedValue: nil)
    static let splitInputHashes = TaskLocal<ArchiveTestCounter?>(wrappedValue: nil)
    static let asciiNameMatches = TaskLocal<ArchiveTestCounter?>(wrappedValue: nil)
}
#endif
