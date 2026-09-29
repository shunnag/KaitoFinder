import Darwin
import Foundation
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

/// ArchiveSession・VolumePublishTransaction の分割保存の取消しと、証明済み rollback 後の再試行を確かめる（2 テスト）。
/// セットは VolumePublishFixture で作り、ArchiveSplitSaveHooks で失敗と取消しを差し込む。観測点は didHash・
/// openReader・fault、保存失敗の種別、世代、編集可否、回復待ち状態、回復索引と保存後の巻。
nonisolated final class SplitCancellationFollowupTests: XCTestCase {
    private final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        init(_ url: URL) { presentedItemURL = url; super.init() }
    }

    private static func hooks() -> ArchiveSplitSaveHooks {
        var hooks = ArchiveSplitSaveHooks()
        hooks.operations.trash = { _ in throw CocoaError(.fileWriteUnknown) }
        hooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
        return hooks
    }

    private static func save(_ session: ArchiveSession, fixture: VolumePublishFixture,
                      hooks: ArchiveSplitSaveHooks) async throws -> ArchiveSplitSaveResult {
        let snapshot = try await session.deferredSnapshot()
        let entry = try XCTUnwrap(snapshot.entries.first)
        var pending = ArchivePendingChanges()
        pending.renames[.init(index: entry.index, expectedName: entry.name, baseGeneration: snapshot.generation)] = "renamed.bin"
        let layout = try XCTUnwrap(session.volumeLayout).publicationLayout()
        let target = VolumeSetTarget(parent: fixture.root, layout: layout, expected: await session.sourceIdentity,
            schedule: fixture.target().schedule, filePresenter: Presenter(fixture.gate))
        let publication = ArchiveSavePublication(); defer { publication.finish() }
        return try await session.savePendingSplit(pending, baseGeneration: snapshot.generation, target: target,
            estimatedLength: UInt64(fixture.oldBytes.count), progress: Progress(), publication: publication,
            index: fixture.index, hooks: hooks, willPublish: nil, willReload: nil)
    }

    func testStagedReaderCancellationSkipsRehashAndFailureMapping() async throws {
        for cancels in [false, true] {
            let fixture = try VolumePublishFixture()
            let metadata = ArchiveVolumeMetadataStore(fileURL: fixture.directory.url.appendingPathComponent("metadata.json"))
            let session = try ArchiveSession(url: fixture.gate, allowsSplitSave: true, volumeMetadataStore: metadata)
            let hashes = Mutex(0), hashesAtOpen = Mutex<Int?>(nil)
            var hooks = Self.hooks()
            hooks.operations.didHash = { _ in hashes.withLock { $0 += 1 } }
            hooks.operations.openReader = { url, options in
                hashesAtOpen.withLock { $0 = hashes.withLock { $0 } }
                if cancels {
                    // S4 の open だけを取消済み Task にし、実 reader の CancellationError を通す。
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try ArchiveReader.open(url: url, options: options)
                }
                throw KaitoError.io(EIO)
            }
            hooks.fault = { if $0 == .s5 { XCTFail("S5 に進んではいけない") } }
            let injected = hooks
            let task = Task { try await Self.save(session, fixture: fixture, hooks: injected) }
            do { _ = try await task.value; XCTFail("reader の失敗を伝播する") }
            catch is CancellationError { XCTAssertTrue(cancels) }
            catch let failure as ArchiveSplitSaveFailure {
                XCTAssertFalse(cancels, "取消しを保存失敗に変換してはいけない")
                XCTAssertEqual(failure.kind, .failed)
            }
            let before = try XCTUnwrap(hashesAtOpen.withLock { $0 })
            XCTAssertGreaterThan(before, 0)
            XCTAssertEqual(hashes.withLock { $0 }, before * (cancels ? 1 : 2))
            XCTAssertEqual(task.isCancelled, cancels)
            XCTAssertFalse(session.requiresSplitRecovery)
            XCTAssertTrue(session.capabilities.canEdit)
            try fixture.assertOld()
            XCTAssertTrue(try fixture.index.entries().isEmpty)
            await session.close()
        }
    }

    func testCancelledCallerKeepsProvenRollbackRetryable() async throws {
        let fixture = try VolumePublishFixture()
        let metadata = ArchiveVolumeMetadataStore(fileURL: fixture.directory.url.appendingPathComponent("metadata.json"))
        let session = try ArchiveSession(url: fixture.gate, allowsSplitSave: true, volumeMetadataStore: metadata)
        let generation = session.generation
        let reached = XCTestExpectation(description: "S7"), resume = DispatchSemaphore(value: 0)
        var hooks = Self.hooks()
        hooks.fault = { step in
            if step == .s7 {
                reached.fulfill()
                guard resume.wait(timeout: .now() + 15) == .success else { throw VolumePublishError.coordinationTimedOut }
                throw VolumePublishError.validationFailed
            }
        }
        let injected = hooks
        let task = Task { try await Self.save(session, fixture: fixture, hooks: injected) }
        await fulfillment(of: [reached], timeout: 10)
        // S5 後の処理を止め、rollback 後の再オープン時には呼び出し Task が確実に取消済みになる。
        task.cancel(); resume.signal()
        do { _ = try await task.value; XCTFail("rollback を伝播する") }
        catch let failure as ArchiveSplitSaveFailure {
            XCTAssertEqual(failure.kind, .rolledBack)
            XCTAssertNotNil(failure.restoredIdentity)
            XCTAssertFalse(failure.requiresReopen)
        }
        XCTAssertTrue(task.isCancelled)
        XCTAssertEqual(session.generation, generation)
        XCTAssertFalse(session.requiresSplitRecovery)
        XCTAssertTrue(session.capabilities.canEdit)
        try fixture.assertOld()
        try await session.verifyDeferredIdentity()
        let result = try await Self.save(session, fixture: fixture, hooks: Self.hooks())
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(session.generation, generation + 1)
        let reader = try ArchiveReader.open(url: fixture.gate)
        XCTAssertEqual(reader.entries.map(\.name), ["renamed.bin"])
        await session.close()
    }
}
