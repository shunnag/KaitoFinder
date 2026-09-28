import AppKit
import Foundation

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

/// A successful M2 commit never becomes a failed save because old-volume cleanup failed.
/// Only uncertain publication failures require reopening; proven rollbacks remain retryable.
/// Save-time sibling of `ArchiveVolumeOpenError` (Documents/ArchiveVolumeOpenRecovery.swift): both are
/// LocalizedError + RecoverableError and point at a staging with 「Finderで表示」. This one reports a failed save;
/// that one is raised when opening a set whose earlier save was interrupted, and completes it before reopening.
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
