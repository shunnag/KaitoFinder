import Foundation
import GyoshukuKit
import KaitoKit

/// 新規作成と形式変換は、追加元を常に書庫 root に置く一回限りの操作。
nonisolated struct ArchiveCreationPlan: Sendable {
    struct Existing: Sendable {
        let url: URL
        let password: String?
        let entries: [ArchiveEntry]
    }

    let sources: [URL]
    let destination: URL
    let format: GyoshukuKit.ArchiveFormat
    let options: WriterOptions
    let existing: Existing?

    init(sources: [URL], destination: URL, format: GyoshukuKit.ArchiveFormat,
         options: WriterOptions = WriterOptions(), existing: Existing? = nil) {
        self.sources = sources
        self.destination = destination
        self.format = format
        self.options = options
        self.existing = existing
    }

    static func filenameExtension(for format: GyoshukuKit.ArchiveFormat) -> String {
        switch format {
        case .zip: "zip"
        case .tar: "tar"
        case .tarGzip: "tar.gz"
        case .sevenZip: "7z"
        case .lha: "lzh"
        }
    }

    static func defaultName(for sources: [URL], format: GyoshukuKit.ArchiveFormat) -> String {
        let name = sources.count == 1 ? sources[0].lastPathComponent : String(localized: "アーカイブ")
        return name + "." + filenameExtension(for: format)
    }

    static func conversionName(for archive: URL, format: GyoshukuKit.ArchiveFormat) -> String {
        let name = archive.lastPathComponent
        // 二重拡張子も一つの書庫拡張子として外す。写真などの通常の拡張子は defaultName が残す。
        let wrappers = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lzma", "tar.Z"]
        let stem: String
        if let suffix = wrappers.first(where: { name.lowercased().hasSuffix("." + $0.lowercased()) }) {
            stem = String(name.dropLast(suffix.count + 1))
        } else { stem = archive.deletingPathExtension().lastPathComponent }
        return stem + "." + filenameExtension(for: format)
    }
}
