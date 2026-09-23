import Darwin
import Foundation
import KaitoKit
import Synchronization

nonisolated enum VolumePublishBarrier: Sendable, Equatable {
    case retiredGate, placedSiblings, withdrawnGate, restoredSiblings, restoredOld
}

/// I/O 境界の注入。通常は実 API を使い、試験では失敗と呼び出し順を再現する。
nonisolated struct VolumePublishOperations: Sendable {
    var trash: @Sendable (URL) throws -> URL = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw VolumePublishError.validationFailed }
        return result as URL
    }
    var willRemove: @Sendable (URL) throws -> Void = { _ in }
    var didRemove: @Sendable (URL) throws -> Void = { _ in }
    var openReader: @Sendable (URL, ReaderOptions) throws -> ArchiveReader = { try ArchiveReader.open(url: $0, options: $1) }
    /// Opt-in, post-commit reader diagnostic; nil means do not open a reader during recovery.
    var recoveryReaderDiagnostic: (@Sendable (String?) -> Void)? = nil
    var volumeInfo: @Sendable (VolumePublishDirectory) throws -> VolumePublishFS.VolumeInfo = { try VolumePublishFS.volumeInfo($0) }
    var mountedVolumes: @Sendable () throws -> [VolumePublishFS.MountedVolume] = { try VolumePublishFS.mountedVolumes() }
    var nonLocalMountedVolumes: @Sendable () throws -> [VolumePublishFS.MountedVolume] = { try VolumePublishFS.mountedVolumes(includeNonLocal: true) }
    var renameStaging: @Sendable (Int32, String, String, UInt32) -> Int32 = { fd, from, to, flags in
        renameatx_np(fd, from, fd, to, flags)
    }
    var didHash: @Sendable (URL) -> Void = { _ in }
    var didBarrier: @Sendable (VolumePublishBarrier) -> Void = { _ in }
    var willCoordinate: @Sendable (URL) throws -> Void = { _ in }
}

/// DispatchQueue.sync は同じ thread で実行しうる。別 thread で Task の取消状態を切り離す。
nonisolated enum VolumePublishUncancelled {
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let result = Mutex<Result<T, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let value = Result { try body() }
            result.withLock { $0 = value }
            finished.signal()
        }
        finished.wait()
        return try result.withLock { $0! }.get()
    }
}
