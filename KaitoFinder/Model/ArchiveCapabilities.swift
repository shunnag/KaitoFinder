import Darwin
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
        case splitArchive
        case unevenSplitArchive
        case nativeSplitArchive
        case mixedVolumes
    }
    let mode: Mode?
    let refusal: Refusal?
    let splitSave: Bool
    let splitIrreversible: Bool

    init(mode: Mode, splitSave: Bool = false, splitIrreversible: Bool = false) {
        self.mode = mode
        self.splitSave = splitSave
        self.splitIrreversible = splitIrreversible
        refusal = nil
    }

    init(refusal: Refusal) {
        mode = nil
        self.refusal = refusal
        splitSave = false
        splitIrreversible = false
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
        // GyoshukuKit の曖昧な終端の門番。理由は他の門番と同じく GyoshukuKit の文言を添える。
        case .gatekeeper(.ambiguousEndRecord, let reason): String(localized: "このアーカイブは変更できません。\(reason)", bundle: bundle)
        case .encrypted: String(localized: "暗号化されたアーカイブを変更するにはパスワードが必要です。", bundle: bundle)
        case .temporaryCopy: String(localized: "一時的なコピーのため変更できません。", bundle: bundle)
        case .splitArchive: String(localized: "分割アーカイブは、設定で「保存時にまとめて書き込む」を選ぶと編集できます。", bundle: bundle)
        case .unevenSplitArchive: String(localized: "巻サイズが揃っていない分割アーカイブは、設定で「保存時にまとめて書き込む」を選ぶと編集できます。", bundle: bundle)
        case .nativeSplitArchive: String(localized: "ZIP本来の分割アーカイブは変更できません。", bundle: bundle)
        case .mixedVolumes: String(localized: "分割アーカイブの巻が混在しています。", bundle: bundle)
        case .unrepresentable(let reason): String(localized: "このアーカイブには、書き直せない項目があります。\(reason)", bundle: bundle)
        case .unavailable(let reason): String(localized: "このアーカイブは変更できません。\(reason)", bundle: bundle)
        }
    }

    /// reader を持たない呼出側向け。従来どおり、形式の判定と書き込み権限を先に確かめてから一度だけ開く
    /// （書き込めない形式・権限のない場所・圧縮 tar の外側の判定に、書庫の解析や一時展開を要しない）。
    static func inspect(url: URL, format: KaitoKit.ArchiveFormat, password: String? = nil) -> Self {
        inspect(url: url, format: format, password: password) {
            try ArchiveReader.open(url: url, options: .kaitoFinder(password: password))
        }
    }

    /// 既に開いた reader から編集可否を導く。書庫を開き直さず、一覧（entries）と形式だけを読む。
    /// ZIP は GyoshukuKit の `ArchiveUpdater.probe`（終端の門番、reader を作らない）で entry 数を照合する。
    /// tar / 7z / LHA は `ArchiveRewriter.probe(entries:format:)` で表現可能性を検査する。
    /// G4 の中央ディレクトリの照合は公開時（`ArchiveUpdater.open`）に行うため、終端の門番を通っても
    /// その照合に失敗する ZIP は、最初の編集で拒否される。reader はスレッドセーフではないので、
    /// 呼出側（ArchiveSession の actor 内）が所有したまま呼ぶ。
    static func inspect(reader: ArchiveReader, url: URL, password: String? = nil,
                        format: KaitoKit.ArchiveFormat? = nil, splitLayout: ArchiveVolumeLayout? = nil,
                        allowsSplitSave: Bool = false, allowsImmediateSplitSave: Bool = false, mixedVolumes: Bool = false) -> Self {
        if ArchiveTemporaryCopy.contains(url) { return Self(refusal: .temporaryCopy) }
        if mixedVolumes { return Self(refusal: .mixedVolumes) }
        if let layout = splitLayout ?? reader.volumeSet.map({ ArchiveVolumeLayout(volumeSet: $0) }) {
            if case .zipSpanned = layout.scheme { return Self(refusal: .nativeSplitArchive) }
            if allowsSplitSave { return inspectSplit(reader: reader, layout: layout, password: password) }
            if allowsImmediateSplitSave {
                let inspected = inspectSplit(reader: reader, layout: layout, password: password)
                guard let mode = inspected.mode else { return inspected }
                guard layout.immediateSchedule != nil else { return Self(refusal: .unevenSplitArchive) }
                return Self(mode: mode, splitSave: true, splitIrreversible: true)
            }
            return Self(refusal: .splitArchive)
        }
        return inspect(url: url, format: format ?? reader.format, password: password) { reader }
    }

    /// Call only after detecting a split set: an ordinary .zip is also parseable as a final ZIP volume.
    static func splitRefusal(for url: URL, scheme: ArchiveVolumeSet.Scheme? = nil) -> Refusal {
        if case .zipSpanned? = scheme ?? ArchiveVolumeSet.parse(fileName: url.lastPathComponent)?.scheme {
            return .nativeSplitArchive
        }
        return .splitArchive
    }

    private static func inspectSplit(reader: ArchiveReader, layout: ArchiveVolumeLayout, password: String?) -> Self {
        guard case .numbered = layout.scheme else { return Self(refusal: .nativeSplitArchive) }
        do {
            let mode: Mode
            switch reader.format {
            case .zip: mode = .inPlace // The joined ZIP's gatekeeper is checked by the W producer.
            case .sevenZip: mode = .rewrite(.sevenZip)
            case .lha: mode = .rewrite(.lha)
            case .tar:
                switch try FormatDetector.detect(url: layout.gateURL) {
                case .tar: mode = .rewrite(.tar)
                case .gzip: mode = .rewrite(.tarGzip)
                case .bzip2: mode = .rewrite(.tarBzip2)
                case .xz: mode = .rewrite(.tarXZ)
                default: return Self(refusal: .format(try FormatDetector.detect(url: layout.gateURL).displayName))
                }
            default: return Self(refusal: .format(reader.format.displayName))
            }
            if reader.entries.contains(where: \.isEncrypted), password == nil { return Self(refusal: .encrypted) }
            let parent = try VolumePublishDirectory(VolumePublishFS.canonicalParent(of: layout.gateURL))
            let expected = try ArchiveSetIdentity.capture(layout: layout)
            do {
                try VolumeSetPublication.checkOldPermissions(.init(parent: parent.url, layout: layout, expected: expected,
                    schedule: .single), parent: parent)
            } catch {
                return Self(refusal: .unavailable(String(localized: "アーカイブまたは親フォルダへの書き込み権限がありません。")))
            }
            let format: GyoshukuKit.ArchiveFormat
            switch mode { case .inPlace: format = .zip; case .rewrite(let output): format = output }
            try ArchiveRewriter.probe(entries: reader.entries, format: format)
            return Self(mode: mode, splitSave: true)
        } catch { return Self(refusal: refusal(for: error)) }
    }

    // 拒否の優先順: 一時コピー → 分割 → 形式（tar は外側の圧縮）→ [ZIP: 暗号化 → 終端の門番] →
    // 書き込み権限 → [書き直し形式: 表現可能性 → 暗号化]。reader は必要になった時点で一度だけ得る。
    private static func inspect(url: URL, format: KaitoKit.ArchiveFormat, password: String?,
                                reader open: () throws -> ArchiveReader) -> Self {
        if ArchiveTemporaryCopy.contains(url) { return Self(refusal: .temporaryCopy) }
        if ArchiveSplitVolume.isSplitVolumeMember(url) { return Self(refusal: splitRefusal(for: url)) }
        do {
            let mode: Mode
            switch format {
            case .zip:
                let reader = try open()
                if let set = reader.volumeSet { return Self(refusal: splitRefusal(for: url, scheme: set.scheme)) }
                if reader.entries.contains(where: \.isEncrypted), password == nil { return Self(refusal: .encrypted) }
                // 従来の updater open と同じ門番と照合。原本が通常ファイルであることも同じ経路で確かめる。
                let probe = try ArchiveUpdater.probe(url: url)
                guard probe.entryCount == UInt64(reader.entries.count) else {
                    throw UpdaterError.invalidArchive("KaitoKit の entry 数と EOCD が一致しません")
                }
                mode = .inPlace
            case .tar:
                // ArchiveReader は圧縮 tar の内側を報告する。外側の判定もエンジンに任せ、
                // skippable frame や tar のファイル名を短い圧縮署名と取り違えない。
                switch try FormatDetector.detect(url: url) {
                case .tar: mode = .rewrite(.tar)
                case .gzip: mode = .rewrite(.tarGzip)
                case .bzip2: mode = .rewrite(.tarBzip2)
                case .xz: mode = .rewrite(.tarXZ)
                case .compress: return Self(refusal: .format("tar.Z"))
                case .zstd: return Self(refusal: .format("tar.zst"))
                case .lz4: return Self(refusal: .format("tar.lz4"))
                case .lzma: return Self(refusal: .format("tar.lzma"))
                case .lzip: return Self(refusal: .format("tar.lz"))
                case .brotli: return Self(refusal: .format("tar.br"))
                default: return Self(refusal: .format(format.displayName))
                }
            case .sevenZip: mode = .rewrite(.sevenZip)
            case .lha: mode = .rewrite(.lha)
            default: return Self(refusal: .format(format.displayName))
            }
            guard FileManager.default.isWritableFile(atPath: url.path),
                  FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                return Self(refusal: .unavailable(String(localized: "アーカイブまたは親フォルダへの書き込み権限がありません。")))
            }
            if case .rewrite(let outputFormat) = mode {
                // 従来の rewriter open と同じく、原本が通常ファイル（symlink でない）であることを確かめてから
                // 全 entry の表現可能性を検査する。ファイルもディレクトリも作らず、書庫も開き直さない。
                var info = stat()
                guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                    throw RewriterError.invalidArchive("通常ファイルではありません")
                }
                let reader = try open()
                if let set = reader.volumeSet { return Self(refusal: splitRefusal(for: url, scheme: set.scheme)) }
                try ArchiveRewriter.probe(entries: reader.entries, format: outputFormat)
                if reader.entries.contains(where: \.isEncrypted), password == nil { return Self(refusal: .encrypted) }
            }
            return Self(mode: mode)
        } catch { return Self(refusal: refusal(for: error)) }
    }

    private static func refusal(for error: any Error) -> Refusal {
        switch error {
        case UpdaterError.editingRefused(let gatekeeper, let reason): .gatekeeper(gatekeeper, reason)
        case RewriterError.password: .encrypted
        // 従来は rewriter open が KaitoError を RewriterError.password に写していた。url 版でも同じ拒否にする。
        case KaitoError.passwordRequired, KaitoError.wrongPassword: .encrypted
        case RewriterError.unrepresentable(let entry, let reason): .unrepresentable("\(entry): \(reason)")
        default: .unavailable(ArchiveErrorText.describe(error))
        }
    }
}
