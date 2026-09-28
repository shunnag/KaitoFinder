import Darwin
import Foundation

/// 巻の同一性の証拠。dev・inode・size・mtime（秒と ns）だけを比べる。
/// xattr や Spotlight で変わる ctime は含めない。`VolumePublishFS.sameFile` と rename 前後の照合が使う。
/// 用途の違う `ArchiveFileIdentity`（Model）・`ArchiveImportSourceStamp`（ctime を含む）とは統合しない。
nonisolated struct VolumeFileStamp: Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let seconds: Int64
    let nanoseconds: Int64
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        seconds = Int64(info.st_mtimespec.tv_sec); nanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }
}

nonisolated extension stat {
    var isRegularFile: Bool { st_mode & S_IFMT == S_IFREG }
    var isDirectory: Bool { st_mode & S_IFMT == S_IFDIR }
}
