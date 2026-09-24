import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSaveCorrectionTests: XCTestCase {
    // P1・P1b・P2。file だけでなく明示 directory と重複・循環退避名も検査する。
    @MainActor func testMoveBackToOriginalPathUnderRenamedFolderInEveryFormat() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tarGzip, .lha] {
            for sequence in ["P1", "P1b", "P2"] {
                let fixture = try DeferredSaveFixture(format: format, secondFolder: sequence == "P2")
                let document = fixture.document
                defer { document.close() }
                var expected: [String: EntryKind] = ["a.txt": .file, "b.txt": .file, "folder/": .directory,
                                                      "folder/child.txt": .file]
                if sequence == "P2" {
                    for (source, target) in [("folder", "tmp"), ("other", "folder"), ("tmp", "other")] {
                        _ = try await document.rename(fixture.node(source), to: target, progress: Progress())
                    }
                    _ = try await document.move([fixture.node("other/child.txt")], to: "folder", progress: Progress())
                    expected["other/"] = .directory
                    expected["folder/sibling.txt"] = .file
                } else {
                    _ = try await document.rename(fixture.node("folder"), to: "renamed", progress: Progress())
                    expected["renamed/"] = .directory
                    if sequence == "P1b" {
                        _ = try await document.move([fixture.node("renamed/child.txt")], to: "", progress: Progress())
                        _ = try await document.append(urls: [fixture.file("child.txt", contents: "replacement")],
                                                      to: "renamed", progress: Progress())
                        expected["renamed/child.txt"] = .file
                    }
                    _ = try await document.createFolder(in: "", baseName: "folder", progress: Progress())
                    _ = try await document.move([fixture.node(sequence == "P1b" ? "child.txt" : "renamed/child.txt")],
                                                to: "folder", progress: Progress())
                }
                let projected = try await document.projectedEntries()
                XCTAssertEqual(projected.map(\.name).sorted(), expected.keys.sorted(), "\(format) \(sequence)")
                XCTAssertEqual(Set(projected.map(\.name)).count, projected.count)
                XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
                try await fixture.save()
                XCTAssertEqual(try DeferredSaveFixture.inventory(fixture.archive), expected, "\(format) \(sequence)")
                let saved = try DeferredSaveFixture.contents(fixture.archive)
                XCTAssertEqual(saved["folder/child.txt"], Data("child".utf8))
                if sequence == "P1b" { XCTAssertEqual(saved["renamed/child.txt"], Data("replacement".utf8)) }
                if sequence == "P2" { XCTAssertEqual(saved["folder/sibling.txt"], Data("sibling".utf8)) }
            }
        }
    }

    @MainActor func testDiscardAndReloadWaitsForReadLeaseAndPreservesLateEditAndChangeCount() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.append(urls: [fixture.file("staged")], to: "", progress: Progress())
        let staging = try XCTUnwrap(document.pendingEditor?.staging)
        var read: StagingRegistry.ReadLease? = try staging.acquireRead()
        defer { read = nil }
        // 同じ内容でも inode が変われば読み直す。alert の discard と同じ入口を使う。
        try fixture.original.write(to: fixture.archive, options: .atomic)
        let reverting = Task { try await document.revertPending() }
        try await scenarioWait { document.pendingEditor?.staging == nil }
        XCTAssertTrue(document.isDeferredSaveRunning)
        XCTAssertFalse(document.undoManager!.canUndo)
        let late = Task { try await document.createFolder(in: "", baseName: "late", progress: Progress()) }
        await Task.yield()
        document.updateChangeCount(.changeDone)
        withExtendedLifetime(read) {}
        read = nil
        try await reverting.value
        _ = try await late.value
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertEqual(document.pendingChanges.createdFolders.map(\.path), ["late/"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
        try await fixture.save()
        XCTAssertTrue(try DeferredSaveFixture.inventory(fixture.archive).keys.contains("late/"))
    }

    @MainActor func testPermissionOnlyChangeAllowsSaveAndSaveAs() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tarGzip, .lha] {
            for saveAs in [false, true] {
                let fixture = try DeferredSaveFixture(format: format), document = fixture.document
                defer { document.close() }
                _ = try await document.createFolder(in: "", baseName: "pending", progress: Progress())
                var info = stat()
                XCTAssertEqual(lstat(fixture.archive.path, &info), 0)
                let changedMode = (info.st_mode & 0o7777) ^ 0o100
                XCTAssertEqual(chmod(fixture.archive.path, changedMode), 0)
                var destination = fixture.archive
                if saveAs {
                    destination = fixture.directory.url.appendingPathComponent("saved.zip")
                    let output = destination, creator = ArchiveCreationController(store: fixture.store)
                    creator.destinationHandler = { _, _ in output }
                    try await document.savePendingAs(using: creator, on: nil, progress: Progress())
                    XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
                } else {
                    try await fixture.save()
                    XCTAssertEqual(lstat(fixture.archive.path, &info), 0)
                    XCTAssertEqual(info.st_mode & 0o7777, changedMode)
                }
                XCTAssertTrue(try DeferredSaveFixture.inventory(destination).keys.contains("pending/"))
                XCTAssertFalse(document.isDocumentEdited)
            }
        }
    }

    @MainActor func testFinderMoveFollowsPresentedURLForSaveAndSaveAs() async throws {
        for saveAs in [false, true] {
            let fixture = try DeferredSaveFixture(), document = fixture.document
            defer { document.close() }
            let originalSession = try XCTUnwrap(document.session)
            _ = try await document.createFolder(in: "", baseName: "pending", progress: Progress())
            let parent = fixture.directory.url.appendingPathComponent("moved")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            let moved = parent.appendingPathComponent("renamed.zip")
            try FileManager.default.moveItem(at: fixture.archive, to: moved)
            document.presentedItemDidMove(to: moved)
            // NSDocument は file access の直列化を経て main queue で URL を更新する。
            try await scenarioWait { document.fileURL == moved }
            XCTAssertEqual(document.fileURL, moved)
            let destination: URL
            if saveAs {
                destination = fixture.directory.url.appendingPathComponent("saved.zip")
                let output = destination, creator = ArchiveCreationController(store: fixture.store)
                creator.destinationHandler = { _, _ in
                    XCTAssertEqual(originalSession.sourceURL, moved)
                    try await originalSession.verifyDeferredIdentity()
                    return output
                }
                try await document.savePendingAs(using: creator, on: nil, progress: Progress())
                XCTAssertEqual(try Data(contentsOf: moved), fixture.original)
            } else {
                destination = moved
                try await fixture.save()
            }
            XCTAssertEqual(originalSession.sourceURL, moved)
            XCTAssertEqual(document.fileURL, destination)
            let savedSession = try XCTUnwrap(document.session)
            XCTAssertEqual(savedSession.sourceURL, destination)
            try await savedSession.verifyDeferredIdentity()
            XCTAssertTrue(try DeferredSaveFixture.inventory(destination).keys.contains("pending/"))
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.archive.path))
        }
    }

    @MainActor func testQuitCancelsDeferredSaveAsWhilePanelIsWaiting() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        let creator = ArchiveCreationController(store: fixture.store), progress = Progress()
        var waiting = false, finished = false
        creator.destinationHandler = { _, _ in
            waiting = true
            try await Task.sleep(for: .seconds(30))
            return nil
        }
        let saving = Task { try await document.savePendingAs(using: creator, on: nil, progress: progress) }
        defer { document.deferredSaveTask?.cancel(); saving.cancel(); document.close() }
        try await scenarioWait { waiting }
        let quitting = Task { await document.prepareForTermination(); finished = true }
        try await scenarioWait { progress.isCancelled }
        try await scenarioWait { finished }
        await quitting.value
        _ = await saving.result
        XCTAssertNil(creator.savePanel)
        XCTAssertFalse(document.isDeferredSaveRunning)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testQuitWaitsWithoutCancellingAfterDeferredPublishBoundary() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
        defer { gate.release(); document.close() }
        _ = try await document.createFolder(in: "", baseName: "saved", progress: Progress())
        let cancelled = Mutex(false)
        document.deferredWillReload = { gate.pauseOnce(); cancelled.withLock { $0 = Task.isCancelled } }
        let saving = Task { try await fixture.save() }
        try await scenarioWait { gate.isEntered }
        var finished = false
        let quitting = Task { await document.prepareForTermination(); finished = true }
        await Task.yield()
        XCTAssertFalse(finished)
        gate.release()
        try await saving.value
        await quitting.value
        XCTAssertFalse(cancelled.withLock { $0 })
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertTrue(try DeferredSaveFixture.inventory(fixture.archive).keys.contains("saved/"))
    }

    @MainActor func testQuitCancelsDeferredSaveAsWritingBeforePublish() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
        let progress = Progress(), creator = ArchiveCreationController(store: fixture.store)
        let destination = fixture.directory.url.appendingPathComponent("saved.zip")
        creator.destinationHandler = { _, _ in destination }
        document.deferredWillPublish = { gate.pauseOnce() }
        let saving = Task { try await document.savePendingAs(using: creator, on: nil, progress: progress) }
        defer { gate.release(); document.deferredSaveTask?.cancel(); document.close() }
        try await scenarioWait { gate.isEntered }
        let quitting = Task { await document.prepareForTermination() }
        try await scenarioWait { progress.isCancelled }
        gate.release()
        _ = await saving.result
        await quitting.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(document.fileURL, fixture.archive)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testLHARefusesUnrepresentableAdditionsAndRenamesBeforeReservation() async throws {
        let fixture = try DeferredSaveFixture(format: .lha), document = fixture.document
        defer { document.close() }
        _ = try await document.createFolder(in: "", baseName: "kept", progress: Progress())
        let previous = document.pendingChanges
        let link = fixture.directory.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "a.txt")
        let emoji = try fixture.file("😀.txt")
        for source in [link, emoji] {
            do { _ = try await document.append(urls: [source], to: "", progress: Progress()); XCTFail("Must refuse before reservation") }
            catch RewriterError.unrepresentable { }
            XCTAssertEqual(document.pendingChanges, previous)
            XCTAssertNil(document.pendingEditor?.staging)
        }
        do { _ = try await document.rename(fixture.node("a.txt"), to: "😀.txt", progress: Progress()); XCTFail("Unencodable rename") }
        catch RewriterError.unrepresentable { }
        XCTAssertEqual(document.pendingChanges, previous)
        try await fixture.save()
        XCTAssertTrue(try DeferredSaveFixture.inventory(fixture.archive).keys.contains("kept/"))
    }

    @MainActor func testFirstZIPReservationRunsCentralDirectoryGateAndRemembersRefusal() async throws {
        let source = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('a.txt', b'first-payload')
            z.writestr('b.txt', b'second-payload')
        """)
        var data = try Data(contentsOf: source.archive)
        let central = data.subdata(in: (data.count - 6)..<(data.count - 2)).withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        for offset in [18, 22, central + 20, central + 24] {
            withUnsafeBytes(of: UInt32(central).littleEndian) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        try data.write(to: source.archive)
        let defaults = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: defaults.defaults)
        store.preferences.saveBehavior = .onSave
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        defer { document.close() }
        try document.read(from: source.archive, ofType: "public.data")
        let session = try XCTUnwrap(document.session)
        XCTAssertTrue(session.capabilities.canEdit)
        do { _ = try await document.createFolder(in: "", progress: Progress()); XCTFail("Full ZIP gate is required") }
        catch UpdaterError.invalidArchive { }
        XCTAssertFalse(session.capabilities.canEdit)
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(try Data(contentsOf: source.archive), data)
    }

    @MainActor func testPublishedReloadFailureInvalidatesWithoutReportingExternalChange() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.createFolder(in: "", baseName: "saved", progress: Progress())
        document.deferredWillReload = { throw CocoaError(.fileReadUnknown) }
        try await fixture.save()
        let session = try XCTUnwrap(document.session)
        XCTAssertTrue(session.isInvalidated)
        XCTAssertFalse(session.capabilities.canEdit)
        XCTAssertEqual(document.deferredReloadFailure, ArchiveSession.reloadFailureMessage)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertTrue(try DeferredSaveFixture.inventory(fixture.archive).keys.contains("saved/"))
        do { try await session.verifyDeferredIdentity(); XCTFail("Invalidated session") }
        catch {
            XCTAssertEqual(ArchiveErrorText.describe(error), String(localized: "変更後のアーカイブを読み直せませんでした。"))
        }
        let creator = ArchiveCreationController(store: fixture.store)
        creator.destinationHandler = { _, _ in XCTFail("Invalid reader must be reported before the panel"); return nil }
        do { try await document.savePendingAs(using: creator, on: nil, progress: Progress()); XCTFail("Invalidated session") }
        catch {
            XCTAssertEqual(ArchiveErrorText.describe(error), String(localized: "変更後のアーカイブを読み直せませんでした。"))
        }
    }
}
