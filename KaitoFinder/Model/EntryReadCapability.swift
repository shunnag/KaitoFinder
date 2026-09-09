import Foundation
import KaitoKit

/// 一覧のメタデータだけで判定する。可否の照会では stream を開かない。
/// 圧縮データ内で初めて分かる制限・破損は展開時の失敗報告に委ねる。
nonisolated struct EntryReadCapability: Sendable {
    let reason: String?
    var canPreview: Bool { reason == nil }
    var canOpen: Bool { reason == nil }

    init(entry: ArchiveEntry?, isDirectory: Bool, format: ArchiveFormat) {
        if isDirectory || entry?.kind == .directory {
            reason = String(localized: "フォルダはプレビューまたは外部アプリケーションで開けません")
        } else if let entry {
            if entry.isEncrypted {
                reason = String(localized: "暗号化された項目にはパスワードが必要です")
            } else if entry.isIncomplete {
                reason = String(localized: "不完全な項目は内容を検証できないため開けません")
            } else if entry.kind != .file {
                reason = String(localized: "リンクまたは特殊な項目は単独で開けません")
            } else if !Self.supportsMethod(entry, format: format) {
                reason = String(localized: "未対応の圧縮方式です: \(entry.methodDescription)")
            } else {
                do { _ = try ExtractionPath.components(entry.name); reason = nil }
                catch { reason = String(describing: error) }
            }
        } else {
            reason = String(localized: "選択した項目が見つかりません")
        }
    }

    private static func supportsMethod(_ entry: ArchiveEntry, format: ArchiveFormat) -> Bool {
        let method = entry.methodDescription
        // KaitoKit 0.3.0 の公開メタデータと decoder の対応。エンジン追加時はここも更新する。
        switch format {
        case .zip: return ["stored", "deflate", "deflate64", "bzip2", "lzma"].contains(method)
        case .lha:
            return ["-lh0-", "-lh1-", "-lh4-", "-lh5-", "-lh6-", "-lh7-", "-lhx-",
                    "-lz4-", "-lz5-", "-lzs-", "-pm0-"].contains(method)
        case .cab: return ["cab (stored)", "cab (MSZIP)"].contains(method) && entry.formatSpecific["continued"] == nil
        case .xar: return ["xar (stored)", "xar (zlib)", "xar (bzip2)", "xar (lzma)", "xar (xz)"].contains(method)
        case .sevenZip:
            let supported = ["Copy", "LZMA", "LZMA2", "PPMd7", "Deflate", "BZip2", "7zAES-256",
                             "Delta", "BCJ", "ARM", "ARMT", "ARM64", "PPC", "SPARC", "IA64", "BCJ2"]
            return method.isEmpty || method.split(separator: "+").allSatisfy {
                $0.split(separator: ":").first.map { supported.contains(String($0)) } == true
            }
        case .rar:
            if entry.formatSpecific["rarVersion"] == "7", method != "RAR5 stored" { return false }
            return ["stored", "RAR4 fastest", "RAR4 fast", "RAR4 normal", "RAR4 good", "RAR4 best",
                    "RAR5 stored", "RAR5 method 1", "RAR5 method 2", "RAR5 method 3", "RAR5 method 4", "RAR5 method 5"].contains(method)
        default: return true
        }
    }
}
