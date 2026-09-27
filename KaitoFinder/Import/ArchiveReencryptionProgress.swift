import Foundation
import GyoshukuKit

/// replay の件数と公開の一単位の間に、commit の仕事量を割り当てる。
nonisolated final class ArchiveReencryptionProgress {
    static let units: Int64 = 1_000
    private let progress: Progress
    private var completed: Int64 = 0

    init(_ progress: Progress) { self.progress = progress }

    func update(_ value: ArchiveUpdater.CommitProgress) throws {
        try ArchiveImportPlan.checkCancellation(progress)
        let units = value.totalBytes == 0 ? Self.units
            : Int64(min(1, Double(value.completedBytes) / Double(value.totalBytes)) * Double(Self.units))
        let next = max(completed, units)
        progress.completedUnitCount += next - completed
        completed = next
    }
}
