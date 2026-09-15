import KaitoKit

extension KaitoKit.ArchiveFormat {
    /// 形式名は製品・規格の表記を保ち、言語によらず同じ名前を使う。
    nonisolated var displayName: String {
        switch self {
        case .zip: "ZIP"
        case .rar: "RAR"
        case .sevenZip: "7z"
        case .lha: "LHA"
        case .stuffIt: "StuffIt"
        case .stuffItX: "StuffIt X"
        case .tar: "tar"
        case .cpio: "cpio"
        case .ar: "ar"
        case .iso: "ISO 9660"
        case .cab: "CAB"
        case .rpm: "RPM"
        case .xar: "xar"
        case .gzip: "gzip"
        case .bzip2: "bzip2"
        case .xz: "xz"
        case .zstd: "Zstandard"
        case .lzma: "LZMA"
        case .compress: "UNIX compress"
        }
    }
}
