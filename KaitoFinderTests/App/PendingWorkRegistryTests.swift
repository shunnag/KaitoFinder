import AppKit
import Darwin
import Foundation
import KaitoKit
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
        for prefix in [".KaitoFinder-add-", ".KaitoFinder-new-", ".KaitoFinder-staging-"] {
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
        // defer を実行せずに終わったプロセスがディスクに残した台帳を、新しいインスタンスが読む。
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
        // 元の inode を割り当てたままにし、置き換えた directory がそれを再利用できないようにする。
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
        delegate.recoverableWorkIndex = RecoverableWorkIndex(fileURL: try volumePublishTestURL(fixture.url).appendingPathComponent("volume-index.json"))
        delegate.sweepsPendingWorkAtLaunch = true
        await delegate.startLaunchSweeps().value
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(try Self.entries(in: file).isEmpty)
    }

    // 旧名: ArchiveEditTests
    @MainActor func testPendingRegistryTracksDocumentAppendUntilSuccessOrCancellation() async throws {
        for cancel in [false, true] {
            let fixture = try ScenarioFixture(), source = try fixture.file("appended.txt")
            let (document, _) = try await scenarioDocument(fixture)
            let file = fixture.root.appendingPathComponent("pending.json")
            try Data("[]".utf8).write(to: file)
            let registry = PendingWorkRegistry(fileURL: file), gate = ScenarioGate(), progress = Progress()
            let before = try Data(contentsOf: fixture.archive)
            defer { gate.release() }
            let task = Task {
                try await ArchiveImportTransaction.pendingWorkRegistry.withValue(registry) {
                    try await document.append(urls: [source], to: "", progress: progress, willPublish: { gate.pauseOnce() })
                }
            }
            try await scenarioWait { gate.isEntered }
            let entries = try PendingWorkRegistryTests.entries(in: file)
            XCTAssertEqual(entries.count, 1)
            let work = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".KaitoFinder-add-") })
            XCTAssertEqual((entries.first?["path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                           work.resolvingSymlinksInPath().path)
            XCTAssertNotNil(entries.first?["device"])
            XCTAssertNotNil(entries.first?["inode"])
            if cancel { progress.cancel() }
            gate.release()
            do {
                let result = try await task.value
                XCTAssertFalse(cancel)
                XCTAssertEqual(result.addedPaths, ["appended.txt"])
            } catch {
                XCTAssertTrue(cancel)
                XCTAssertTrue(error is CancellationError)
                XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
            XCTAssertTrue(try PendingWorkRegistryTests.entries(in: file).isEmpty)
        }
    }

    // 旧名: ArchiveEditTests
    @MainActor func testPendingRegistryTracksPublicationUntilSuccessOrFailure() async throws {
        enum Failure: Error { case injected }
        for fail in [false, true] {
            let fixture = try ScenarioFixture(), source = try fixture.file("added.txt")
            let file = fixture.root.appendingPathComponent("pending.json")
            try Data("[]".utf8).write(to: file)
            let registry = PendingWorkRegistry(fileURL: file), gate = ScenarioGate()
            let archive = fixture.archive, before = try Data(contentsOf: archive)
            defer { gate.release() }
            let task = Task.detached {
                try ArchiveImportTransaction.publish(archive: archive, mode: .inPlace, options: .init(), progress: Progress(),
                    willPublish: {
                        gate.pauseOnce()
                        if fail { throw Failure.injected }
                    }, registry: registry, expectedOutput: .init(existing: try ArchiveReader.open(url: archive).entries,
                        additions: [.init(adding: "added.txt", kind: .file)], mode: .inPlace)) { updater in
                        try updater.add(contentsOf: source, as: "added.txt")
                    }
            }
            try await scenarioWait { gate.isEntered }
            let entries = try PendingWorkRegistryTests.entries(in: file)
            XCTAssertEqual(entries.count, 1)
            let work = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".KaitoFinder-add-") })
            XCTAssertEqual((entries.first?["path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                           work.resolvingSymlinksInPath().path)
            XCTAssertNotNil(entries.first?["device"])
            XCTAssertNotNil(entries.first?["inode"])
            gate.release()
            do {
                try await task.value
                XCTAssertFalse(fail)
                XCTAssertEqual(try ScenarioFixture.contents(archive)["added.txt"], Data("added".utf8))
            } catch {
                XCTAssertTrue(fail)
                guard case Failure.injected = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(try Data(contentsOf: archive), before)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
            XCTAssertTrue(try PendingWorkRegistryTests.entries(in: file).isEmpty)
        }
    }

    // 旧名: ArchiveEditTests
    func testRegistryWriteFailureDoesNotPreventPublication() throws {
        let fixture = try ScenarioFixture(), source = try fixture.file("added.txt")
        let blocker = try fixture.file("registry-parent")
        let registry = PendingWorkRegistry(fileURL: blocker.appendingPathComponent("pending.json"))
        XCTAssertThrowsError(try registry.register(fixture.root.appendingPathComponent(".KaitoFinder-add-probe")))
        try ArchiveImportTransaction.publish(archive: fixture.archive, mode: .inPlace, options: .init(), progress: Progress(),
            willPublish: nil, registry: registry, expectedOutput: .init(existing: try ArchiveReader.open(url: fixture.archive).entries,
                additions: [.init(adding: "added.txt", kind: .file)], mode: .inPlace)) { updater in
                try updater.add(contentsOf: source, as: "added.txt")
            }
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive)["added.txt"], Data("added".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".KaitoFinder-add-") })
    }
}


extension PendingWorkRegistryTests {
    func testSweepRetainsUnremovableDirectoryAndContinuesToNextEntry() throws {
        let fixture = try ArchiveTestDirectory(), file = fixture.url.appendingPathComponent("pending.json")
        let parent = fixture.url.appendingPathComponent("locked")
        let blocked = parent.appendingPathComponent(".KaitoFinder-add-blocked")
        let removable = fixture.url.appendingPathComponent(".KaitoFinder-new-removable")
        let registry = PendingWorkRegistry(fileURL: file)
        for directory in [blocked, removable] {
            try registry.register(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try registry.recordIdentity(directory)
        }
        try Self.simulateLegacyProcessExit(in: file)
        XCTAssertEqual(chmod(parent.path, 0o555), 0)
        defer { chmod(parent.path, 0o700) }
        var removed: [URL] = []
        XCTAssertNoThrow(removed = try registry.sweep(), "An unremovable directory must not abort the sweep")
        XCTAssertEqual(removed.map(\.path), [removable.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: removable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocked.path))
        XCTAssertEqual(try Self.entries(in: file).compactMap { $0["path"] as? String }, [blocked.path])
    }
}
