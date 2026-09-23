import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSaveStagingCorrectionTests: XCTestCase {
    private func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            let code = errno
            // macOS は ACL がない場合も ENOENT を返す。項目自体の不在とは区別する。
            if code == ENOENT {
                var info = stat()
                if lstat(url.path, &info) == 0 { return "" }
            }
            throw ExtractionFailure.system(code)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { throw ExtractionFailure.system(errno) }
        defer { acl_free(text) }
        return String(cString: text)
    }

    func testAbsentACLCanBeClearedRepeatedlyButMissingFileStillFails() throws {
        let directory = try ArchiveTestDirectory(), file = directory.url.appendingPathComponent("no-acl")
        try Data([1]).write(to: file)
        for _ in 0..<2 {
            try StagingRegistry.clearRemovalRestrictions(file)
            XCTAssertEqual(try aclText(file), "")
        }
        try FileManager.default.removeItem(at: file)
        for operation in [{ _ = try self.aclText(file) }, { try StagingRegistry.clearRemovalRestrictions(file) }] {
            XCTAssertThrowsError(try operation()) { error in
                if case ExtractionFailure.system(let code) = error { XCTAssertEqual(code, ENOENT) }
                else { XCTFail("Expected ENOENT, got \(error)") }
            }
        }
    }

    @MainActor func testImmutableDenyDeleteSourceCanBeSavedRevertedAndStagingRemoved() async throws {
        for operation in ["save", "revert"] {
            let fixture = try DeferredSaveFixture(), document = fixture.document
            let source = try fixture.file("locked.txt", contents: "keep")
            defer {
                _ = lchflags(source.path, 0)
                _ = try? fixture.directory.run("/bin/chmod", ["-N", source.path])
                document.close()
            }
            try fixture.directory.run("/bin/chmod", ["+a", "everyone deny delete", source.path])
            XCTAssertEqual(lchflags(source.path, UInt32(UF_IMMUTABLE)), 0)
            _ = try await document.append(urls: [source], to: "", progress: Progress())
            let staged = try XCTUnwrap(document.pendingChanges.additions.first?.stagedURL)
            let root = try XCTUnwrap(document.pendingEditor?.staging?.directory)
            var info = stat()
            XCTAssertEqual(lstat(staged.path, &info), 0)
            XCTAssertEqual(info.st_flags, 0)
            XCTAssertFalse(try aclText(staged).contains("deny"))
            XCTAssertEqual(lstat(source.path, &info), 0)
            XCTAssertNotEqual(info.st_flags & UInt32(UF_IMMUTABLE), 0)
            XCTAssertTrue(try aclText(source).contains("deny"))
            if operation == "save" {
                try await fixture.save()
                XCTAssertEqual(try DeferredSaveFixture.contents(fixture.archive)["locked.txt"], Data("keep".utf8))
            } else { try await document.revertPending() }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            _ = try await document.append(urls: [fixture.file("next.txt")], to: "", progress: Progress())
            try await document.revertPending()
        }
    }

    func testRemovalRetriesLegacyFlaggedStagingWithoutFollowingSymlinks() throws {
        let directory = try ArchiveTestDirectory(), registry = StagingRegistry(root: directory.url.appendingPathComponent("Staging"))
        let lease = try registry.create(id: UUID()), file = lease.directory.appendingPathComponent("legacy")
        let outside = directory.url.appendingPathComponent("outside")
        try Data([1]).write(to: file)
        try Data([2]).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: lease.directory.appendingPathComponent("link").path,
                                                  withDestinationPath: outside.path)
        defer { _ = lchflags(file.path, 0); _ = lchflags(outside.path, 0); lease.remove() }
        try directory.run("/bin/chmod", ["+a", "everyone deny delete", file.path])
        XCTAssertEqual(lchflags(file.path, UInt32(UF_IMMUTABLE)), 0)
        XCTAssertEqual(lchflags(outside.path, UInt32(UF_IMMUTABLE)), 0)
        lease.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.directory.path))
        var info = stat()
        XCTAssertEqual(lstat(outside.path, &info), 0)
        XCTAssertNotEqual(info.st_flags & UInt32(UF_IMMUTABLE), 0)
        XCTAssertTrue(try registry.sweep().isEmpty)
    }

    func testMissingOwnerLockIsTrashedOnce() throws {
        let directory = try ArchiveTestDirectory(), registry = StagingRegistry(root: directory.url.appendingPathComponent("Staging"))
        var lease: StagingRegistry.Lease? = try registry.create(id: UUID())
        let root = try XCTUnwrap(lease?.directory)
        try Data("only copy".utf8).write(to: root.appendingPathComponent("payload.txt"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".KaitoFinder-owner.lock"))
        withExtendedLifetime(lease) {}
        lease = nil
        let recovered = directory.url.appendingPathComponent("Trash")
        let results = try registry.sweep { source in
            try FileManager.default.moveItem(at: source, to: recovered)
            return recovered
        }
        XCTAssertEqual(results, [recovered])
        XCTAssertEqual(try Data(contentsOf: recovered.appendingPathComponent("payload.txt")), Data("only copy".utf8))
        XCTAssertTrue(try registry.sweep().isEmpty)
    }

    @MainActor func testNewStagingLeaseDoesNotReuseDirectoryStillHeldByARead() async throws {
        let directory = try ArchiveTestDirectory(), registry = StagingRegistry(root: directory.url.appendingPathComponent("Staging"))
        let editor = ArchivePendingEditor(registry: registry), source = directory.url.appendingPathComponent("photo.png")
        try Data([1]).write(to: source)
        let items = [ArchiveImportPlan.Item(url: source, path: "photo.png", isDirectory: false)]
        let first = try await editor.stage(items, progress: Progress())
        let old = try XCTUnwrap(editor.reset())
        var read: StagingRegistry.ReadLease? = try old.acquireRead()
        let cleanup = Task { await old.removeWhenUnused() }
        defer { read = nil }
        let second = try await editor.stage(items, progress: Progress())
        XCTAssertNotEqual(first[0].stagedURL, second[0].stagedURL)
        XCTAssertEqual(second[0].stagedURL.lastPathComponent, "photo.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first[0].stagedURL.path))
        withExtendedLifetime(read) {}
        read = nil
        await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.directory.path))
        await editor.reset()?.removeWhenUnused()
    }

    func testProtectedNonessentialXattrFailureDoesNotAbortStagingMetadata() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("source")
        let target = directory.url.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let name = "com.kaitofinder.protected-fixture", bytes = Data([1])
        XCTAssertEqual(bytes.withUnsafeBytes { setxattr(source.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 0)
        let quarantine = Data("0081;12345678;fixture;".utf8)
        try ExtractionQuarantine.apply(quarantine, to: source)
        for code in [EPERM, ENOTSUP] {
            var attempted = false
            try StagingRegistry.copyExtendedAttributes(from: source, to: target, progress: Progress()) { url, attribute, value in
                if attribute == name { attempted = true; throw ExtractionFailure.system(code) }
                if attribute == ExtractionQuarantine.name { try ExtractionQuarantine.apply(value, to: url) }
            }
            XCTAssertTrue(attempted)
            XCTAssertEqual(try ExtractionQuarantine.read(from: target), quarantine)
        }
    }

    @MainActor func testCancellingCrossVolumeFallbackByTaskOrProgressRemovesPartialBatchAndRegistration() async throws {
        for cancelTask in [false, true] {
            let directory = try ArchiveTestDirectory(), registry = StagingRegistry(root: directory.url.appendingPathComponent("Staging"))
            let editor = ArchivePendingEditor(registry: registry), gate = ScenarioGate(), progress = Progress()
            editor.allowsClone = false
            editor.didCopyStagingBytes = { _ in gate.pauseOnce() }
            let source = directory.url.appendingPathComponent("large.bin")
            try Data(repeating: 0x5a, count: 2 * 1024 * 1024).write(to: source)
            let stage = Task { try await editor.stage([.init(url: source, path: "large.bin", isDirectory: false)], progress: progress) }
            defer { gate.release(); stage.cancel() }
            try await scenarioWait { gate.isEntered }
            let root = try XCTUnwrap(editor.staging?.directory)
            if cancelTask { stage.cancel() } else { progress.cancel() }
            gate.release()
            do { _ = try await stage.value; XCTFail("Copy must be cancelled within the item") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertNil(editor.staging)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            XCTAssertTrue(try registry.sweep { url in XCTFail("Cancelled partial copy is not an orphan"); return url }.isEmpty)
        }
    }

    @MainActor func testQuitCancelsPartialReservationAndCleansWithoutOrphanNotification() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
        let editor = try XCTUnwrap(document.pendingEditor)
        editor.allowsClone = false
        editor.didCopyStagingBytes = { _ in gate.pauseOnce() }
        let source = try fixture.file("large.bin")
        try Data(repeating: 1, count: 2 * 1024 * 1024).write(to: source)
        let adding = Task { try await document.append(urls: [source], to: "", progress: Progress()) }
        defer { gate.release(); adding.cancel(); document.close() }
        try await scenarioWait { gate.isEntered }
        let root = try XCTUnwrap(editor.staging?.directory)
        let quitting = Task { await document.prepareForTermination() }
        try await scenarioWait { editor.stagingTask?.isCancelled == true }
        gate.release()
        await quitting.value
        do { _ = try await adding.value; XCTFail("Quit must cancel staging") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }
}
