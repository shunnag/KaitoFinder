import Foundation
import KaitoKit

nonisolated enum ArchivePasswordChallenge: Equatable, Sendable {
    case required, incorrect

    init?(_ error: any Error) {
        switch error as? KaitoError {
        case .passwordRequired: self = .required
        case .wrongPassword: self = .incorrect
        default: return nil
        }
    }

    func message(bundle: Bundle = .main) -> String {
        switch self {
        case .required: String(localized: "アーカイブのパスワードを入力してください。", bundle: bundle)
        case .incorrect: String(localized: "パスワードが違います。もう一度入力してください。", bundle: bundle)
        }
    }
}
