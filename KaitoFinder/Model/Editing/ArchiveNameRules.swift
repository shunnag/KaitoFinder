import GyoshukuKit

nonisolated extension GyoshukuKit.ArchiveFormat {
    var allowsColonsAndBackslashes: Bool {
        switch self {
        case .tar, .tarGzip, .tarBzip2, .tarXZ: true
        case .zip, .sevenZip, .lha: false
        }
    }

    /// tar と、その圧縮包み（tar.gz / tar.bz2 / tar.xz）。owner ID の扱いなど tar 系だけの規則に使う。
    var isTarFamily: Bool {
        switch self {
        case .tar, .tarGzip, .tarBzip2, .tarXZ: true
        case .zip, .sevenZip, .lha: false
        }
    }
}
