import Foundation
import GyoshukuKit

#if DEBUG
/// 試験が publish の各段階を観測・妨害するための TaskLocal。名前は試験ファイルが綴るので変えない。
/// 本番の呼び出しは何も設定せず、nil のまま通る。
nonisolated extension ArchiveImportTransaction {
    static let willAddFileForTesting = TaskLocal<(@Sendable (URL) -> Void)?>(wrappedValue: nil)
    static let didCommitForTesting = TaskLocal<(@Sendable (URL) throws -> Void)?>(wrappedValue: nil)
    static let didOpenVerificationSourceForTesting = TaskLocal<(@Sendable (URL) throws -> Void)?>(wrappedValue: nil)
    static let didVerifyForTesting = TaskLocal<(@Sendable (URL) throws -> Void)?>(wrappedValue: nil)
    static let didPublishForTesting = TaskLocal<(@Sendable (URL) -> Void)?>(wrappedValue: nil)
    static let didCommitUpdaterForTesting = TaskLocal<(@Sendable (ArchiveUpdater) throws -> Void)?>(wrappedValue: nil)
    static let willCommitUpdaterForTesting = TaskLocal<(@Sendable () throws -> Void)?>(wrappedValue: nil)
    static let didCommitTarUpdaterForTesting = TaskLocal<(@Sendable (TarUpdater) throws -> Void)?>(wrappedValue: nil)
    static let didCommitLHAUpdaterForTesting = TaskLocal<(@Sendable (LHAUpdater) throws -> Void)?>(wrappedValue: nil)
    static let didCommitSevenZipUpdaterForTesting = TaskLocal<(@Sendable (SevenZipUpdater) throws -> Void)?>(wrappedValue: nil)
    static let didCommitCompressedTarUpdaterForTesting = TaskLocal<(@Sendable (CompressedTarUpdater) throws -> Void)?>(wrappedValue: nil)
    static let didFallBackToRewriteForTesting = TaskLocal<(@Sendable (String) -> Void)?>(wrappedValue: nil)
    static let didFallBackToFullVerificationForTesting = TaskLocal<(@Sendable (String) -> Void)?>(wrappedValue: nil)
}
#endif
