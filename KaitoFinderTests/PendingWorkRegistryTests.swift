import AppKit
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class PendingWorkRegistryTests: XCTestCase {
    func testLaunchSweepPreservesWorkRegisteredByThisRunningProcess() async throws {
        let fixture = try ArchiveTestDirectory(), file = fixture.url.appendingPathComponent("pending.json")
        let directory = fixture.url.appendingPathComponent(".KaitoFinder-new-" + UUID().uuidString, isDirectory: true)
        let registry = PendingWorkRegistry(fileURL: file)
        // 起動時に utility Task が実行される前に、新しい作成処理が登録を済ませた順序。
        try registry.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let payload = directory.appendingPathComponent("archive.zip"), bytes = Data("work in progress".utf8)
        try bytes.write(to: payload)
        try registry.recordIdentity(directory)
        await PendingWorkRegistry(fileURL: file).startLaunchSweep().value
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertEqual(try? Data(contentsOf: payload), bytes)
        XCTAssertEqual(try Self.entries(in: file).compactMap { $0["path"] as? String }, [directory.path])
        registry.unregister(directory)
        XCTAssertTrue(try Self.entries(in: file).isEmpty)
    }

    func testLaunchSweepRetainsRegistrationBeforeDirectoryCreation() async throws {
        let fixture = try ArchiveTestDirectory(), file = fixture.url.appendingPathComponent("pending.json")
        let directory = fixture.url.appendingPathComponent(".KaitoFinder-add-" + UUID().uuidString, isDirectory: true)
        let registry = PendingWorkRegistry(fileURL: file)
        try registry.register(directory)
        await registry.startLaunchSweep().value
        XCTAssertEqual(try Self.entries(in: file).compactMap { $0["path"] as? String }, [directory.path])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try registry.recordIdentity(directory)
        XCTAssertNotNil(try Self.entries(in: file).first?["inode"])
        registry.unregister(directory)
    }

    static func entries(in file: URL) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
    }

    private static func simulateLegacyProcessExit(in file: URL) throws {
        var entries = try entries(in: file)
        for index in entries.indices { entries[index].removeValue(forKey: "processID") }
        try JSONSerialization.data(withJSONObject: entries).write(to: file, options: .atomic)
    }

    func testLaunchSweepRecoversWorkOwnedByAnExitedProcess() async throws {
        let fixture = try ArchiveTestDirectory(), file = fixture.url.appendingPathComponent("pending.json")
        let directory = fixture.url.appendingPathComponent(".KaitoFinder-new-" + UUID().uuidString, isDirectory: true)
        let registry = PendingWorkRegistry(fileURL: file)
        try registry.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try registry.recordIdentity(directory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        var entries = try Self.entries(in: file)
        entries[0]["processID"] = process.processIdentifier
        try JSONSerialization.data(withJSONObject: entries).write(to: file, options: .atomic)
        await registry.startLaunchSweep().value
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(try Self.entries(in: file).isEmpty)
    }

    func testCrashRecoveryRemovesRecordedWorkWithoutFollowingDescendantSymlinks() throws {
        let fixture = try ArchiveTestDirectory(), file = fixture.url.appendingPathComponent("pending.json")
        let outside = fixture.url.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let marker = outside.appendingPathComponent("keep.txt"), bytes = Data("keep outside contents".utf8)
        try bytes.write(to: marker)
        var work: [URL] = []
        for prefix in [".KaitoFinder-add-", ".KaitoFinder-new-"] {
            let directory = fixture.url.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
            let registry = PendingWorkRegistry(fileURL: file)
            try registry.register(directory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("unfinished archive".utf8).write(to: directory.appendingPathComponent("archive"))
            let nested = directory.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("file-link"), withDestinationURL: marker)
            try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("folder-link"), withDestinationURL: outside)
            try registry.recordIdentity(directory)
            let entry = try XCTUnwrap(Self.entries(in: file).first { $0["path"] as? String == directory.path })
            var info = stat()
            XCTAssertEqual(lstat(directory.path, &info), 0)
            XCTAssertEqual((entry["device"] as? NSNumber)?.int64Value, Int64(info.st_dev))
            XCTAssertEqual((entry["inode"] as? NSNumber)?.uint64Value, info.st_ino)
            work.append(directory)
        }
        // A fresh instance sees the on-disk ledger left by a process that never ran defer.
        try Self.simulateLegacyProcessExit(in: file)
        let removed = try PendingWorkRegistry(fileURL: file).sweep()
        XCTAssertEqual(Set(removed.map(\.path)), Set(work.map(\.path)))
        for directory in work { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)) }
        XCTAssertEqual(try Data(contentsOf: marker), bytes)
        XCTAssertTrue(try Self.entries(in: file).isEmpty)
    }

    func testRegisterUnregisterRoundTripAndCorruptJSONRecovery() throws {
        let fixture = try ArchiveTestDirectory(), file = fixture.url.appendingPathComponent("support/pending.json")
        let directory = fixture.url.appendingPathComponent(".KaitoFinder-add-" + UUID().uuidString)
        let registry = PendingWorkRegistry(fileURL: file)
        try registry.register(directory)
        let entry = try XCTUnwrap(Self.entries(in: file).first)
        XCTAssertEqual(entry["path"] as? String, directory.path)
        XCTAssertNil(entry["device"])
        XCTAssertNil(entry["inode"])
        registry.unregister(directory)
        XCTAssertTrue(try Self.entries(in: file).isEmpty)
        try Data("broken JSON".utf8).write(to: file)
        try registry.register(directory)
        XCTAssertEqual(try Self.entries(in: file).compactMap { $0["path"] as? String }, [directory.path])
        try Data("broken again".utf8).write(to: file)
        XCTAssertTrue(try registry.sweep().isEmpty)
        XCTAssertTrue(try Self.entries(in: file).isEmpty)
    }

    func testSweepDropsUnsafeReplacementsAndMissingPathsWithoutDeletingThem() throws {
        let fixture = try ArchiveTestDirectory(), file = fixture.url.appendingPathComponent("pending.json")
        let registry = PendingWorkRegistry(fileURL: file)
        let ordinary = fixture.url.appendingPathComponent("user-folder", isDirectory: true)
        let link = fixture.url.appendingPathComponent(".KaitoFinder-add-link", isDirectory: true)
        let regular = fixture.url.appendingPathComponent(".KaitoFinder-new-file")
        let replaced = fixture.url.appendingPathComponent(".KaitoFinder-add-replaced", isDirectory: true)
        let moved = fixture.url.appendingPathComponent("original-work", isDirectory: true)
        let wrongDevice = fixture.url.appendingPathComponent(".KaitoFinder-new-device", isDirectory: true)
        let missing = fixture.url.appendingPathComponent(".KaitoFinder-new-missing")
        let untracked = fixture.url.appendingPathComponent(".KaitoFinder-add-untracked", isDirectory: true)
        let bytes = Data("preserve".utf8)
        for directory in [ordinary, replaced, wrongDevice, untracked] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try bytes.write(to: directory.appendingPathComponent("keep.txt"))
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ordinary)
        try bytes.write(to: regular)
        for directory in [ordinary, link, regular, replaced, wrongDevice, missing] { try registry.register(directory) }
        try registry.recordIdentity(replaced)
        try registry.recordIdentity(wrongDevice)
        // Keep the original inode allocated, so the replacement cannot reuse it.
        try FileManager.default.moveItem(at: replaced, to: moved)
        try FileManager.default.createDirectory(at: replaced, withIntermediateDirectories: false)
        try bytes.write(to: replaced.appendingPathComponent("keep.txt"))
        var entries = try Self.entries(in: file)
        let deviceIndex = try XCTUnwrap(entries.firstIndex { $0["path"] as? String == wrongDevice.path })
        let device = try XCTUnwrap(entries[deviceIndex]["device"] as? NSNumber)
        entries[deviceIndex]["device"] = device.int64Value + 1
        try JSONSerialization.data(withJSONObject: entries).write(to: file, options: .atomic)
        try Self.simulateLegacyProcessExit(in: file)
        XCTAssertTrue(try PendingWorkRegistry(fileURL: file).sweep().isEmpty)
        for directory in [ordinary, replaced, wrongDevice, untracked, moved] {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("keep.txt")), bytes)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), ordinary.path)
        XCTAssertEqual(try Data(contentsOf: regular), bytes)
        XCTAssertTrue(try Self.entries(in: file).isEmpty)
    }

    func testSweepRecoversDirectoryCreatedBeforeIdentityWasRecorded() throws {
        let fixture = try ArchiveTestDirectory(), file = fixture.url.appendingPathComponent("pending.json")
        let directory = fixture.url.appendingPathComponent(".KaitoFinder-new-" + UUID().uuidString)
        let registry = PendingWorkRegistry(fileURL: file)
        try registry.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Self.simulateLegacyProcessExit(in: file)
        XCTAssertEqual(try registry.sweep().map(\.path), [directory.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(try Self.entries(in: file).isEmpty)
    }

    func testConcurrentInstancesDoNotLoseRegistrationsOrUnregistrations() throws {
        let fixture = try ArchiveTestDirectory(), file = fixture.url.appendingPathComponent("pending.json")
        let directories = (0..<24).map { fixture.url.appendingPathComponent(".KaitoFinder-add-\($0)") }
        let failures = Mutex<[String]>([])
        DispatchQueue.concurrentPerform(iterations: directories.count) { index in
            do { try PendingWorkRegistry(fileURL: file).register(directories[index]) }
            catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        XCTAssertTrue(failures.withLock { $0 }.isEmpty)
        XCTAssertEqual(Set(try Self.entries(in: file).compactMap { $0["path"] as? String }), Set(directories.map(\.path)))
        DispatchQueue.concurrentPerform(iterations: directories.count) { index in
            PendingWorkRegistry(fileURL: file).unregister(directories[index])
        }
        XCTAssertTrue(try Self.entries(in: file).isEmpty)
    }

    @MainActor func testAppDelegateStartsSweepWithInjectedRegistry() async throws {
        let fixture = try ArchiveTestDirectory(), file = fixture.url.appendingPathComponent("pending.json")
        let directory = fixture.url.appendingPathComponent(".KaitoFinder-add-" + UUID().uuidString)
        let registry = PendingWorkRegistry(fileURL: file)
        try registry.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try registry.recordIdentity(directory)
        try Self.simulateLegacyProcessExit(in: file)
        let delegate = AppDelegate()
        delegate.pendingWorkRegistry = registry
        delegate.sweepsPendingWorkAtLaunch = true
        await delegate.startLaunchSweeps().value
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(try Self.entries(in: file).isEmpty)
    }
}
