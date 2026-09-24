import AppKit
import Foundation
import GyoshukuKit
import KaitoKit

/// Consent describes one destination and one class of publication hazard.
nonisolated struct ArchiveSplitHazardLocation: Hashable, Sendable {
    let parent: URL
    let volume: String
    let hazard: String
    init?(parent: URL, info: VolumePublishFS.VolumeInfo) {
        guard let hazard = info.hazard else { return nil }
        self.parent = parent.resolvingSymlinksInPath().standardizedFileURL
        volume = info.cacheIdentity
        self.hazard = hazard
    }
}

nonisolated enum VolumeOldDisposalPolicy: String, Codable, Sendable { case trash, remove }

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

/// A successful M2 commit never becomes a failed save because old-volume cleanup failed.
/// Only uncertain publication failures require reopening; proven rollbacks remain retryable.
nonisolated struct ArchiveSplitSaveFailure: LocalizedError, RecoverableError {
    enum Kind: Sendable { case retry, coordination, tooManyVolumes, rolledBack, held, failed }
    enum Context: Sendable { case deferredReplacement, immediateReplacement, newSet }
    var context: Context = .deferredReplacement
    let kind: Kind
    let staging: URL?
    let diagnostic: String
    var keepsPendingChanges = true
    var restoredIdentity: ArchiveSetIdentity? = nil
    var requiresReopen: Bool { kind == .held && context != .newSet }
    var errorDescription: String? {
        if context == .newSet {
            if kind == .rolledBack {
                return String(localized: "新しい分割アーカイブを作成できませんでした。元のアーカイブは変更されていません。もう一度保存してください。")
            }
            if kind == .held {
                return String(localized: "新しい分割アーカイブの作成を完了できませんでした。元のアーカイブは変更されていません。保存先の作業フォルダをFinderで確認してください。")
            }
        }
        if context == .immediateReplacement {
            switch kind {
            case .retry: return String(localized: "別の保存または回復処理中です。しばらくしてからもう一度変更してください。")
            case .coordination: return String(localized: "変更のためのファイル調整が時間切れになりました。原本は変更されていません。もう一度変更してください。")
            case .tooManyVolumes: return String(localized: "分割数が上限（128）を超えるため変更できません。「別名で保存」で巻サイズを大きくしてください。")
            default: break
            }
        }
        return switch kind {
        case .retry: String(localized: "別の保存または回復処理中です。しばらくしてからもう一度保存してください。")
        case .coordination: String(localized: "保存のためのファイル調整が時間切れになりました。原本は変更されていません。もう一度保存してください。")
        case .tooManyVolumes: String(localized: "分割数が上限（128）を超えるため保存できません。巻サイズを大きくしてください。")
        case .rolledBack: keepsPendingChanges ? String(localized: "保存できなかったため、元の分割アーカイブに戻しました。未保存の変更は保持されています。もう一度保存してください。")
            : String(localized: "保存できなかったため、元の分割アーカイブに戻しました。もう一度変更してください。")
        case .held: keepsPendingChanges ? String(localized: "分割アーカイブの保存を完了できませんでした。未保存の変更は保持されています。回復するまで編集できません。アーカイブを開き直してください。")
            : String(localized: "分割アーカイブの保存を完了できませんでした。回復するまで編集できません。アーカイブを開き直してください。")
        case .failed: diagnostic
        }
    }
    var recoveryOptions: [String] {
        staging == nil ? [String(localized: "キャンセル")] : [String(localized: "Finderで表示"), String(localized: "キャンセル")]
    }
    func attemptRecovery(optionIndex: Int) -> Bool {
        if optionIndex == 0, let staging { Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([staging]) } }
        return false
    }

    static func map(_ error: any Error, staging: URL?, context: Context = .deferredReplacement) -> Self {
        let kind: Kind
        var folder: URL?
        switch error {
        case VolumePublishError.ownerAlive: kind = .retry
        case VolumePublishError.coordinationTimedOut: kind = .coordination
        case VolumePublishError.tooManyVolumes: kind = .tooManyVolumes
        case VolumePublishError.rolledBack(_, let cleanupFailure, let disposal):
            kind = .rolledBack
            if case .kept(let url) = disposal { folder = url }
            else if cleanupFailure != nil, let staging, FileManager.default.fileExists(atPath: staging.path) { folder = staging }
        case VolumePublishError.rollbackIncomplete(let url), VolumePublishError.unresolvedPublication(let url),
             VolumePublishError.publishedReaderFailed(let url, _), VolumePublishError.publishedVerificationPending(let url, _):
            kind = .held; folder = url
        case is SimulatedCrash: kind = .held; folder = staging
        default: kind = .failed
        }
        let diagnostic: String
        if case VolumePublishError.nameOccupied = error {
            diagnostic = String(localized: "同じ名前の分割ファイルが既にあります。")
        } else { diagnostic = ArchiveErrorText.describe(error) }
        return Self(context: context, kind: kind, staging: folder, diagnostic: diagnostic)
    }
}

/// Both editing modes use the same result and publication boundary.
nonisolated protocol ArchiveMutationResult: Sendable {
    var reloadFailure: String? { get set }
    var didPublishMutation: Bool { get }
}
nonisolated extension ArchiveImportResult: ArchiveMutationResult {
    var didPublishMutation: Bool { !addedPaths.isEmpty }
}
nonisolated extension ArchiveEditResult: ArchiveMutationResult {
    var didPublishMutation: Bool { published }
}
nonisolated extension ArchivePasswordEditResult: ArchiveMutationResult {
    var didPublishMutation: Bool { true }
}

/// Owns the M5 begin / produce / validate / publish sequence for replacement and new sets.
nonisolated enum ArchiveSplitSavePipeline {
    static func run(target: VolumeSetTarget, estimatedLength: UInt64, plan: ArchiveSaveReplayPlan,
                    password: String?, progress: Progress, publication: ArchiveSavePublication?,
                    index: RecoverableWorkIndex, metadataStore: ArchiveVolumeMetadataStore,
                    hooks: ArchiveSplitSaveHooks, willPublish: (@Sendable () throws -> Void)?,
                    keepsPendingChanges: Bool = true, produce: (VolumeSetPublication) throws -> ArchiveSplitWorkProducer.Result) throws
        -> (published: PublishedVolumeSet, recompressedZIP: Bool) {
        var started: VolumeSetPublication?
        do {
            progress.totalUnitCount = Int64(plan.edits.removals.count + plan.edits.renames.count + plan.additions.count + plan.folders.count + 1)
            progress.completedUnitCount = 0
            var target = target
            target.writesVolumeMetadata = true
            try hooks.willBegin(target)
            let options = ReaderOptions.kaitoFinder(password: password)
            let split = try VolumeSetPublication.begin(target, estimatedOutputLength: estimatedLength, progress: progress,
                index: index, options: options, coordinationTimeout: hooks.coordinationTimeout,
                operations: hooks.operations, metadataStore: metadataStore, fault: { step in
                    if step == .s5 { try publication?.enterSplitBoundary() }
                    try hooks.fault(step)
                })
            started = split
            defer { split.cancel() }
            let produced = try produce(split)
            try ArchiveSplitWorkProducer.validate(ArchiveReader.open(url: split.workURL, options: options), plan: plan)
            try hooks.didProduceWork(split.workURL)
            try plan.validate()
            try willPublish?()
            let published = try split.publish(progress: progress) { reader in
                try ArchiveSplitWorkProducer.validate(reader, plan: plan)
            }
            hooks.didPublish(published)
            progress.completedUnitCount = progress.totalUnitCount
            return (published, produced.recompressedZIP)
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
