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
        case temporaryCopy
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

    var canEdit: Bool { refusal == nil }
    var rewriteNotice: String? {
        guard case .rewrite = mode else { return nil }
        return String(localized: "編集するとアーカイブ全体を再圧縮します")
    }
    var readOnlyReason: String? { readOnlyReason(bundle: .main) }

    func readOnlyReason(bundle: Bundle) -> String? {
        switch refusal {
        case nil: nil
        case .format(let name): String(localized: "\(name)アーカイブは変更できません。", bundle: bundle)
        case .gatekeeper(.sfxPrefix, let reason): String(localized: "SFX付きZIPは安全に変更できません。\(reason)", bundle: bundle)
        case .gatekeeper(.trailingData, let reason): String(localized: "このZIPは終端の後ろに追加データがあり、安全に変更できません。\(reason)", bundle: bundle)
        case .gatekeeper(.centralDirectoryOffset, let reason):
            String(localized: "このZIPは中央ディレクトリの位置が不正です。4 GiB超の項目をZIP64なしで格納した場合など、安全に変更できません。\(reason)", bundle: bundle)
        case .encrypted: String(localized: "暗号化されたアーカイブを変更するにはパスワードが必要です。", bundle: bundle)
        case .temporaryCopy: String(localized: "一時的なコピーのため変更できません。", bundle: bundle)
        case .unrepresentable(let reason): String(localized: "このアーカイブには、書き直せない項目があります。\(reason)", bundle: bundle)
        case .unavailable(let reason): String(localized: "このアーカイブは変更できません。\(reason)", bundle: bundle)
        }
    }

    static func inspect(url: URL, format: KaitoKit.ArchiveFormat, password: String? = nil) -> Self {
        if ArchiveTemporaryCopy.contains(url) { return Self(refusal: .temporaryCopy) }
        do {
            let mode: Mode
            switch format {
            case .zip:
                let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
                if reader.entries.contains(where: \.isEncrypted), password == nil { return Self(refusal: .encrypted) }
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
            default: return Self(refusal: .format(format.displayName))
            }
            guard FileManager.default.isWritableFile(atPath: url.path),
                  FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                return Self(refusal: .unavailable(String(localized: "アーカイブまたは親フォルダへの書き込み権限がありません。")))
            }
            if case .rewrite(let outputFormat) = mode {
                // 全 entry の表現可能性を検査するだけで、最初の add / commit まで
                // ファイルもディレクトリも作らない。開いて破棄するのが副作用のない probe。
                let rewriter = try ArchiveRewriter.open(url: url, password: password, output: nil, format: outputFormat)
                if rewriter.hasEncryptedEntries, password == nil { return Self(refusal: .encrypted) }
            }
            return Self(mode: mode)
        } catch UpdaterError.editingRefused(let gatekeeper, let reason) {
            return Self(refusal: .gatekeeper(gatekeeper, reason))
        } catch RewriterError.password {
            return Self(refusal: .encrypted)
        } catch KaitoError.passwordRequired {
            return Self(refusal: .encrypted)
        } catch RewriterError.unrepresentable(let entry, let reason) {
            return Self(refusal: .unrepresentable("\(entry): \(reason)"))
        } catch { return Self(refusal: .unavailable(ArchiveErrorText.describe(error))) }
    }
}
