#if DEBUG
import Synchronization

nonisolated final class ArchiveTestCounter: Sendable {
    private let storage = Atomic<Int>(0)
    var value: Int { storage.load(ordering: .relaxed) }
    func increment() { storage.wrappingAdd(1, ordering: .relaxed) }
}

nonisolated enum ArchiveTestCounters {
    static let keys = TaskLocal<ArchiveTestCounter?>(wrappedValue: nil)
    static let slowRepresentability = TaskLocal<ArchiveTestCounter?>(wrappedValue: nil)
    static let mainThreadFilters = TaskLocal<ArchiveTestCounter?>(wrappedValue: nil)
    static let splitInputHashes = TaskLocal<ArchiveTestCounter?>(wrappedValue: nil)
}
#endif
