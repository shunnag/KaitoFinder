import Darwin
import Foundation
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class VolumePublishRound3Tests: XCTestCase {
    private enum Fault: Error { case io }
    private func noTrash() -> VolumePublishOperations {
        var operations = VolumePublishOperations()
        operations.trash = { _ in throw Fault.io }
        return operations
    }

    /// Real split/validation/rename primitives produce crash states without needing a coordinator claim.
    private func staged(_ fixture: VolumePublishFixture, operations: VolumePublishOperations = .init()) throws -> VolumePublishTransaction {
        var publication: VolumeSetPublication? = try fixture.begin(operations: operations)
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

    func testEmptyIndexNeverEntersBlockingMountProbe() throws {
        let fixture = try VolumePublishFixture()
        let probed = Mutex(false), unblock = DispatchSemaphore(value: 0)
        var operations = noTrash()
        operations.mountedVolumes = { _ in
            probed.withLock { $0 = true }
            _ = unblock.wait(timeout: .now() + 0.1)
            return []
        }
        XCTAssertTrue(VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll().isEmpty)
        XCTAssertFalse(probed.withLock { $0 }, "An empty index must not touch any mount")
    }

    func testDidMountProbesOnlyNotifiedVolume() throws {
        let fixture = try VolumePublishFixture(), transaction = try staged(fixture)
        transaction.journal.release()
        let probes = Mutex<[URL]>([]), mount = fixture.root
        var operations = noTrash()
        operations.mountedVolumes = { _ in XCTFail("didMount must not enumerate other mounts"); return [] }
        operations.volumeInfo = { directory in
            probes.withLock { $0.append(directory.url) }
            return try VolumePublishFS.volumeInfo(directory)
        }
        let results = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll(mountedVolume: mount)
        XCTAssertTrue(results.contains { if case .recovered = $0 { return true }; return false }, "\(results)")
        XCTAssertEqual(probes.withLock { $0 }, [mount])
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.staging.url.path))
    }

    func testMountProbeRunsBeforeSetLockAndOnlyOnceForAbsentStage() throws {
        let fixture = try VolumePublishFixture(), parent = try VolumePublishDirectory(fixture.root)
        let volume = try VolumePublishFS.volumeInfo(parent), root = try VolumePublishFS.volumeRoot(parent)
        let url = fixture.root.appendingPathComponent(VolumePublishFS.stagingPrefix + UUID().uuidString)
        try fixture.index.register(url, volumeUUID: volume.uuid, gateName: fixture.plan.gateName)
        let calls = Mutex(0)
        var operations = noTrash()
        operations.mountedVolumes = { _ in
            calls.withLock { $0 += 1 }
            let lock = try VolumePublishLock.setLock(volumeUUID: volume.uuid, gateInode: nil, parent: fixture.root,
                gate: fixture.plan.gateName, directory: fixture.index.setLocksURL)
            lock.release()
            return [.init(root: root, uuid: volume.uuid)]
        }
        let result = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: url)
        guard case .recovered = result else { return XCTFail("Probe ran with the set lock held: \(result)") }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testHeldDoneBackupAllowsThirdSaveAfterDifferentOrLargerGeneration() throws {
        for count in [5, 7, 2] {
            let fixture = try VolumePublishFixture()
            var first = try staged(fixture, operations: noTrash())
            try first.retireOld(hook: { _ in }); _ = try first.placeNew(hook: { _ in })
            try first.validateHashes(in: first.parent); try first.phase(.done)
            try Data("externally changed backup".utf8).write(to: first.staging.url.appendingPathComponent("old/" + fixture.plan.gateName))
            first.journal.release()
            let layout = ArchiveVolumeLayout(scheme: fixture.scheme, volumes: fixture.plan.volumes.map {
                .init(url: fixture.root.appendingPathComponent($0.name), length: $0.length)
            }, openedVolumeIndex: 0)
            let plan = try VolumePlan(totalLength: UInt64(fixture.oldBytes.count),
                schedule: .uniform(size: UInt64((fixture.oldBytes.count + count - 1) / count)), scheme: fixture.scheme)
            let target = VolumeSetTarget(parent: fixture.root, layout: layout, expected: try ArchiveSetIdentity.capture(layout: layout),
                schedule: .uniform(size: plan.largestVolume))
            var publication: VolumeSetPublication? = try VolumeSetPublication.begin(target, estimatedOutputLength: plan.totalLength,
                index: fixture.index, operations: noTrash())
            let url = publication!.stagingURL, work = publication!.workURL
            try fixture.oldBytes.write(to: work); publication = nil
            let staging = try VolumePublishDirectory(url), journal = try VolumePublishJournal(staging: staging, create: false)
            var record = try journal.read()
            record.newVolumes = try VolumeSplitter.split(workURL: work, into: staging.directory("new"), plan: plan, oldLayout: layout)
            record.totalLength = plan.totalLength
            var second = VolumePublishTransaction(parent: first.parent, staging: staging, journal: journal,
                renamer: .init(usesFallback: false), index: fixture.index, record: record, operations: noTrash())
            try second.validateNew(in: staging.directory("new")); try second.phase(.prepared)
            try second.retireOld(hook: { _ in }); _ = try second.placeNew(hook: { _ in })
            try second.validateHashes(in: second.parent); try second.phase(.done)
            _ = try second.dispose("old"); try second.removeEmptyStaging(); journal.release()
            let current = ArchiveVolumeLayout(scheme: fixture.scheme, volumes: plan.volumes.map {
                .init(url: fixture.root.appendingPathComponent($0.name), length: $0.length)
            }, openedVolumeIndex: 0)
            let thirdTarget = VolumeSetTarget(parent: fixture.root, layout: current, expected: try ArchiveSetIdentity.capture(layout: current),
                schedule: .uniform(size: plan.largestVolume))
            do {
                let third = try VolumeSetPublication.begin(thirdTarget, estimatedOutputLength: plan.totalLength,
                    index: fixture.index, operations: noTrash())
                third.cancel()
            } catch { XCTFail("Third save with \(count) volumes: \(error)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: first.staging.url.appendingPathComponent("old").path))
            XCTAssertEqual(try Data(contentsOf: first.staging.url.appendingPathComponent("old/" + fixture.plan.gateName)), Data("externally changed backup".utf8))
            let recorded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(VolumePublishJournal.inspect(first.staging))) as? [String: Any])
            XCTAssertEqual(recorded["keptOldVolumes"] as? Bool, true)
        }
    }

    func testUnknownUUIDStoredJournalRecoversAndRemovesCompletedHint() throws {
        let fixture = try VolumePublishFixture()
        var operations = noTrash()
        operations.volumeInfo = { directory in
            let info = try VolumePublishFS.volumeInfo(directory)
            return .init(uuid: "unknown-volume", cacheIdentity: info.cacheIdentity, fileSystem: info.fileSystem,
                         available: info.available, hazard: nil)
        }
        let transaction = try staged(fixture, operations: operations)
        transaction.journal.release()
        operations.mountedVolumes = { _ in [] }
        let results = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
        XCTAssertTrue(results.contains { if case .recovered = $0 { return true }; return false }, "\(results)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.staging.url.path))
        XCTAssertTrue(try fixture.index.entries().isEmpty, "Completed recovery removes the hint even with an unknown UUID")
        try fixture.assertOld()
    }

    func testRebasedParentCannotDiscardLiveJournalLessS1() throws {
        let fixture = try VolumePublishFixture()
        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + fixture.root.path, isDirectory: true)
        guard let directory = try? VolumePublishDirectory(alias) else { throw XCTSkip("Requires the boot Data firmlink") }
        let originalDirectory = try VolumePublishDirectory(fixture.root)
        var original = stat(), other = stat()
        XCTAssertEqual(fstat(originalDirectory.fd, &original), 0)
        XCTAssertEqual(fstat(directory.fd, &other), 0)
        guard original.st_dev == other.st_dev, original.st_ino == other.st_ino else { throw XCTSkip("Not the same boot directory") }
        let publication = try fixture.begin { step in
            guard step == .stagingCreated else { return }
            let entry = try XCTUnwrap(fixture.index.entries().first)
            let url = alias.appendingPathComponent(URL(fileURLWithPath: entry.stagingPath).lastPathComponent)
            XCTAssertEqual(VolumePublishRecovery(index: fixture.index).recover(staging: url), .owned(url))
            XCTAssertTrue(FileManager.default.fileExists(atPath: entry.stagingPath))
        }
        publication.cancel()
    }

    func testUnreadableJournalNeverDiscardsUnderscoreVolumes() throws {
        for region in ["old", "new", "abandoned"] {
            let fixture = try VolumePublishFixture(), parent = try VolumePublishDirectory(fixture.root)
            let staging = try parent.directory(VolumePublishFS.stagingPrefix + UUID().uuidString, create: true)
            let directory = try staging.directory(region, create: true)
            let file = directory.url.appendingPathComponent("._scan.tar.001"), bytes = Data("only surviving volume".utf8)
            try bytes.write(to: file)
            try Data("unreadable journal".utf8).write(to: staging.url.appendingPathComponent("journal"))
            let before = try VolumePublishFixture.snapshot(fixture.root)
            guard case .held = VolumePublishRecovery(index: fixture.index).recover(staging: staging.url)
            else { XCTFail("An arbitrary ._ name is not metadata"); continue }
            XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
        }
    }

    func testDiscardClosesJournalBeforeFirstRemoval() throws {
        let fixture = try VolumePublishFixture()
        var transaction = try staged(fixture)
        let journal = transaction.journal, checked = Mutex(false)
        var operations = noTrash()
        operations.willRemove = { _ in
            if !checked.withLock({ value in let was = value; value = true; return was }) {
                XCTAssertThrowsError(try journal.read(), "No journal handle may remain open across the tombstone rename")
            }
        }
        transaction.operations = operations
        _ = try transaction.discardPrepared()
        XCTAssertTrue(checked.withLock { $0 })
        try fixture.assertRemoved(transaction.staging.url)
    }

    func testRecoveryVolumeProbeDoesNotHoldProcessMutex() throws {
        let first = try VolumePublishFixture(), second = try VolumePublishFixture()
        let firstStage = try staged(first), secondStage = try staged(second)
        firstStage.journal.release(); secondStage.journal.release()
        let completed = DispatchSemaphore(value: 0)
        var operations = noTrash()
        operations.volumeInfo = { parent in
            Thread.detachNewThread {
                _ = VolumePublishRecovery(index: second.index).recover(staging: secondStage.staging.url)
                completed.signal()
            }
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success, "A volume probe held the process-wide recovery mutex")
            return try VolumePublishFS.volumeInfo(parent)
        }
        guard case .recovered = VolumePublishRecovery(index: first.index, operations: operations).recover(staging: firstStage.staging.url)
        else { return XCTFail("Prepared recovery failed") }
    }

    func testMountCandidatesExcludeUnrelatedNetworkAndVirtualRootsButIncludeFSKitFAT() {
        XCTAssertTrue(VolumePublishFS.shouldProbeMount(flags: UInt32(MNT_LOCAL), extendedFlags: 0, kind: "apfs", includeNonLocal: false))
        for kind in ["autofs", "devfs", "nullfs", "devicefs", "fskit"] {
            XCTAssertFalse(VolumePublishFS.shouldProbeMount(flags: UInt32(MNT_LOCAL), extendedFlags: 0, kind: kind, includeNonLocal: false))
        }
        XCTAssertFalse(VolumePublishFS.shouldProbeMount(flags: 0, extendedFlags: 0, kind: "smbfs", includeNonLocal: false))
        XCTAssertTrue(VolumePublishFS.shouldProbeMount(flags: UInt32(MNT_LOCAL), extendedFlags: UInt32(MNT_EXT_FSKIT), kind: "msdos", includeNonLocal: false))
        XCTAssertTrue(VolumePublishFS.shouldProbeMount(flags: 0, extendedFlags: 0, kind: "smbfs", includeNonLocal: true))
    }

    func testTimedOutMountProbeReusesItsOutstandingWorker() throws {
        let fixture = try VolumePublishFixture(), calls = Mutex(0), unblock = DispatchSemaphore(value: 0)
        defer { unblock.signal() }
        let probe: @Sendable () throws -> VolumePublishFS.MountedVolume? = {
            calls.withLock { $0 += 1 }
            _ = unblock.wait(timeout: .now() + 5)
            return nil
        }
        for _ in 0..<3 {
            XCTAssertThrowsError(try VolumePublishMountProbe.run(root: fixture.root, timeout: 0.05, probe: probe)) {
                XCTAssertEqual($0 as? VolumePublishError, .system(ETIMEDOUT))
            }
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testRecoveryQueueCoalescesMountsAndRunsSeriallyOffCaller() throws {
        let fixture = try VolumePublishFixture(), entered = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0), calls = Mutex<[URL?]>([])
        let other = fixture.root.appendingPathComponent("other-mount")
        let queue = VolumePublishRecoveryQueue { _, mount in
            XCTAssertFalse(Thread.isMainThread)
            let first = calls.withLock { $0.append(mount); return $0.count == 1 }
            if first { entered.signal(); _ = unblock.wait(timeout: .now() + 5) }
        }
        defer { unblock.signal() }
        queue.schedule(index: fixture.index, mountedVolume: fixture.root) { finished.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        for _ in 0..<10 { queue.schedule(index: fixture.index, mountedVolume: fixture.root) { finished.signal() } }
        queue.schedule(index: fixture.index, mountedVolume: other) { finished.signal() }
        XCTAssertEqual(calls.withLock { $0.count }, 1)
        unblock.signal()
        for _ in 0..<12 { XCTAssertEqual(finished.wait(timeout: .now() + 2), .success) }
        XCTAssertEqual(calls.withLock { $0 }, [fixture.root, fixture.root, other])
    }

    func testDuplicateUUIDStoredJournalRecoversAndMissingHintIsRetained() throws {
        let fixture = try VolumePublishFixture(), transaction = try staged(fixture)
        transaction.journal.release()
        let volume = try VolumePublishFS.volumeInfo(transaction.parent), root = try VolumePublishFS.volumeRoot(transaction.parent)
        var operations = noTrash()
        operations.mountedVolumes = { _ in [.init(root: root, uuid: volume.uuid), .init(root: fixture.root, uuid: volume.uuid)] }
        let recovery = VolumePublishRecovery(index: fixture.index, operations: operations)
        XCTAssertTrue(recovery.recoverAll().contains { if case .recovered = $0 { return true }; return false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.staging.url.path))
        XCTAssertTrue(try fixture.index.entries().isEmpty, "Completed work does not retain a clone hint")
        // Absence alone still cannot identify which clone held an unresolved staging.
        try fixture.index.register(transaction.staging.url, volumeUUID: volume.uuid, gateName: fixture.plan.gateName)
        _ = recovery.recoverAll()
        XCTAssertEqual(try fixture.index.entries().count, 1, "Clone ambiguity must not prune a missing hint")
    }

    func testStoredPathRecoveryRemovesHintWithoutEnumeratingOnEitherPass() throws {
        let fixture = try VolumePublishFixture(), transaction = try staged(fixture)
        transaction.journal.release()
        var operations = noTrash()
        operations.mountedVolumes = { _ in XCTFail("An existing stored staging needs no mount enumeration"); return [] }
        _ = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.staging.url.path))
        XCTAssertTrue(try fixture.index.entries().isEmpty)
        _ = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
        XCTAssertTrue(try fixture.index.entries().isEmpty)
    }

    func testUnknownUUIDRejectsMismatchedStoredJournal() throws {
        let fixture = try VolumePublishFixture(), transaction = try staged(fixture)
        transaction.journal.release()
        let entry = try XCTUnwrap(fixture.index.entries().first)
        try fixture.index.removeCompleted(transaction.staging.url)
        try fixture.index.register(transaction.staging.url, volumeUUID: "unknown-volume", gateName: "another.tar.001")
        var operations = noTrash()
        operations.mountedVolumes = { _ in XCTFail("An unknown UUID cannot be resolved by enumeration"); return [] }
        _ = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.stagingPath))
        XCTAssertEqual(try fixture.index.entries().count, 1)
    }

    func testRetiredGateWithUnknownOrDuplicateUUIDReachesRecoveryAtLaunchAndDidMount() throws {
        for unknown in [true, false] {
            for mountNotification in [true, false] {
                let fixture = try VolumePublishFixture()
                var operations = noTrash()
                let actual = try VolumePublishFS.volumeInfo(VolumePublishDirectory(fixture.root))
                let uuid = unknown ? "unknown-volume" : actual.uuid
                operations.volumeInfo = { _ in
                    .init(uuid: uuid, cacheIdentity: actual.cacheIdentity, fileSystem: actual.fileSystem,
                          available: actual.available, hazard: nil)
                }
                var transaction = try staged(fixture, operations: operations)
                try transaction.retireOld(hook: { _ in }); transaction.journal.release()
                let before = try VolumePublishFixture.snapshot(fixture.root), coordinated = Mutex(false)
                operations.mountedVolumes = { _ in [.init(root: fixture.root, uuid: uuid), .init(root: fixture.root.appendingPathComponent("clone"), uuid: uuid)] }
                operations.willCoordinate = { _ in coordinated.withLock { $0 = true }; throw Fault.io }
                _ = VolumePublishRecovery(index: fixture.index, operations: operations)
                    .recoverAll(mountedVolume: mountNotification ? fixture.root : nil)
                XCTAssertTrue(coordinated.withLock { $0 }, "The stored S7 journal must reach the recovery move claim")
                XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
                XCTAssertEqual(try fixture.index.entries().count, 1)
            }
        }
    }

    func testRebasedEntryLookupAndCompletionUseVolumeRelativePath() throws {
        let fixture = try VolumePublishFixture(), transaction = try staged(fixture)
        transaction.journal.release()
        let entry = try XCTUnwrap(fixture.index.entries().first)
        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + transaction.staging.url.path, isDirectory: true)
        guard let parent = try? VolumePublishDirectory(alias.deletingLastPathComponent()) else { throw XCTSkip("Requires the boot Data firmlink") }
        let root = try VolumePublishFS.volumeRoot(parent)
        XCTAssertTrue(entry.matches(alias, volumeUUID: entry.volumeUUID, root: root))
        try fixture.index.rebase(entry, to: alias)
        guard case .recovered = VolumePublishRecovery(index: fixture.index).recover(staging: transaction.staging.url)
        else { return XCTFail("Original-path recovery must find the rebased index entry") }
        try fixture.assertRemoved(transaction.staging.url)
    }

    func testVerificationReportCoversRound3RecoveryRules() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let report = try String(contentsOf: repo.appendingPathComponent("Documentation/verification/2026-09-23-volume-set-publisher.md"), encoding: .utf8)
        for term in ["Round 3", "stored path first", "staging-locks", "keptOldVolumes", "EBUSY", "coalesc", "non-local", "hint"] {
            XCTAssertTrue(report.contains(term), "Missing round-3 rule: \(term)")
        }
        XCTAssertFalse(report.contains("A done staging with a freshly proven live new set cannot block"))
    }

    func testS1OwnershipIsHeldBeforeIndexVisibilityAndAfterJournalClosure() throws {
        let fixture = try VolumePublishFixture()
        let publication = try fixture.begin { step in
            guard [.registered, .stagingCreated, .journalCreated].contains(step) else { return }
            let entry = try XCTUnwrap(fixture.index.entries().first)
            XCTAssertNotNil(entry.stagingLockName)
            let url = URL(fileURLWithPath: entry.stagingPath, isDirectory: true)
            XCTAssertEqual(VolumePublishRecovery(index: fixture.index).recover(staging: url), .owned(url))
            var operations = VolumePublishOperations()
            operations.mountedVolumes = { _ in XCTFail("A live S1 owner needs no mount resolution"); return [] }
            operations.volumeInfo = { _ in XCTFail("A live S1 owner needs no volume probe"); throw Fault.io }
            XCTAssertEqual(VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll(), [.owned(url)])
        }
        publication.cancel()
        try fixture.assertRemoved(publication.stagingURL)
    }

    func testNetworkBusyRenameFallsBackInPlaceAndResumesWithJournalLast() throws {
        for failure in [EBUSY, EACCES] {
            for stop in [nil, "archive.tar.002", "journal"] as [String?] {
                let fixture = try VolumePublishFixture()
                var transaction = try staged(fixture)
                let journal = transaction.journal, stagingName = transaction.staging.url.lastPathComponent
                let outside = fixture.root.appendingPathComponent("outside"), bytes = Data("untouched".utf8)
                try bytes.write(to: outside)
                try FileManager.default.createSymbolicLink(at: transaction.staging.url.appendingPathComponent("new/link"), withDestinationURL: outside)
                var operations = noTrash()
                operations.volumeInfo = { directory in
                    let info = try VolumePublishFS.volumeInfo(directory)
                    return .init(uuid: info.uuid, cacheIdentity: info.cacheIdentity, fileSystem: "smbfs", available: info.available, hazard: "non-local")
                }
                operations.renameStaging = { _, _, _, _ in
                    do { _ = try journal.read(); XCTFail("Journal is still open") } catch {}
                    do {
                        let unexpected = try VolumePublishLock.stagingLock(stagingName, directory: fixture.index.stagingLocksURL)
                        unexpected.release(); XCTFail("Discard lost staging ownership")
                    } catch { XCTAssertEqual(error as? VolumePublishError, .ownerAlive) }
                    errno = failure
                    return -1
                }
                operations.willRemove = { url in
                    if url.lastPathComponent == "journal" {
                        XCTAssertEqual(try VolumePublishDirectory(url.deletingLastPathComponent()).names(), ["journal"])
                    }
                }
                operations.didRemove = { url in if url.lastPathComponent == stop { throw SimulatedCrash() } }
                transaction.operations = operations; transaction.isNetworkVolume = true
                if stop != nil {
                    XCTAssertThrowsError(try transaction.discardPrepared()) { XCTAssertTrue($0 is SimulatedCrash) }
                    operations.didRemove = { _ in }
                    guard case .recovered = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: transaction.staging.url)
                    else { XCTFail("Interrupted network discard did not resume: \(String(describing: stop))"); continue }
                } else { _ = try transaction.discardPrepared() }
                XCTAssertEqual(try Data(contentsOf: outside), bytes)
                try fixture.assertOld(); try fixture.assertRemoved(transaction.staging.url)
            }
        }
    }

    func testLocalBusyRenameDoesNotAuthorizeInPlaceRemoval() throws {
        let fixture = try VolumePublishFixture()
        var transaction = try staged(fixture), operations = noTrash()
        operations.renameStaging = { _, _, _, _ in errno = EBUSY; return -1 }
        transaction.operations = operations
        let before = try VolumePublishFixture.snapshot(transaction.staging.url)
        XCTAssertThrowsError(try transaction.discardPrepared()) { XCTAssertEqual($0 as? VolumePublishError, .system(EBUSY)) }
        XCTAssertEqual(try VolumePublishFixture.snapshot(transaction.staging.url), before)
    }
}
