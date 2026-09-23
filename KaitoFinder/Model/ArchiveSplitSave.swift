import AppKit
import Foundation
import GyoshukuKit
import KaitoKit

nonisolated struct ArchiveSplitSaveHooks: Sendable {
    var operations = VolumePublishOperations()
    var coordinationTimeout: TimeInterval = 10
    var fault: @Sendable (VolumePublishStep) throws -> Void = { _ in }
    var willBegin: @Sendable (VolumeSetTarget) throws -> Void = { _ in }
    var didProduceWork: @Sendable (URL) throws -> Void = { _ in }
}

nonisolated struct ArchiveSplitSaveResult: Sendable {
    let published: PublishedVolumeSet
    let reloadFailure: String?
    let recompressedZIP: Bool
    var modificationDate: Date {
        let gate = published.identity.volumes[0]
        return Date(timeIntervalSince1970: Double(gate.modificationSeconds) + Double(gate.modificationNanoseconds) / 1_000_000_000)
    }
}

/// A successful M2 commit never becomes a failed save because old-volume cleanup failed.
/// All post-S5 failures keep the pending plan and require reopening before further editing.
nonisolated struct ArchiveSplitSaveFailure: LocalizedError, RecoverableError {
    enum Kind: Sendable { case retry, coordination, tooManyVolumes, rolledBack, held, failed }
    let kind: Kind
    let staging: URL?
    let diagnostic: String
    var requiresReopen: Bool { kind == .held || kind == .rolledBack }
    var errorDescription: String? {
        switch kind {
        case .retry: String(localized: "別の保存または回復処理中です。しばらくしてからもう一度保存してください。")
        case .coordination: String(localized: "保存のためのファイル調整が時間切れになりました。原本は変更されていません。もう一度保存してください。")
        case .tooManyVolumes: String(localized: "分割数が上限（128）を超えるため保存できません。巻サイズを大きくしてください。")
        case .rolledBack: String(localized: "保存できなかったため、元の分割アーカイブに戻しました。未保存の変更は保持されています。編集を続けるには、アーカイブを開き直してください。")
        case .held: String(localized: "分割アーカイブの保存を完了できませんでした。未保存の変更は保持されています。回復するまで編集できません。アーカイブを開き直してください。")
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

    static func map(_ error: any Error, staging: URL?) -> Self {
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
        return Self(kind: kind, staging: folder, diagnostic: ArchiveErrorText.describe(error))
    }
}
