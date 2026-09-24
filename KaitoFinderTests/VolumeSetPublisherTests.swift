import CryptoKit
import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class VolumeSetPublisherTests: XCTestCase {
    private func disk(_ fileSystem: String) throws -> VolumePublishTestDisk {
        let disk = try VolumePublishTestDisk(fileSystem)
        addTeardownBlock { try disk.detach() }
        return disk
    }

    private let scheme = ArchiveVolumeSet.Scheme.numbered(stem: "archive.tar", width: 3)
    private enum Injected: Error { case failure }

    func testUniformAndExplicitPlansAndVolumeLimit() throws {
        for (length, expected) in [(7, [7]), (20, [10, 10]), (23, [10, 10, 3])] {
            let plan = try VolumePlan(totalLength: UInt64(length), schedule: .uniform(size: 10), scheme: scheme)
            XCTAssertEqual(plan.volumes.map(\.length), expected.map(UInt64.init))
            XCTAssertEqual(plan.gateName, "archive.tar.001")
            XCTAssertEqual(plan.volumes.last!.offset + plan.volumes.last!.length, UInt64(length))
        }
        let plan = try VolumePlan(totalLength: 25, schedule: .explicit([9, 4, 2]), scheme: scheme)
        XCTAssertEqual(plan.volumes.map(\.length), [9, 4, 4, 4, 4])
        XCTAssertEqual(try VolumePlan(totalLength: 13, schedule: .explicit([3]), scheme: scheme).volumes.map(\.length), [3, 3, 3, 3, 1])
        XCTAssertThrowsError(try VolumePlan(totalLength: 1290, schedule: .uniform(size: 10), scheme: scheme)) {
            XCTAssertEqual($0 as? VolumePublishError, .tooManyVolumes(required: 129))
        }
        XCTAssertThrowsError(try VolumePlan(totalLength: UInt64(Int64.max), schedule: .uniform(size: 1), scheme: scheme)) {
            XCTAssertEqual($0 as? VolumePublishError, .tooManyVolumes(required: UInt64(Int64.max)))
        }
        for schedule in [VolumePlan.Schedule.uniform(size: 0), .explicit([]), .explicit([9, 0])] {
            XCTAssertThrowsError(try VolumePlan(totalLength: 10, schedule: schedule, scheme: scheme))
        }
        XCTAssertThrowsError(try VolumePlan(totalLength: 0, schedule: .uniform(size: 10), scheme: scheme))
        XCTAssertThrowsError(try VolumePlan(totalLength: 100, schedule: .uniform(size: 10),
            scheme: .zipSpanned(stem: "archive", volumePrefix: "z", lastExtension: "zip")))
    }

    private func splitterDirectories() throws -> (ArchiveTestDirectory, VolumePublishDirectory, VolumePublishDirectory, VolumePublishDirectory) {
        let fixture = try ArchiveTestDirectory()
        let parent = try VolumePublishDirectory(volumePublishTestURL(fixture.url))
        let staging = try parent.directory(VolumePublishFS.stagingPrefix + UUID().uuidString, create: true)
        return (fixture, parent, try staging.directory("work", create: true), try staging.directory("new", create: true))
    }

    private func xattr(_ url: URL, _ name: String, _ data: Data) throws {
        let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw VolumePublishError.system(errno) }
    }
    private func xattr(_ url: URL, _ name: String) throws -> Data? {
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        if count < 0, errno == ENOATTR { return nil }
        guard count >= 0 else { throw VolumePublishError.system(errno) }
        var bytes = Data(count: count)
        let actual = bytes.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, count, 0, XATTR_NOFOLLOW) }
        guard actual == count else { throw VolumePublishError.system(errno) }
        return bytes
    }

    func testSplitterConcatenationHashesModesAllXattrsAndFirstQuarantine() throws {
        let (fixture, parent, work, new) = try splitterDirectories()
        defer { withExtendedLifetime(fixture) {} }
        let bytes = Data((0..<103).map(UInt8.init)), workURL = work.url.appendingPathComponent("archive.tar")
        try bytes.write(to: workURL)
        let urls = ["archive.tar.001", "archive.tar.002"].map { parent.url.appendingPathComponent($0) }
        for url in urls { try Data("old".utf8).write(to: url) }
        XCTAssertEqual(chmod(urls[0].path, 0o640), 0)
        XCTAssertEqual(chmod(urls[1].path, 0o604), 0)
        try xattr(urls[0], "com.shunnag.test.gate", Data("gate".utf8))
        try xattr(urls[1], "com.shunnag.test.second", Data([0, 1, 0, 2]))
        try xattr(urls[0], "com.shunnag.test.empty", Data())
        let quarantine = Data("0083;12345678;KaitoFinder;".utf8)
        try xattr(urls[1], "com.apple.quarantine", quarantine)
        let layout = ArchiveVolumeLayout(scheme: scheme, volumes: urls.map { .init(url: $0, length: 3) }, openedVolumeIndex: 0)
        let plan = try VolumePlan(totalLength: UInt64(bytes.count), schedule: .uniform(size: 30), scheme: scheme)
        let records = try VolumeSplitter.split(workURL: workURL, into: new, plan: plan, oldLayout: layout)
        XCTAssertEqual(try Data(contentsOf: workURL), Data())
        var joined = Data()
        for (i, record) in records.enumerated() {
            let url = new.url.appendingPathComponent(record.name), data = try Data(contentsOf: url)
            joined.append(data)
            XCTAssertEqual(record.sha256, VolumePublishFS.digest(data))
            XCTAssertEqual(UInt64(data.count), record.length)
            XCTAssertEqual(try XCTUnwrap(new.info(record.name)).st_mode & 0o777, i == 1 ? 0o604 : 0o640)
            XCTAssertEqual(try xattr(url, "com.apple.quarantine"), quarantine)
            XCTAssertEqual(try xattr(url, "com.shunnag.test.gate"), i == 1 ? nil : Data("gate".utf8))
            XCTAssertEqual(try xattr(url, "com.shunnag.test.second"), i == 1 ? Data([0, 1, 0, 2]) : nil)
            XCTAssertEqual(try xattr(url, "com.shunnag.test.empty"), i == 1 ? nil : Data())
        }
        XCTAssertEqual(joined, bytes)
    }

    func testNewSetCopiesWorkAttributesAndQuarantine() throws {
        let (fixture, _, work, new) = try splitterDirectories()
        defer { withExtendedLifetime(fixture) {} }
        let url = work.url.appendingPathComponent("archive.tar"), bytes = Data(repeating: 0x5a, count: 40)
        try bytes.write(to: url)
        XCTAssertEqual(chmod(url.path, 0o640), 0)
        try xattr(url, "com.shunnag.test.work", Data([7, 8]))
        let quarantine = Data("0083;12345678;KaitoFinder;".utf8)
        try xattr(url, "com.apple.quarantine", quarantine)
        let plan = try VolumePlan(totalLength: 40, schedule: .explicit([13, 7]), scheme: scheme)
        let records = try VolumeSplitter.split(workURL: url, into: new, plan: plan, oldLayout: nil)
        for record in records {
            let output = new.url.appendingPathComponent(record.name)
            XCTAssertEqual(try xattr(output, "com.shunnag.test.work"), Data([7, 8]))
            XCTAssertEqual(try xattr(output, "com.apple.quarantine"), quarantine)
            XCTAssertEqual(try XCTUnwrap(new.info(record.name)).st_mode & 0o777, 0o640)
        }
    }

    func testSplitterNeverFollowsWorkOutputOrParentSymlinks() throws {
        let (fixture, parent, work, new) = try splitterDirectories()
        defer { withExtendedLifetime(fixture) {} }
        let victim = parent.url.appendingPathComponent("victim"), original = Data(repeating: 0x71, count: 40)
        try original.write(to: victim)
        let link = work.url.appendingPathComponent("archive.tar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)
        let plan = try VolumePlan(totalLength: 40, schedule: .uniform(size: 20), scheme: scheme)
        XCTAssertThrowsError(try VolumeSplitter.split(workURL: link, into: new, plan: plan, oldLayout: nil))
        XCTAssertEqual(try Data(contentsOf: victim), original)
        try FileManager.default.removeItem(at: link)
        try original.write(to: link)
        try FileManager.default.createSymbolicLink(at: new.url.appendingPathComponent("archive.tar.002"), withDestinationURL: victim)
        XCTAssertThrowsError(try VolumeSplitter.split(workURL: link, into: new, plan: plan, oldLayout: nil))
        XCTAssertEqual(try Data(contentsOf: victim), original)
        let alias = parent.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: work.url)
        XCTAssertThrowsError(try VolumePublishDirectory(alias))
    }

    func testAPFSHappyPathsGrowShrinkOneSameAndCreate() throws {
        let disk = try disk("APFS")
        defer { try? disk.detach() }
        for (oldCount, newCount) in [(3, 5), (5, 2), (5, 1), (3, 3), (0, 4)] {
            let fixture = try VolumePublishFixture(parent: disk.mount, oldCount: oldCount, newCount: newCount)
            let publication = try fixture.begin()
            let result = try publication.publish(progress: Progress()) { reader in
                XCTAssertEqual(reader.entries.map(\.name), ["payload.bin"])
            }
            XCTAssertEqual(result.layout.volumes.count, newCount)
            XCTAssertEqual(result.identity, try ArchiveSetIdentity.capture(layout: result.layout))
            if oldCount > 0 {
                guard case .trashed(let url) = result.oldVolumesDisposal else { return XCTFail("APFS should Trash old/: \(result.oldVolumesDisposal)") }
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            } else { XCTAssertEqual(result.oldVolumesDisposal, .none) }
            try fixture.assertNew()
            try fixture.assertRemoved(publication.stagingURL)
        }
    }

    func testEveryBoundaryOrdinaryFailureRollsBackAndCrashRecoversWithoutMixedGate() throws {
        let disk = try disk("APFS")
        defer { try? disk.detach() }
        for (oldCount, newCount) in [(3, 5), (5, 2), (3, 1), (3, 3), (0, 3)] {
            let template = try VolumePublishFixture(parent: disk.mount, oldCount: oldCount, newCount: newCount)
            for step in template.steps {
                for crash in [false, true] {
                    let fixture = try VolumePublishFixture(parent: disk.mount, oldCount: oldCount, newCount: newCount)
                    let reached = Mutex(false)
                    let publication = try fixture.begin { current in
                        try fixture.assertGateIsComplete(allowAbsent: true)
                        if current == step {
                            reached.withLock { $0 = true }
                            if crash { throw SimulatedCrash() }
                            throw Injected.failure
                        }
                    }
                    XCTAssertThrowsError(try publication.publish(progress: Progress())) { error in
                        if crash { XCTAssertTrue(error is SimulatedCrash, "\(step): \(error)") }
                    }
                    XCTAssertTrue(reached.withLock { $0 }, "Missing injection: \(step)")
                    if crash {
                        let result = VolumePublishRecovery(index: fixture.index).recover(staging: publication.stagingURL)
                        guard case .recovered = result else { return XCTFail("\(step): \(result)") }
                        try fixture.assertGateIsComplete(allowAbsent: false)
                    } else { try fixture.assertOld() }
                    try fixture.assertRemoved(publication.stagingURL)
                }
            }
        }
    }

    func testPreflightNameOccupancyAndVolumeLimitWriteNothing() throws {
        for occupiedIndex in 3...5 {
            let fixture = try VolumePublishFixture()
            let name = fixture.scheme.fileName(forVolumeAt: occupiedIndex, count: 6)
            try Data("unrelated".utf8).write(to: fixture.root.appendingPathComponent(name))
            let before = try VolumePublishFixture.snapshot(fixture.root)
            XCTAssertThrowsError(try fixture.begin()) { XCTAssertEqual($0 as? VolumePublishError, .nameOccupied(name)) }
            XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
        }
        let fixture = try VolumePublishFixture(oldCount: 0)
        let tooMany = VolumeSetTarget(parent: fixture.root, newSetScheme: scheme, schedule: .uniform(size: 1))
        XCTAssertThrowsError(try VolumeSetPublication.begin(tooMany, estimatedOutputLength: 129, index: fixture.index)) {
            XCTAssertEqual($0 as? VolumePublishError, .tooManyVolumes(required: 129))
        }
        XCTAssertTrue(try VolumePublishDirectory(fixture.root).names().isEmpty)
    }

    func testRewriterAssemblyCheckAndVerifiedZIPStyleJoin() throws {
        let fixture = try VolumePublishFixture()
        let publication = try VolumeSetPublication.begin(fixture.target(), estimatedOutputLength: UInt64(fixture.newBytes.count), index: fixture.index)
        defer { publication.cancel() }
        let rewriter = try ArchiveRewriter.open(url: fixture.gate, format: .tar)
        try publication.verifyAssembledInput(rewriter.volumeSet)
        XCTAssertThrowsError(try publication.verifyAssembledInput(nil))
        try publication.copyInputToWork(progress: Progress())
        XCTAssertEqual(try Data(contentsOf: publication.workURL), fixture.oldBytes)
        let third = fixture.root.appendingPathComponent("archive.tar.003")
        let bytes = try Data(contentsOf: third)
        try FileManager.default.removeItem(at: third)
        try bytes.write(to: third)
        let changed = try ArchiveRewriter.open(url: fixture.gate, format: .tar)
        XCTAssertThrowsError(try publication.verifyAssembledInput(changed.volumeSet)) {
            XCTAssertEqual($0 as? VolumePublishError, .setChanged)
        }
    }

    func testCancellationStopsBeforeS5AndIsIgnoredAfterS5() throws {
        let before = try VolumePublishFixture(), cancelled = Progress()
        cancelled.cancel()
        let snapshot = try VolumePublishFixture.snapshot(before.root)
        XCTAssertThrowsError(try VolumeSetPublication.begin(before.target(), estimatedOutputLength: UInt64(before.newBytes.count),
            progress: cancelled, index: before.index)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try VolumePublishFixture.snapshot(before.root), snapshot)
        let preparing = try before.begin()
        XCTAssertThrowsError(try preparing.publish(progress: cancelled)) { XCTAssertTrue($0 is CancellationError) }
        try before.assertOld()
        let fixture = try VolumePublishFixture(), progress = Progress()
        let publication = try fixture.begin { if $0 == .s6 { progress.cancel() } }
        _ = try publication.publish(progress: progress)
        XCTAssertFalse(progress.isCancellable)
        try fixture.assertNew()
    }

    func testFailedRollbackKeepsAbandonedDataIndexAndHidesOurNewGate() throws {
        let fixture = try VolumePublishFixture(), location = Mutex<URL?>(nil)
        let publication = try fixture.begin { step in
            if step == .s9 {
                let staging = try XCTUnwrap(location.withLock { $0 })
                try Data("external change".utf8).write(to: staging.appendingPathComponent("old/archive.tar.002"))
                throw Injected.failure
            }
        }
        location.withLock { $0 = publication.stagingURL }
        XCTAssertThrowsError(try publication.publish(progress: Progress())) {
            XCTAssertEqual($0 as? VolumePublishError, .rollbackIncomplete(publication.stagingURL))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: publication.stagingURL.appendingPathComponent("abandoned").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.gate.path))
        XCTAssertEqual(try fixture.index.entries().count, 1)
        let before = try VolumePublishFixture.snapshot(fixture.root)
        guard case .held = VolumePublishRecovery(index: fixture.index).recover(staging: publication.stagingURL) else {
            return XCTFail("An unprovable old set must be retained")
        }
        XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
    }

    func testFAT32HazardConsentHappyPathAndCrashRecovery() throws { try hazardousFileSystem("MS-DOS FAT32") }
    func testExFATHazardConsentHappyPathAndCrashRecovery() throws { try hazardousFileSystem("ExFAT") }
    private func hazardousFileSystem(_ fileSystem: String) throws {
        let disk = try disk(fileSystem)
        defer { try? disk.detach() }
        try disk.disableTrash()
        let fixture = try VolumePublishFixture(parent: disk.mount)
        let before = try VolumePublishFixture.snapshot(fixture.root)
        XCTAssertThrowsError(try fixture.begin()) {
            guard case VolumePublishError.hazardousVolume = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try VolumePublishFixture.snapshot(fixture.root), before)
        let publication = try fixture.begin(consent: true)
        let result = try publication.publish(progress: Progress())
        XCTAssertTrue(result.usedExclusiveRenameFallback)
        XCTAssertEqual(result.oldVolumesDisposal, .removed)
        try fixture.assertNew()
        try fixture.assertRemoved(publication.stagingURL)
        let crashed = try VolumePublishFixture(parent: disk.mount)
        let interrupted = try crashed.begin(consent: true) { if $0 == .s8 { throw SimulatedCrash() } }
        XCTAssertThrowsError(try interrupted.publish(progress: Progress())) { XCTAssertTrue($0 is SimulatedCrash) }
        let recovery = VolumePublishRecovery(index: crashed.index).recover(staging: interrupted.stagingURL)
        guard case .recovered(_, .forward, .removed) = recovery else { return XCTFail("\(recovery)") }
        try crashed.assertRemoved(interrupted.stagingURL)
        try crashed.assertNew()
    }

    func testHFSPlusHappyPathUsesTrash() throws {
        let disk = try disk("HFS+")
        defer { try? disk.detach() }
        let fixture = try VolumePublishFixture(parent: disk.mount, oldCount: 5, newCount: 2)
        let publication = try fixture.begin(), result = try publication.publish(progress: Progress())
        guard case .trashed(let url) = result.oldVolumesDisposal else { return XCTFail("\(result.oldVolumesDisposal)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try fixture.assertNew()
        try fixture.assertRemoved(publication.stagingURL)
    }

    func testMaximum128VolumesDoesNotExhaustDescriptors() throws {
        AppDelegate.raiseFileDescriptorLimit()
        let fixture = try VolumePublishFixture(oldCount: 128, newCount: 128)
        let publication = try fixture.begin()
        _ = try publication.publish(progress: Progress())
        try fixture.assertNew()
        try fixture.assertRemoved(publication.stagingURL)
    }

    func testOptionalSevenZipReadsPublishedNumberedSet() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/7zz") else {
            throw XCTSkip("7zz is not installed")
        }
        let fixture = try VolumePublishFixture()
        let publication = try fixture.begin()
        _ = try publication.publish(progress: Progress())
        _ = try fixture.directory.run("/opt/homebrew/bin/7zz", ["t", fixture.gate.path])
    }
}
