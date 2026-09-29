import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

/// ArchiveSession の header 暗号化プローブの失敗と、再読込後の暗号化方針の維持を確かめる（4 テスト）。
/// 書庫は SevenZipUpdateFixture と ArchiveWriter で作る。観測点は willProbeEncryptedHeadersForTesting・
/// encryptionSettings・isInvalidated・reloadFailure と、保存後の ArchiveReader のパスワード要求。
nonisolated final class ArchiveHeaderProbeTests: XCTestCase {
    func testUnknownProbeErrorsPreventOpeningSession() throws {
        let directory = try ArchiveTestDirectory()
        let url = try SevenZipUpdateFixture.frozen("z_aesonlyh", at: directory.url)
        for failure: KaitoError in [.io(EIO), .io(EMFILE), .limitExceeded("header probe")] {
            try ArchiveSession.willProbeEncryptedHeadersForTesting.withValue({ throw failure }) {
                XCTAssertThrowsError(try ArchiveSession(url: url, password: "secret")) {
                    XCTAssertEqual($0 as? KaitoError, failure)
                }
            }
        }
    }

    func testCancelledProbePreventsOpeningSession() async throws {
        let directory = try ArchiveTestDirectory()
        let url = try SevenZipUpdateFixture.make(directory.url, password: "secret")
        let task = Task {
            try ArchiveSession.willProbeEncryptedHeadersForTesting.withValue({
                // 最初の open は通し、パスワードなしのプローブだけを取消済み Task で開く。
                withUnsafeCurrentTask { $0?.cancel() }
            }) { try ArchiveSession(url: url, password: "secret") }
        }
        do {
            let session = try await task.value
            await session.close()
            XCTFail("取消されたプローブで session を開いてはいけない")
        } catch is CancellationError { }
        XCTAssertTrue(task.isCancelled)
    }

    func testReloadProbeFailurePreservesHeaderOnlyEncryptionAndNextWrite() async throws {
        let directory = try ArchiveTestDirectory()
        let url = directory.url.appendingPathComponent("headers-only.7z")
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip,
            options: .init(password: "secret", encryptsSevenZipHeaders: true))
        try writer.addDirectory("private")
        try writer.finish()
        let session = try ArchiveSession(url: url, password: "secret")
        XCTAssertFalse(session.hasEncryptedEntries)
        try await ArchiveSession.willProbeEncryptedHeadersForTesting.withValue({ throw KaitoError.io(EMFILE) }) {
            try await session.reloadAfterMutation()
        }
        let settings = await session.encryptionSettings()
        XCTAssertTrue(settings.encryptsSevenZipHeaders)
        XCTAssertEqual(settings.password, "secret")
        XCTAssertFalse(session.isInvalidated)
        _ = try await session.createFolder(in: "", progress: Progress())
        XCTAssertThrowsError(try ArchiveReader.open(url: url)) {
            XCTAssertEqual($0 as? KaitoError, .passwordRequired)
        }
        _ = try ArchiveReader.open(url: url, options: .kaitoFinder(password: "secret"))
        await session.close()
    }

    func testReloadProbeFailureKeepsNewSaveAndPasswordSettings() async throws {
        for deferred in [false, true] {
            let directory = try ArchiveTestDirectory()
            let url = try SevenZipUpdateFixture.make(directory.url)
            let session = try ArchiveSession(url: url)
            let settings = ArchiveEncryptionSettings(password: "new-key", encryptsSevenZipHeaders: true)
            try await ArchiveSession.willProbeEncryptedHeadersForTesting.withValue({ throw KaitoError.io(EIO) }) {
                let result: ArchivePasswordEditResult
                if deferred {
                    var pending = ArchivePendingChanges()
                    pending.outputEncryption = settings
                    let publication = ArchiveSavePublication(); defer { publication.finish() }
                    result = try await session.savePending(pending, baseGeneration: session.generation,
                        progress: Progress(), publication: publication)
                } else {
                    result = try await session.updatePassword(.set, settings: settings, progress: Progress())
                }
                XCTAssertNil(result.reloadFailure)
            }
            let actual = await session.encryptionSettings()
            XCTAssertTrue(actual.encryptsSevenZipHeaders)
            XCTAssertEqual(actual.password, settings.password)
            await session.close()
        }
    }
}
