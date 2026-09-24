import AppKit
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ImmediateOpeningTests: XCTestCase {
    @MainActor private func controller(_ document: ArchiveDocument) throws -> ArchiveWindowController {
        try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
    }

    @MainActor private func node(_ path: String, in controller: ArchiveWindowController) throws -> EntryNode {
        let view = controller.outlineView
        return try XCTUnwrap((0..<view.numberOfRows).compactMap { view.item(atRow: $0) as? EntryNode }.first { $0.path == path })
    }

    @MainActor private func validateRename(in controller: ArchiveWindowController, indexed: Bool) throws {
        let selected = try node("a.txt", in: controller), view = controller.outlineView
        view.selectRowIndexes(IndexSet(integer: view.row(forItem: selected)), byExtendingSelection: false)
        controller.renameEntry(nil)
        defer { view.cancelRenaming() }
        let validation = try XCTUnwrap(controller.renameValidation)
        XCTAssertEqual(validation.usesOccupancy, indexed)
        XCTAssertNoThrow(try validation.plan(for: "renamed.txt"))
        XCTAssertThrowsError(try validation.plan(for: "b.txt")) { XCTAssertEqual($0 as? ArchiveEditError, .collision("b.txt")) }
        XCTAssertThrowsError(try validation.plan(for: "folder")) { XCTAssertEqual($0 as? ArchiveEditError, .collision("folder")) }
    }

    @MainActor func testTreeDisplaysBeforeIndexAndRenameUsesFallbackThenPreparedOccupancy() async throws {
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document, gate = ScenarioGate()
        let events = Mutex<[(ArchiveReservationDiagnostics.Event, Bool)]>([])
        defer { gate.release(); document.close() }
        ArchiveReservationDiagnostics.observer.withValue({ event, main in
            events.withLock { $0.append((event, main)) }
            if event == .renameIndex { gate.pauseOnce() }
        }) { document.makeWindowControllers() }
        try await scenarioWait { gate.isEntered }
        let controller = try controller(document), root = try XCTUnwrap(node("a.txt", in: controller).parent)
        XCTAssertEqual(controller.outlineView.numberOfRows, 3)
        XCTAssertNil(root.editOccupancy)
        XCTAssertNil(controller.renameOccupancy)
        XCTAssertFalse(controller.renameIndexIsReady)
        try validateRename(in: controller, indexed: false)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(controller.isListLoadingVisible)
        gate.release()
        try await scenarioWait { controller.renameIndexIsReady }
        XCTAssertNotNil(controller.renameOccupancy)
        XCTAssertLessThan(try XCTUnwrap(controller.treeDisplayedAt), try XCTUnwrap(controller.renameIndexReadyAt))
        XCTAssertNil(root.editOccupancy)
        XCTAssertTrue(try node("a.txt", in: controller).parent === root)
        try validateRename(in: controller, indexed: true)
        let observed = events.withLock { $0 }
        XCTAssertFalse(observed.contains { [.renameIndex, .renameIndexBuilt].contains($0.0) && $0.1 })
        XCTAssertTrue(observed.contains { $0.0 == .treeDisplayed && $0.1 })
        XCTAssertTrue(observed.contains { $0.0 == .renameIndexReady && $0.1 })
        XCTAssertLessThan(try XCTUnwrap(observed.firstIndex { $0.0 == .treeDisplayed }),
                          try XCTUnwrap(observed.firstIndex { $0.0 == .renameIndex }))
    }

    @MainActor func testCompletedOccupancyFromOlderGenerationIsIgnored() async throws {
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document, gate = ScenarioGate()
        defer { gate.release(); document.close() }
        ArchiveReservationDiagnostics.observer.withValue({ event, _ in
            if event == .renameIndexBuilt { gate.pauseOnce() }
        }) { document.makeWindowControllers() }
        try await scenarioWait { gate.isEntered }
        let controller = try controller(document), oldIndex = try XCTUnwrap(controller.renameIndexTask)
        let session = try XCTUnwrap(document.session), generation = session.generation
        try await session.reloadAfterMutation()
        XCTAssertGreaterThan(session.generation, generation)
        // キャンセルされていない完成済みの結果も、世代が違えば採用しない。
        XCTAssertFalse(oldIndex.isCancelled)
        gate.release()
        await oldIndex.value
        XCTAssertFalse(controller.renameIndexIsReady)
        XCTAssertNil(controller.renameOccupancy)
        try await document.reloadAfterMutation()
        try await scenarioWait { controller.renameIndexIsReady }
        XCTAssertNotNil(controller.renameOccupancy)
    }

    @MainActor func testReplacingTreeInSameGenerationRejectsLateIndex() async throws {
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document, gate = ScenarioGate()
        defer { gate.release(); document.close() }
        ArchiveReservationDiagnostics.observer.withValue({ event, _ in
            if event == .renameIndexBuilt { gate.pauseOnce() }
        }) { document.makeWindowControllers() }
        try await scenarioWait { gate.isEntered }
        let controller = try controller(document), oldIndex = try XCTUnwrap(controller.renameIndexTask)
        let session = try XCTUnwrap(document.session)
        let replacement = EntryNode.tree(from: [archiveColumnEntry("replacement.txt")])
        controller.display(replacement, session: session, generation: session.generation)
        gate.release()
        await oldIndex.value
        XCTAssertTrue(try node("replacement.txt", in: controller).parent === replacement)
        XCTAssertFalse(controller.renameIndexIsReady)
        XCTAssertNil(controller.renameOccupancy)
    }

    @MainActor func testPostEditKeepsPreviousRowsThenDisplaysBeforeNewIndex() async throws {
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document
        let treeGate = ScenarioGate(), indexGate = ScenarioGate()
        defer { treeGate.release(); indexGate.release(); document.close() }
        document.makeWindowControllers()
        let controller = try controller(document)
        try await scenarioWait { controller.renameIndexIsReady }
        let old = try node("a.txt", in: controller), session = try XCTUnwrap(document.session), generation = session.generation
        let edit = Task {
            try await ArchiveReservationDiagnostics.observer.withValue({ event, main in
                if event == .tree && !main { treeGate.pauseOnce() }
                if event == .renameIndex { indexGate.pauseOnce() }
            }) { try await document.rename(old, to: "renamed.txt", progress: Progress()) }
        }
        try await scenarioWait { treeGate.isEntered }
        XCTAssertTrue(try node("a.txt", in: controller) === old)
        XCTAssertNil(controller.renameOccupancy)
        try await scenarioWait { controller.isListLoadingVisible }
        XCTAssertTrue(try node("a.txt", in: controller) === old)
        treeGate.release()
        _ = try await edit.value
        try await scenarioWait { indexGate.isEntered }
        XCTAssertGreaterThan(session.generation, generation)
        XCTAssertNotNil(try node("renamed.txt", in: controller))
        XCTAssertFalse(controller.isListLoadingVisible)
        XCTAssertFalse(controller.renameIndexIsReady)
        indexGate.release()
        try await scenarioWait { controller.renameIndexIsReady }
        let occupancy = try XCTUnwrap(controller.renameOccupancy)
        XCTAssertTrue(occupancy.collides("renamed.txt", directory: false))
        XCTAssertFalse(occupancy.collides("a.txt", directory: false))
    }

    @MainActor func testSlowInitialLoadsRevealAfterDelayAndHideOnDisplayInBothModes() async throws {
        preserveArchiveWindowFrame()
        for mode in [ArchivePreferences.SaveBehavior.immediate, .onSave] {
            let fixture = try DeferredSaveFixture(behavior: mode), document = fixture.document, gate = ScenarioGate()
            defer { gate.release(); document.close() }
            ArchiveReservationDiagnostics.observer.withValue({ event, main in
                if event == .tree && !main { gate.pauseOnce() }
            }) { document.makeWindowControllers() }
            let controller = try controller(document)
            try await scenarioWait { gate.isEntered }
            let responder = controller.window?.firstResponder
            XCTAssertFalse(controller.isListLoadingVisible)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(controller.isListLoadingVisible)
            try await scenarioWait { controller.isListLoadingVisible }
            XCTAssertEqual(controller.statusBar.stringValue, String(localized: "項目を読み込んでいます…"))
            XCTAssertTrue(controller.listLoadingIndicator.isIndeterminate)
            XCTAssertEqual(controller.listLoadingIndicator.controlSize, .small)
            XCTAssertTrue(controller.window?.firstResponder === responder)
            XCTAssertNil(controller.window?.attachedSheet)
            XCTAssertTrue(controller.searchField.isEnabled)
            gate.release()
            try await scenarioWait { controller.outlineView.numberOfRows == 3 }
            XCTAssertFalse(controller.isListLoadingVisible)
            XCTAssertNotEqual(controller.statusBar.stringValue, String(localized: "項目を読み込んでいます…"))
            _ = try await document.projectedEntries()
        }
    }

    @MainActor func testFastLoadNeverRevealsIndicator() async throws {
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document
        defer { document.close() }
        document.makeWindowControllers()
        let controller = try controller(document), deadline = ContinuousClock.now + .milliseconds(750)
        while ContinuousClock.now < deadline {
            XCTAssertFalse(controller.isListLoadingVisible)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(controller.outlineView.numberOfRows, 3)
        XCTAssertTrue(controller.renameIndexIsReady)
    }

    @MainActor func testCloseHidesSlowLoadAndLateTreeCannotRedisplay() async throws {
        preserveArchiveWindowFrame()
        for closesDocument in [true, false] {
            let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document, gate = ScenarioGate()
            defer { gate.release(); document.close() }
            ArchiveReservationDiagnostics.observer.withValue({ event, main in
                if event == .tree && !main { gate.pauseOnce() }
            }) { document.makeWindowControllers() }
            let controller = try controller(document)
            try await scenarioWait { controller.isListLoadingVisible }
            if closesDocument { document.close() } else { controller.close() }
            XCTAssertFalse(controller.isListLoadingVisible)
            gate.release()
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertFalse(controller.isListLoadingVisible)
            XCTAssertEqual(controller.outlineView.numberOfRows, 0)
            XCTAssertFalse(controller.renameIndexIsReady)
        }
    }

    @MainActor func testReloadFailureHidesIndicatorAndKeepsPreviousRows() async throws {
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document, gate = ScenarioGate()
        defer { gate.release(); document.close() }
        document.makeWindowControllers()
        let controller = try controller(document), session = try XCTUnwrap(document.session)
        try await scenarioWait { controller.renameIndexIsReady }
        let old = try node("a.txt", in: controller)
        let blockedReload = Task { try await session.reloadAfterMutation(willOpen: { gate.pauseOnce() }) }
        try await scenarioWait { gate.isEntered }
        let reload = Task { try await document.reloadAfterMutation() }
        try await scenarioWait { controller.isListLoadingVisible }
        XCTAssertTrue(try node("a.txt", in: controller) === old)
        try FileManager.default.removeItem(at: fixture.archive)
        gate.release()
        _ = await blockedReload.result
        do { try await reload.value; XCTFail("Reload unexpectedly succeeded") } catch { }
        XCTAssertFalse(controller.isListLoadingVisible)
        XCTAssertTrue(try node("a.txt", in: controller) === old)
        XCTAssertNil(controller.renameOccupancy)
    }

    @MainActor func testExternalChangeRevertKeepsPreviousRowsUntilNewTreeInBothModes() async throws {
        preserveArchiveWindowFrame()
        for mode in [ArchivePreferences.SaveBehavior.immediate, .onSave] {
            let fixture = try DeferredSaveFixture(behavior: mode), document = fixture.document, gate = ScenarioGate()
            defer { gate.release(); document.close() }
            document.makeWindowControllers()
            let controller = try controller(document)
            try await scenarioWait { controller.outlineView.numberOfRows == 3 }
            _ = try await document.projectedEntries()
            let old = try node("a.txt", in: controller)
            let replacement = fixture.directory.url.appendingPathComponent("replacement.zip")
            let writer = try ArchiveWriter.create(url: replacement, format: .zip)
            try writer.add(data: Data([42]), as: "external.txt")
            try writer.finish()
            try Data(contentsOf: replacement).write(to: fixture.archive, options: .atomic)
            let revert = Task {
                try await ArchiveReservationDiagnostics.observer.withValue({ event, main in
                    if event == .tree && !main { gate.pauseOnce() }
                }) {
                    if mode == .onSave { try await document.revertPending() }
                    else { try document.revert(toContentsOf: fixture.archive, ofType: "public.data") }
                }
            }
            try await scenarioWait { gate.isEntered }
            try await scenarioWait { controller.isListLoadingVisible }
            XCTAssertTrue(try node("a.txt", in: controller) === old)
            gate.release()
            try await revert.value
            try await scenarioWait { controller.outlineView.numberOfRows == 1 }
            XCTAssertNotNil(try node("external.txt", in: controller))
            XCTAssertFalse(controller.isListLoadingVisible)
        }
    }

    @MainActor func testOldCompletionDoesNotHideNewLoadingIndicator() async throws {
        preserveArchiveWindowFrame()
        let controller = ArchiveWindowController()
        defer { controller.close() }
        let old = controller.beginListLoading(), current = controller.beginListLoading()
        try await scenarioWait { controller.isListLoadingVisible }
        controller.finishListLoading(old)
        XCTAssertTrue(controller.isListLoadingVisible)
        controller.finishListLoading(current)
        XCTAssertFalse(controller.isListLoadingVisible)
    }

    // M4-B より前の条件と計数を独立に残す。
    private func legacyOccupancy(_ entries: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat) -> ArchivePathOccupancy.Overlay? {
        var occupancy: ArchivePathOccupancy? = .init()
        for entry in entries where occupancy != nil {
            if let normalized = try? ArchiveEditPlan.normalizedPath(entry.name, directory: entry.kind == .directory, format: format),
               normalized.utf8.elementsEqual(entry.name.utf8),
               entry.pathComponents.joined(separator: "/") == ArchiveEditPlan.key(entry.name) {
                occupancy!.insert(ArchiveEditPlan.key(entry.name), directory: entry.kind == .directory)
            } else { occupancy = nil }
        }
        return occupancy.map(ArchivePathOccupancy.Overlay.init)
    }

    func testOccupancyMatchesLegacyIncludingFallbackAndFormatRules() async throws {
        let regular = [archiveColumnEntry("folder/", index: 0, kind: .directory),
            archiveColumnEntry("folder/a.txt", index: 1), archiveColumnEntry("folder/a.txt", index: 2),
            archiveColumnEntry("café.txt", index: 3), archiveColumnEntry("implicit/child.txt", index: 4),
            archiveColumnEntry("folder/", index: 5, kind: .directory), archiveColumnEntry("link", index: 6, kind: .hardlink)]
        let nfd = archiveColumnEntry("cafe\u{301}.txt", index: 7), dotted = archiveColumnEntry("./folder/b.txt", index: 8)
        let colon = archiveColumnEntry("man3/File::Spec.3pm", index: 9)
        let archives = [[], regular, regular + [colon], regular + [nfd], regular + [dotted],
                        regular + [nfd, dotted, colon], [archiveColumnEntry("missing-slash", kind: .directory)],
                        [archiveColumnEntry("a//b")], [archiveColumnEntry("bad\\name")]]
        let probes = ["", "folder", "folder/a.txt", "folder/a.txt/child", "folder/new", "café.txt", "cafe\u{301}.txt",
                      "implicit", "implicit/child.txt", "missing", "man3", "man3/File::Spec.3pm", "link", "link/child"]
        for format in [GyoshukuKit.ArchiveFormat.zip, .tar] {
            for entries in archives {
                let old = legacyOccupancy(entries, format: format)
                let results = [EntryNode.renameOccupancy(from: entries, format: format),
                    EntryNode.tree(from: entries, format: format, indexingEdits: true).editOccupancy,
                    await EntryNode.buildRenameOccupancy(from: entries, format: format)]
                for result in results {
                    XCTAssertEqual(old == nil, result == nil, "\(format): \(entries.map(\.name))")
                    guard var expected = old, var actual = result else { continue }
                    for removed in 0...entries.count {
                        for path in probes {
                            XCTAssertEqual(actual.containsSubtree(at: path), expected.containsSubtree(at: path), path)
                            XCTAssertEqual(actual.selectionCount(at: path), expected.selectionCount(at: path), path)
                            XCTAssertEqual(actual.isFolder(path), expected.isFolder(path), path)
                            XCTAssertEqual(actual.firstFileAncestor(path), expected.firstFileAncestor(path), path)
                            for directory in [true, false] {
                                XCTAssertEqual(actual.collides(path, directory: directory), expected.collides(path, directory: directory), path)
                            }
                        }
                        if removed < entries.count {
                            let entry = entries[removed], key = ArchiveEditPlan.key(entry.name)
                            expected.remove(key, directory: entry.kind == .directory)
                            actual.remove(key, directory: entry.kind == .directory)
                        }
                    }
                }
            }
        }
        XCTAssertNotNil(EntryNode.renameOccupancy(from: regular + [colon], format: .tar))
        XCTAssertNil(EntryNode.renameOccupancy(from: regular + [colon], format: .zip))
        XCTAssertNil(EntryNode.renameOccupancy(from: regular + [nfd], format: .tar))
        XCTAssertNil(EntryNode.renameOccupancy(from: regular + [dotted], format: .tar))
    }
}
