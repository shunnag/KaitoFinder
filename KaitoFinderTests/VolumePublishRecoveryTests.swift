import Darwin
import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class VolumePublishRecoveryTests: XCTestCase {
    private func disk(_ fileSystem: String) throws -> VolumePublishTestDisk {
        let disk = try VolumePublishTestDisk(fileSystem)
        addTeardownBlock { try disk.detach() }
        return disk
    }

    private func crashed(_ fixture: VolumePublishFixture, at step: VolumePublishStep = .s6, consent: Bool = false) throws -> URL {
        let publication = try fixture.begin(consent: consent) { if $0 == step { throw SimulatedCrash() } }
        XCTAssertThrowsError(try publication.publish(progress: Progress())) { XCTAssertTrue($0 is SimulatedCrash, "\($0)") }
        return publication.stagingURL
    }

    private func corruptSlot(_ staging: URL, slot: Int) throws {
        let directory = try VolumePublishDirectory(staging), fd = try directory.openFile("journal", flags: O_RDWR)
        defer { close(fd) }
        let offset = UInt64(slot * VolumePublishJournal.slotSize + VolumePublishJournal.headerSize + 11)
        var byte = try VolumePublishFS.read(fd, length: 1, offset: offset)
        byte[0] ^= 0xff
        try VolumePublishFS.write(fd, data: byte, offset: offset)
        try VolumePublishFS.sync(fd)
    }

    func testOneCorruptSlotUsesOtherAndBothCorruptSlotsHoldWithoutChanges() throws {
        let fixture = try VolumePublishFixture(), staging = try crashed(fixture)
        // S1=slot0、S5=slot1、S6=slot0。古い prepared でも old/ の内容から前進する。
        try corruptSlot(staging, slot: 0)
        let record = try VolumePublishJournal.inspect(VolumePublishDirectory(staging))
        XCTAssertEqual(record.phase, .prepared)
        let result = VolumePublishRecovery(index: fixture.index).recover(staging: staging)
        guard case .recovered(_, .forward, _) = result else { return XCTFail("\(result)") }
        try fixture.assertNew()
        try fixture.assertRemoved(staging)

        let unreadable = try VolumePublishFixture(), broken = try crashed(unreadable)
        try corruptSlot(broken, slot: 0)
        try corruptSlot(broken, slot: 1)
        let before = try VolumePublishFixture.snapshot(unreadable.root), entries = try unreadable.index.entries()
        guard case .held = VolumePublishRecovery(index: unreadable.index).recover(staging: broken) else {
            return XCTFail("Both slots invalid must HOLD")
        }
        XCTAssertEqual(try VolumePublishFixture.snapshot(unreadable.root), before)
        XCTAssertEqual(try unreadable.index.entries(), entries)
    }

    func testUnrelatedOccupantAndSymlinkCauseHoldWithoutTouchingAnything() throws {
        for symlink in [false, true] {
            let fixture = try VolumePublishFixture(), staging = try crashed(fixture)
            let victim = fixture.root.appendingPathComponent("unrelated")
            try Data("keep every byte".utf8).write(to: victim)
            if symlink { try FileManager.default.createSymbolicLink(at: fixture.gate, withDestinationURL: victim) }
            else { try Data("unrelated gate".utf8).write(to: fixture.gate) }
            let before = try VolumePublishFixture.snapshot(fixture.root)
            guard case .held = VolumePublishRecovery(index: fixture.index).recover(staging: staging) else {
                return XCTFail("Occupied target must HOLD")
            }
            XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
            XCTAssertEqual(try fixture.index.entries().count, 1)
        }
    }

    func testExternallyModifiedOldVolumeCannotGoForward() throws {
        let fixture = try VolumePublishFixture(), staging = try crashed(fixture)
        let oldGate = staging.appendingPathComponent("old/archive.tar.001")
        let fd = open(oldGate.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VolumePublishError.system(errno) }
        defer { close(fd) }
        var byte: UInt8 = 0xff
        XCTAssertEqual(pwrite(fd, &byte, 1, 0), 1)
        // APFS の mtime が必ず変わるよう、秒を明示して進める。
        var times = [timespec(tv_sec: 1, tv_nsec: 0), timespec(tv_sec: 2, tv_nsec: 0)]
        XCTAssertEqual(futimens(fd, &times), 0)
        let before = try VolumePublishFixture.snapshot(fixture.root)
        guard case .held = VolumePublishRecovery(index: fixture.index).recover(staging: staging) else { return XCTFail("Modified old gate must HOLD") }
        XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
    }

    func testAbandonedDirectoryOrPhaseAlwaysRollsBackwardEvenWithCompleteNewSet() throws {
        for marker in [true, false] {
            let fixture = try VolumePublishFixture(), stagingURL = try crashed(fixture, at: .s8)
            let staging = try VolumePublishDirectory(stagingURL)
            if marker {
                XCTAssertEqual(renameatx_np(staging.fd, "new", staging.fd, "abandoned", UInt32(RENAME_EXCL)), 0)
            } else {
                let journal = try VolumePublishJournal(staging: staging, create: false)
                var record = try journal.read()
                record.phase = .abandoned
                try journal.write(record)
                journal.release()
            }
            let result = VolumePublishRecovery(index: fixture.index).recover(staging: stagingURL)
            guard case .recovered(_, .backward, _) = result else { return XCTFail("\(result)") }
            try fixture.assertOld()
            try fixture.assertRemoved(stagingURL)
        }
    }

    func testIncompleteNewSetRollsBackwardAndPreparedDiscardsOnlyGeneratedStaging() throws {
        let fixture = try VolumePublishFixture(), staging = try crashed(fixture, at: .s7)
        try Data("incomplete".utf8).write(to: staging.appendingPathComponent("new/archive.tar.005"))
        let result = VolumePublishRecovery(index: fixture.index).recover(staging: staging)
        guard case .recovered(_, .backward, .trashed(let trash)) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.path))
        try fixture.assertOld()
        try fixture.assertRemoved(staging)

        let prepared = try VolumePublishFixture(), unused = try crashed(prepared, at: .s5)
        guard case .recovered(_, .discardedPreparation, _) = VolumePublishRecovery(index: prepared.index).recover(staging: unused) else {
            return XCTFail("Prepared with intact old set should discard preparation")
        }
        try prepared.assertOld()
        try prepared.assertRemoved(unused)
    }

    func testRecoveryHidesPrematureNewGateBeforeRetiringOldSiblings() throws {
        let fixture = try VolumePublishFixture(), url = try crashed(fixture)
        let staging = try VolumePublishDirectory(url), parent = try VolumePublishDirectory(fixture.root)
        let new = try staging.directory("new"), journal = try VolumePublishJournal(staging: staging, create: false)
        let record = try journal.read()
        let renamer = VolumeExclusiveRename(usesFallback: record.usesExclusiveRenameFallback)
        // 順不同で metadata が残った状態を作る。旧 gate は old/、旧兄弟はまだ最終名。
        try renamer.move(record.newGate, from: new, to: parent)
        var transaction = VolumePublishTransaction(parent: parent, staging: staging, journal: journal,
            renamer: renamer, index: fixture.index, record: record)
        let contents = try transaction.inspect()
        XCTAssertTrue(contents.allOld && contents.allNew)
        try transaction.retireOld { _ in XCTAssertNil(try parent.info(record.newGate)) }
        _ = try transaction.placeNew { step in
            if step == .s8 { XCTAssertNil(try parent.info(record.newGate)) }
            else if step == .s9 { try fixture.assertNew() }
        }
        journal.release()
        guard case .recovered(_, .forward, _) = VolumePublishRecovery(index: fixture.index).recover(staging: url) else {
            return XCTFail("Proven content should finish forward recovery")
        }
        try fixture.assertNew()
        try fixture.assertRemoved(url)
    }

    func testLivePublisherOrSeparatelyLockedJournalIsSkipped() throws {
        let fixture = try VolumePublishFixture(), publication = try fixture.begin()
        let before = try VolumePublishFixture.snapshot(fixture.root)
        XCTAssertEqual(VolumePublishRecovery(index: fixture.index).recover(staging: publication.stagingURL), .owned(publication.stagingURL))
        XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
        publication.cancel()

        let dead = try VolumePublishFixture(), staging = try crashed(dead)
        let fd = try VolumePublishDirectory(staging).openFile("journal", flags: O_RDWR)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(VolumePublishRecovery(index: dead.index).recover(staging: staging), .owned(staging))
    }

    func testJournalPathsAreValidatedBeforeRecoveryMakesChanges() throws {
        let fixture = try VolumePublishFixture(), stagingURL = try crashed(fixture)
        let staging = try VolumePublishDirectory(stagingURL), journal = try VolumePublishJournal(staging: staging, create: false)
        let record = try journal.read()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["stem"] = "../outside"
        let invalid = try JSONDecoder().decode(VolumePublishJournalRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try invalid.validate(stagingName: stagingURL.lastPathComponent))
        XCTAssertThrowsError(try journal.write(invalid))
        journal.release()
    }

    func testIndexRetainsMissingPathsAndPreservesCorruptOriginal() throws {
        let fixture = try VolumePublishFixture(), missing = fixture.root.appendingPathComponent(VolumePublishFS.stagingPrefix + UUID().uuidString)
        try fixture.index.register(missing, volumeUUID: "previous-mount")
        let entries = try fixture.index.entries()
        _ = VolumePublishRecovery(index: fixture.index).recoverAll()
        XCTAssertEqual(try fixture.index.entries(), entries)
        let corrupt = Data("{broken index".utf8)
        try corrupt.write(to: fixture.index.fileURL)
        XCTAssertTrue(try fixture.index.entries().isEmpty)
        let support = fixture.index.fileURL.deletingLastPathComponent()
        let copies = try FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("index.json.corrupt-") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copies.first)), corrupt)
        XCTAssertEqual(try JSONDecoder().decode([RecoverableWorkIndex.Entry].self, from: Data(contentsOf: fixture.index.fileURL)), [])
    }

    func testParentScanRecoversWithoutIndexAndRemountDoesNotRequireDeviceNumber() throws {
        let disk = try disk("APFS")
        defer { try? disk.detach() }
        let fixture = try VolumePublishFixture(parent: disk.mount), staging = try crashed(fixture, at: .s7)
        // 索引を失っても親の列挙で発見する。journal の UUID は診断用で判定には用いない。
        try fixture.index.removeCompleted(staging)
        try disk.detach()
        try disk.attach()
        let results = VolumePublishRecovery(index: fixture.index).recoverAll(parents: [fixture.root], mountedVolume: disk.mount)
        XCTAssertTrue(results.contains { if case .recovered(_, .forward, _) = $0 { return true }; return false })
        try fixture.assertNew()
        try fixture.assertRemoved(staging)
    }

    func testFAT32SameSizeSameTwoSecondMtimeModificationIsRejectedByOldHash() throws {
        let disk = try disk("MS-DOS FAT32")
        defer { try? disk.detach() }
        let fixture = try VolumePublishFixture(parent: disk.mount)
        let staging = try crashed(fixture, at: .retiredVolume(1), consent: true)
        let old = try VolumePublishDirectory(staging.appendingPathComponent("old")), name = "archive.tar.002"
        let journal = try VolumePublishJournal.inspect(VolumePublishDirectory(staging))
        XCTAssertTrue(journal.hashesOldVolumes)
        XCTAssertTrue(journal.oldVolumes.allSatisfy { $0.sha256 != nil })
        let before = try XCTUnwrap(old.info(name)), fd = try old.openFile(name, flags: O_RDWR)
        defer { close(fd) }
        var bytes = try VolumePublishFS.read(fd, length: 1, offset: 0)
        bytes[0] ^= 0xff
        try VolumePublishFS.write(fd, data: bytes, offset: 0)
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(futimens(fd, &times), 0)
        try VolumePublishFS.sync(fd)
        let after = try XCTUnwrap(old.info(name))
        XCTAssertEqual(after.st_size, before.st_size)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_mtimespec.tv_sec / 2, before.st_mtimespec.tv_sec / 2)
        XCTAssertNotEqual(try VolumePublishFS.hash(old, name), journal.oldVolumes[1].sha256)
        let snapshot = try VolumePublishFixture.snapshot(fixture.root)
        guard case .held = VolumePublishRecovery(index: fixture.index).recover(staging: staging) else {
            return XCTFail("FAT old-volume hash must veto forward recovery")
        }
        XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), snapshot)
    }

    func testFAT32UnchangedGateBytesInBothGenerationsCanRecoverForward() throws {
        let disk = try disk("MS-DOS FAT32")
        defer { try? disk.detach() }
        let fixture = try VolumePublishFixture(parent: disk.mount, oldCount: 3, newCount: 3)
        let publication = try fixture.begin(consent: true) { if $0 == .s9 { throw SimulatedCrash() } }
        // tar の先頭巻をそのまま残し、後続の payload だけを書き換える。
        var expected = fixture.newBytes
        expected.replaceSubrange(0..<fixture.oldParts[0].count, with: fixture.oldParts[0])
        try expected.write(to: publication.workURL)
        XCTAssertThrowsError(try publication.publish(progress: Progress())) { XCTAssertTrue($0 is SimulatedCrash) }
        let result = VolumePublishRecovery(index: fixture.index).recover(staging: publication.stagingURL)
        switch result {
        case .recovered(_, .forward, _): try fixture.assertRemoved(publication.stagingURL)
        case .held(_, _, .some(.kept(_))):
            let record = try VolumePublishJournal.inspect(VolumePublishDirectory(publication.stagingURL))
            XCTAssertEqual(record.phase, .done)
        default: XCTFail("An unchanged gate is not an ambiguous occupant: \(result)")
        }
        var joined = Data()
        for volume in fixture.plan.volumes { joined.append(try Data(contentsOf: fixture.root.appendingPathComponent(volume.name))) }
        XCTAssertEqual(joined, expected)
        XCTAssertEqual(try ArchiveReader.open(url: fixture.gate).volumeSet?.volumes.count, 3)
    }

    func testUnresolvedSameStemAndFailedRegistrationAbortBeforeCallerReceivesWork() throws {
        let fixture = try VolumePublishFixture(), staging = try crashed(fixture, at: .s5)
        let retry = try fixture.begin()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        retry.cancel()
        let fresh = try VolumePublishFixture(), blocked = try volumePublishTestURL(fresh.directory.url).appendingPathComponent("not-a-folder")
        try Data("keep".utf8).write(to: blocked)
        let index = RecoverableWorkIndex(fileURL: blocked.appendingPathComponent("index.json"))
        XCTAssertThrowsError(try VolumeSetPublication.begin(fresh.target(), estimatedOutputLength: UInt64(fresh.newBytes.count), index: index))
        try fresh.assertOld()
        XCTAssertEqual(try Data(contentsOf: blocked), Data("keep".utf8))

        // set-lock の作成までは通し、S1 の索引登録そのものを失敗させる。
        let registration = try VolumePublishFixture()
        let invalidIndex = try volumePublishTestURL(registration.directory.url).appendingPathComponent("index-is-directory")
        try FileManager.default.createDirectory(at: invalidIndex, withIntermediateDirectories: false)
        let failedIndex = RecoverableWorkIndex(fileURL: invalidIndex)
        let before = try VolumePublishFixture.snapshot(registration.root)
        XCTAssertThrowsError(try VolumeSetPublication.begin(registration.target(), estimatedOutputLength: UInt64(registration.newBytes.count), index: failedIndex))
        XCTAssertEqual(try VolumePublishFixture.snapshot(registration.root), before)
    }

    @MainActor func testLaunchRunsRecoveryAlongsideTheLegacySweepWithIsolatedIndexes() async throws {
        let fixture = try VolumePublishFixture(), staging = try crashed(fixture, at: .s7)
        let delegate = AppDelegate()
        delegate.pendingWorkRegistry = PendingWorkRegistry(fileURL: fixture.directory.url.appendingPathComponent("pending.json"))
        delegate.recoverableWorkIndex = fixture.index
        delegate.sweepsPendingWorkAtLaunch = true
        await delegate.startLaunchSweeps().value
        try fixture.assertNew()
        try fixture.assertRemoved(staging)
    }

    func testLegacyPendingRegistryNeverSweepsVolumePublicationPrefix() throws {
        let fixture = try VolumePublishFixture(), staging = try crashed(fixture, at: .s5)
        let file = fixture.directory.url.appendingPathComponent("legacy-pending.json")
        // 旧版の形式で所有者のない項目が紛れ込んでも、vol- は削除対象にならない。
        try JSONSerialization.data(withJSONObject: [["path": staging.path]]).write(to: file)
        _ = try PendingWorkRegistry(fileURL: file).sweep()
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try fixture.index.entries().count, 1)
        try fixture.assertOld()
    }
}
