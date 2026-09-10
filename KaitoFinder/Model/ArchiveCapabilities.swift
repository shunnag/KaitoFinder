import Foundation
import KaitoKit
import GyoshukuKit

nonisolated struct ArchiveCapabilities: Sendable {
    enum Refusal: Sendable, Equatable {
        case format(String)
        case gatekeeper(UpdateGatekeeper, String)
        case unavailable(String)
    }
    let refusal: Refusal?
    var canAppend: Bool { refusal == nil }
    var canDelete: Bool { false }
    var canRename: Bool { false }
    var canEditAttributes: Bool { false }
    var readOnlyReason: String? {
        switch refusal {
        case nil: nil
        case .format(let name): "\(name) 書庫は変更できません"
        case .gatekeeper(.sfxPrefix, let reason): "SFX 付き ZIP は安全に変更できません。\(reason)"
        case .gatekeeper(.trailingData, let reason): "この ZIP は終端の後ろに追加データがあり、安全に変更できません。\(reason)"
        case .gatekeeper(.centralDirectoryOffset, let reason):
            "この ZIP は中央ディレクトリの位置が不正です。4 GiB 超の項目を ZIP64 なしで格納した場合など、安全に変更できません。\(reason)"
        case .unavailable(let reason): "この書庫は変更できません。\(reason)"
        }
    }

    // open は検査のみ。最初の add まで updater は作業ファイルを作らない。
    static func inspect(url: URL, format: KaitoKit.ArchiveFormat) -> Self {
        guard format == .zip else { return Self(refusal: .format(format.rawValue.uppercased())) }
        do {
            _ = try ArchiveUpdater.open(url: url)
            guard FileManager.default.isWritableFile(atPath: url.path),
                  FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                return Self(refusal: .unavailable("書庫または親フォルダへの書き込み権限がありません"))
            }
            return Self(refusal: nil)
        } catch UpdaterError.editingRefused(let gatekeeper, let reason) {
            return Self(refusal: .gatekeeper(gatekeeper, reason))
        } catch { return Self(refusal: .unavailable(String(describing: error))) }
    }
}
