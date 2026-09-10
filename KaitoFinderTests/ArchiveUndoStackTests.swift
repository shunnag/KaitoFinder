import AppKit
import CryptoKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveUndoStackTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let archive: URL
        let inputs: URL

        init(payloadBytes: Int = 4096) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("KaitoFinder-UndoTests-" + UUID().uuidString)
            archive = root.appendingPathComponent("user/Archive.zip")
            inputs = root.appendingPathComponent("inputs")
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
            let payload = try file("payload.bin", byteCount: payloadBytes)
            let writer = try ArchiveWriter.create(url: archive, options: WriterOptions(compressionMethod: .stored))
            try writer.add(contentsOf: payload, as: "old.txt")
            try writer.add(data: Data("nested original".utf8), as: "sub/old.txt")
            try writer.finish()
            let handle = try FileHandle(forWritingTo: archive)
            try handle.synchronize()
            try handle.close()
        }

        func file(_ name: String, byteCount: Int = 128) throws -> URL {
            let url = inputs.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            // stored の大容量 fixture は実際に全 byte を書く。疎ファイルでは clone の測定にならない。
            var seed: UInt64 = 0x12345678
            let chunk = Data((0..<min(byteCount, 1024 * 1024)).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return UInt8(truncatingIfNeeded: seed >> 32)
            })
            var remaining = byteCount
            while remaining > 0 {
                let count = min(remaining, chunk.count)
                try handle.write(contentsOf: chunk.prefix(count))
                remaining -= count
            }
            return url
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private final class Gate: Sendable {
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        func wait() {
            XCTAssertFalse(Thread.isMainThread)
            entered.withLock { $0 = true }
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
    }

    private func digest(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return Data(digest.finalize())
    }

    private func attributes(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
        return info
    }

    private func mode(_ url: URL) throws -> mode_t { try attributes(url).st_mode & 0o7777 }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @MainActor private func document(_ fixture: Fixture, stack: ArchiveUndoStack = ArchiveUndoStack()) throws -> ArchiveDocument {
        let document = ArchiveDocument(undoStack: stack)
        try document.read(from: fixture.archive, ofType: "zip")
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
        }
        return document
    }

    @MainActor private func append(_ name: String, fixture: Fixture, document: ArchiveDocument,
                                  byteCount: Int = 128) async throws {
        let result = try await document.append(urls: [fixture.file(name, byteCount: byteCount)], to: "", progress: Progress())
        XCTAssertEqual(result.addedPaths, [name])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(result.reloadFailure)
    }

    @MainActor private func undo(_ document: ArchiveDocument) async throws {
        let manager = try XCTUnwrap(document.undoManager)
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
    }

    @MainActor private func redo(_ document: ArchiveDocument) async throws {
        let manager = try XCTUnwrap(document.undoManager)
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
    }

    @MainActor private func waitForGate(_ gate: Gate) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !gate.entered.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(gate.entered.withLock { $0 })
    }

    @MainActor func testAppendUndoRestoresFullArchiveSHA256() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        let before = try digest(fixture.archive)
        try await append("added.txt", fixture: fixture, document: document)
        XCTAssertNotEqual(try digest(fixture.archive), before)
        let slot = try XCTUnwrap(document.archiveUndoStack.slots.first)
        XCTAssertEqual(try digest(slot.url), before)
        try await undo(document)
        XCTAssertEqual(try digest(fixture.archive), before)
        XCTAssertFalse(exists(slot.directory))
    }

    @MainActor func testRedoRestoresFullPostAppendSHA256() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        try await append("added.txt", fixture: fixture, document: document)
        let after = try digest(fixture.archive)
        try await undo(document)
        XCTAssertNotEqual(try digest(fixture.archive), after)
        let slot = try XCTUnwrap(document.archiveUndoStack.slots.first)
        XCTAssertTrue(slot.isRedo)
        XCTAssertEqual(try digest(slot.url), after)
        try await redo(document)
        XCTAssertEqual(try digest(fixture.archive), after)
        XCTAssertFalse(exists(slot.directory))
    }

    @MainActor func testUndoRedoReopensReaderAndAdvancesGeneration() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        let session = try XCTUnwrap(document.session)
        let originalNames = Set(["old.txt", "sub/old.txt"])
        XCTAssertEqual(session.generation, 0)
        try await append("added.txt", fixture: fixture, document: document)
        XCTAssertEqual(session.generation, 1)
        for (generation, names) in [(UInt64(2), originalNames), (UInt64(3), originalNames.union(["added.txt"]))] {
            if generation == 2 { try await undo(document) } else { try await redo(document) }
            let snapshot = await session.snapshot()
            XCTAssertEqual(snapshot.generation, generation)
            XCTAssertEqual(document.generation, generation)
            XCTAssertEqual(Set(snapshot.entries.map(\.name)), names)
            let reader = try await session.extractionReader()
            XCTAssertEqual(Set(reader.entries.map(\.name)), names)
            XCTAssertEqual(Set(try ArchiveReader.open(url: fixture.archive).entries.map(\.name)), names)
        }
    }

    @MainActor private func assertModeRoundTrip(_ permissions: mode_t) async throws {
        let fixture = try Fixture(), document = try document(fixture)
        XCTAssertEqual(chmod(fixture.archive.path, permissions), 0)
        try await append("added.txt", fixture: fixture, document: document)
        let slot = try XCTUnwrap(document.archiveUndoStack.slots.first)
        XCTAssertEqual(try mode(slot.url), 0o600)
        XCTAssertEqual(try mode(slot.directory), 0o700)
        XCTAssertEqual(try mode(fixture.archive), permissions)
        try await undo(document)
        XCTAssertEqual(try mode(fixture.archive), permissions)
        try await redo(document)
        XCTAssertEqual(try mode(fixture.archive), permissions)
    }

    @MainActor func testMode0644SurvivesRestrictedUndoSlot() async throws { try await assertModeRoundTrip(0o644) }
    @MainActor func testMode0600SurvivesUndoAndRedo() async throws { try await assertModeRoundTrip(0o600) }

    @MainActor func testSwapPreservesModeReadImmediatelyBeforeReplacement() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        XCTAssertEqual(chmod(fixture.archive.path, 0o644), 0)
        try await append("added.txt", fixture: fixture, document: document)
        XCTAssertEqual(chmod(fixture.archive.path, 0o600), 0)
        try await undo(document)
        XCTAssertEqual(try mode(fixture.archive), 0o600)
        XCTAssertEqual(chmod(fixture.archive.path, 0o644), 0)
        try await redo(document)
        XCTAssertEqual(try mode(fixture.archive), 0o644)
    }

    @MainActor func testQuarantineBytesSurviveUndoAndRedo() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        let quarantine = Data("0081;12345678;KaitoFinderUndoTests;original".utf8)
        try ExtractionQuarantine.apply(quarantine, to: fixture.archive)
        try await append("added.txt", fixture: fixture, document: document)
        try await undo(document)
        XCTAssertEqual(try ExtractionQuarantine.read(from: fixture.archive), quarantine)
        let session = try XCTUnwrap(document.session)
        let afterUndo = await session.quarantine
        XCTAssertEqual(afterUndo, quarantine)
        let current = Data("0081;12345679;KaitoFinderUndoTests;current".utf8)
        try ExtractionQuarantine.apply(current, to: fixture.archive)
        try await redo(document)
        XCTAssertEqual(try ExtractionQuarantine.read(from: fixture.archive), current)
        let afterRedo = await session.quarantine
        XCTAssertEqual(afterRedo, current)
    }

    @MainActor func testTwelveAppendsKeepTenSlotsAndDeleteOldestFiles() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        var slots: [ArchiveUndoStack.Slot] = []
        var afterTwo = Data()
        for index in 0..<12 {
            try await append("added\(index).txt", fixture: fixture, document: document)
            slots.append(try XCTUnwrap(document.archiveUndoStack.slots.last))
            if index == 1 { afterTwo = try digest(fixture.archive) }
        }
        XCTAssertEqual(document.archiveUndoStack.slots.count, 10)
        for slot in slots.prefix(2) {
            XCTAssertFalse(exists(slot.url))
            XCTAssertFalse(exists(slot.directory))
        }
        for slot in slots.suffix(10) { XCTAssertTrue(exists(slot.url)) }
        for _ in 0..<10 { try await undo(document) }
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertEqual(try digest(fixture.archive), afterTwo)
        for _ in 0..<10 { try await redo(document) }
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
        XCTAssertEqual(document.archiveUndoStack.slots.count, 10)
    }

    @MainActor func testByteBoundDeletesOldestSlotsUntilTotalFits() async throws {
        let fixture = try Fixture()
        let budget = UInt64(try attributes(fixture.archive).st_size) * 3 + 24 * 1024
        let stack = ArchiveUndoStack(maximumBytes: budget)
        let document = try document(fixture, stack: stack)
        var older: [ArchiveUndoStack.Slot] = []
        for index in 0..<3 {
            try await append("small\(index).txt", fixture: fixture, document: document)
            older.append(try XCTUnwrap(stack.slots.last))
        }
        try await append("large.png", fixture: fixture, document: document, byteCount: 24 * 1024)
        older.append(try XCTUnwrap(stack.slots.last))
        // 退避 byte は編集前のサイズ。次の追加で大きくなった原本が履歴に入る。
        try await append("last.txt", fixture: fixture, document: document)
        XCTAssertLessThanOrEqual(stack.retainedBytes, budget)
        XCTAssertEqual(stack.retainedBytes, try stack.slots.reduce(0) { try $0 + UInt64(attributes($1.url).st_size) })
        XCTAssertGreaterThan(stack.slots.count, 0)
        XCTAssertLessThan(stack.slots.count, 5)
        let retained = Set(stack.slots.map(\.id))
        XCTAssertFalse(retained.contains(older[0].id))
        for slot in older where !retained.contains(slot.id) {
            XCTAssertFalse(exists(slot.url))
            XCTAssertFalse(exists(slot.directory))
        }
        XCTAssertTrue(exists(try XCTUnwrap(stack.slots.last).url))
    }

    @MainActor func testCloseDeletesUndoAndRedoSlotDirectories() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        for index in 0..<3 { try await append("added\(index).txt", fixture: fixture, document: document) }
        try await undo(document)
        let slots = document.archiveUndoStack.slots
        XCTAssertTrue(slots.contains(where: \.isRedo))
        XCTAssertTrue(slots.contains { !$0.isRedo })
        document.close()
        await document.undoCleanup?.value
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertEqual(document.archiveUndoStack.retainedBytes, 0)
        for slot in slots { XCTAssertFalse(exists(slot.directory)) }
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
    }

    func testCloneOf256MiBArchiveSharesDiskExtents() async throws {
        let fixture = try Fixture(payloadBytes: 256 * 1024 * 1024)
        let info = try attributes(fixture.archive)
        XCTAssertGreaterThanOrEqual(info.st_size, 256 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(info.st_blocks * 512, 256 * 1024 * 1024)
        func available() throws -> Int64 {
            let url = URL(fileURLWithPath: fixture.archive.path)
            return try XCTUnwrap(url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage)
        }
        let stack = ArchiveUndoStack()
        let before = try available()
        let slot = try XCTUnwrap(stack.capture(fixture.archive))
        defer { stack.discard(slot) }
        let after = try available()
        XCTAssertLessThan(before - after, 16 * 1024 * 1024)
        XCTAssertEqual(try attributes(slot.url).st_dev, info.st_dev)
        XCTAssertEqual(try digest(slot.url), try digest(fixture.archive))
        print("UNDO CLONE: archive=\(info.st_size) bytes, available capacity decrease=\(before - after) bytes")
    }

    @MainActor func testFailureAfterCloneDiscardsSlotAndRegistersNoUndo() async throws {
        let fixture = try Fixture()
        let directories = Mutex<[URL]>([])
        let stack = ArchiveUndoStack { source, destination in
            XCTAssertFalse(Thread.isMainThread)
            directories.withLock { $0.append(destination.deletingLastPathComponent()) }
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let document = try document(fixture, stack: stack)
        let before = try digest(fixture.archive)
        let archive = fixture.archive
        let previousMode = try mode(archive)
        do {
            _ = try await document.append(urls: [fixture.file("added.txt")], to: "", progress: Progress(), willPublish: {
                // identity の検査を実際に失敗させる。原本の byte は変更しない。
                guard chmod(archive.path, previousMode == 0o600 ? 0o644 : 0o600) == 0 else {
                    throw ExtractionFailure.system(errno)
                }
            })
            XCTFail("原本が変わった追加は公開できない")
        } catch { }
        XCTAssertEqual(try digest(fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertEqual(directories.withLock { $0.count }, 1)
        for directory in directories.withLock({ $0 }) { XCTAssertFalse(exists(directory)) }
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
    }

    @MainActor func testCancellationAfterCloneDiscardsSlotWithoutUndo() async throws {
        let fixture = try Fixture(), directories = Mutex<[URL]>([])
        let stack = ArchiveUndoStack { source, destination in
            directories.withLock { $0.append(destination.deletingLastPathComponent()) }
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let document = try document(fixture, stack: stack), progress = Progress()
        let before = try digest(fixture.archive)
        do {
            _ = try await document.append(urls: [fixture.file("added.txt")], to: "", progress: progress,
                                          willPublish: { progress.cancel() })
            XCTFail("取消し後に公開できない")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try digest(fixture.archive), before)
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertEqual(directories.withLock { $0.count }, 1)
        for directory in directories.withLock({ $0 }) { XCTAssertFalse(exists(directory)) }
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testUnsupportedCloneAllowsAppendAndClearsStaleHistory() async throws {
        for unsupported in [ENOTSUP, EXDEV] {
            let fixture = try Fixture(), failure = Mutex<Int32>(0), directories = Mutex<[URL]>([])
            let stack = ArchiveUndoStack { source, destination in
                directories.withLock { $0.append(destination.deletingLastPathComponent()) }
                let code = failure.withLock { $0 }
                return code == 0 ? ArchiveUndoStack.cloneFile(from: source, to: destination) : code
            }
            let document = try document(fixture, stack: stack)
            try await append("first.txt", fixture: fixture, document: document)
            XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
            let before = try digest(fixture.archive)
            failure.withLock { $0 = unsupported }
            try await append("second.txt", fixture: fixture, document: document)
            XCTAssertNotEqual(try digest(fixture.archive), before)
            XCTAssertEqual(document.generation, 2)
            XCTAssertEqual(Set(try ArchiveReader.open(url: fixture.archive).entries.map(\.name)),
                           ["old.txt", "sub/old.txt", "first.txt", "second.txt"])
            XCTAssertFalse(document.canUndoNextMutation)
            XCTAssertTrue(stack.slots.isEmpty)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
            for directory in directories.withLock({ $0 }) { XCTAssertFalse(exists(directory)) }
        }
    }

    @MainActor func testUnexpectedCloneFailureAbortsAppendWithoutUndo() async throws {
        let fixture = try Fixture(), directories = Mutex<[URL]>([])
        let stack = ArchiveUndoStack { _, destination in
            directories.withLock { $0.append(destination.deletingLastPathComponent()) }
            return EIO
        }
        let document = try document(fixture, stack: stack)
        let before = try digest(fixture.archive)
        do {
            _ = try await document.append(urls: [fixture.file("added.txt")], to: "", progress: Progress())
            XCTFail("予期しない clone 障害を無視しない")
        } catch { }
        XCTAssertEqual(try digest(fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertEqual(directories.withLock { $0.count }, 1)
        for directory in directories.withLock({ $0 }) { XCTAssertFalse(exists(directory)) }
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testUndoRegistrationUndoAndRedoNeverDirtyDocument() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        let manager = try XCTUnwrap(document.undoManager)
        XCTAssertTrue(document.hasUndoManager)
        XCTAssertTrue(document.writableTypes(for: .saveOperation).isEmpty)
        XCTAssertFalse(document.isDocumentEdited)
        try await append("added.txt", fixture: fixture, document: document)
        XCTAssertTrue(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        XCTAssertFalse(document.isDocumentEdited)
        try await undo(document)
        XCTAssertFalse(manager.canUndo)
        XCTAssertTrue(manager.canRedo)
        XCTAssertFalse(document.isDocumentEdited)
        try await redo(document)
        XCTAssertTrue(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        XCTAssertFalse(document.isDocumentEdited)
    }

    @MainActor func testSlotsStayOutsideArchiveParentDirectory() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        let parent = fixture.archive.deletingLastPathComponent()
        try Data("neighbor".utf8).write(to: parent.appendingPathComponent("neighbor.txt"))
        let before = try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted()
        try await append("added.txt", fixture: fixture, document: document)
        for slot in document.archiveUndoStack.slots {
            XCTAssertFalse(slot.directory.standardizedFileURL.path.hasPrefix(parent.standardizedFileURL.path + "/"))
            XCTAssertEqual(try attributes(slot.url).st_dev, try attributes(fixture.archive).st_dev)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted(), before)
        try await undo(document)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted(), before)
        try await redo(document)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).sorted(), before)
    }

    @MainActor private func materialize(_ document: ArchiveDocument) async throws
        -> (ArchiveMaterializationController, ArchiveEntryPayload, URL) {
        let session = try XCTUnwrap(document.session)
        let snapshot = await session.snapshot()
        let entry = try XCTUnwrap(snapshot.entries.first { $0.name == "old.txt" })
        let payload = ArchiveEntryPayload(archiveURL: session.sourceURL, generation: snapshot.generation,
            entryIndex: entry.index, path: entry.name, isDirectory: false)
        let controller = try XCTUnwrap(document.materializationController())
        let item = ArchivePreviewItem(payload: payload,
            capability: EntryReadCapability(entry: entry, isDirectory: false, format: session.format), requiresProgress: false)
        controller.setSelection([item])
        controller.display(index: 0) { _ in }
        await controller.task?.value
        return (controller, payload, try XCTUnwrap(item.previewItemURL))
    }

    @MainActor func testUndoAndRedoDisposeMaterializationCachesAndFiles() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        try await append("added.txt", fixture: fixture, document: document)
        let (afterAppend, appendPayload, appendURL) = try await materialize(document)
        XCTAssertTrue(exists(appendURL))
        try await undo(document)
        await document.materializationCleanup?.value
        XCTAssertNil(afterAppend.cachedItem(for: appendPayload))
        XCTAssertFalse(exists(appendURL))
        let (afterUndo, undoPayload, undoURL) = try await materialize(document)
        XCTAssertFalse(afterAppend === afterUndo)
        XCTAssertTrue(exists(undoURL))
        try await redo(document)
        await document.materializationCleanup?.value
        XCTAssertNil(afterUndo.cachedItem(for: undoPayload))
        XCTAssertFalse(exists(undoURL))
        XCTAssertFalse(afterUndo === document.materializationController())
    }

    @MainActor func testAppendAfterUndoDeletesRedoSlotAndPreservesUndoOrder() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        let original = try digest(fixture.archive)
        try await append("first.txt", fixture: fixture, document: document)
        let first = try digest(fixture.archive)
        try await append("second.txt", fixture: fixture, document: document)
        try await undo(document)
        let redoSlot = try XCTUnwrap(document.archiveUndoStack.slots.first(where: \.isRedo))
        try await append("third.txt", fixture: fixture, document: document)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
        XCTAssertFalse(exists(redoSlot.directory))
        try await undo(document)
        XCTAssertEqual(try digest(fixture.archive), first)
        try await undo(document)
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testFailedUndoLeavesBytesAndUndoRegistrationAvailableForRetry() async throws {
        let fixture = try Fixture(), failure = Mutex<Int32>(0)
        let stack = ArchiveUndoStack { source, destination in
            let code = failure.withLock { $0 }
            return code == 0 ? ArchiveUndoStack.cloneFile(from: source, to: destination) : code
        }
        let document = try document(fixture, stack: stack)
        let original = try digest(fixture.archive)
        try await append("added.txt", fixture: fixture, document: document)
        let added = try digest(fixture.archive)
        failure.withLock { $0 = EIO }
        let manager = try XCTUnwrap(document.undoManager)
        manager.undo()
        await document.undoTask?.value
        XCTAssertNotNil(document.undoFailure)
        XCTAssertEqual(try digest(fixture.archive), added)
        XCTAssertEqual(document.generation, 1)
        XCTAssertTrue(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        XCTAssertFalse(document.isDocumentEdited)
        failure.withLock { $0 = 0 }
        try await undo(document)
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertTrue(manager.canRedo)
    }

    @MainActor func testCloseWaitsForPendingPublicationBeforeDeletingItsSlot() async throws {
        let fixture = try Fixture(), directories = Mutex<[URL]>([]), gate = Gate()
        let stack = ArchiveUndoStack { source, destination in
            directories.withLock { $0.append(destination.deletingLastPathComponent()) }
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let document = try document(fixture, stack: stack)
        let original = try digest(fixture.archive), added = try fixture.file("added.txt")
        let task = Task {
            try await document.append(urls: [added], to: "", progress: Progress(), willPublish: { gate.wait() })
        }
        try await waitForGate(gate)
        document.close()
        XCTAssertTrue(exists(try XCTUnwrap(directories.withLock { $0.first })))
        gate.release.signal()
        do { _ = try await task.value; XCTFail("閉じた文書の未公開の追加を取り消す") }
        catch { XCTAssertTrue(error is CancellationError) }
        await document.undoCleanup?.value
        XCTAssertEqual(try digest(fixture.archive), original)
        for directory in directories.withLock({ $0 }) { XCTAssertFalse(exists(directory)) }
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testPendingUndoRejectsRepeatedUndoRedoAndAppend() async throws {
        let fixture = try Fixture(), gate = Gate(), calls = Mutex(0)
        let stack = ArchiveUndoStack { source, destination in
            let index = calls.withLock { $0 += 1; return $0 }
            if index == 2 { gate.wait() }
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let document = try document(fixture, stack: stack)
        let original = try digest(fixture.archive)
        try await append("first.txt", fixture: fixture, document: document)
        let manager = try XCTUnwrap(document.undoManager)
        manager.undo()
        try await waitForGate(gate)
        XCTAssertFalse(manager.canUndo)
        XCTAssertFalse(manager.canRedo)
        manager.undo()
        manager.redo()
        do {
            _ = try await document.append(urls: [fixture.file("second.txt")], to: "", progress: Progress())
            XCTFail("復元中に別の変更を始めない")
        } catch { }
        gate.release.signal()
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(document.generation, 2)
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertTrue(manager.canRedo)
        try await redo(document)
        XCTAssertEqual(document.generation, 3)
    }

    @MainActor func testClosingOneDocumentPreservesAnotherDocumentsSlots() async throws {
        let firstFixture = try Fixture(), secondFixture = try Fixture()
        let first = try document(firstFixture), second = try document(secondFixture)
        try await append("added.txt", fixture: firstFixture, document: first)
        try await append("added.txt", fixture: secondFixture, document: second)
        let firstSlot = try XCTUnwrap(first.archiveUndoStack.slots.first)
        let secondSlot = try XCTUnwrap(second.archiveUndoStack.slots.first)
        first.close()
        await first.undoCleanup?.value
        XCTAssertFalse(exists(firstSlot.directory))
        XCTAssertTrue(exists(secondSlot.url))
        try await undo(second)
        XCTAssertFalse(exists(secondSlot.directory))
    }

    @MainActor func testSlotLargerThanByteLimitIsDeletedWithoutUndoRegistration() async throws {
        let fixture = try Fixture(), directories = Mutex<[URL]>([])
        let stack = ArchiveUndoStack(maximumBytes: 1) { source, destination in
            directories.withLock { $0.append(destination.deletingLastPathComponent()) }
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let document = try document(fixture, stack: stack)
        let original = try digest(fixture.archive)
        try await append("added.txt", fixture: fixture, document: document)
        XCTAssertNotEqual(try digest(fixture.archive), original)
        XCTAssertEqual(stack.retainedBytes, 0)
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertEqual(directories.withLock { $0.count }, 1)
        for directory in directories.withLock({ $0 }) { XCTAssertFalse(exists(directory)) }
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertFalse(document.isDocumentEdited)
    }

    @MainActor func testEditMenuShortcutsUseDocumentUndoManager() async throws {
        let fixture = try Fixture(), document = try document(fixture)
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        XCTAssertTrue(window.undoManager === document.undoManager)
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        let undoItem = try XCTUnwrap(items.first { $0.action == #selector(ArchiveDocument.undo(_:)) })
        let redoItem = try XCTUnwrap(items.first { $0.action == #selector(ArchiveDocument.redo(_:)) })
        XCTAssertEqual(undoItem.keyEquivalent, "z")
        XCTAssertEqual(redoItem.keyEquivalent, "Z")
        XCTAssertTrue(undoItem.keyEquivalentModifierMask.contains(.command))
        XCTAssertTrue(redoItem.keyEquivalentModifierMask.contains(.command))
        let original = try digest(fixture.archive)
        try await append("added.txt", fixture: fixture, document: document)
        let added = try digest(fixture.archive)
        XCTAssertTrue(document.validateUserInterfaceItem(undoItem))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(undoItem.action), to: document, from: undoItem))
        await document.undoTask?.value
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertTrue(document.validateUserInterfaceItem(redoItem))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(redoItem.action), to: document, from: redoItem))
        await document.undoTask?.value
        XCTAssertEqual(try digest(fixture.archive), added)
    }
}
