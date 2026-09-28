import Foundation

nonisolated struct ArchivePublicationError: Error, Equatable, LocalizedError, CustomNSError {
    static let verificationFailed = Self(reason: nil)
    let reason: ArchiveVerificationFailure?
    // 診断の詳細は利用者向けの error の同値性と NSError に混ぜない。
    static func == (lhs: Self, rhs: Self) -> Bool { true }
    static var errorDomain: String { "KaitoFinder.ArchivePublicationError" }
    var errorCode: Int { 0 }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message()] }

    var errorDescription: String? { message() }

    func message(bundle: Bundle = .main) -> String {
        String(localized: "変更後のアーカイブを検証できなかったため、保存を中止しました。元のアーカイブは変更されていません。", bundle: bundle)
    }
}

nonisolated enum ArchiveEditError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case invalidName(String)
    case collision(String)
    case sameLocation(String)
    case destinationInsideSource(String)
    case missingFolder(String)
    case indexMismatch(Int)
    case staleSelection
    case archiveChanged
    case splitArchive
    case conflictingSelection

    var description: String { errorDescription! }

    var errorDescription: String? {
        switch self {
        case .invalidName(let name): String(localized: "この名前には変更できません: \(name)。")
        case .collision(let name): String(localized: "同じ名前の項目が既にあります: \(name)。")
        case .sameLocation(let path): String(localized: "同じ場所です: \(path)。")
        case .destinationInsideSource(let path): String(localized: "フォルダを自分自身の中へは移動できません: \(path)。")
        case .missingFolder(let folder): String(localized: "移動先のフォルダが見つかりません: \(folder)。")
        case .indexMismatch: String(localized: "選択した項目とアーカイブ内の項目が一致しません。アーカイブを開き直してください。")
        case .staleSelection: String(localized: "選択した項目が変更されています。アーカイブを開き直してください。")
        case .archiveChanged: String(localized: "アーカイブが変更されています。開き直してください。")
        case .splitArchive: ArchiveCapabilities(refusal: .splitArchive).readOnlyReason
        case .conflictingSelection: String(localized: "同じ項目への変更が重複しています。")
        }
    }
}
