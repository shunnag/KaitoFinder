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
    /// commit 後に reader で行う診断で、使う側が明示的に有効にする。nil なら回復中に reader を開かない。
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
    /// nil なら常に Foundation を使う。試験は callback を返さずにおき、実際の時間切れを確かめられる。
    var coordinate: VolumePublishCoordination.Request? = nil
}

/// 公開の手順の境界。`VolumeSetPublication.begin(fault:)` の hook が各点で呼ばれ、試験はそこで失敗や `SimulatedCrash` を注入する。
/// S 番号の意味は `VolumeSetPublication` の手順表と同じ。S0・S2〜S4 には hook が無く、S1 の内部は registered〜journalCreated。
nonisolated enum VolumePublishStep: Sendable, Hashable {
    /// S1: 回復索引へ登録した直後、staging を mkdir する前。
    case registered
    /// S1: staging を作って親を同期した後、journal を作る前。
    case stagingCreated
    /// S1: journal を作った後、work/new/old と最初の記録を書く前。
    case journalCreated
    /// S5: 調整を取得して臨界区間に入った直後、phase=retiring と旧 gate の退避より前。
    case s5
    /// S6: 旧 gate を old/ へ退避した後、残りの旧巻を退避する前。
    case s6
    /// S7: 旧巻をすべて old/ へ退避した後、新巻を配置する前。
    case s7
    /// S8: gate 以外の新巻を配置した後、新 gate を置く前。
    case s8
    /// S9: 新 gate を置き、親を同期して phase=placed を書いた後。
    case s9
    /// S10: 配置した新セットの全文 hash と reader の検証が通った後。
    case s10
    /// S11: S10 の直後、durable な done を書く前。
    case s11
    /// done を書いた後、旧巻を処分する前。
    case committed
    /// 旧巻を処分（Trash または除去）した後、staging を片付ける前。
    case oldDisposed
    /// 空の staging を消して親を同期した後、索引から外す前。
    case stagingRemoved
    /// 索引から外した後、staging lock を片付ける前。
    case indexRemoved
    /// S7 の途中: journal の旧巻の i 番目（gate 以外）を old/ へ退避した直後。
    case retiredVolume(Int)
    /// S8 の途中: journal の新巻の i 番目（gate 以外）を配置した直後。
    case placedVolume(Int)
}

/// 障害注入専用。捕捉時は rollback せず fd を閉じ、実際のクラッシュと同じ残骸を作る。
nonisolated struct SimulatedCrash: Error, Sendable {}
