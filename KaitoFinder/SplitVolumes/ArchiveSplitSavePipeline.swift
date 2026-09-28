import Foundation
import KaitoKit

nonisolated struct ArchiveSplitSaveHooks: Sendable {
    var operations = VolumePublishOperations()
    var coordinationTimeout: TimeInterval = 10
    var fault: @Sendable (VolumePublishStep) throws -> Void = { _ in }
    var willBegin: @Sendable (VolumeSetTarget) throws -> Void = { _ in }
    var didProduceWork: @Sendable (URL) throws -> Void = { _ in }
    var didReadInputBytes: @Sendable (Int) -> Void = { _ in }
    var didPublish: @Sendable (PublishedVolumeSet) -> Void = { _ in }
}

nonisolated struct ArchiveSplitSaveResult: Sendable {
    let published: PublishedVolumeSet
    let reloadFailure: String?
    let recompressedZIP: Bool
    var modificationDate: Date { published.identity.modificationDate }
}

/// Owns the M5 begin / produce / validate / publish sequence for replacement and new sets.
nonisolated enum ArchiveSplitSavePipeline {
    static func run(target: VolumeSetTarget, estimatedLength: UInt64, additionalWorkBytes: UInt64 = 0, plan: ArchiveSaveReplayPlan,
                    password: String?, zipEncryption: ArchiveOutputProjection.ExpectedZipEncryption? = nil,
                    progress: Progress, publication: ArchiveSavePublication?,
                    index: RecoverableWorkIndex, metadataStore: ArchiveVolumeMetadataStore,
                    hooks: ArchiveSplitSaveHooks, willPublish: (@Sendable () throws -> Void)?,
                    keepsPendingChanges: Bool = true, produce: (VolumeSetPublication) throws -> ArchiveSplitWorkProducer.Result) throws
        -> (published: PublishedVolumeSet, recompressedZIP: Bool, mode: ArchiveCapabilities.Mode) {
        var started: VolumeSetPublication?
        do {
            progress.totalUnitCount = Int64(plan.edits.removals.count + plan.edits.renames.count + plan.additions.count + plan.folders.count + 1)
            progress.completedUnitCount = 0
            var target = target
            target.writesVolumeMetadata = true
            try hooks.willBegin(target)
            let options = ReaderOptions.kaitoFinder(password: password)
            let split = try VolumeSetPublication.begin(target, estimatedOutputLength: estimatedLength,
                additionalWorkBytes: additionalWorkBytes, progress: progress,
                index: index, options: options, coordinationTimeout: hooks.coordinationTimeout,
                operations: hooks.operations, metadataStore: metadataStore, fault: { step in
                    if step == .s5 { try publication?.enterSplitBoundary() }
                    try hooks.fault(step)
                })
            started = split
            defer { split.cancel() }
            let produced = try produce(split)
            // S4 が W と同じ byte の巻を計画と照合する。拒否は引き続き S5 より前。
            try hooks.didProduceWork(split.workURL)
            try plan.validate()
            try willPublish?()
            let published = try split.publish(progress: progress) { reader in
                try ArchiveSplitWorkProducer.validate(reader, plan: plan, mode: produced.mode, zipEncryption: zipEncryption)
            }
            hooks.didPublish(published)
            progress.completedUnitCount = progress.totalUnitCount
            return (published, produced.recompressedZIP, produced.mode)
        } catch is CancellationError { throw CancellationError() }
        catch {
            var failure = ArchiveSplitSaveFailure.map(error, staging: started?.stagingURL)
            if failure.kind == .rolledBack, target.layout != nil, let started {
                do { failure.restoredIdentity = try started.restoredInputIdentity() }
                catch { failure = .map(VolumePublishError.rollbackIncomplete(started.stagingURL), staging: started.stagingURL) }
            }
            failure.context = target.layout == nil ? .newSet : (keepsPendingChanges ? .deferredReplacement : .immediateReplacement)
            failure.keepsPendingChanges = keepsPendingChanges
            throw failure
        }
    }
}
