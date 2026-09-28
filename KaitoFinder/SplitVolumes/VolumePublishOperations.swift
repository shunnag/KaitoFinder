import Darwin
import Foundation
import KaitoKit

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
    var mountedVolumes: @Sendable (Set<String>) throws -> VolumePublishFS.MountScan = { try VolumePublishFS.mountedVolumes(fileSystems: $0) }
    var nonLocalMountedVolumes: @Sendable (Set<String>) throws -> VolumePublishFS.MountScan = { try VolumePublishFS.mountedVolumes(includeNonLocal: true, fileSystems: $0) }
    var renameStaging: @Sendable (Int32, String, String, UInt32) -> Int32 = { fd, from, to, flags in
        renameatx_np(fd, from, fd, to, flags)
    }
    var didHash: @Sendable (URL) -> Void = { _ in }
    var didRecheckStamps: @Sendable (URL) -> Void = { _ in }
    var allowsStampRecheck = true
    var didBarrier: @Sendable (VolumePublishBarrier) -> Void = { _ in }
    var willCoordinate: @Sendable (URL) throws -> Void = { _ in }
    /// Nil always uses Foundation. Tests can withhold the callback to exercise the real timeout.
    var coordinate: VolumePublishCoordination.Request? = nil
}

nonisolated enum VolumePublishStep: Sendable, Hashable {
    case registered, stagingCreated, journalCreated
    case s5, s6, s7, s8, s9, s10, s11
    case committed, oldDisposed, stagingRemoved, indexRemoved
    case retiredVolume(Int)
    case placedVolume(Int)
}

/// 障害注入専用。捕捉時は rollback せず fd を閉じ、実際のクラッシュと同じ残骸を作る。
nonisolated struct SimulatedCrash: Error, Sendable {}
