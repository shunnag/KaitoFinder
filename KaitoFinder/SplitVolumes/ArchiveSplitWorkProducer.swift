import Darwin
import Foundation
import GyoshukuKit
import KaitoKit

nonisolated enum ArchiveSplitWorkProducer {
    struct Result: Sendable {
        let recompressedZIP: Bool
        let mode: ArchiveCapabilities.Mode
    }

    /// Produces a complete single archive W. The verifier is called BEFORE any pending edit is replayed.
    /// Overwrite passes publication.verifyAssembledInput; a new-set caller can pass source.verify.
    static func produce(source: ArchiveVolumeInput, workURL: URL, mode: ArchiveCapabilities.Mode,
                        password: String?, options: WriterOptions, plan: ArchiveSaveReplayPlan,
                        progress: Progress, verifyAssembledInput: (ArchiveVolumeSet?) throws -> Void) throws -> Result {
        try plan.validate()
        switch mode {
        case .inPlace:
            let baseTotal = progress.totalUnitCount, baseCompleted = progress.completedUnitCount
            try source.copy(to: workURL, progress: progress)
            let updater: ArchiveUpdater
            do { updater = try ArchiveStageDiagnostics.measure(.updaterOpen) { try ArchiveUpdater.open(url: workURL, options: options) } }
            catch let error as UpdaterError where isStructuralRefusal(error) {
                try FileManager.default.removeItem(at: workURL)
                try rewrite(source: source, workURL: workURL, format: .zip, password: password, options: options,
                            plan: plan, progress: progress, verifyAssembledInput: verifyAssembledInput)
                return Result(recompressedZIP: true, mode: .rewrite(.zip))
            }
            let meter = ArchiveReencryptionProgress(progress)
            if plan.outputEncryption != nil { progress.totalUnitCount += ArchiveReencryptionProgress.units }
            try ArchiveStageDiagnostics.measure(.replay) { try plan.replay(on: updater, sourcePassword: password, progress: progress) }
            try ArchiveImportPlan.checkCancellation(progress)
            do {
                try ArchiveStageDiagnostics.measure(.commit) {
                    #if DEBUG
                    try ArchiveImportTransaction.willCommitUpdaterForTesting.get()?()
                    #endif
                    try updater.commit(progress: plan.outputEncryption == nil ? nil : meter.update)
                }
            } catch UpdaterError.nonRelocatableEntry where plan.outputEncryption != nil {
                try FileManager.default.removeItem(at: workURL)
                progress.totalUnitCount = baseTotal
                progress.completedUnitCount = baseCompleted
                try rewrite(source: source, workURL: workURL, format: .zip, password: password, options: options,
                            plan: plan, progress: progress, verifyAssembledInput: verifyAssembledInput)
                return Result(recompressedZIP: true, mode: .rewrite(.zip))
            }
            #if DEBUG
            try ArchiveImportTransaction.didCommitUpdaterForTesting.get()?(updater)
            #endif
        case .update: throw ArchiveEditError.staleSelection
        case .rewrite(let format):
            try rewrite(source: source, workURL: workURL, format: format, password: password, options: options,
                        plan: plan, progress: progress, verifyAssembledInput: verifyAssembledInput)
        }
        return Result(recompressedZIP: false, mode: mode)
    }

    private static func isStructuralRefusal(_ error: UpdaterError) -> Bool {
        switch error {
        case .editingRefused, .invalidArchive, .nonRelocatableEntry: true
        case .invalidEntryIndex, .sourceChanged, .invalidState, .reencryptionFailed: false
        }
    }

    static func produce(existing: ArchiveCreationPlan.Existing, workURL: URL,
                        format: GyoshukuKit.ArchiveFormat, options: WriterOptions,
                        plan: ArchiveSaveReplayPlan, progress: Progress, didRead: (Int) -> Void = { _ in }) throws -> Result {
        let expected = try existing.identity ?? ArchiveSetIdentity.capture(url: existing.url, layout: existing.volumeLayout)
        if let layout = existing.volumeLayout, case .numbered = layout.scheme {
            let input = try ArchiveVolumeInput(layout: layout, expected: expected)
            let joined = workURL.deletingLastPathComponent().appendingPathComponent("input-" + UUID().uuidString + "-" + layout.gateURL.deletingPathExtension().lastPathComponent)
            defer { try? FileManager.default.removeItem(at: joined) }
            try input.copy(to: joined, progress: progress, didRead: didRead)
            try rewrite(sourceURL: joined, workURL: workURL, format: format, password: existing.password,
                options: options, plan: plan, progress: progress) { set in
                    guard set == nil else { throw VolumePublishError.setChanged }
                    try input.verify(nil, requiresAssembledSet: false, checkCancellation: { try ArchiveImportPlan.checkCancellation(progress) })
                }
            try input.verify(nil, requiresAssembledSet: false, checkCancellation: { try ArchiveImportPlan.checkCancellation(progress) })
            return Result(recompressedZIP: false, mode: .rewrite(format))
        }
        func verify(_ set: ArchiveVolumeSet?) throws {
            if let set {
                guard ArchiveSetIdentity(volumeSet: set) == expected else { throw VolumePublishError.setChanged }
            } else if expected.volumes.count != 1 { throw VolumePublishError.setChanged }
            guard try ArchiveSetIdentity.capture(url: existing.url, layout: existing.volumeLayout) == expected else {
                throw VolumePublishError.setChanged
            }
        }
        try plan.validate()
        try rewrite(sourceURL: existing.url, workURL: workURL, format: format, password: existing.password,
                    options: options, plan: plan, progress: progress, verifyAssembledInput: verify)
        return Result(recompressedZIP: false, mode: .rewrite(format))
    }

    private static func rewrite(source: ArchiveVolumeInput, workURL: URL, format: GyoshukuKit.ArchiveFormat,
                                password: String?, options: WriterOptions, plan: ArchiveSaveReplayPlan,
                                progress: Progress, verifyAssembledInput: (ArchiveVolumeSet?) throws -> Void) throws {
        try rewrite(sourceURL: source.layout.gateURL, workURL: workURL, format: format, password: password,
                    options: options, plan: plan, progress: progress) { set in
            try ArchiveImportPlan.checkCancellation(progress)
            try verifyAssembledInput(set)
        }
    }

    private static func rewrite(sourceURL: URL, workURL: URL, format: GyoshukuKit.ArchiveFormat,
                                password: String?, options: WriterOptions, plan: ArchiveSaveReplayPlan,
                                progress: Progress, verifyAssembledInput: (ArchiveVolumeSet?) throws -> Void) throws {
        let rewriter = try ArchiveStageDiagnostics.measure(.rewriterOpen) {
            try ArchiveRewriter.open(url: sourceURL, password: password, output: workURL, format: format, options: options)
        }
        try verifyAssembledInput(rewriter.volumeSet)
        try ArchiveStageDiagnostics.measure(.replay) {
            try plan.replay(on: rewriter, progress: progress,
                            preservingOwnerIDs: options.preserveOwnerIDs && [.tar, .tarGzip, .tarBzip2, .tarXZ].contains(format))
        }
        progress.totalUnitCount += Int64(rewriter.entryNames.count)
        try ArchiveStageDiagnostics.measure(.commit) {
            try rewriter.commit { _, _ in
                progress.completedUnitCount += 1
                try ArchiveImportPlan.checkCancellation(progress)
            }
        }
    }

    static func validate(_ reader: ArchiveReader, plan: ArchiveSaveReplayPlan, mode: ArchiveCapabilities.Mode,
                         zipEncryption: ArchiveOutputProjection.ExpectedZipEncryption? = nil) throws {
        try ArchiveOutputProjection(plan: plan, mode: mode, zipEncryption: zipEncryption).validate(reader)
    }
}
