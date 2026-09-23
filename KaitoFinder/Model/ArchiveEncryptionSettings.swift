import Foundation
import GyoshukuKit
import KaitoKit

/// パスワードはセッションと取り消しスロットのメモリだけに保持する。
nonisolated struct ArchiveEncryptionSettings: Sendable, Equatable {
    var password: String? = nil
    var zipEncryption: ZipEncryption = .aes256
    var encryptsSevenZipHeaders = false

    static func supports(_ format: GyoshukuKit.ArchiveFormat) -> Bool {
        format == .zip || format == .sevenZip
    }

    static func zipMethod(in entries: [ArchiveEntry]) -> ZipEncryption {
        let encrypted = entries.filter(\.isEncrypted)
        return !encrypted.isEmpty && encrypted.allSatisfy {
            $0.formatSpecific["encryption"] == "ZipCrypto" || $0.methodDescription.contains("ZipCrypto")
        } ? .zipCrypto : .aes256
    }

    func applying(to base: WriterOptions, format: GyoshukuKit.ArchiveFormat) -> WriterOptions {
        var options = base
        options.password = Self.supports(format) ? password : nil
        options.zipEncryption = zipEncryption
        options.encryptsSevenZipHeaders = format == .sevenZip && options.password != nil && encryptsSevenZipHeaders
        return options
    }
}

nonisolated enum ArchivePasswordAction: CaseIterable, Sendable {
    case set, change, remove

    var actionName: String {
        switch self {
        case .set: "パスワードの設定"
        case .change: "パスワードの変更"
        case .remove: "パスワードの削除"
        }
    }

    func title(bundle: Bundle = .main) -> String {
        switch self {
        case .set: String(localized: "パスワードを設定…", bundle: bundle)
        case .change: String(localized: "パスワードを変更…", bundle: bundle)
        case .remove: String(localized: "パスワードを削除", bundle: bundle)
        }
    }

    func buttonTitle(bundle: Bundle = .main) -> String {
        switch self {
        case .set: String(localized: "パスワードを設定", bundle: bundle)
        case .change: String(localized: "パスワードを変更", bundle: bundle)
        case .remove: String(localized: "パスワードを削除", bundle: bundle)
        }
    }
}

nonisolated struct ArchivePasswordEditResult: Sendable {
    var reloadFailure: String?
}
