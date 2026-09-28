import Foundation

nonisolated enum VolumePublishError: Error, Equatable {
    case invalidPlan
    case unsupportedScheme
    case tooManyVolumes(required: UInt64)
    case hazardousVolume(String)
    case insufficientSpace(required: UInt64, available: UInt64)
    case nameOccupied(String)
    case unresolvedPublication(URL)
    case setChanged
    case unsafePath(String)
    case system(Int32)
    case journalUnreadable
    case journalTooLarge
    case ownerAlive
    case coordinationTimedOut
    case validationFailed
    case rollbackIncomplete(URL)
    case alreadyUsed
    case fat32WorkFileTooLarge(length: UInt64)
    case contentMismatch(String)
    case publishedReaderFailed(staging: URL, diagnostic: String)
    case stagedReaderFailed(String)
    case publishedVerificationPending(staging: URL, diagnostic: String)
    case rolledBack(underlying: String, cleanupFailed: String?, disposal: VolumeDisposal)
}

nonisolated extension VolumePublishError: LocalizedError {
    var errorDescription: String? { message() }

    func message(bundle: Bundle = .main) -> String {
        switch self {
        case .fat32WorkFileTooLarge:
            return String(localized: "このアーカイブの作業ファイルはFAT32の上限を超えます。APFSまたはexFATのディスクに保存してください。", bundle: bundle)
        case .insufficientSpace:
            return String(localized: "保存先の空き容量が足りません。空き容量を増やすか、別の場所に保存してください。", bundle: bundle)
        case .nameOccupied:
            return String(localized: "同じ名前の分割ファイルが既にあります。", bundle: bundle)
        case .setChanged:
            return String(localized: "アーカイブが別のアプリで変更されました", bundle: bundle)
        case .unsupportedScheme:
            return String(localized: "ZIP本来の分割アーカイブは変更できません。", bundle: bundle)
        case .tooManyVolumes:
            return String(localized: "分割数が上限（128）を超えるため保存できません。巻サイズを大きくしてください。", bundle: bundle)
        case .ownerAlive, .alreadyUsed:
            return String(localized: "別の保存または回復処理中です。しばらくしてからもう一度保存してください。", bundle: bundle)
        case .coordinationTimedOut:
            return String(localized: "保存のためのファイル調整が時間切れになりました。原本は変更されていません。もう一度保存してください。", bundle: bundle)
        case .rolledBack:
            return String(localized: "保存できなかったため、元の分割アーカイブに戻しました。未保存の変更は保持されています。もう一度保存してください。", bundle: bundle)
        case .rollbackIncomplete, .unresolvedPublication, .publishedReaderFailed, .publishedVerificationPending:
            return String(localized: "分割アーカイブの保存を完了できませんでした。回復するまで編集できません。アーカイブを開き直してください。", bundle: bundle)
        case .journalUnreadable, .journalTooLarge:
            return String(localized: "分割アーカイブの保存が中断されています", bundle: bundle) + "\n"
                + String(localized: "中断した保存を完了して開く", bundle: bundle)
        case .validationFailed, .contentMismatch, .stagedReaderFailed:
            return String(localized: "アーカイブの原本を確認できません。", bundle: bundle) + "\n"
                + String(localized: "保存できませんでした。設定、保存先のアクセス権と空き容量を確認して、もう一度試してください。", bundle: bundle)
        case .invalidPlan, .unsafePath, .system, .hazardousVolume:
            return String(localized: "保存できませんでした。設定、保存先のアクセス権と空き容量を確認して、もう一度試してください。", bundle: bundle)
        }
    }
}
