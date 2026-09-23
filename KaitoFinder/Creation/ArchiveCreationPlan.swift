import Foundation
import GyoshukuKit
import KaitoKit

/// 新規作成と形式変換は、追加元を常に書庫 root に置く一回限りの操作。
nonisolated struct ArchiveCreationPlan: Sendable {
    struct Existing: Sendable {
        let url: URL
        let password: String?
        let entries: [ArchiveEntry]
        var identity: ArchiveSetIdentity? = nil
        var volumeLayout: ArchiveVolumeLayout? = nil
        var encryption: ArchiveEncryptionSettings? = nil
        var pending: ArchiveSaveReplayPlan? = nil
        var publication: ArchiveSavePublication? = nil
    }

    let sources: [URL]
    let destination: URL
    let format: GyoshukuKit.ArchiveFormat
    let options: WriterOptions
    let existing: Existing?
    let importOptions: ArchiveImportPlan.Options

    init(sources: [URL], destination: URL, format: GyoshukuKit.ArchiveFormat,
         options: WriterOptions = WriterOptions(), existing: Existing? = nil,
         importOptions: ArchiveImportPlan.Options = .init()) {
        self.sources = sources
        self.destination = destination
        self.format = format
        self.options = options
        self.existing = existing
        self.importOptions = importOptions
    }

    static func filenameExtension(for format: GyoshukuKit.ArchiveFormat) -> String {
        switch format {
        case .zip: "zip"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarXZ: "tar.xz"
        case .sevenZip: "7z"
        case .lha: "lzh"
        }
    }

    static func acceptedExtensions(for format: GyoshukuKit.ArchiveFormat) -> [String] {
        switch format {
        case .zip: ["zip"]
        case .tar: ["tar"]
        case .tarGzip: ["tar.gz", "tgz"]
        case .tarBzip2: ["tar.bz2", "tbz2", "tbz"]
        case .tarXZ: ["tar.xz", "txz"]
        case .sevenZip: ["7z"]
        case .lha: ["lzh", "lha"]
        }
    }

    static func hasAcceptedExtension(_ url: URL, for format: GyoshukuKit.ArchiveFormat) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return acceptedExtensions(for: format).contains { name.hasSuffix("." + $0) }
    }

    static func defaultName(for sources: [URL], format: GyoshukuKit.ArchiveFormat) -> String {
        let name = sources.count == 1 ? sources[0].lastPathComponent : String(localized: "アーカイブ")
        return name + "." + filenameExtension(for: format)
    }

    static func conversionName(for archive: URL, format: GyoshukuKit.ArchiveFormat) -> String {
        archiveStem(for: archive) + "." + filenameExtension(for: format)
    }

    static func archiveStem(for archive: URL) -> String {
        let name = archive.lastPathComponent
        // 二重拡張子も一つのアーカイブ拡張子として外し、形式変換と一括展開で共有する。
        let wrappers = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz4", "tar.lzma", "tar.Z"]
        let stem: String
        if let suffix = wrappers.first(where: { name.lowercased().hasSuffix("." + $0.lowercased()) }) {
            stem = String(name.dropLast(suffix.count + 1))
        } else { stem = archive.deletingPathExtension().lastPathComponent }
        return stem.isEmpty ? String(localized: "アーカイブ") : stem
    }
}
