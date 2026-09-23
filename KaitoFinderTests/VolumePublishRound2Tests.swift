import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class VolumePublishRound2Tests: XCTestCase {
    private enum Fault: Error { case io }
    private func noTrash() -> VolumePublishOperations {
        var operations = VolumePublishOperations()
        operations.trash = { _ in throw Fault.io }
        return operations
    }
    /// Construct a real S4/S9 crash state using the transaction primitives, without a coordinator mock.
    private func staged(_ fixture: VolumePublishFixture, placed: Bool = false,
                        operations: VolumePublishOperations = .init()) throws -> VolumePublishTransaction {
        var publication: VolumeSetPublication? = try fixture.begin()
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
        if placed {
            try transaction.proveOldBeforeRetiring()
            try transaction.retireOld(hook: { _ in })
            _ = try transaction.placeNew { if $0 == .s9 { throw SimulatedCrash() } }
        }
        return transaction
    }
    private func placed(_ fixture: VolumePublishFixture) throws -> URL {
        // A simulated crash unwinds the journal owner without performing rollback.
        XCTAssertThrowsError(try staged(fixture, placed: true)) { XCTAssertTrue($0 is SimulatedCrash, "\($0)") }
        return URL(fileURLWithPath: try XCTUnwrap(fixture.index.entries().first).stagingPath, isDirectory: true)
    }
    func testEncryptedHeaderRecoveryCommitsWithoutPasswordAndAllowsNextBegin() throws {
        let fixture = try VolumePublishFixture(encrypted: true)
        let url = try placed(fixture)
        XCTAssertThrowsError(try ArchiveReader.open(url: fixture.gate))
        let result = VolumePublishRecovery(index: fixture.index, operations: noTrash()).recover(staging: url)
        guard case .recovered(_, .forward, _) = result else { return XCTFail("\(result)") }
        try fixture.assertRemoved(url)
        let reader = try ArchiveReader.open(url: fixture.gate, options: fixture.readerOptions)
        let set = try XCTUnwrap(reader.volumeSet)
        let layout = ArchiveVolumeLayout(scheme: set.scheme, volumes: set.volumes.map { .init(url: fixture.root.appendingPathComponent($0.url.lastPathComponent), length: $0.length) }, openedVolumeIndex: 0)
        let target = VolumeSetTarget(parent: fixture.root, layout: layout, expected: try ArchiveSetIdentity.capture(layout: layout), schedule: fixture.target().schedule)
        do {
            let next = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(fixture.newBytes.count), index: fixture.index, options: fixture.readerOptions)
            next.cancel()
        } catch { XCTFail("Next begin: \(error)") }
    }
    private nonisolated final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        init(_ url: URL) { presentedItemURL = url; super.init() }
    }
    func testPresentedPlacedSetCleansUpWithoutLiveMoves() throws {
        let fixture = try VolumePublishFixture(), url = try placed(fixture)
        let presenter = Presenter(fixture.gate)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        var operations = noTrash()
        operations.willCoordinate = { _ in XCTFail("Moves-free cleanup requested a live-name claim") }
        guard case .recovered(_, .forward, _) = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: url)
        else { return XCTFail("Presented, hash-proven set must finish cleanup") }
        try fixture.assertNew(); try fixture.assertRemoved(url)
    }
    func testPresentedNonGateHoldsBeforeRecoveryMoves() throws {
        let fixture = try VolumePublishFixture()
        var transaction = try staged(fixture)
        XCTAssertThrowsError(try transaction.retireOld { if $0 == .s6 { throw SimulatedCrash() } })
        transaction.journal.release()
        let presenter = Presenter(fixture.root.appendingPathComponent(fixture.plan.volumes[1].name))
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        guard case .held(_, let reason, _) = VolumePublishRecovery(index: fixture.index).recover(staging: transaction.staging.url)
        else { return XCTFail("Presented sibling must hold") }
        XCTAssertTrue(reason.contains("presented"), reason)
        XCTAssertNil(try transaction.parent.info(fixture.plan.gateName))
    }

    func testDiscardTombstonesBeforeRemovalAndRecoversWithoutJournal() throws {
        let fixture = try VolumePublishFixture()
        var operations = noTrash()
        operations.willRemove = { url in
            XCTAssertTrue(url.lastPathComponent.hasSuffix(".discard"), "Must rename before the first unlink")
            throw SimulatedCrash()
        }
        let transaction = try staged(fixture, operations: operations)
        XCTAssertThrowsError(try transaction.discardPrepared()) { XCTAssertTrue($0 is SimulatedCrash) }
        transaction.journal.release()
        let tombstone = URL(fileURLWithPath: transaction.staging.url.path + ".discard", isDirectory: true)
        if FileManager.default.fileExists(atPath: tombstone.path) {
            try FileManager.default.removeItem(at: tombstone.appendingPathComponent("journal"))
        }
        guard case .recovered = VolumePublishRecovery(index: fixture.index).recover(staging: tombstone)
        else { return XCTFail("Journal-less tombstone must be disposable") }
        try fixture.assertOld(); try fixture.assertRemoved(transaction.staging.url)
    }
    func testOldRemovalCannotFollowSwappedStagingAncestor() throws {
        let fixture = try VolumePublishFixture(), url = try placed(fixture)
        let staging = try VolumePublishDirectory(url), journal = try VolumePublishJournal(staging: staging, create: false)
        var record = try journal.read(); record.phase = .done; try journal.write(record)
        let victim = fixture.root.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victim.appendingPathComponent("old"), withIntermediateDirectories: true)
        let sentinel = victim.appendingPathComponent("old/keep")
        try Data("user data".utf8).write(to: sentinel)
        let swapped = Mutex(false)
        var operations = noTrash()
        let originalRemove = operations.willRemove
        operations.willRemove = { location in
            if location.lastPathComponent == "old", !swapped.withLock({ value in let old = value; value = true; return old }) {
                try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: url.path + "-moved"))
                try FileManager.default.createSymbolicLink(at: url, withDestinationURL: victim)
            }
            try originalRemove(location)
        }
        let transaction = VolumePublishTransaction(parent: try VolumePublishDirectory(fixture.root), staging: staging, journal: journal,
            renamer: .init(usesFallback: false), index: fixture.index, record: record, operations: operations)
        _ = try transaction.dispose("old")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("user data".utf8))
    }

    func testDoneNoTrashRetainsOldWhenNewIsMissingOrCorrupt() throws {
        for missing in [true, false] {
            let fixture = try VolumePublishFixture(), url = try placed(fixture)
            let staging = try VolumePublishDirectory(url), journal = try VolumePublishJournal(staging: staging, create: false)
            var record = try journal.read(); record.phase = .done; try journal.write(record); journal.release()
            if missing { try FileManager.default.removeItem(at: fixture.gate) }
            else { try Data("foreign replacement".utf8).write(to: fixture.gate) }
            let oldBefore = try VolumePublishFixture.snapshot(url.appendingPathComponent("old"))
            let result = VolumePublishRecovery(index: fixture.index, operations: noTrash()).recover(staging: url)
            guard case .held = result else { XCTFail("Only complete copy must stay: \(result)"); continue }
            XCTAssertEqual(try VolumePublishFixture.snapshot(url.appendingPathComponent("old")), oldBefore)
            XCTAssertEqual(try fixture.index.entries().count, 1)
        }
    }

    func testNativeXattrVolumePreservesIndependentAppleDoubleNames() throws {
        for rollback in [true, false] {
            let fixture = try VolumePublishFixture()
            guard ["apfs", "hfs"].contains(try VolumePublishFS.volumeInfo(VolumePublishDirectory(fixture.root)).fileSystem)
            else { throw XCTSkip("Requires native-xattr APFS or HFS+") }
            let sentinels = [fixture.plan.gateName, fixture.plan.volumes.last!.name].map { fixture.root.appendingPathComponent("._" + $0) }
            for url in sentinels { try Data("independent user file".utf8).write(to: url) }
            var transaction = try staged(fixture, operations: noTrash())
            try transaction.proveOldBeforeRetiring(); try transaction.retireOld(hook: { _ in })
            _ = try transaction.placeNew(hook: { _ in })
            if rollback { try transaction.rollback(); _ = try transaction.dispose("abandoned") }
            else { try transaction.validateHashes(in: transaction.parent); try transaction.phase(.done); _ = try transaction.dispose("old") }
            try transaction.removeEmptyStaging()
            for url in sentinels { XCTAssertEqual(try Data(contentsOf: url), Data("independent user file".utf8)) }
        }
    }

    func testUnknownAndAmbiguousVolumeUUIDNeverPrunesIndex() throws {
        for unknown in [true, false] {
            let fixture = try VolumePublishFixture()
            let url = fixture.root.appendingPathComponent(VolumePublishFS.stagingPrefix + UUID().uuidString)
            let actual = try VolumePublishFS.volumeInfo(VolumePublishDirectory(fixture.root))
            let uuid = unknown ? "unknown-volume" : actual.uuid
            try fixture.index.register(url, volumeUUID: uuid, gateName: fixture.plan.gateName)
            var operations = noTrash()
            operations.volumeInfo = { _ in .init(uuid: uuid, cacheIdentity: uuid, fileSystem: "apfs", available: .max, hazard: nil) }
            operations.mountedVolumes = { [.init(root: fixture.root, uuid: uuid), .init(root: fixture.root.appendingPathComponent("clone"), uuid: uuid)] }
            _ = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: url)
            XCTAssertEqual(try fixture.index.entries().count, 1, "Unknown/ambiguous UUID must never authorize pruning")
        }
    }
    func testLaunchResolvesUUIDRelativeStagingWithoutDidMount() throws {
        let fixture = try VolumePublishFixture()
        let transaction = try staged(fixture), url = transaction.staging.url
        transaction.journal.release()
        let entry = try XCTUnwrap(fixture.index.entries().first)
        let stale = fixture.root.appendingPathComponent("not-mounted").appendingPathComponent(url.lastPathComponent)
        try fixture.index.rebase(entry, to: stale)
        var operations = noTrash()
        let root = try VolumePublishFS.volumeRoot(transaction.parent)
        operations.mountedVolumes = { [.init(root: root, uuid: entry.volumeUUID)] }
        let results = VolumePublishRecovery(index: fixture.index, operations: operations).recoverAll()
        XCTAssertTrue(results.contains { if case .recovered = $0 { return true }; return false }, "\(results)")
        try fixture.assertRemoved(url); try fixture.assertOld()
    }
    func testLaunchRecoveryAfterRealRemount() throws {
        let disk = try VolumePublishTestDisk("APFS")
        defer { try? disk.detach() }
        let fixture = try VolumePublishFixture(parent: disk.mount)
        let transaction = try staged(fixture), name = transaction.staging.url.lastPathComponent
        transaction.journal.release()
        try disk.detach()
        let newMount = disk.mount.deletingLastPathComponent().appendingPathComponent("remounted")
        try disk.attach(at: newMount)
        _ = VolumePublishRecovery(index: fixture.index).recoverAll()
        XCTAssertTrue(try fixture.index.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newMount.appendingPathComponent(fixture.root.lastPathComponent).appendingPathComponent(name).path))
    }

    func testCompletedRollbackDisposesDespiteLaterLiveEditsAndNextOccupant() throws {
        let fixture = try VolumePublishFixture()
        var transaction = try staged(fixture)
        try transaction.retireOld(hook: { _ in }); _ = try transaction.placeNew(hook: { _ in })
        try transaction.rollback(); transaction.journal.release()
        try Data("later user edit".utf8).write(to: fixture.gate)
        let next = fixture.root.appendingPathComponent(fixture.scheme.fileName(forVolumeAt: fixture.oldParts.count, count: fixture.oldParts.count + 1))
        try Data("later next occupant".utf8).write(to: next)
        let presenter = Presenter(fixture.gate)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let result = VolumePublishRecovery(index: fixture.index, operations: noTrash()).recover(staging: transaction.staging.url)
        guard case .recovered(_, .backward, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(try Data(contentsOf: fixture.gate), Data("later user edit".utf8))
        XCTAssertEqual(try Data(contentsOf: next), Data("later next occupant".utf8))
        try fixture.assertRemoved(transaction.staging.url)
    }
    func testNoOldMovedRollbackIgnoresForeignLiveNames() throws {
        let fixture = try VolumePublishFixture()
        var transaction = try staged(fixture)
        try Data("changed before S6".utf8).write(to: fixture.gate)
        try Data("occupied next".utf8).write(to: fixture.root.appendingPathComponent("archive.tar.004"))
        XCTAssertNoThrow(try transaction.rollback())
        XCTAssertEqual(try Data(contentsOf: fixture.gate), Data("changed before S6".utf8))
    }

    func testRollbackUsesHeldParentAfterFolderRenameAtEveryBarrier() throws {
        for boundary in [VolumePublishStep.s6, .s7, .s8, .s9] {
            let fixture = try VolumePublishFixture()
            var transaction = try staged(fixture)
            let moved = fixture.root.deletingLastPathComponent().appendingPathComponent("renamed-" + UUID().uuidString)
            let hook: (VolumePublishStep) throws -> Void = { step in
                if step == boundary { try FileManager.default.moveItem(at: fixture.root, to: moved); throw Fault.io }
            }
            XCTAssertThrowsError(try { try transaction.retireOld(hook: hook); _ = try transaction.placeNew(hook: hook) }())
            XCTAssertNoThrow(try transaction.rollback(), "\(boundary)")
            for (i, bytes) in fixture.oldParts.enumerated() {
                XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(fixture.scheme.fileName(forVolumeAt: i, count: fixture.oldParts.count))), bytes)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent("archive.tar.004").path))
        }
    }

    func testBeginSkipsOtherStemDuringUnreadableJournalWindow() throws {
        let fixture = try VolumePublishFixture()
        let publication = try fixture.begin { step in
            if step == .journalCreated {
                let target = VolumeSetTarget(parent: fixture.root, newSetScheme: .numbered(stem: "other.tar", width: 3), schedule: .uniform(size: 4096))
                let other = try VolumeSetPublication.begin(target, estimatedOutputLength: 8000, index: fixture.index)
                other.cancel()
            }
        }
        publication.cancel()
    }
    func testBeginSkipsUnattributedUnreadableStagingWithoutTouchingIt() throws {
        let fixture = try VolumePublishFixture()
        let stranger = fixture.root.appendingPathComponent(VolumePublishFS.stagingPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: stranger.appendingPathComponent("old"), withIntermediateDirectories: true)
        let note = stranger.appendingPathComponent("old/user-file")
        try Data("keep".utf8).write(to: note)
        let publication = try fixture.begin(); publication.cancel()
        XCTAssertEqual(try Data(contentsOf: note), Data("keep".utf8))
    }
    func testBeginAllowsProvenDoneSetWithHeldOldCleanup() throws {
        let fixture = try VolumePublishFixture(), url = try placed(fixture)
        let staging = try VolumePublishDirectory(url), journal = try VolumePublishJournal(staging: staging, create: false)
        var record = try journal.read(); record.phase = .done; try journal.write(record); journal.release()
        try Data("foreign old backup".utf8).write(to: url.appendingPathComponent("old/" + fixture.plan.gateName))
        let layout = ArchiveVolumeLayout(scheme: fixture.scheme, volumes: fixture.plan.volumes.map {
            .init(url: fixture.root.appendingPathComponent($0.name), length: $0.length)
        }, openedVolumeIndex: 0)
        let target = VolumeSetTarget(parent: fixture.root, layout: layout, expected: try ArchiveSetIdentity.capture(layout: layout), schedule: fixture.target().schedule)
        let next = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(fixture.newBytes.count), index: fixture.index, operations: noTrash())
        next.cancel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
    func testBeginRechecksOccupancyAfterPreparedCleanup() throws {
        let fixture = try VolumePublishFixture(oldCount: 0)
        let transaction = try staged(fixture); transaction.journal.release()
        var operations = noTrash()
        operations.willRemove = { url in
            if url.lastPathComponent.hasSuffix(".discard") { try Data("foreign".utf8).write(to: fixture.gate) }
        }
        XCTAssertThrowsError(try fixture.begin(operations: operations)) {
            guard case VolumePublishError.nameOccupied = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.gate), Data("foreign".utf8))
    }

    func testFallbackOwnershipExpiresWhenOwnPublicationReleasesJournal() throws {
        let fixture = try VolumePublishFixture()
        let transaction = try staged(fixture)
        var record = transaction.record
        let identity = VolumePublishProcessIdentity(bootSession: "test-boot", pid: getpid(), startSeconds: 123, startMicroseconds: 456)
        record.owner = identity
        try transaction.journal.write(record)
        let unsupported: @Sendable (Int32, Int32) -> Int32 = { _, _ in errno = ENOTSUP; return -1 }
        XCTAssertThrowsError(try VolumePublishJournal(staging: transaction.staging, create: false, lock: unsupported, processIdentity: { _ in identity })) {
            guard case VolumePublishError.ownerAlive = $0 else { return XCTFail("\($0)") }
        }
        transaction.journal.release()
        let recovered = try VolumePublishJournal(staging: transaction.staging, create: false, lock: unsupported, processIdentity: { _ in identity })
        recovered.release()
        // A held recovery also relinquishes its ownership; its durable PID is merely stale metadata.
        let retry = try VolumePublishJournal(staging: transaction.staging, create: false, lock: unsupported, processIdentity: { _ in identity })
        retry.release()
    }

    func testCriticalSectionRegistersBeforeFinalCancellationCheck() throws {
        let counter = VolumePublishCriticalSection()
        XCTAssertThrowsError(try counter.enter {
            XCTAssertEqual(counter.count, 1, "Termination must see the lease before the final cancellation check")
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(counter.count, 0, "Cancellation must release the lease")
    }

    func testTerminationClosureExcludesLaterCriticalEntry() throws {
        let counter = VolumePublishCriticalSection()
        var lease: VolumePublishCriticalSection.Lease? = try counter.enter()
        XCTAssertFalse(counter.closeIfIdle())
        withExtendedLifetime(lease) {}; lease = nil
        XCTAssertTrue(counter.closeIfIdle())
        XCTAssertThrowsError(try counter.enter()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(counter.count, 0)
    }

    func testFinalHashProofDetectsNextNameCreatedDuringHashing() throws {
        let fixture = try VolumePublishFixture()
        var operations = noTrash()
        operations.didHash = { url in
            if url == fixture.gate { try? Data("foreign next".utf8).write(to: fixture.root.appendingPathComponent(fixture.plan.nextVolumeName)) }
        }
        var transaction = try staged(fixture)
        try transaction.retireOld(hook: { _ in }); _ = try transaction.placeNew(hook: { _ in })
        transaction.operations = operations
        XCTAssertThrowsError(try transaction.validateHashes(in: transaction.parent)) {
            guard case VolumePublishError.nameOccupied = $0 else { return XCTFail("\($0)") }
        }
    }
    func testRecoveryWithdrawsOnNextNameCollisionDuringFinalHash() throws {
        for allFinal in [true, false] {
            let fixture = try VolumePublishFixture()
            var transaction = try staged(fixture)
            try transaction.retireOld(hook: { _ in })
            if allFinal { _ = try transaction.placeNew(hook: { _ in }) }
            let url = transaction.staging.url; transaction.journal.release()
            let hashes = Mutex(0)
            var operations = noTrash()
            operations.didHash = { location in
                guard location == fixture.gate else { return }
                let number = hashes.withLock { $0 += 1; return $0 }
                if number == (allFinal ? 2 : 1) {
                    try? Data("foreign next".utf8).write(to: fixture.root.appendingPathComponent(fixture.plan.nextVolumeName))
                }
            }
            let result = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: url)
            guard case .recovered(_, .backward, _) = result else { XCTFail("\(result)"); continue }
            for (i, bytes) in fixture.oldParts.enumerated() {
                XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.scheme.fileName(forVolumeAt: i, count: fixture.oldParts.count))), bytes)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("archive.tar.004").path))
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.plan.nextVolumeName)), Data("foreign next".utf8))
        }
    }

    func testShrinkRetirementIgnoresRetiredOldOnlyOccupantsBeyondGap() throws {
        let fixture = try VolumePublishFixture(oldCount: 6, newCount: 2)
        var transaction = try staged(fixture)
        try transaction.retireOld(hook: { _ in })
        let foreign = fixture.root.appendingPathComponent("archive.tar.005")
        try Data("beyond gap".utf8).write(to: foreign)
        XCTAssertNoThrow(try transaction.retireOld(hook: { _ in }))
        _ = try transaction.placeNew(hook: { _ in })
        try transaction.validateHashes(in: transaction.parent)
        XCTAssertEqual(try Data(contentsOf: foreign), Data("beyond gap".utf8))
    }
    func testShrinkRecoveryCompletesWithForeignOldOnlyNameBeyondNextGap() throws {
        let fixture = try VolumePublishFixture(oldCount: 6, newCount: 2), url = try placed(fixture)
        let foreign = fixture.root.appendingPathComponent("archive.tar.005")
        try Data("beyond gap".utf8).write(to: foreign)
        let result = VolumePublishRecovery(index: fixture.index, operations: noTrash()).recover(staging: url)
        guard case .recovered(_, .forward, _) = result else { return XCTFail("\(result)") }
        let reader = try ArchiveReader.open(url: fixture.gate)
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), fixture.newContents)
        XCTAssertEqual(try Data(contentsOf: foreign), Data("beyond gap".utf8))
        try fixture.assertRemoved(url)
    }

    func testCanonicallyEquivalentGateNamesContendOnSameSetLock() throws {
        let fixture = try VolumePublishFixture()
        let first = try VolumePublishLock.setLock(volumeUUID: "test-volume", gateInode: nil, parent: fixture.root,
            gate: "Caf\u{e9}.7z.001", directory: fixture.index.setLocksURL)
        defer { first.release() }
        XCTAssertThrowsError(try VolumePublishLock.setLock(volumeUUID: "test-volume", gateInode: nil, parent: fixture.root,
            gate: "cafe\u{301}.7z.001", directory: fixture.index.setLocksURL)) {
            guard case VolumePublishError.ownerAlive = $0 else { return XCTFail("\($0)") }
        }
    }

    func testCallingPresenterIsExcludedBeforeCoordinatedRecovery() throws {
        let fixture = try VolumePublishFixture()
        var transaction = try staged(fixture)
        try transaction.retireOld(hook: { _ in }); transaction.journal.release()
        let presenter = Presenter(fixture.gate)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let called = Mutex(false)
        var operations = noTrash()
        operations.willCoordinate = { _ in called.withLock { $0 = true }; throw Fault.io }
        _ = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: transaction.staging.url, presenter: presenter)
        XCTAssertTrue(called.withLock { $0 }, "The caller's own presenter must not HOLD before coordination")
    }
    func testDiscardRemovesJournalLastAndResumesEveryDeletionBoundary() throws {
        for stop in ["archive.tar.002", "new", "work", "journal"] {
            let fixture = try VolumePublishFixture()
            var operations = noTrash()
            operations.didRemove = { url in
                if url.lastPathComponent == "journal" {
                    XCTAssertTrue(try VolumePublishDirectory(url.deletingLastPathComponent()).names().isEmpty, "journal must be last")
                }
                if url.lastPathComponent == stop { throw SimulatedCrash() }
            }
            let transaction = try staged(fixture, operations: operations)
            XCTAssertThrowsError(try transaction.discardPrepared()) { XCTAssertTrue($0 is SimulatedCrash) }
            transaction.journal.release()
            guard case .recovered = VolumePublishRecovery(index: fixture.index).recover(staging: transaction.staging.url)
            else { XCTFail("Interrupted discard must finish at \(stop)"); continue }
            try fixture.assertOld(); try fixture.assertRemoved(transaction.staging.url)
        }
    }
    func testDiscardUnlinksNestedSymlinkWithoutTraversingTarget() throws {
        let fixture = try VolumePublishFixture()
        let transaction = try staged(fixture)
        let victim = fixture.root.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
        try Data("user data".utf8).write(to: victim.appendingPathComponent("keep"))
        try FileManager.default.createSymbolicLink(at: transaction.staging.url.appendingPathComponent("new/link"), withDestinationURL: victim)
        _ = try transaction.discardPrepared()
        XCTAssertEqual(try Data(contentsOf: victim.appendingPathComponent("keep")), Data("user data".utf8))
    }
    func testVerificationReportDescribesRound2RecoveryRules() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let report = try String(contentsOf: repo.appendingPathComponent("Documentation/verification/2026-09-23-volume-set-publisher.md"), encoding: .utf8)
        for term in ["Round 2", ".discard", "journal last", "getmntinfo", "NFC", "length + SHA-256", "any volume", "NSCocoaErrorDomain Code=512"] {
            XCTAssertTrue(report.contains(term), "Missing correction evidence: \(term)")
        }
        XCTAssertFalse(report.contains("Never retire/place/restore live names or require the new set still to exist."))
    }

    func testPresentedBackwardPreparationWithoutLiveMovesCleansUp() throws {
        let fixture = try VolumePublishFixture()
        var transaction = try staged(fixture)
        try transaction.phase(.retiring)
        try FileManager.default.removeItem(at: transaction.staging.url.appendingPathComponent("new/" + fixture.plan.volumes[1].name))
        transaction.journal.release()
        let presenter = Presenter(fixture.gate)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let result = VolumePublishRecovery(index: fixture.index, operations: noTrash()).recover(staging: transaction.staging.url)
        guard case .recovered(_, .backward, _) = result else { return XCTFail("\(result)") }
        try fixture.assertOld(); try fixture.assertRemoved(transaction.staging.url)
    }

    func testLaunchResolvesRealBootVolumeWithoutFalseCloneAmbiguity() throws {
        let fixture = try VolumePublishFixture()
        let transaction = try staged(fixture); transaction.journal.release()
        let results = VolumePublishRecovery(index: fixture.index, operations: noTrash()).recoverAll()
        XCTAssertTrue(results.contains { if case .recovered = $0 { return true }; return false }, "\(results)")
        try fixture.assertOld()
        XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.staging.url.path))
        XCTAssertEqual(try fixture.index.entries().count, 1, "Existing boot-volume paths do not need mount enumeration")
    }

    func testOptionalReaderDiagnosticUsesCallerOptionsWithoutHoldingCommit() throws {
        let fixture = try VolumePublishFixture(encrypted: true), url = try placed(fixture)
        let diagnostics = Mutex<[String?]>([])
        var operations = noTrash()
        operations.openReader = { _, options in
            XCTAssertEqual(options.password, "round2-secret")
            throw Fault.io
        }
        operations.recoveryReaderDiagnostic = { diagnostic in diagnostics.withLock { $0.append(diagnostic) } }
        let result = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: url, options: fixture.readerOptions)
        guard case .recovered(_, .forward, _) = result else { return XCTFail("Diagnostic cannot block commit: \(result)") }
        XCTAssertEqual(diagnostics.withLock { $0.count }, 1)
        XCTAssertNotNil(diagnostics.withLock { $0.first! })
        try fixture.assertRemoved(url)
    }

}
