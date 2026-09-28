import AppKit
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredOpeningTests: XCTestCase {
    @MainActor func testBaseTreeAppearsBeforePreparationAndWaitingEditChecksCollisions() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        let updater = ScenarioGate(), validation = ScenarioGate()
        let observations = Mutex<[(ArchiveReservationDiagnostics.Event, Bool)]>([])
        defer { updater.release(); validation.release(); document.close() }
        ArchiveReservationDiagnostics.observer.withValue({ event, main in
            observations.withLock { $0.append((event, main)) }
            if event == .updaterPreparation { updater.pauseOnce() }
            if event == .baseValidation { validation.pauseOnce() }
        }) { document.makeWindowControllers() }
        // controller の空ツリー初期化は計測対象外。
        observations.withLock { $0.removeAll() }
        try await scenarioWait { updater.isEntered }
        let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        let session = try XCTUnwrap(document.session)
        XCTAssertEqual(controller.outlineView.numberOfRows, 3)
        XCTAssertNil(document.pendingEditor?.validation)
        XCTAssertFalse(validation.isEntered)
        let node = try XCTUnwrap((0..<controller.outlineView.numberOfRows).compactMap {
            controller.outlineView.item(atRow: $0) as? EntryNode
        }.first { $0.path == "a.txt" })
        controller.outlineView.selectRowIndexes(IndexSet(integer: controller.outlineView.row(forItem: node)), byExtendingSelection: false)
        let entry = try XCTUnwrap(node.entry), reading = try XCTUnwrap(session.pendingReadSnapshot)
        XCTAssertEqual(reading.origin(for: entry), .base(index: entry.index, expectedName: entry.name, baseGeneration: session.generation))
        var started = false, finished = false
        let edit = Task {
            started = true
            defer { finished = true }
            return try await document.rename(node, to: "b.txt", progress: Progress())
        }
        try await scenarioWait { started }
        XCTAssertFalse(finished)
        XCTAssertTrue(document.pendingChanges.isEmpty)
        updater.release()
        try await scenarioWait { validation.isEntered }
        XCTAssertFalse(finished)
        XCTAssertEqual(controller.outlineView.numberOfRows, 3)
        XCTAssertTrue(controller.outlineView.item(atRow: controller.outlineView.selectedRow) as? EntryNode === node)
        validation.release()
        do { _ = try await edit.value; XCTFail("A waiting edit accepted a duplicate path") }
        catch { XCTAssertEqual(error as? ArchiveEditError, .collision("b.txt")) }
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertTrue(controller.outlineView.item(atRow: controller.outlineView.selectedRow) as? EntryNode === node)
        let events = observations.withLock { $0 }
        for event: ArchiveReservationDiagnostics.Event in [.tree, .updaterPreparation, .baseValidation] {
            XCTAssertEqual(events.filter { $0.0 == event }.count, 1, "\(event)")
            XCTAssertFalse(events.contains { $0.0 == event && $0.1 }, "Main thread: \(event)")
        }
        _ = try await document.rename(node, to: "renamed.txt", progress: Progress())
        let projected = try await document.projectedEntries()
        XCTAssertEqual(Set(projected.map(\.name)),
                       ["renamed.txt", "b.txt", "folder/", "folder/child.txt"])
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testEditWaitingForPreparationRevealsProgressAndHonorsCancellation() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
        defer { gate.release(); document.close() }
        ArchiveReservationDiagnostics.observer.withValue({ event, _ in
            if event == .baseValidation { gate.pauseOnce() }
        }) { document.makeWindowControllers() }
        try await scenarioWait { gate.isEntered }
        let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        XCTAssertEqual(controller.outlineView.numberOfRows, 3)
        controller.newFolder(nil)
        let sheet = try XCTUnwrap(controller.editProgressSheet), panel = try XCTUnwrap(sheet.window)
        let edit = try XCTUnwrap(controller.extractionTask)
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertTrue(controller.operationInFlight)
        XCTAssertTrue(document.pendingChanges.isEmpty)
        try await scenarioWait { panel.alphaValue == 1 }
        XCTAssertNil(document.pendingEditor?.validation)
        XCTAssertEqual(controller.outlineView.numberOfRows, 3)
        controller.cancelExtraction()
        gate.release()
        await edit.value
        XCTAssertTrue(sheet.progress.isCancelled)
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertNil(controller.editProgressSheet)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testBackgroundUpdaterFailureIsReportedOnlyByWaitingEdit() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('a.txt', b'first-payload')
            z.writestr('b.txt', b'second-payload')
        """)
        var data = try Data(contentsOf: fixture.archive)
        let central = data.subdata(in: (data.count - 6)..<(data.count - 2)).withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        for offset in [18, 22, central + 20, central + 24] {
            withUnsafeBytes(of: UInt32(central).littleEndian) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        try data.write(to: fixture.archive)
        let defaults = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: defaults.defaults)
        store.preferences.saveBehavior = .onSave
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store), gate = ScenarioGate()
        defer { gate.release(); document.close() }
        try document.read(from: fixture.archive, ofType: "public.data")
        let session = try XCTUnwrap(document.session)
        ArchiveReservationDiagnostics.observer.withValue({ event, _ in
            if event == .baseValidation { gate.pauseOnce() }
        }) { document.makeWindowControllers() }
        try await scenarioWait { gate.isEntered }
        let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        XCTAssertEqual(controller.outlineView.numberOfRows, 2)
        XCTAssertTrue(session.capabilities.canEdit)
        XCTAssertNil(controller.window?.attachedSheet)
        var started = false, finished = false
        let edit = Task {
            started = true
            defer { finished = true }
            return try await document.createFolder(in: "", progress: Progress())
        }
        try await scenarioWait { started }
        XCTAssertFalse(finished)
        gate.release()
        do { _ = try await edit.value; XCTFail("Full ZIP validation was bypassed") }
        catch UpdaterError.invalidArchive { }
        XCTAssertFalse(session.capabilities.canEdit)
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), data)
    }
}
