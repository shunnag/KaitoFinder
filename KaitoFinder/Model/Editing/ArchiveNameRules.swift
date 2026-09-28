import GyoshukuKit

nonisolated extension GyoshukuKit.ArchiveFormat {
    var allowsColonsAndBackslashes: Bool {
        switch self {
        case .tar, .tarGzip, .tarBzip2, .tarXZ: true
        case .zip, .sevenZip, .lha: false
        }
    }
}
