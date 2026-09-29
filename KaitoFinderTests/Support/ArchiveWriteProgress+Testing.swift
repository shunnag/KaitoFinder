import Foundation
@testable public import KaitoFinder

extension ArchiveWriteProgress {
    /// テストの計画にも本番と同じ進捗の台帳を使う。
    nonisolated static func forTesting(progress: Progress = Progress(), plan: Plan) -> ArchiveWriteProgress {
        ArchiveWriteProgress(progress: progress, plan: plan)
    }
}
