import Foundation

nonisolated enum ArchiveSplitScheduleChoice: Sendable, Equatable {
    case original, mostCommon, single, size(UInt64)

    func schedule(for layout: ArchiveVolumeLayout) throws -> VolumePlan.Schedule {
        switch self {
        case .original: return .explicit(layout.volumes.map(\.length))
        case .mostCommon:
            let counts = Dictionary(grouping: layout.volumes.map(\.length), by: { $0 }).mapValues(\.count)
            // 同数のときは大きいサイズを選び、ディレクトリや列挙の順序に左右されない。
            let size = counts.keys.max { counts[$0]! == counts[$1]! ? $0 < $1 : counts[$0]! < counts[$1]! }!
            return .uniform(size: size)
        case .single: return .single
        case .size(let size):
            guard size >= 64 * 1024, size <= UInt64(Int64.max) else { throw VolumePublishError.invalidPlan }
            return .uniform(size: size)
        }
    }
}
