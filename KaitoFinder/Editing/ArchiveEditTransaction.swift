import Foundation
import GyoshukuKit
import KaitoKit

nonisolated enum ArchiveEditTransaction {
    static func run(plan: ArchiveEditPlan, archive: URL, mode: ArchiveCapabilities.Mode,
                    options: WriterOptions = WriterOptions(), password: String? = nil, progress: Progress,
                    willOpenUpdater: (@Sendable () throws -> Void)? = nil,
                    willPublish: (@Sendable () throws -> Void)? = nil, expectedIdentity: ArchiveSetIdentity? = nil,
                    verifiedOutput: ArchiveVerifiedOutputSink? = nil,
                    sessionReader: sending ArchiveReader? = nil, occupancy: ArchivePathOccupancy.Overlay? = nil) throws -> ArchiveEditResult {
        guard !plan.removals.isEmpty || !plan.renames.isEmpty else {
            return ArchiveEditResult(removedPaths: [], renamedPaths: [])
        }
        let count = plan.removals.count + plan.renames.count
        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: count, additions: [], itemCount: count,
            carriedBytes: ArchiveWriteProgress.carriedBytes(plan.existing, removing: plan.removals.map(\.index)), changesExisting: true))
        let identity = try ArchiveImportTransaction.publish(archive: archive, mode: mode, options: options, password: password, progress: progress,
            ledger: ledger,
            willOpenUpdater: willOpenUpdater, willPublish: willPublish, expectedIdentity: expectedIdentity,
            verifiedOutput: verifiedOutput, sessionReader: sessionReader,
            expectedOutput: .init(existing: plan.existing, removing: plan.removals.map(\.index), renaming: plan.renames, mode: mode)) { updater in
            // 別 reader での照合では updater の index を証明できない。予約前に本人の一覧と照合する。
            try ArchiveStageDiagnostics.measure(.planValidation) {
                try plan.verifyNames(updater.entryNames)
                try plan.validateChanges(entries: plan.existing, occupancy: occupancy)
            }
            try ArchiveImportPlan.checkCancellation(progress)
            if !plan.removals.isEmpty {
                try updater.remove(entriesAt: plan.removals.map(\.index))
                ledger.didCount(plan.removals.count)
            }
            for change in plan.renames {
                try ArchiveImportPlan.checkCancellation(progress)
                try updater.rename(entryAt: change.entry.index, to: change.path)
                ledger.didCount()
            }
        }
        return ArchiveEditResult(removedPaths: plan.removals.map(\.expectedName), renamedPaths: plan.renames.map(\.path), publishedIdentity: identity)
    }
}
