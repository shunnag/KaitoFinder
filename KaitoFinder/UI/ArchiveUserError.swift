import Foundation

/// UI が利用者へ提示する NSError。ドメイン値はテスト（ReadOnlyDropConversionUITests）が照合するため変更しない。
nonisolated enum ArchiveUserError {
    static let creationDomain = "com.shunnag.KaitoFinder.creation"
    static let passwordDomain = "com.shunnag.KaitoFinder.password"

    /// アーカイブ作成・保存パネルの検証エラー。code は既定の 1 のほか、名前の衝突で 2 を使う。
    static func creation(_ description: String, code: Int = 1, failureReason: String? = nil) -> NSError {
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
        if let failureReason { userInfo[NSLocalizedFailureReasonErrorKey] = failureReason }
        return NSError(domain: creationDomain, code: code, userInfo: userInfo)
    }

    /// パスワード入力欄の検証エラー。
    static func password(_ description: String) -> NSError {
        NSError(domain: passwordDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
