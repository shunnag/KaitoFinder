import AppKit
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

/// ArchiveDocument・ArchiveWindowController の即時表示と名前索引の準備を確かめる 12 テスト。
/// DeferredSaveFixture・ScenarioGate を使い、表示行・読み込み表示・世代と占有表の整合を観測する。
nonisolated final class ImmediateOpeningTests: XCTestCase {
    @MainActor private func controller(_ document: ArchiveDocument) throws -> ArchiveWindowController {
        try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
    }

    @MainActor private func validateRename(in controller: ArchiveWindowController, indexed: Bool) throws {
        let selected = try controller.displayedNode("a.txt"), view = controller.outlineView
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
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document, gate = ScenarioGate()
        let events = Mutex<[(ArchiveReservationDiagnostics.Event, Bool)]>([])
        defer { gate.release(); document.close() }
        ArchiveReservationDiagnostics.observer.withValue({ event, main in
            events.withLock { $0.append((event, main)) }
            if event == .renameIndex { gate.pauseOnce() }
        }) { document.makeWindowControllers() }
        try await scenarioWait { gate.isEntered }
        let controller = try controller(document), root = try XCTUnwrap(controller.displayedNode("a.txt").parent)
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
        XCTAssertTrue(try controller.displayedNode("a.txt").parent === root)
        try validateRename(in: controller, indexed: true)
        let observed = events.withLock { $0 }
        XCTAssertFalse(observed.contains { [.renameIndex, .renameIndexBuilt].contains($0.0) && $0.1 })
        XCTAssertTrue(observed.contains { $0.0 == .treeDisplayed && $0.1 })
        XCTAssertTrue(observed.contains { $0.0 == .renameIndexReady && $0.1 })
        XCTAssertLessThan(try XCTUnwrap(observed.firstIndex { $0.0 == .treeDisplayed }),
                          try XCTUnwrap(observed.firstIndex { $0.0 == .renameIndex }))
    }

    @MainActor func testCompletedOccupancyFromOlderGenerationIsIgnored() async throws {
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
        XCTAssertTrue(try controller.displayedNode("replacement.txt").parent === replacement)
        XCTAssertFalse(controller.renameIndexIsReady)
        XCTAssertNil(controller.renameOccupancy)
    }

    @MainActor func testPostEditKeepsPreviousRowsThenDisplaysBeforeNewIndex() async throws {
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document
        let treeGate = ScenarioGate(), indexGate = ScenarioGate()
        defer { treeGate.release(); indexGate.release(); document.close() }
        document.makeWindowControllers()
        let controller = try controller(document)
        try await scenarioWait { controller.renameIndexIsReady }
        let old = try controller.displayedNode("a.txt"), session = try XCTUnwrap(document.session), generation = session.generation
        let events = Mutex<[(ArchiveReservationDiagnostics.Event, UInt64, Bool)]>([])
        let builds = Mutex<[UInt64]>([]), droppedRenames = Mutex<[[Int: String]]>([])
        XCTAssertNotNil(session.nameIndex(generation: generation, format: session.reservationFormat))
        let edit = Task {
            // 不完全な差分を位置照合で捨てさせ、改名欄の背景準備による再構築を通す。
            try await ArchiveSession.nameIndexChangeForTesting.withValue({ change in
                droppedRenames.withLock { $0.append(change.renamed) }
                var change = change
                change.renamed = [:]
                return change
            }) {
                try await ArchiveStageDiagnostics.observer.withValue({ event in
                    if case .began(_, .nameIndexBuild) = event { builds.withLock { $0.append(session.generation) } }
                }) {
                    try await ArchiveReservationDiagnostics.observer.withValue({ event, main in
                        events.withLock { $0.append((event, session.generation, main)) }
                        if event == .tree && !main { treeGate.pauseOnce() }
                        if event == .renameIndex { indexGate.pauseOnce() }
                    }) { try await document.rename(old, to: "renamed.txt", progress: Progress()) }
                }
            }
        }
        try await scenarioWait { treeGate.isEntered }
        let postEditGeneration = session.generation
        XCTAssertGreaterThan(postEditGeneration, generation)
        XCTAssertEqual(droppedRenames.withLock { $0 }, [[try XCTUnwrap(old.entry).index: "renamed.txt"]])
        XCTAssertNil(session.nameIndex(generation: generation, format: session.reservationFormat))
        XCTAssertNil(session.nameIndex(generation: postEditGeneration, format: session.reservationFormat))
        XCTAssertTrue(builds.withLock { $0.isEmpty })
        XCTAssertTrue(try controller.displayedNode("a.txt") === old)
        XCTAssertNil(controller.renameOccupancy)
        XCTAssertFalse(controller.renameIndexIsReady)
        try await scenarioWait { controller.isListLoadingVisible }
        XCTAssertTrue(try controller.displayedNode("a.txt") === old)
        treeGate.release()
        _ = try await edit.value
        try await scenarioWait { indexGate.isEntered }
        XCTAssertEqual(session.generation, postEditGeneration)
        XCTAssertNil(session.nameIndex(generation: postEditGeneration, format: session.reservationFormat))
        XCTAssertNotNil(try controller.displayedNode("renamed.txt"))
        XCTAssertFalse(controller.isListLoadingVisible)
        XCTAssertFalse(controller.renameIndexIsReady)
        XCTAssertNil(controller.renameOccupancy)
        indexGate.release()
        try await scenarioWait { controller.renameIndexIsReady }
        let occupancy = try XCTUnwrap(controller.renameOccupancy)
        XCTAssertTrue(occupancy.collides("renamed.txt", directory: false))
        XCTAssertFalse(occupancy.collides("a.txt", directory: false))
        let rebuilt = try XCTUnwrap(session.nameIndex(generation: postEditGeneration, format: session.reservationFormat))
        XCTAssertTrue(rebuilt.overlay.collides("renamed.txt", directory: false))
        XCTAssertFalse(rebuilt.overlay.collides("a.txt", directory: false))
        XCTAssertEqual(builds.withLock { $0 }, [postEditGeneration])
        let observed = events.withLock { $0 }
        for event in [ArchiveReservationDiagnostics.Event.renameIndex, .renameIndexBuilt] {
            let matches = observed.filter { $0.0 == event }
            XCTAssertEqual(matches.map { $0.1 }, [postEditGeneration])
            XCTAssertFalse(matches.contains { $0.2 })
        }
        XCTAssertLessThan(try XCTUnwrap(observed.firstIndex { $0.0 == .treeDisplayed }),
                          try XCTUnwrap(observed.firstIndex { $0.0 == .renameIndex }))
    }

    @MainActor func testPostEditReusesAdvancedIndexWithoutExposingOldOccupancy() async throws {
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document, treeGate = ScenarioGate()
        defer { treeGate.release(); document.close() }
        document.makeWindowControllers()
        let controller = try controller(document)
        try await scenarioWait { controller.renameIndexIsReady }
        let old = try controller.displayedNode("a.txt"), session = try XCTUnwrap(document.session), generation = session.generation
        let previous = try XCTUnwrap(controller.renameOccupancy)
        XCTAssertTrue(previous.collides("a.txt", directory: false))
        XCTAssertFalse(previous.collides("renamed.txt", directory: false))
        let events = Mutex<[(ArchiveReservationDiagnostics.Event, UInt64)]>([])
        let stages = Mutex<[(ArchiveStageDiagnostics.Stage, UInt64)]>([])
        let checkReadyOccupancy: @MainActor @Sendable () -> Void = {
            guard session.generation > generation, controller.renameIndexIsReady else { return }
            XCTAssertNotNil(controller.renameOccupancy)
            XCTAssertEqual(controller.renameOccupancy?.collides("renamed.txt", directory: false), true)
            XCTAssertEqual(controller.renameOccupancy?.collides("a.txt", directory: false), false)
        }
        let edit = Task {
            try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append((stage, session.generation)) } }
            }) {
                try await ArchiveReservationDiagnostics.observer.withValue({ event, main in
                    events.withLock { $0.append((event, session.generation)) }
                    if event == .tree && !main { treeGate.pauseOnce() }
                    // 表示・ready 通知のその場でも調べ、待機の poll 間に古い占有表を公開していないか確認する。
                    if main { MainActor.assumeIsolated { checkReadyOccupancy() } }
                }) { try await document.rename(old, to: "renamed.txt", progress: Progress()) }
            }
        }
        try await scenarioWait { checkReadyOccupancy(); return treeGate.isEntered }
        let postEditGeneration = session.generation
        XCTAssertGreaterThan(postEditGeneration, generation)
        let advanced = try XCTUnwrap(session.nameIndex(generation: postEditGeneration, format: session.reservationFormat))
        XCTAssertTrue(advanced.overlay.collides("renamed.txt", directory: false))
        XCTAssertFalse(advanced.overlay.collides("a.txt", directory: false))
        XCTAssertTrue(try controller.displayedNode("a.txt") === old)
        XCTAssertNil(controller.renameOccupancy)
        XCTAssertFalse(controller.renameIndexIsReady)
        try await scenarioWait { checkReadyOccupancy(); return controller.isListLoadingVisible }
        XCTAssertTrue(try controller.displayedNode("a.txt") === old)
        treeGate.release()
        _ = try await edit.value
        checkReadyOccupancy()
        try await scenarioWait { checkReadyOccupancy(); return controller.renameIndexIsReady }
        XCTAssertEqual(session.generation, postEditGeneration)
        XCTAssertNotNil(try controller.displayedNode("renamed.txt"))
        XCTAssertFalse(controller.isListLoadingVisible)
        XCTAssertTrue(controller.renameIndexIsReady)
        checkReadyOccupancy()
        let observed = events.withLock { $0 }
        XCTAssertFalse(observed.contains { [.renameIndex, .renameIndexBuilt].contains($0.0) })
        for event in [ArchiveReservationDiagnostics.Event.treeDisplayed, .renameIndexReady] {
            XCTAssertEqual(observed.filter { $0.0 == event }.map { $0.1 }, [postEditGeneration])
        }
        let recordedStages = stages.withLock { $0 }
        XCTAssertFalse(recordedStages.contains { $0.0 == .nameIndexBuild })
        XCTAssertEqual(recordedStages.filter { $0.0 == .nameIndexAdvance }.map { $0.1 }, [postEditGeneration])
        XCTAssertEqual(recordedStages.filter { $0.0 == .treeBuild }.map { $0.1 }, [postEditGeneration])
    }

    @MainActor func testSlowInitialLoadsRevealAfterDelayAndHideOnDisplayInBothModes() async throws {
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
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document, gate = ScenarioGate()
        defer { gate.release(); document.close() }
        document.makeWindowControllers()
        let controller = try controller(document), session = try XCTUnwrap(document.session)
        try await scenarioWait { controller.renameIndexIsReady }
        let old = try controller.displayedNode("a.txt")
        let blockedReload = Task { try await session.reloadAfterMutation(willOpen: { gate.pauseOnce() }) }
        try await scenarioWait { gate.isEntered }
        let reload = Task { try await document.reloadAfterMutation() }
        try await scenarioWait { controller.isListLoadingVisible }
        XCTAssertTrue(try controller.displayedNode("a.txt") === old)
        try FileManager.default.removeItem(at: fixture.archive)
        gate.release()
        _ = await blockedReload.result
        do { try await reload.value; XCTFail("Reload unexpectedly succeeded") } catch { }
        XCTAssertFalse(controller.isListLoadingVisible)
        XCTAssertTrue(try controller.displayedNode("a.txt") === old)
        XCTAssertNil(controller.renameOccupancy)
    }

    @MainActor func testExternalChangeRevertKeepsPreviousRowsUntilNewTreeInBothModes() async throws {
        for mode in [ArchivePreferences.SaveBehavior.immediate, .onSave] {
            let fixture = try DeferredSaveFixture(behavior: mode), document = fixture.document, gate = ScenarioGate()
            defer { gate.release(); document.close() }
            document.makeWindowControllers()
            let controller = try controller(document)
            try await scenarioWait { controller.outlineView.numberOfRows == 3 }
            _ = try await document.projectedEntries()
            let old = try controller.displayedNode("a.txt")
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
            XCTAssertTrue(try controller.displayedNode("a.txt") === old)
            gate.release()
            try await revert.value
            try await scenarioWait { controller.outlineView.numberOfRows == 1 }
            XCTAssertNotNil(try controller.displayedNode("external.txt"))
            await document.waitForDeferredPreparationForTesting()
            XCTAssertNil(controller.listLoadingTokenForTesting)
            XCTAssertFalse(controller.isListLoadingVisible)
            if mode == .onSave {
                let snapshot = await document.session!.snapshot()
                XCTAssertEqual(document.pendingEditor?.baseGeneration, snapshot.generation)
                XCTAssertEqual(document.pendingEditor?.base, snapshot.entries)
            }
        }
    }

    @MainActor func testOldCompletionDoesNotHideNewLoadingIndicator() async throws {
        let controller = ArchiveWindowController()
        defer { controller.close() }
        let old = controller.beginListLoading(), current = controller.beginListLoading()
        try await scenarioWait { controller.isListLoadingVisible }
        controller.finishListLoading(old)
        XCTAssertTrue(controller.isListLoadingVisible)
        controller.finishListLoading(current)
        XCTAssertFalse(controller.isListLoadingVisible)
    }

    // EntryNode の占有計算（renameOccupancy・editOccupancy・buildRenameOccupancy）と比べる独立の参照実装。
    // 全項目の名前が正規化済みで pathComponents が key と一致するときだけ占有を積み、1 件でも外れれば nil（fallback）を返す。
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
