import GyoshukuKit

nonisolated extension GyoshukuKit.ArchiveFormat {
    var allowsColonsAndBackslashes: Bool {
        switch self {
        case .tar, .tarGzip, .tarBzip2, .tarXZ, .tarLZMA, .tarLzip, .tarLZ4, .tarBrotli, .tarCompress: true
        case .zip, .sevenZip, .lha: false
        }
    }

    /// 所有者 ID と名前の規則を共有する tar 系の出力形式。
    var isTarFamily: Bool {
        switch self {
        case .tar, .tarGzip, .tarBzip2, .tarXZ, .tarLZMA, .tarLzip, .tarLZ4, .tarBrotli, .tarCompress: true
        case .zip, .sevenZip, .lha: false
        }
    }
}
