import Darwin
import Foundation
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class VolumePublishRound4Tests: XCTestCase {
    private enum Fault: Error { case io }
    private func noTrash() -> VolumePublishOperations {
        var operations = VolumePublishOperations()
        operations.trash = { _ in throw Fault.io }
        return operations
    }

    /// Real S4 bytes and transaction primitives; no coordinator or archive API substitutes.
    private func staged(_ fixture: VolumePublishFixture, operations: VolumePublishOperations = .init(),
                        consent: Bool = false) throws -> VolumePublishTransaction {
        var publication: VolumeSetPublication? = try fixture.begin(consent: consent, operations: operations)
        let url = publication!.stagingURL, work = publication!.workURL
        publication = nil
        let parent = try VolumePublishDirectory(fixture.root), staging = try parent.directory(url.lastPathComponent)
        let journal = try VolumePublishJournal(staging: staging, create: false)
        var record = try journal.read()
        record.newVolumes = try VolumeSplitter.split(workURL: work, into: staging.directory("new"), plan: fixture.plan, oldLayout: fixture.layout)
        record.totalLength = fixture.plan.totalLength
        var transaction = VolumePublishTransaction(parent: parent, staging: staging, journal: journal,
            renamer: .init(usesFallback: false), index: fixture.index, record: record, operations: operations)
        try transaction.validateNew(in: staging.directory("new"), options: fixture.readerOptions)
        try transaction.phase(.prepared)
        return transaction
    }

    private func lockURL(_ staging: URL, index: RecoverableWorkIndex) -> URL {
        index.stagingLocksURL.appendingPathComponent(staging.lastPathComponent + ".lock")
    }

    func testFSKitFATLaunchResolvesChangedMountPathAndRecordsFileSystem() throws {
        for kind in ["msdos", "exfat", "future-data-fs"] {
            let fixture = try VolumePublishFixture()
            var operations = noTrash()
            operations.volumeInfo = { directory in
                let actual = try VolumePublishFS.volumeInfo(directory)
                return .init(uuid: actual.uuid, cacheIdentity: actual.cacheIdentity, fileSystem: kind,
                             available: actual.available, hazard: kind)
            }
            let transaction = try staged(fixture, operations: operations, consent: true)
            transaction.journal.release()
            let entry = try XCTUnwrap(fixture.index.entries().first)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
            XCTAssertEqual(json["fileSystem"] as? String, kind)
            let stale = fixture.root.appendingPathComponent("old-mount").appendingPathComponent(transaction.staging.url.lastPathComponent)
            try fixture.index.rebase(entry, to: stale)
            let root = try VolumePublishFS.volumeRoot(transaction.parent)
            operations.mountedVolumes = { fileSystems in
                XCTAssertTrue(fileSystems.contains(kind))
                guard VolumePublishFS.shouldProbeMount(flags: UInt32(MNT_LOCAL), extendedFlags: UInt32(MNT_EXT_FSKIT),
                    kind: kind, includeNonLocal: false, fileSystems: fileSystems) else { return [] }
                return [.init(root: root, uuid: entry.volumeUUID)]
            }
            let results = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
            XCTAssertTrue(results.contains { if case .recovered = $0 { return true }; return false }, "\(results)")
            try fixture.assertOld(); try fixture.assertRemoved(transaction.staging.url)
        }
    }

    func testBadMountIsReportedWithoutBlockingHealthyRecoveryOrPruningMissingHint() throws {
        for failure in [EACCES, ENOENT, ETIMEDOUT] {
            let fixture = try VolumePublishFixture(), transaction = try staged(fixture)
            transaction.journal.release()
            let entry = try XCTUnwrap(fixture.index.entries().first)
            let stale = fixture.root.appendingPathComponent("old-mount").appendingPathComponent(transaction.staging.url.lastPathComponent)
            try fixture.index.rebase(entry, to: stale)
            let missing = fixture.root.appendingPathComponent(VolumePublishFS.stagingPrefix + UUID().uuidString)
            try fixture.index.register(missing, volumeUUID: entry.volumeUUID, gateName: fixture.plan.gateName)
            let root = try VolumePublishFS.volumeRoot(transaction.parent), bad = fixture.root.appendingPathComponent("bad-mount")
            let resume = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
            defer { resume.signal() }
            var operations = noTrash()
            operations.mountedVolumes = { _ in
                VolumePublishFS.probeMounts([bad, root], timeout: 0.05) { candidate in
                    if candidate == bad {
                        if failure == ETIMEDOUT {
                            _ = resume.wait(timeout: .now() + 5)
                            finished.signal()
                        }
                        throw VolumePublishError.system(failure)
                    }
                    return .init(root: candidate, uuid: entry.volumeUUID)
                }
            }
            let results = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
            XCTAssertTrue(results.contains { if case .held(let url, let reason, _) = $0 { return url == bad && reason.contains("\(failure)") }; return false })
            XCTAssertTrue(results.contains { if case .recovered(let url, _, _) = $0 { return url == transaction.staging.url }; return false }, "\(results)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.staging.url.path))
            XCTAssertEqual(try fixture.index.entries().map(\.stagingPath), [missing.path], "An incomplete enumeration must retain absent hints")
            try fixture.assertOld()
            resume.signal()
            if failure == ETIMEDOUT { XCTAssertEqual(finished.wait(timeout: .now() + 2), .success) }
            operations.mountedVolumes = { _ in [.init(root: root, uuid: entry.volumeUUID)] }
            _ = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
            XCTAssertTrue(try fixture.index.entries().isEmpty, "A later complete scan can prune the missing hint")
        }
    }

    func testFSKitDeviceAndVirtualMountsStayExcludedEvenWhenRecorded() {
        for kind in ["autofs", "devfs", "nullfs", "DeviceFS", "fskit"] {
            for includeNonLocal in [false, true] {
                XCTAssertFalse(VolumePublishFS.shouldProbeMount(flags: UInt32(MNT_LOCAL), extendedFlags: UInt32(MNT_EXT_FSKIT),
                    kind: kind, includeNonLocal: includeNonLocal, fileSystems: [kind.lowercased()]))
            }
        }
    }

    func testRunningMountTriggerGetsAnotherPassAndItsOwnCompletions() throws {
        let fixture = try VolumePublishFixture(), entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0), calls = Mutex(0), completionRuns = Mutex<[Int]>([])
        let queue = VolumePublishRecoveryQueue { _, _ in
            let run = calls.withLock { $0 += 1; return $0 }
            if run == 1 { entered.signal(); _ = resume.wait(timeout: .now() + 5) }
        }
        defer { resume.signal() }
        queue.schedule(index: fixture.index, mountedVolume: fixture.root) { completed.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        for _ in 0..<10 {
            queue.schedule(index: fixture.index, mountedVolume: fixture.root) {
                let run = calls.withLock { $0 }
                completionRuns.withLock { $0.append(run) }
                completed.signal()
            }
        }
        resume.signal()
        for _ in 0..<11 { XCTAssertEqual(completed.wait(timeout: .now() + 2), .success) }
        XCTAssertEqual(calls.withLock { $0 }, 2)
        XCTAssertEqual(completionRuns.withLock { $0 }, Array(repeating: 2, count: 10))
    }

    func testStalledUnknownStoredPathDoesNotBlockLocalRecoveryOrNextMountJob() throws {
        let remote = try VolumePublishFixture(), local = try VolumePublishFixture()
        let remoteStage = try staged(remote), localStage = try staged(local)
        remoteStage.journal.release(); localStage.journal.release()
        try remote.index.removeCompleted(remoteStage.staging.url)
        try remote.index.register(remoteStage.staging.url, volumeUUID: "unknown-volume", gateName: remote.plan.gateName, nonLocalVolume: true)
        let localVolume = try VolumePublishFS.volumeInfo(localStage.parent)
        try remote.index.register(localStage.staging.url, volumeUUID: localVolume.uuid, gateName: local.plan.gateName)
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let probes = Mutex(0), results = Mutex<[VolumePublishRecovery.Result]>([])
        var operations = noTrash()
        operations.mountedVolumes = { _ in XCTFail("The unresolved UUID is unknown"); return [] }
        operations.volumeInfo = { parent in
            if parent.url == remote.root {
                probes.withLock { $0 += 1 }; entered.signal()
                _ = resume.wait(timeout: .now() + 5)
                throw Fault.io
            }
            return try VolumePublishFS.volumeInfo(parent)
        }
        let recovery = VolumePublishRecovery(index: remote.index, operations: operations)
        let queue = VolumePublishRecoveryQueue { _, mount in
            if mount == nil { let values = recovery.recoverAll(); results.withLock { $0 = values } }
        }
        defer { resume.signal() }
        queue.schedule(index: remote.index)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        queue.schedule(index: remote.index, mountedVolume: local.root) { finished.signal() }
        let completedInTime = finished.wait(timeout: .now() + 2)
        XCTAssertEqual(completedInTime, .success, "A stored-path probe must give up after one second")
        resume.signal()
        if completedInTime != .success { XCTAssertEqual(finished.wait(timeout: .now() + 2), .success) }
        XCTAssertEqual(probes.withLock { $0 }, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localStage.staging.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteStage.staging.url.path))
        XCTAssertEqual(try remote.index.entries().map(\.stagingPath), [remoteStage.staging.url.path])
        XCTAssertTrue(results.withLock { $0.contains { if case .held(let url, _, _) = $0 { return url == remoteStage.staging.url }; return false } })
    }

    func testSetLockCollisionDoesNotAcquireOrCreateStagingLock() throws {
        let fixture = try VolumePublishFixture(), transaction = try staged(fixture)
        transaction.journal.release()
        let file = lockURL(transaction.staging.url, index: fixture.index)
        try FileManager.default.removeItem(at: file)
        let volume = try VolumePublishFS.volumeInfo(transaction.parent)
        let lock = try VolumePublishLock.setLock(volumeUUID: volume.uuid, gateInode: nil, parent: fixture.root,
            gate: fixture.plan.gateName, directory: fixture.index.setLocksURL)
        defer { lock.release() }
        XCTAssertEqual(VolumePublishRecovery(index: fixture.index).recover(staging: transaction.staging.url), .owned(transaction.staging.url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Recovery must obtain the set lock before acquiring a staging lock")
    }

    func testBeginReportsLiveSameStemStagingAsRetryableBusy() throws {
        let fixture = try VolumePublishFixture(), transaction = try staged(fixture)
        transaction.journal.release()
        let lock = try VolumePublishLock.stagingLock(transaction.staging.url.lastPathComponent, directory: fixture.index.stagingLocksURL)
        XCTAssertThrowsError(try fixture.begin()) { XCTAssertEqual($0 as? VolumePublishError, .ownerAlive) }
        lock.release()
        let retry = try fixture.begin()
        retry.cancel()
        try fixture.assertOld(); try fixture.assertRemoved(transaction.staging.url)
    }

    func testResolvedPublicationRemovesStagingLockForCancelCommitAndRollback() throws {
        let cancelled = try VolumePublishFixture(), publication = try cancelled.begin()
        let file = lockURL(publication.stagingURL, index: cancelled.index)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        publication.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        for rollback in [false, true] {
            let fixture = try VolumePublishFixture()
            var transaction = try staged(fixture, operations: noTrash())
            try transaction.retireOld(hook: { _ in }); _ = try transaction.placeNew(hook: { _ in })
            if rollback { try transaction.rollback(); _ = try transaction.dispose("abandoned") }
            else { try transaction.validateHashes(in: transaction.parent); try transaction.phase(.done); _ = try transaction.dispose("old") }
            try transaction.removeEmptyStaging()
            XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL(transaction.staging.url, index: fixture.index).path))
            try fixture.assertRemoved(transaction.staging.url)
        }
    }

    func testLaunchSweepsUnindexedStagingLocksButPreservesHeldAndIndexedLocks() throws {
        let fixture = try VolumePublishFixture()
        let orphan = fixture.root.appendingPathComponent(VolumePublishFS.stagingPrefix + UUID().uuidString)
        let held = fixture.root.appendingPathComponent(VolumePublishFS.stagingPrefix + UUID().uuidString)
        let staleLock = try VolumePublishLock.stagingLock(orphan.lastPathComponent, directory: fixture.index.stagingLocksURL)
        staleLock.release()
        let liveLock = try VolumePublishLock.stagingLock(held.lastPathComponent, directory: fixture.index.stagingLocksURL)
        defer { liveLock.release() }
        var operations = noTrash()
        operations.mountedVolumes = { _ in XCTFail("Orphan lock sweep must not probe volumes"); return [] }
        operations.volumeInfo = { _ in XCTFail("Empty index must not probe paths"); throw Fault.io }
        _ = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL(orphan, index: fixture.index).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL(held, index: fixture.index).path))
        liveLock.release()
        try fixture.index.register(held, volumeUUID: "unknown-volume", gateName: fixture.plan.gateName)
        _ = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL(held, index: fixture.index).path))
        XCTAssertEqual(try fixture.index.entries().count, 1)
    }

    func testAutomaticCompletionRemovesUnknownUUIDHintsForEveryCleanupDirection() throws {
        for phase in [VolumePublishJournalRecord.Phase.prepared, .placed, .done, .abandoned] {
            let fixture = try VolumePublishFixture()
            var operations = noTrash()
            operations.volumeInfo = { directory in
                let actual = try VolumePublishFS.volumeInfo(directory)
                return .init(uuid: "unknown-volume", cacheIdentity: actual.cacheIdentity, fileSystem: "smbfs",
                             available: actual.available, hazard: "non-local")
            }
            var transaction = try staged(fixture, operations: operations, consent: true)
            if phase != .prepared {
                try transaction.retireOld(hook: { _ in }); _ = try transaction.placeNew(hook: { _ in })
                if phase == .done { try transaction.phase(.done) }
                if phase == .abandoned { try transaction.rollback() }
            }
            transaction.journal.release()
            operations.mountedVolumes = { _ in XCTFail("Known stored staging must not enumerate"); return [] }
            let results = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
            XCTAssertTrue(results.contains { if case .recovered = $0 { return true }; return false }, "\(results)")
            try fixture.assertRemoved(transaction.staging.url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL(transaction.staging.url, index: fixture.index).path))
            if phase == .prepared || phase == .abandoned { try fixture.assertOld() } else { try fixture.assertNew() }
        }
    }

    func testParentScanOfMovedFolderRemovesOriginalHintOnCompletion() throws {
        let fixture = try VolumePublishFixture(), transaction = try staged(fixture)
        transaction.journal.release()
        let moved = fixture.root.deletingLastPathComponent().appendingPathComponent("moved-" + UUID().uuidString)
        try FileManager.default.moveItem(at: fixture.root, to: moved)
        var operations = noTrash()
        operations.mountedVolumes = { _ in [] }
        let results = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll(parents: [moved])
        XCTAssertTrue(results.contains { if case .recovered = $0 { return true }; return false }, "\(results)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(transaction.staging.url.lastPathComponent).path))
        XCTAssertTrue(try fixture.index.entries().isEmpty)
    }

    func testTombstoneCompletionRemovesUnknownHintAndLockAtDidMount() throws {
        let fixture = try VolumePublishFixture(), transaction = try staged(fixture)
        transaction.journal.release()
        let entry = try XCTUnwrap(fixture.index.entries().first)
        try fixture.index.removeCompleted(transaction.staging.url)
        try fixture.index.register(transaction.staging.url, volumeUUID: "unknown-volume", gateName: entry.gateName)
        let tombstone = URL(fileURLWithPath: transaction.staging.url.path + ".discard", isDirectory: true)
        try FileManager.default.moveItem(at: transaction.staging.url, to: tombstone)
        try FileManager.default.removeItem(at: tombstone.appendingPathComponent("journal"))
        var operations = noTrash()
        operations.mountedVolumes = { _ in XCTFail("didMount must not enumerate"); return [] }
        let results = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll(mountedVolume: fixture.root)
        XCTAssertTrue(results.contains { if case .recovered = $0 { return true }; return false }, "\(results)")
        try fixture.assertRemoved(transaction.staging.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL(transaction.staging.url, index: fixture.index).path))
    }

    func testVerificationReportCoversRound4RecoveryRules() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let report = try String(contentsOf: repo.appendingPathComponent("Documentation/verification/2026-09-23-volume-set-publisher.md"), encoding: .utf8)
        for term in ["Round 4", "FSKit", "incomplete enumeration", "set lock → staging lock", "running job", "stored-path probes", "unlink"] {
            XCTAssertTrue(report.contains(term), "Missing round-4 rule: \(term)")
        }
    }
}
