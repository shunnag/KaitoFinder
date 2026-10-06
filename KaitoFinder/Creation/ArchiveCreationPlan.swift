import Darwin
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
        var quarantine: Data? = nil
    }

    let sources: [URL]
    let destination: URL
    let format: GyoshukuKit.ArchiveFormat
    let singleStreamFormat: SingleStreamFormat?
    let options: WriterOptions
    let existing: Existing?
    let importOptions: ArchiveImportPlan.Options
    var splitSchedule: VolumePlan.Schedule? = nil
    var allowHazardousVolume = false

    init(sources: [URL], destination: URL, format: GyoshukuKit.ArchiveFormat,
         options: WriterOptions = WriterOptions(), existing: Existing? = nil,
         importOptions: ArchiveImportPlan.Options = .init(), singleStreamFormat: SingleStreamFormat? = nil) {
        self.sources = sources
        self.destination = destination
        self.format = format
        self.singleStreamFormat = singleStreamFormat
        self.options = options
        self.existing = existing
        self.importOptions = importOptions
    }

    /// lstat でリンクを辿らず、パッケージも単独 stream の候補から外す。
    static func canCompressSingleFile(_ sources: [URL]) -> Bool {
        guard sources.count == 1, let source = sources.first, source.isFileURL else { return false }
        var info = stat()
        guard lstat(source.path, &info) == 0, info.isRegularFile,
              let values = try? source.resourceValues(forKeys: [.isPackageKey]), values.isPackage != true else { return false }
        return true
    }

    static let singleStreamFormats: [SingleStreamFormat] = [.gzip, .bzip2, .xz, .zstd, .lzip, .lzma, .lz4, .brotli, .compress]

    static func filenameExtension(for format: SingleStreamFormat) -> String {
        switch format {
        case .gzip: "gz"
        case .bzip2: "bz2"
        case .xz: "xz"
        case .zstd: "zst"
        case .lzip: "lz"
        case .lzma: "lzma"
        case .lz4: "lz4"
        case .brotli: "br"
        case .compress: "Z"
        }
    }

    static func archiveFormat(for format: SingleStreamFormat) -> GyoshukuKit.ArchiveFormat {
        switch format {
        case .gzip: .tarGzip
        case .bzip2: .tarBzip2
        case .xz: .tarXZ
        case .zstd: .tarZstd
        case .lzip: .tarLzip
        case .lzma: .tarLZMA
        case .lz4: .tarLZ4
        case .brotli: .tarBrotli
        case .compress: .tarCompress
        }
    }

    var filenameExtension: String {
        singleStreamFormat.map { Self.filenameExtension(for: $0) } ?? Self.filenameExtension(for: format)
    }

    var hasAcceptedExtension: Bool {
        if let singleStreamFormat {
            return destination.pathExtension.lowercased() == Self.filenameExtension(for: singleStreamFormat).lowercased()
        }
        return Self.hasAcceptedExtension(destination, for: format)
    }

    static func filenameExtension(for format: GyoshukuKit.ArchiveFormat) -> String {
        switch format {
        case .zip: "zip"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .tarBzip2: "tar.bz2"
        case .tarXZ: "tar.xz"
        case .tarZstd: "tar.zst"
        case .tarLzip: "tar.lz"
        case .tarLZMA: "tar.lzma"
        case .tarLZ4: "tar.lz4"
        case .tarBrotli: "tar.br"
        case .tarCompress: "tar.Z"
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
        case .tarZstd: ["tar.zst", "tzst"]
        // .tlz は lzip と LZMA の両方で使われるため、出力の別名にはしない。
        case .tarLzip: ["tar.lz"]
        case .tarLZMA: ["tar.lzma"]
        case .tarLZ4: ["tar.lz4"]
        case .tarBrotli: ["tar.br", "tbr"]
        case .tarCompress: ["tar.z", "taz"]
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
        let wrappers = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz4", "tar.lzma", "tar.lz", "tar.br", "tar.Z"]
        let stem: String
        if let suffix = wrappers.first(where: { name.lowercased().hasSuffix("." + $0.lowercased()) }) {
            stem = String(name.dropLast(suffix.count + 1))
        } else { stem = archive.deletingPathExtension().lastPathComponent }
        return stem.isEmpty ? String(localized: "アーカイブ") : stem
    }
}
