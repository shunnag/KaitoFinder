import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSaveExtractionTests: XCTestCase {
    @MainActor private func payload(_ path: String, in fixture: DeferredSaveFixture) async throws -> ArchiveEntryPayload {
        let node = try await fixture.node(path)
        return ArchiveEntryPayload(node: node, session: try XCTUnwrap(fixture.document.session),
                                   generation: fixture.document.generation)
    }

    @MainActor private func directory(in fixture: DeferredSaveFixture, named name: String = UUID().uuidString) throws -> URL {
        let url = fixture.directory.url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }

    @MainActor private func write(_ promise: ArchiveFilePromise, to url: URL) async -> (any Error)? {
        await withCheckedContinuation { continuation in
            promise.filePromiseProvider(NSFilePromiseProvider(), writePromiseTo: url) { @Sendable error in
                continuation.resume(returning: error)
            }
        }
    }

    @MainActor private func preview(_ payload: ArchiveEntryPayload, session: ArchiveSession,
                                    worker: EntryMaterializer) async throws -> URL {
        let entry = try XCTUnwrap(session.pendingReadSnapshot?.resolve(payload).first)
        let item = ArchivePreviewItem(payload: payload,
            capability: .init(entry: entry, isDirectory: false, format: session.format), requiresProgress: false)
        let controller = ArchiveMaterializationController { payload, progress in
            try await worker.materialize(payload, progress: progress)
        }
        controller.setSelection([item])
        controller.display(index: 0) { _ in }
        await controller.task?.value
        return try XCTUnwrap(item.previewItemURL)
    }

    @MainActor func testSwapExtractPromiseClipboardAndQuickLookAgreeWithSave() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let session = try XCTUnwrap(document.session)
        for (source, name) in [("a.txt", "temporary.txt"), ("b.txt", "a.txt"), ("temporary.txt", "b.txt")] {
            _ = try await document.rename(fixture.node(source), to: name, progress: Progress())
        }
        let a = try await payload("a.txt", in: fixture), b = try await payload("b.txt", in: fixture)
        XCTAssertEqual(a.origin, .base(index: 1, expectedName: "b.txt", baseGeneration: document.generation))
        XCTAssertEqual(b.origin, .base(index: 0, expectedName: "a.txt", baseGeneration: document.generation))
        let output = try directory(in: fixture)
        try ArchiveCopyOut.check(await ExtractionService.extract([a, b], from: session, to: output, progress: Progress()))
        let copied = try await ArchiveCopyOut.prepare([a, b], from: session, progress: Progress(),
            temporaryDirectory: .init(root: directory(in: fixture)))
        let worker = EntryMaterializer(session: session, temporaryDirectory: .init(root: try directory(in: fixture)))
        for (index, item, contents) in [(0, a, "B"), (1, b, "A")] {
            let expected = Data(contents.utf8)
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(item.path)), expected)
            XCTAssertEqual(try Data(contentsOf: copied.urls[index]), expected)
            let promised = try directory(in: fixture).appendingPathComponent(item.path)
            let failure = await write(ArchiveFilePromise(payload: item, session: session), to: promised)
            XCTAssertNil(failure)
            XCTAssertEqual(try Data(contentsOf: promised), expected)
            let url = try await preview(item, session: session, worker: worker)
            XCTAssertEqual(url.lastPathComponent, item.path)
            XCTAssertEqual(try Data(contentsOf: url), expected)
        }
        await worker.close()
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        try await fixture.save()
        let saved = try DeferredSaveFixture.contents(fixture.archive)
        XCTAssertEqual(saved["a.txt"], Data("B".utf8))
        XCTAssertEqual(saved["b.txt"], Data("A".utf8))
    }

    @MainActor func testStagedSnapshotIsUsedByEveryFileReadAndOpenCopyIsReadOnly() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tarGzip, .lha] {
            let fixture = try DeferredSaveFixture(format: format), document = fixture.document
            defer { document.close() }
            let session = try XCTUnwrap(document.session), source = try fixture.file("added.txt", contents: "staged")
            _ = try await document.append(urls: [source], to: "", progress: Progress())
            let item = try await payload("added.txt", in: fixture)
            XCTAssertEqual(item.origin, .pending(try XCTUnwrap(document.pendingChanges.additions.first?.id)))
            try Data("source changed".utf8).write(to: source)
            let output = try directory(in: fixture)
            try ArchiveCopyOut.check(await ExtractionService.extract([item], from: session, to: output, progress: Progress()))
            let copied = try await ArchiveCopyOut.prepare([item], from: session, progress: Progress(),
                temporaryDirectory: .init(root: directory(in: fixture)))
            let promise = output.appendingPathComponent("promised.txt")
            let failure = await write(ArchiveFilePromise(payload: item, session: session), to: promise)
            XCTAssertNil(failure)
            let worker = EntryMaterializer(session: session, temporaryDirectory: .init(root: try directory(in: fixture)))
            let quickLook = try await preview(item, session: session, worker: worker)
            // Open / Open With use this same materializer, including its marker and 0400 mode.
            let openCopy = try await worker.materialize(item, progress: Progress())
            for url in [output.appendingPathComponent(item.path), copied.urls[0], promise, quickLook, openCopy] {
                XCTAssertEqual(try Data(contentsOf: url), Data("staged".utf8))
            }
            var info = stat()
            XCTAssertEqual(lstat(openCopy.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o400)
            XCTAssertTrue(ArchiveTemporaryCopy.contains(openCopy))
            await worker.close()
        }
    }

    @MainActor func testMixedFolderExpandAllAndFolderPromiseOmitRemovalsAndUseProjectedNames() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let session = try XCTUnwrap(document.session)
        _ = try await document.append(urls: [fixture.file("added.txt", contents: "added")], to: "folder", progress: Progress())
        _ = try await document.rename(fixture.node("folder/child.txt"), to: "renamed.txt", progress: Progress())
        _ = try await document.move([fixture.node("b.txt")], to: "folder", progress: Progress())
        let removed = try await payload("folder/b.txt", in: fixture)
        _ = try await document.remove([fixture.node("folder/b.txt")], progress: Progress())
        _ = try await document.createFolder(in: "folder", baseName: "empty", progress: Progress())
        _ = try await document.rename(fixture.node("folder"), to: "mixed", progress: Progress())
        let root = EntryNode.tree(from: try await document.projectedEntries())
        let all = ArchiveEntryPayload.payloads(for: root.children, session: session, generation: document.generation)
        let output = try directory(in: fixture)
        try ArchiveCopyOut.check(await ExtractionService.extract(all, from: session, to: output, progress: Progress()))
        let paths = try XCTUnwrap(FileManager.default.subpaths(atPath: output.path))
        XCTAssertEqual(Set(paths), ["a.txt", "mixed", "mixed/renamed.txt", "mixed/added.txt", "mixed/empty"])
        let folder = try await payload("mixed", in: fixture)
        let promise = output.appendingPathComponent("promised")
        let failure = await write(ArchiveFilePromise(payload: folder, session: session), to: promise)
        XCTAssertNil(failure)
        for parent in [output.appendingPathComponent("mixed"), promise] {
            XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent("renamed.txt")), Data("child".utf8))
            XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent("added.txt")), Data("added".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("b.txt").path))
        }
        do {
            _ = try await ExtractionService.extract([removed], from: session, to: output, progress: Progress())
            XCTFail("Removed payload must fail before producing any bytes")
        } catch { XCTAssertEqual(ArchiveErrorText.describe(error), ArchiveEntryPayload.staleSelection.description) }
    }

    @MainActor func testStalePromiseAndMismatchedOriginFailWithoutNameFallback() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let session = try XCTUnwrap(document.session), old = try await payload("a.txt", in: fixture)
        let promise = ArchiveFilePromise(payload: old, session: session)
        _ = try await document.rename(fixture.node("a.txt"), to: "temporary.txt", progress: Progress())
        _ = try await document.rename(fixture.node("b.txt"), to: "a.txt", progress: Progress())
        let destination = try directory(in: fixture).appendingPathComponent("a.txt")
        let failure = await write(promise, to: destination)
        XCTAssertEqual(failure.map { ArchiveErrorText.describe($0) }, ArchiveEntryPayload.staleSelection.description)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let current = try await payload("a.txt", in: fixture), snapshot = try XCTUnwrap(session.pendingReadSnapshot)
        for origin: ArchiveEntryPayload.Origin in [
            .base(index: 0, expectedName: "a.txt", baseGeneration: current.generation),
            .base(index: 1, expectedName: "a.txt", baseGeneration: current.generation),
            .base(index: 1, expectedName: "b.txt", baseGeneration: current.generation + 1), .pending(UUID())
        ] {
            let invalid = ArchiveEntryPayload(archiveURL: current.archiveURL, generation: current.generation,
                entryIndex: current.entryIndex, path: current.path, isDirectory: false, revision: current.revision, origin: origin)
            XCTAssertThrowsError(try snapshot.resolve(invalid))
        }
        let unversioned = ArchiveEntryPayload(archiveURL: current.archiveURL, generation: current.generation,
            entryIndex: current.entryIndex, path: current.path, isDirectory: false)
        XCTAssertThrowsError(try snapshot.resolve(unversioned))
        XCTAssertThrowsError(try current.resolve(in: snapshot.base, generation: current.generation))
        // Undo restores the name, but must not make an old revision valid again.
        document.undoManager?.undo()
        document.undoManager?.undo()
        XCTAssertThrowsError(try XCTUnwrap(session.pendingReadSnapshot).resolve(old))
    }

    @MainActor func testVirtualFolderUsesAnOriginAnchorAndCombinesReaderAndStaging() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let session = try XCTUnwrap(document.session), editor = try XCTUnwrap(document.pendingEditor)
        _ = try await document.projectedEntries()
        var changes = editor.changes
        changes.renames[.init(index: 0, expectedName: "a.txt", baseGeneration: document.generation)] = "virtual/base.txt"
        changes.renames[.init(index: 1, expectedName: "b.txt", baseGeneration: document.generation)] = "virtual/nested/base.txt"
        let source = try fixture.file("incoming.txt", contents: "pending")
        changes.additions = try await editor.stage([
            .init(url: source, path: "virtual/added.txt", isDirectory: false),
            .init(url: source, path: "virtual/nested/added.txt", isDirectory: false)
        ], progress: Progress())
        editor.replace(changes)
        let virtual = try await payload("virtual", in: fixture)
        XCTAssertNil(virtual.entryIndex)
        XCTAssertNotNil(virtual.origin)
        let parent = try directory(in: fixture, named: "promise-storage/deep/parent")
        let alias = fixture.directory.url.appendingPathComponent("promise-alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: parent.deletingLastPathComponent().path)
        // An ancestor alias deliberately changes the resolved path's depth, even when TMPDIR is canonical.
        for output in [parent.appendingPathComponent("direct"), alias.appendingPathComponent("parent/aliased")] {
            let failure = await write(ArchiveFilePromise(payload: virtual, session: session), to: output)
            XCTAssertNil(failure)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: output.path)), ["base.txt", "added.txt", "nested"])
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("base.txt")), Data("A".utf8))
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("nested/base.txt")), Data("B".utf8))
            for path in ["added.txt", "nested/added.txt"] {
                XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(path)), Data("pending".utf8))
            }
            for folder in [output, output.appendingPathComponent("nested")] {
                var info = stat()
                XCTAssertEqual(lstat(folder.path, &info), 0)
                XCTAssertEqual(info.st_mode & 0o777, 0o777 & ~ExtractionPermissions.processMask, folder.path)
            }
            var info = stat()
            XCTAssertEqual(lstat(parent.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, 0o700, "Finalizing the promise must not change its existing parent")
        }
    }

    @MainActor func testClipboardPublishesSwappedAndStagedBytes() async throws {
        let pasteboard = NSPasteboard(name: .init("KaitoFinder-M4-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else { throw XCTSkip("Named pasteboard is unavailable") }
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        for (source, name) in [("a.txt", "temp.txt"), ("b.txt", "a.txt"), ("temp.txt", "b.txt")] {
            _ = try await document.rename(fixture.node(source), to: name, progress: Progress())
        }
        _ = try await document.append(urls: [fixture.file("added.txt", contents: "snapshot")], to: "", progress: Progress())
        let names = ["a.txt", "b.txt", "added.txt"]
        var items: [ArchiveEntryPayload] = []
        for name in names { items.append(try await payload(name, in: fixture)) }
        let urls = try await ArchiveCopyOut.copy(items, from: XCTUnwrap(document.session), to: pasteboard,
            progress: Progress(), temporaryDirectory: .init(root: directory(in: fixture)))
        XCTAssertEqual(urls.map(\.lastPathComponent), names)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, [Data("B".utf8), Data("A".utf8), Data("snapshot".utf8)])
        XCTAssertEqual(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .fileURL) }, urls.map(\.absoluteString))
    }

    @MainActor func testActiveStagedPromiseSurvivesRevertSaveAndCloseThenReleasesStaging() async throws {
        for operation in ["revert", "save", "close"] {
            let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
            defer { gate.release(); document.close() }
            let source = try fixture.file("large.bin")
            let expected = Data(repeating: 0x5a, count: 512 * 1024)
            try expected.write(to: source)
            _ = try await document.append(urls: [source], to: "", progress: Progress())
            let session = try XCTUnwrap(document.session), item = try await payload("large.bin", in: fixture)
            let stage = try XCTUnwrap(document.pendingEditor?.staging?.directory)
            let destination = try directory(in: fixture).appendingPathComponent("copy.bin")
            let promise = ArchiveFilePromise(payload: item, session: session, didWrite: { _ in gate.pauseOnce() })
            let writing = Task { await self.write(promise, to: destination) }
            try await scenarioWait { gate.isEntered }
            var cleaned = false
            let cleanup = Task {
                switch operation {
                case "revert":
                    try document.revert(toContentsOf: fixture.archive, ofType: "public.data")
                    try await XCTUnwrap(document.deferredSaveTask).value
                case "save": try await fixture.save()
                default: document.close(); await document.stagingCleanup?.value
                }
                cleaned = true
            }
            try await scenarioWait { document.pendingEditor?.staging == nil }
            XCTAssertFalse(cleaned)
            if operation != "close" { XCTAssertTrue(document.isDeferredSaveRunning) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: stage.path))
            gate.release()
            let failure = await writing.value
            XCTAssertNil(failure)
            try await cleanup.value
            XCTAssertTrue(cleaned)
            XCTAssertEqual(try Data(contentsOf: destination), expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        }
    }

    @MainActor func testInArchiveCopyStagesRenamedAndPendingPromiseContentsBeforeInputRemoval() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let session = try XCTUnwrap(document.session)
        _ = try await document.rename(fixture.node("a.txt"), to: "renamed.txt", progress: Progress())
        _ = try await document.append(urls: [fixture.file("pending.txt", contents: "snapshot")], to: "", progress: Progress())
        for (name, contents) in [("renamed.txt", "A"), ("pending.txt", "snapshot")] {
            let item = try await payload(name, in: fixture), received = try directory(in: fixture).appendingPathComponent(name)
            let failure = await write(ArchiveFilePromise(payload: item, session: session), to: received)
            XCTAssertNil(failure)
            _ = try await document.append(urls: [received], to: "folder", progress: Progress())
            try FileManager.default.removeItem(at: received.deletingLastPathComponent())
            let copy = try await payload("folder/" + name, in: fixture)
            XCTAssertNotEqual(copy.origin, item.origin)
            let worker = EntryMaterializer(session: session, temporaryDirectory: .init(root: try directory(in: fixture)))
            let url = try await worker.materialize(copy, progress: Progress())
            XCTAssertEqual(try Data(contentsOf: url), Data(contents.utf8))
            await worker.close()
        }
    }

    @MainActor func testCompareContentsUsesRenamedBaseOriginAndStagedSourceLease() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let session = try XCTUnwrap(document.session)
        _ = try await document.rename(fixture.node("b.txt"), to: "renamed.txt", progress: Progress())
        let source = try fixture.file("renamed.txt", contents: "incoming")
        let worker = EntryMaterializer(session: session, temporaryDirectory: .init(root: try directory(in: fixture)))
        var compared = false
        _ = try await document.append(urls: [source], to: "", progress: Progress(), resolveConflict: { conflict in
            guard case .archive(let payload) = conflict.existing.source else {
                XCTFail("Renamed base comparison must carry origin"); return .init(choice: .skip)
            }
            let url = try await worker.materialize(payload, progress: Progress())
            XCTAssertEqual(try Data(contentsOf: url), Data("B".utf8))
            compared = true
            return .init(choice: .replace)
        })
        XCTAssertTrue(compared)
        compared = false
        _ = try await document.append(urls: [source], to: "", progress: Progress(), resolveConflict: { conflict in
            guard case .file(let url) = conflict.existing.source else {
                XCTFail("Pending comparison must use staging"); return .init(choice: .skip)
            }
            XCTAssertEqual(url.lastPathComponent, "renamed.txt", "Quick Look requires the original extension")
            XCTAssertNotNil(conflict.existing.stagingLease)
            XCTAssertEqual(try Data(contentsOf: url), Data("incoming".utf8))
            compared = true
            return .init(choice: .skip)
        })
        XCTAssertTrue(compared)
        await worker.close()
    }

    @MainActor func testStagedDirectorySymlinkPermissionsQuarantineAndCollisionRules() async throws {
        let archiveMark = Data("0081;12345678;archive;".utf8), stagedMark = Data("0081;12345678;staged;".utf8)
        let fixture = try DeferredSaveFixture(quarantine: archiveMark), document = fixture.document
        defer { document.close() }
        let source = try directory(in: fixture, named: "source"), file = source.appendingPathComponent("file")
        XCTAssertEqual(chmod(source.path, 0o751), 0)
        try Data("staged".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, 0o751), 0)
        try ExtractionQuarantine.apply(stagedMark, to: file)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "file")
        _ = try await document.append(urls: [source], to: "", progress: Progress())
        let stagedDirectory = try XCTUnwrap(document.pendingChanges.additions.first { $0.sourceStamp.kind == .directory })
        XCTAssertEqual(stagedDirectory.sourceStamp.permissions, 0o751)
        XCTAssertEqual(chmod(source.path, 0o755), 0, "Later source mode changes must not affect the staged snapshot")
        _ = try await document.rename(fixture.node("source"), to: "renamed", progress: Progress())
        let session = try XCTUnwrap(document.session), base = try await payload("a.txt", in: fixture)
        let folder = try await payload("renamed", in: fixture), output = try directory(in: fixture)
        try ArchiveCopyOut.check(await ExtractionService.extract([base, folder], from: session, to: output, progress: Progress()))
        let extracted = output.appendingPathComponent("renamed/file")
        XCTAssertEqual(try ExtractionQuarantine.read(from: output.appendingPathComponent("a.txt")), archiveMark)
        XCTAssertEqual(try ExtractionQuarantine.read(from: extracted), archiveMark)
        var info = stat()
        XCTAssertEqual(lstat(extracted.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o751 & ~ExtractionPermissions.processMask)
        let promisedDirectory = output.appendingPathComponent("promised-directory")
        let failure = await write(ArchiveFilePromise(payload: folder, session: session), to: promisedDirectory)
        XCTAssertNil(failure)
        for directory in [output.appendingPathComponent("renamed"), promisedDirectory] {
            XCTAssertEqual(lstat(directory.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, mode_t(0o755) & ~ExtractionPermissions.processMask,
                           directory.path)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: output.appendingPathComponent("renamed/link").path), "file")
        let added = try await payload("renamed/file", in: fixture)
        let collision = try await ExtractionService.extract([added], from: session, to: output, progress: Progress())
        XCTAssertEqual(collision.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: extracted), Data("staged".utf8))
    }
}
