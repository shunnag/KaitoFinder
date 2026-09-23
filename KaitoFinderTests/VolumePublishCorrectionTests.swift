import Darwin
import Foundation
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class VolumePublishCorrectionTests: XCTestCase {
    private enum Injected: Error { case failure, trashUnavailable, readerUnavailable }
    private func noTrash() -> VolumePublishOperations {
        var operations = VolumePublishOperations()
        operations.trash = { _ in throw Injected.trashUnavailable }
        return operations
    }
    private func crash(_ fixture: VolumePublishFixture, at step: VolumePublishStep,
                       operations: VolumePublishOperations = .init(), consent: Bool = false) throws -> URL {
        let publication = try fixture.begin(consent: consent, operations: operations) { if $0 == step { throw SimulatedCrash() } }
        XCTAssertThrowsError(try publication.publish(progress: Progress())) { XCTAssertTrue($0 is SimulatedCrash, "\($0)") }
        return publication.stagingURL
    }
    private func disk(_ kind: String) throws -> VolumePublishTestDisk {
        let disk = try VolumePublishTestDisk(kind)
        addTeardownBlock { try disk.detach() }
        return disk
    }
    private func setXattr(_ url: URL, _ name: String, _ bytes: Data) throws {
        guard bytes.withUnsafeBytes({ setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0 else {
            throw VolumePublishError.system(errno)
        }
    }

    // 1 / 4: 実 FAT の AppleDouble と、必ず Trash が失敗する分岐。
    func testFATAndExFATXattrsForeignEntriesAndForcedRemoval() throws {
        for kind in ["MS-DOS FAT32", "ExFAT"] {
            let disk = try disk(kind)
            defer { try? disk.detach() }
            try disk.disableTrash()
            for step in [VolumePublishStep.s7, .s8] {
                let fixture = try VolumePublishFixture(parent: disk.mount)
                for volume in try XCTUnwrap(fixture.layout).volumes {
                    try setXattr(volume.url, "com.apple.quarantine", Data("0083;12345678;KaitoFinder;".utf8))
                    try setXattr(volume.url, "com.shunnag.test.extra", Data([1, 2, 3]))
                }
                let staging = try crash(fixture, at: step, consent: true)
                try Data("Finder metadata".utf8).write(to: staging.appendingPathComponent("old/.DS_Store"))
                try Data("unrelated bookkeeping".utf8).write(to: staging.appendingPathComponent("foreign-note"))
                let result = VolumePublishRecovery(index: fixture.index).recover(staging: staging)
                guard case .recovered(_, .forward, .removed) = result else { return XCTFail("\(kind): \(result)") }
                try fixture.assertNew(); try fixture.assertRemoved(staging)
            }
            let fixture = try VolumePublishFixture(parent: disk.mount)
            for volume in try XCTUnwrap(fixture.layout).volumes {
                try setXattr(volume.url, "com.apple.quarantine", Data("0083;12345678;KaitoFinder;".utf8))
                try setXattr(volume.url, "com.shunnag.test.extra", Data([4, 5]))
            }
            let publication = try fixture.begin(consent: true) { if $0 == .s7 { throw Injected.failure } }
            XCTAssertThrowsError(try publication.publish(progress: Progress())) {
                guard case VolumePublishError.rolledBack(_, nil, .removed) = $0 else { return XCTFail("\($0)") }
            }
            try fixture.assertOld(); try fixture.assertRemoved(publication.stagingURL)
        }
    }

    func testForeignEntriesAreIgnoredOnLocalRecovery() throws {
        let fixture = try VolumePublishFixture(), staging = try crash(fixture, at: .s8)
        for name in [".DS_Store", "old/.DS_Store", "old/foreign", "new/._archive.tar.001"] {
            try Data("metadata".utf8).write(to: staging.appendingPathComponent(name))
        }
        guard case .recovered = VolumePublishRecovery(index: fixture.index).recover(staging: staging) else { return XCTFail("Foreign entries must not HOLD") }
        try fixture.assertNew(); try fixture.assertRemoved(staging)
    }

    // 2: S11 の内側全境界。done は以後 live 名を触らない。
    func testEveryS11CrashOnlyCleansUpAndPreservesPublishedSet() throws {
        for step in [VolumePublishStep.committed, .oldDisposed, .stagingRemoved, .indexRemoved] {
            let fixture = try VolumePublishFixture(), staging = try crash(fixture, at: step)
            let before = try fixture.plan.volumes.map { try Data(contentsOf: fixture.root.appendingPathComponent($0.name)) }
            let result = VolumePublishRecovery(index: fixture.index).recover(staging: staging)
            guard case .recovered(_, .cleanup, _) = result else { return XCTFail("\(step): \(result)") }
            XCTAssertEqual(try fixture.plan.volumes.map { try Data(contentsOf: fixture.root.appendingPathComponent($0.name)) }, before)
            try fixture.assertNew(); try fixture.assertRemoved(staging)
        }
    }
    func testDoneNeverRestoresOldSetAfterUserDeletesNewSet() throws {
        let fixture = try VolumePublishFixture(), staging = try crash(fixture, at: .committed)
        for volume in fixture.plan.volumes { try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(volume.name)) }
        guard case .recovered(_, .cleanup, _) = VolumePublishRecovery(index: fixture.index).recover(staging: staging) else { return XCTFail("done must only clean up") }
        XCTAssertNil(try VolumePublishDirectory(fixture.root).info(fixture.gate.lastPathComponent))
        try fixture.assertRemoved(staging)
    }
    func testS11PartialDirectoryRemovalStillRecoversByCleanupOnly() throws {
        for oldDirectory in [true, false] {
            let fixture = try VolumePublishFixture()
            var operations = noTrash()
            operations.willRemove = { url in
                if oldDirectory && url.lastPathComponent == "old" {
                    try FileManager.default.removeItem(at: url.appendingPathComponent("archive.tar.001"))
                    throw SimulatedCrash()
                }
                if !oldDirectory && url.lastPathComponent.hasPrefix(VolumePublishFS.stagingPrefix) {
                    try FileManager.default.removeItem(at: url.appendingPathComponent("journal"))
                    throw SimulatedCrash()
                }
            }
            let publication = try fixture.begin(operations: operations)
            XCTAssertThrowsError(try publication.publish(progress: Progress())) { XCTAssertTrue($0 is SimulatedCrash) }
            let before = try fixture.plan.volumes.map { try Data(contentsOf: fixture.root.appendingPathComponent($0.name)) }
            guard case .recovered = VolumePublishRecovery(index: fixture.index).recover(staging: publication.stagingURL) else { return XCTFail("Partial cleanup should finish") }
            XCTAssertEqual(try fixture.plan.volumes.map { try Data(contentsOf: fixture.root.appendingPathComponent($0.name)) }, before)
            try fixture.assertNew(); try fixture.assertRemoved(publication.stagingURL)
        }
    }
    func testRecoveryContendsWithPublisherLockAcrossGateGenerations() throws {
        let fixture = try VolumePublishFixture(), staging = try crash(fixture, at: .committed)
        let parent = try VolumePublishDirectory(fixture.root), info = try VolumePublishFS.volumeInfo(parent)
        let gate = try XCTUnwrap(parent.info(fixture.gate.lastPathComponent))
        XCTAssertNotEqual(gate.st_ino, fixture.expected?.volumes.first?.inode)
        let lock = try VolumePublishLock.setLock(volumeUUID: info.uuid, gateInode: gate.st_ino,
            parent: fixture.root, gate: fixture.gate.lastPathComponent, directory: fixture.index.setLocksURL)
        let before = try VolumePublishFixture.snapshot(fixture.root)
        XCTAssertEqual(VolumePublishRecovery(index: fixture.index).recover(staging: staging), .owned(staging))
        XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
        lock.release()
        guard case .recovered(_, .cleanup, _) = VolumePublishRecovery(index: fixture.index).recover(staging: staging) else { return XCTFail("unlock must permit cleanup") }
        try fixture.assertNew()
    }

    // 3: S1 write-ahead と、原本の外部変更後の pre-S5 cleanup。
    func testPreS5AbortAndCancelRemoveStagingAfterExternalChange() throws {
        for cancel in [false, true] {
            let fixture = try VolumePublishFixture(), publication = try fixture.begin(operations: noTrash())
            let third = fixture.root.appendingPathComponent("archive.tar.003")
            try FileManager.default.removeItem(at: third)
            try fixture.oldParts[2].write(to: third)
            if cancel { publication.cancel() }
            else { XCTAssertThrowsError(try publication.publish(progress: Progress())) }
            try fixture.assertRemoved(publication.stagingURL)
            let layout = try XCTUnwrap(fixture.layout)
            let target = VolumeSetTarget(parent: fixture.root, layout: layout, expected: try ArchiveSetIdentity.capture(layout: layout),
                schedule: .uniform(size: fixture.plan.largestVolume))
            let next = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(fixture.newBytes.count), index: fixture.index)
            next.cancel()
            try fixture.assertRemoved(next.stagingURL)
        }
    }
    func testS1CrashWindowsAreIndexedAndLaunchRecoveryDiscardsThem() throws {
        for step in [VolumePublishStep.registered, .stagingCreated, .journalCreated] {
            let fixture = try VolumePublishFixture()
            XCTAssertThrowsError(try fixture.begin { current in
                if current == step {
                    XCTAssertEqual(try fixture.index.entries().count, 1)
                    throw SimulatedCrash()
                }
            }) { XCTAssertTrue($0 is SimulatedCrash) }
            let staging = URL(fileURLWithPath: try XCTUnwrap(fixture.index.entries().first).stagingPath)
            let results = VolumePublishRecovery(index: fixture.index).recoverAll()
            XCTAssertTrue(results.contains { if case .recovered = $0 { return true }; return false }, "\(results)")
            try fixture.assertRemoved(staging)
            let retry = try fixture.begin(); retry.cancel()
        }
    }
    func testJournalOpenFailureRemovesS1StagingAndAllowsRetry() throws {
        let fixture = try VolumePublishFixture()
        XCTAssertThrowsError(try fixture.begin { step in
            if step == .stagingCreated {
                let staging = URL(fileURLWithPath: try XCTUnwrap(fixture.index.entries().first).stagingPath)
                try FileManager.default.createDirectory(at: staging.appendingPathComponent("journal"), withIntermediateDirectories: false)
            }
        })
        XCTAssertTrue(try fixture.index.entries().isEmpty)
        XCTAssertFalse(try VolumePublishDirectory(fixture.root).names().contains { $0.hasPrefix(VolumePublishFS.stagingPrefix) })
        let retry = try fixture.begin(); retry.cancel()
    }
    func testS1NameCollisionDoesNotDeleteTheForeignDirectory() throws {
        let fixture = try VolumePublishFixture(), bytes = Data("keep foreign data".utf8)
        let collision = Mutex<URL?>(nil)
        XCTAssertThrowsError(try fixture.begin { step in
            if step == .registered {
                let url = URL(fileURLWithPath: try XCTUnwrap(fixture.index.entries().first).stagingPath)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                try bytes.write(to: url.appendingPathComponent("foreign"))
                collision.withLock { $0 = url }
            }
        })
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(collision.withLock { $0 }).appendingPathComponent("foreign")), bytes)
    }
    func testBeginDisposesOwnerlessPreparedStageWithoutRecoveryCall() throws {
        let fixture = try VolumePublishFixture(), staging = try crash(fixture, at: .s5)
        let next = try fixture.begin()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        next.cancel(); try fixture.assertOld()
    }

    // 4: no-Trash は成功した rollback と forward recovery の障害にならない。
    func testForcedTrashFailureRemovesCommittedAndRolledBackData() throws {
        let operations = noTrash()
        let committed = try VolumePublishFixture(), publication = try committed.begin(operations: operations)
        XCTAssertEqual(try publication.publish(progress: Progress()).oldVolumesDisposal, .removed)
        try committed.assertNew(); try committed.assertRemoved(publication.stagingURL)
        let rolledBack = try VolumePublishFixture()
        let failed = try rolledBack.begin(operations: operations) { if $0 == .s8 { throw Injected.failure } }
        XCTAssertThrowsError(try failed.publish(progress: Progress())) {
            guard case VolumePublishError.rolledBack(_, nil, .removed) = $0 else { return XCTFail("\($0)") }
        }
        try rolledBack.assertOld(); try rolledBack.assertRemoved(failed.stagingURL)
        let recovery = try VolumePublishFixture(), staging = try crash(recovery, at: .s7)
        guard case .recovered(_, .forward, .removed) = VolumePublishRecovery(index: recovery.index, operations: operations).recover(staging: staging) else { return XCTFail("Recovery should remove superseded old data") }
        try recovery.assertNew(); try recovery.assertRemoved(staging)
    }
    func testFailedTrashRevalidatesOldVolumesBeforeRemoval() throws {
        let fixture = try VolumePublishFixture(), foreign = Data("external replacement must stay".utf8)
        var operations = VolumePublishOperations()
        operations.trash = { directory in
            try foreign.write(to: directory.appendingPathComponent("archive.tar.001"))
            throw Injected.trashUnavailable
        }
        let publication = try fixture.begin(operations: operations)
        let result = try publication.publish(progress: Progress())
        guard case .committed(.some) = result.outcome,
              case .kept(let directory) = result.oldVolumesDisposal else { return XCTFail("Changed old data must remain held") }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("archive.tar.001")), foreign)
        try fixture.assertNew()
        XCTAssertEqual(try fixture.index.entries().count, 1)
    }

    // 5: 呼び出し Task を S5 直後に実際に cancel する。gzip open は Task cancellation を観測する。
    func testCallingTaskCancellationAfterS5DoesNotCancelCompressedTarPublication() async throws {
        let fixture = try VolumePublishFixture(compressed: true)
        let reached = XCTestExpectation(description: "S5 reached"), resume = DispatchSemaphore(value: 0)
        let publication = try fixture.begin { step in
            if step == .s5 { reached.fulfill(); guard resume.wait(timeout: .now() + 15) == .success else { throw Injected.failure } }
        }
        let task = Task.detached { try publication.publish(progress: Progress()) }
        await fulfillment(of: [reached], timeout: 10)
        task.cancel(); resume.signal()
        let result = try await task.value
        XCTAssertEqual(result.outcome, .committed(cleanupFailed: nil))
        try fixture.assertNew(); try fixture.assertRemoved(publication.stagingURL)
    }

    // 6 / 7: reader の環境依存エラーは、全 hash が合う新セットを後退させない。
    func testS10ReaderFailureHoldsHashProvenPublishedSet() throws {
        let fixture = try VolumePublishFixture()
        var operations = VolumePublishOperations()
        operations.openReader = { url, options in
            if url.deletingLastPathComponent() == fixture.root { throw Injected.readerUnavailable }
            return try ArchiveReader.open(url: url, options: options)
        }
        let publication = try fixture.begin(operations: operations)
        XCTAssertThrowsError(try publication.publish(progress: Progress())) {
            guard case VolumePublishError.publishedReaderFailed(_, let message) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(message.contains("verified by hash"))
        }
        try fixture.assertNew()
        XCTAssertNotNil(try VolumePublishDirectory(publication.stagingURL).info("old"))
        guard case .recovered = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: publication.stagingURL) else { return XCTFail("Recovery needs only the S4-validated byte proof") }
        try fixture.assertNew(); try fixture.assertRemoved(publication.stagingURL)
    }
    func testForwardRecoveryReaderFailureNeverRollsBackHashProvenSet() throws {
        let fixture = try VolumePublishFixture(), staging = try crash(fixture, at: .s8)
        var operations = VolumePublishOperations()
        operations.openReader = { _, _ in XCTFail("Recovery must not require a reader"); throw Injected.readerUnavailable }
        guard case .recovered(_, .forward, _) = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: staging) else { return XCTFail("Hash-proven recovery must commit") }
        try fixture.assertNew(); try fixture.assertRemoved(staging)
    }

    func testHashMatchedInodeChangeAtS10HoldsPublication() throws {
        let fixture = try VolumePublishFixture()
        let publication = try fixture.begin { step in
            if step == .s9 {
                let url = fixture.root.appendingPathComponent("archive.tar.002")
                let bytes = try Data(contentsOf: url)
                try FileManager.default.moveItem(at: url, to: fixture.root.appendingPathComponent("replaced-inode"))
                try bytes.write(to: url)
            }
        }
        XCTAssertThrowsError(try publication.publish(progress: Progress())) {
            guard case VolumePublishError.publishedVerificationPending(_, let message) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(message.contains("verified by hash"))
        }
        try fixture.assertNew()
        XCTAssertNil(try VolumePublishDirectory(publication.stagingURL).info("abandoned"))
    }
    func testCommittedCleanupFailureReturnsNewIdentityAndDistinctOutcome() throws {
        let fixture = try VolumePublishFixture()
        let publication = try fixture.begin { if $0 == .oldDisposed { throw Injected.failure } }
        let result = try publication.publish(progress: Progress())
        guard case .committed(.some(let message)) = result.outcome else { return XCTFail("Commit must be reported") }
        XCTAssertTrue(message.contains("failure"))
        XCTAssertEqual(result.identity, try ArchiveSetIdentity.capture(layout: result.layout))
        try fixture.assertNew()
        guard case .recovered(_, .cleanup, _) = VolumePublishRecovery(index: fixture.index).recover(staging: publication.stagingURL) else { return XCTFail("cleanup retry") }
    }
    func testCompletedRollbackCleanupFailureRetainsOriginalCause() throws {
        let fixture = try VolumePublishFixture()
        var operations = noTrash()
        operations.willRemove = { _ in throw Injected.failure }
        let publication = try fixture.begin(operations: operations) { if $0 == .s7 { throw Injected.readerUnavailable } }
        XCTAssertThrowsError(try publication.publish(progress: Progress())) {
            guard case VolumePublishError.rolledBack(let underlying, .some, .kept) = $0 else { return XCTFail("\($0)") }
            XCTAssertTrue(underlying.contains("readerUnavailable"))
        }
        try fixture.assertOld()
        guard case .recovered(_, .backward, _) = VolumePublishRecovery(index: fixture.index).recover(staging: publication.stagingURL) else { return XCTFail("cleanup retry") }
    }

    // 8: foreign new-only 名を保存し、foreign gate があっても先に自分の新巻を引き戻す。
    func testForeignNewOnlyNameDoesNotBlockRestoringOldSet() throws {
        let fixture = try VolumePublishFixture(), foreign = fixture.root.appendingPathComponent("archive.tar.005")
        let bytes = Data("unrelated".utf8)
        let publication = try fixture.begin { if $0 == .placedVolume(3) { try bytes.write(to: foreign) } }
        XCTAssertThrowsError(try publication.publish(progress: Progress())) {
            guard case VolumePublishError.rolledBack(_, nil, _) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        for (i, part) in fixture.oldParts.enumerated() {
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.scheme.fileName(forVolumeAt: i, count: 3))), part)
        }
        XCTAssertNil(try VolumePublishDirectory(fixture.root).info("archive.tar.004"))
        try fixture.assertRemoved(publication.stagingURL)
    }
    func testForeignNextNameAtS10StillWithdrawsNewSetAndRestoresOld() throws {
        let fixture = try VolumePublishFixture(), bytes = Data("foreign next name".utf8)
        let url = fixture.root.appendingPathComponent(fixture.plan.nextVolumeName)
        let publication = try fixture.begin { if $0 == .s9 { try bytes.write(to: url) } }
        XCTAssertThrowsError(try publication.publish(progress: Progress())) {
            guard case VolumePublishError.rolledBack(_, nil, _) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        for (i, part) in fixture.oldParts.enumerated() {
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.scheme.fileName(forVolumeAt: i, count: 3))), part)
        }
        XCTAssertNil(try VolumePublishDirectory(fixture.root).info("archive.tar.004"))
        try fixture.assertRemoved(publication.stagingURL)
    }
    func testForeignGateStillWithdrawsEveryProvenPlacedNewVolume() throws {
        for recovered in [false, true] {
            let fixture = try VolumePublishFixture(), foreign = Data("foreign gate".utf8)
            let publication = try fixture.begin { step in
                if step == .s8 {
                    try foreign.write(to: fixture.gate)
                    if recovered { throw SimulatedCrash() }
                }
            }
            XCTAssertThrowsError(try publication.publish(progress: Progress()))
            if recovered { guard case .held = VolumePublishRecovery(index: fixture.index).recover(staging: publication.stagingURL) else { return XCTFail("Foreign old name must HOLD") } }
            XCTAssertEqual(try Data(contentsOf: fixture.gate), foreign)
            let parent = try VolumePublishDirectory(fixture.root)
            for volume in fixture.plan.volumes.dropFirst() { XCTAssertNil(try parent.info(volume.name)) }
            XCTAssertNotNil(try VolumePublishDirectory(publication.stagingURL).info("abandoned"))
        }
    }
    func testCreateNewRollbackPreservesForeignGateAndWithdrawsItsOwnVolumes() throws {
        let fixture = try VolumePublishFixture(oldCount: 0), bytes = Data("foreign".utf8)
        let publication = try fixture.begin { step in
            if step == .s8 { try bytes.write(to: fixture.gate) }
        }
        XCTAssertThrowsError(try publication.publish(progress: Progress())) {
            guard case VolumePublishError.rolledBack(_, nil, _) = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.gate), bytes)
        for volume in fixture.plan.volumes.dropFirst() { XCTAssertNil(try VolumePublishDirectory(fixture.root).info(volume.name)) }
        try fixture.assertRemoved(publication.stagingURL)
    }
    func testRecoveryWithdrawsNewVolumesWhenForeignGateAppearsDuringCoordination() throws {
        let fixture = try VolumePublishFixture(), staging = try crash(fixture, at: .s8)
        let bytes = Data("foreign gate during coordination".utf8)
        var operations = VolumePublishOperations()
        operations.willCoordinate = { _ in try bytes.write(to: fixture.gate) }
        guard case .held = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: staging) else { return XCTFail("Foreign old gate must HOLD") }
        XCTAssertEqual(try Data(contentsOf: fixture.gate), bytes)
        for volume in fixture.plan.volumes.dropFirst() { XCTAssertNil(try VolumePublishDirectory(fixture.root).info(volume.name)) }
        let old = try VolumePublishDirectory(staging).directory("old")
        for (i, part) in fixture.oldParts.enumerated() {
            XCTAssertEqual(try Data(contentsOf: old.url.appendingPathComponent(fixture.scheme.fileName(forVolumeAt: i, count: 3))), part)
        }
    }

    // 9: hook は実 FULLFSYNC（非対応時 fsync）の完了後にのみ通知される。
    func testDurabilityBarriersPrecedeSiblingMovesGatePublicationAndDisposal() throws {
        let events = Mutex<[String]>([])
        var operations = noTrash()
        operations.didBarrier = { point in events.withLock { $0.append(String(describing: point)) } }
        operations.trash = { _ in events.withLock { $0.append("dispose") }; throw Injected.trashUnavailable }
        let fixture = try VolumePublishFixture()
        let publication = try fixture.begin(operations: operations) { step in
            if step == .s6 { XCTAssertTrue(events.withLock { $0.contains("retiredGate") }) }
            if step == .s8 {
                XCTAssertTrue(events.withLock { $0.contains("placedSiblings") })
                throw Injected.failure
            }
        }
        XCTAssertThrowsError(try publication.publish(progress: Progress()))
        let sequence = events.withLock { $0 }
        XCTAssertLessThan(try XCTUnwrap(sequence.firstIndex(of: "restoredSiblings")), try XCTUnwrap(sequence.firstIndex(of: "restoredOld")))
        XCTAssertLessThan(try XCTUnwrap(sequence.firstIndex(of: "restoredOld")), try XCTUnwrap(sequence.firstIndex(of: "dispose")))
        try fixture.assertOld()
    }
    func testBackwardRecoveryFlushesRestoredOldSetBeforeDisposal() throws {
        let fixture = try VolumePublishFixture(), staging = try crash(fixture, at: .s8), events = Mutex<[String]>([])
        let directory = try VolumePublishDirectory(staging)
        try VolumeExclusiveRename(usesFallback: false).move("new", from: directory, to: directory, as: "abandoned")
        var operations = noTrash()
        operations.didBarrier = { point in events.withLock { $0.append(String(describing: point)) } }
        operations.trash = { _ in events.withLock { $0.append("dispose") }; throw Injected.trashUnavailable }
        guard case .recovered(_, .backward, .removed) = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: staging) else { return XCTFail("backward recovery") }
        let sequence = events.withLock { $0 }
        XCTAssertLessThan(try XCTUnwrap(sequence.firstIndex(of: "restoredOld")), try XCTUnwrap(sequence.firstIndex(of: "dispose")))
        try fixture.assertOld(); try fixture.assertRemoved(staging)
    }

    // 10: coordinator の取得失敗は rename 前に HOLD。presenter も staging に連れて行かない。
    func testRecoveryCoordinatesBeforeMovingLiveNames() throws {
        let fixture = try VolumePublishFixture(), staging = try crash(fixture, at: .s7)
        let called = Mutex(false)
        var operations = VolumePublishOperations()
        operations.willCoordinate = { url in
            XCTAssertEqual(url, fixture.gate)
            called.withLock { $0 = true }
            throw Injected.failure
        }
        let before = try VolumePublishFixture.snapshot(fixture.root)
        guard case .held = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: staging) else { return XCTFail("claim failed") }
        XCTAssertTrue(called.withLock { $0 })
        XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
    }
    private nonisolated final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        init(_ url: URL) { presentedItemURL = url; super.init() }
    }
    func testRecoveryHoldsAnInProcessPresentedGateWithoutMovingIt() throws {
        let fixture = try VolumePublishFixture(), staging = try crash(fixture, at: .s7)
        let presenter = Presenter(fixture.gate)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let before = try VolumePublishFixture.snapshot(fixture.root)
        guard case .held(_, let reason, _) = VolumePublishRecovery(index: fixture.index).recover(staging: staging) else { return XCTFail("Presented gate must HOLD") }
        XCTAssertTrue(reason.contains("presented"))
        XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
    }

    // 11: didMount と同じ index-only 呼び出しを別 mount point から行う。
    func testIndexRecoversByUUIDAfterRemountAtDifferentPath() throws {
        let disk = try disk("APFS")
        defer { try? disk.detach() }
        let fixture = try VolumePublishFixture(parent: disk.mount), staging = try crash(fixture, at: .s7)
        let entry = try XCTUnwrap(fixture.index.entries().first)
        XCTAssertNotNil(entry.relativeStagingPath)
        let mount = disk.mount.deletingLastPathComponent().appendingPathComponent("remounted")
        try disk.detach(); try disk.attach(at: mount)
        let rebased = try XCTUnwrap(entry.resolved(on: mount, uuid: entry.volumeUUID))
        XCTAssertNotEqual(rebased.path, staging.path)
        let results = VolumePublishRecovery(index: fixture.index).recoverAll(mountedVolume: mount)
        XCTAssertTrue(results.contains { if case .recovered(_, .forward, _) = $0 { return true }; return false }, "\(results)")
        let root = rebased.deletingLastPathComponent()
        var joined = Data()
        for volume in fixture.plan.volumes { joined.append(try Data(contentsOf: root.appendingPathComponent(volume.name))) }
        XCTAssertEqual(joined, fixture.newBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rebased.path))
        XCTAssertTrue(try fixture.index.entries().isEmpty)
    }

    // 12a: intermediate symlink を差し替えても、保持 fd の xattr だけが読み書きされる。
    func testDescriptorXattrsCannotBeRedirectedByIntermediateSymlink() throws {
        let fixture = try VolumePublishFixture(oldCount: 0)
        let root = try VolumePublishDirectory(fixture.root)
        let real = try root.directory("real", create: true), evil = try root.directory("evil", create: true)
        for directory in [real, evil] {
            try Data("file".utf8).write(to: directory.url.appendingPathComponent("source"))
            try Data("out".utf8).write(to: directory.url.appendingPathComponent("output"))
        }
        let key = "com.shunnag.test.anchor"
        try setXattr(real.url.appendingPathComponent("source"), key, Data("real".utf8))
        try setXattr(evil.url.appendingPathComponent("source"), key, Data("evil".utf8))
        try setXattr(evil.url.appendingPathComponent("output"), key, Data("untouched".utf8))
        let output = try real.openFile("output", flags: O_RDWR), victim = try evil.openFile("output")
        defer { close(output); close(victim) }
        try FileManager.default.moveItem(at: real.url, to: fixture.root.appendingPathComponent("moved"))
        try FileManager.default.createSymbolicLink(at: real.url, withDestinationURL: evil.url)
        let attributes = try VolumeSplitter.Attributes(directory: real, name: "source")
        XCTAssertEqual(attributes.xattrs[key], Data("real".utf8))
        try attributes.apply(to: output, quarantine: nil)
        func value(_ fd: Int32) throws -> Data {
            let size = fgetxattr(fd, key, nil, 0, 0, 0)
            guard size >= 0 else { throw VolumePublishError.system(errno) }
            var bytes = Data(count: size)
            XCTAssertEqual(bytes.withUnsafeMutableBytes { fgetxattr(fd, key, $0.baseAddress, $0.count, 0, 0) }, size)
            return bytes
        }
        XCTAssertEqual(try value(output), Data("real".utf8))
        XCTAssertEqual(try value(victim), Data("untouched".utf8))
    }
    func testFAT32OversizedWorkIsRefusedAtS0BeforeAnyStagingWrites() throws {
        let fixture = try VolumePublishFixture(oldCount: 0)
        var operations = VolumePublishOperations()
        operations.volumeInfo = { parent in
            let actual = try VolumePublishFS.volumeInfo(parent)
            return .init(uuid: actual.uuid, cacheIdentity: actual.cacheIdentity, fileSystem: "msdos", available: .max, hazard: "msdos")
        }
        let target = VolumeSetTarget(parent: fixture.root, newSetScheme: fixture.scheme,
            schedule: .uniform(size: 1024 * 1024 * 1024), allowHazardousVolume: true)
        XCTAssertThrowsError(try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(UInt32.max), index: fixture.index, operations: operations)) {
            XCTAssertEqual($0 as? VolumePublishError, .fat32WorkFileTooLarge(length: UInt64(UInt32.max)))
        }
        XCTAssertTrue(try VolumePublishDirectory(fixture.root).names().isEmpty)
        XCTAssertTrue(try fixture.index.entries().isEmpty)
        XCTAssertNoThrow(try VolumeSetPublication.checkWorkLength(UInt64(UInt32.max) - 1, fileSystem: "msdos"))
        XCTAssertNoThrow(try VolumeSetPublication.checkWorkLength(UInt64(UInt32.max), fileSystem: "exfat"))
    }
    func testUnchangedVolumesAreNotRehashedWhileGateIsAbsent() throws {
        for fatIdentity in [false, true] {
            let fixture = try VolumePublishFixture(), absent = Mutex(false), hashesWhileAbsent = Mutex<[URL]>([])
            let oldHashesBeforeS6 = Mutex<[URL]>([])
            var operations = VolumePublishOperations()
            if fatIdentity {
                operations.volumeInfo = { parent in
                    let actual = try VolumePublishFS.volumeInfo(parent)
                    return .init(uuid: actual.uuid, cacheIdentity: actual.cacheIdentity, fileSystem: "msdos", available: actual.available, hazard: "msdos")
                }
            }
            operations.didHash = { url in
                if absent.withLock({ $0 }) { hashesWhileAbsent.withLock { $0.append(url) } }
                else if url.deletingLastPathComponent() == fixture.root { oldHashesBeforeS6.withLock { $0.append(url) } }
            }
            let publication = try fixture.begin(consent: fatIdentity, operations: operations) { step in
                if step == .s6 {
                    if fatIdentity { XCTAssertEqual(oldHashesBeforeS6.withLock { $0 }, fixture.layout?.volumes.map(\.url)) }
                    absent.withLock { $0 = true }
                }
                if step == .s9 { absent.withLock { $0 = false } }
            }
            _ = try publication.publish(progress: Progress())
            XCTAssertEqual(hashesWhileAbsent.withLock { $0 }, [])
            try fixture.assertNew()
        }
    }
    func testFixtureAssertionsDetectCreateAndShrinkOrphansBeyondGap() throws {
        let empty = try VolumePublishFixture(oldCount: 0, newCount: 3)
        try Data("orphan".utf8).write(to: empty.root.appendingPathComponent("archive.tar.003"))
        try XCTExpectFailure("The fixture must reject create-new orphans") { try empty.assertOld() }
        let shrink = try VolumePublishFixture(oldCount: 5, newCount: 2), publication = try shrink.begin()
        _ = try publication.publish(progress: Progress())
        try Data("orphan".utf8).write(to: shrink.root.appendingPathComponent("archive.tar.005"))
        try XCTExpectFailure("The fixture must reject surplus volumes past a gap") { try shrink.assertNew() }
        try Data("wider orphan".utf8).write(to: shrink.root.appendingPathComponent("archive.tar.1000"))
        try FileManager.default.removeItem(at: shrink.root.appendingPathComponent("archive.tar.005"))
        try XCTExpectFailure("The fixture must reject wider numeric suffixes too") { try shrink.assertNew() }
    }
}
