import Foundation
import KaitoKit
import GyoshukuKit

nonisolated struct ArchiveCapabilities: Sendable {
    enum Mode: Sendable, Equatable {
        case inPlace
        case rewrite(GyoshukuKit.ArchiveFormat)
    }

    enum Refusal: Sendable, Equatable {
        case format(String)
        case gatekeeper(UpdateGatekeeper, String)
        case encrypted
        case unrepresentable(String)
        case unavailable(String)
    }
    let mode: Mode?
    let refusal: Refusal?

    init(mode: Mode) {
        self.mode = mode
        refusal = nil
    }

    init(refusal: Refusal) {
        mode = nil
        self.refusal = refusal
    }

    var canAppend: Bool { refusal == nil }
    var canDelete: Bool { false }
    var canRename: Bool { false }
    var canEditAttributes: Bool { false }
    var rewriteNotice: String? {
        guard case .rewrite = mode else { return nil }
        return String(localized: "編集すると書庫全体を再圧縮します")
    }
    var readOnlyReason: String? {
        switch refusal {
        case nil: nil
        case .format(let name): "\(name) 書庫は変更できません"
        case .gatekeeper(.sfxPrefix, let reason): "SFX 付き ZIP は安全に変更できません。\(reason)"
        case .gatekeeper(.trailingData, let reason): "この ZIP は終端の後ろに追加データがあり、安全に変更できません。\(reason)"
        case .gatekeeper(.centralDirectoryOffset, let reason):
            "この ZIP は中央ディレクトリの位置が不正です。4 GiB 超の項目を ZIP64 なしで格納した場合など、安全に変更できません。\(reason)"
        case .encrypted: String(localized: "暗号化された書庫は、編集すると暗号化が外れるため変更できません")
        case .unrepresentable(let reason): String(localized: "この書庫には、書き直せない項目があります。\(reason)")
        case .unavailable(let reason): "この書庫は変更できません。\(reason)"
        }
    }

    static func inspect(url: URL, format: KaitoKit.ArchiveFormat) -> Self {
        do {
            let mode: Mode
            switch format {
            case .zip:
                // open は検査のみ。最初の add まで updater は作業ファイルを作らない。
                _ = try ArchiveUpdater.open(url: url)
                mode = .inPlace
            case .tar:
                // KaitoKit は tgz も tar と報告する。拡張子でなく外側の magic を調べる。
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let magic = try file.read(upToCount: 6) ?? Data()
                let unsupported: [([UInt8], String)] = [
                    ([0x42, 0x5a, 0x68], "tar.bz2"),
                    ([0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00], "tar.xz"),
                    ([0x1f, 0x9d], "tar.Z"),
                    ([0x28, 0xb5, 0x2f, 0xfd], "tar.zst"),
                    ([0x5d, 0x00, 0x00], "tar.lzma")
                ]
                if let (_, name) = unsupported.first(where: { magic.starts(with: $0.0) }) {
                    return Self(refusal: .format(name))
                }
                mode = .rewrite(magic.starts(with: [0x1f, 0x8b]) ? .tarGzip : .tar)
            case .sevenZip: mode = .rewrite(.sevenZip)
            case .lha: mode = .rewrite(.lha)
            default: return Self(refusal: .format(format.rawValue.uppercased()))
            }
            guard FileManager.default.isWritableFile(atPath: url.path),
                  FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                return Self(refusal: .unavailable("書庫または親フォルダへの書き込み権限がありません"))
            }
            if case .rewrite(let outputFormat) = mode {
                // 全 entry の表現可能性を検査するだけで、最初の add / commit まで
                // ファイルもディレクトリも作らない。開いて破棄するのが副作用のない probe。
                let rewriter = try ArchiveRewriter.open(url: url, output: nil, format: outputFormat)
                guard !rewriter.hasEncryptedEntries else { return Self(refusal: .encrypted) }
            }
            return Self(mode: mode)
        } catch UpdaterError.editingRefused(let gatekeeper, let reason) {
            return Self(refusal: .gatekeeper(gatekeeper, reason))
        } catch RewriterError.password {
            return Self(refusal: .encrypted)
        } catch RewriterError.unrepresentable(let entry, let reason) {
            return Self(refusal: .unrepresentable("\(entry): \(reason)"))
        } catch { return Self(refusal: .unavailable(String(describing: error))) }
    }
}
