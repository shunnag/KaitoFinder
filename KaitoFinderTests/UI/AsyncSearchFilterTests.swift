import AppKit
import KaitoKit
import QuickLookUI
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class AsyncSearchFilterTests: XCTestCase {
    @MainActor private final class Interface {
        let defaults: ArchivePreferencesTestDefaults
        let store: ArchivePreferencesStore
        let controller: ArchiveWindowController
        let root: EntryNode

        init(entries: [ArchiveEntry]? = nil, hidden: Bool = false) throws {
            defaults = try ArchivePreferencesTestDefaults()
            store = ArchivePreferencesStore(defaults: defaults.defaults)
            store.preferences.showsHiddenFiles = hidden
            controller = ArchiveWindowController(preferencesStore: store)
            root = EntryNode.tree(from: entries ?? (0..<200).map {
                archiveColumnEntry("d\($0 / 100)/\($0.isMultiple(of: 2) ? "a" : "b")\($0).txt", index: $0, size: 1)
            })
            controller.display(root)
        }
    }

    @MainActor private func paths(_ controller: ArchiveWindowController) -> [String] {
        (0..<controller.outlineView.numberOfRows).compactMap { (controller.outlineView.item(atRow: $0) as? EntryNode)?.path }
    }

    @MainActor private func request(_ query: String, on controller: ArchiveWindowController, gate: ScenarioGate) throws -> Task<Void, Never> {
        ArchiveWindowController.filterExecution.withValue(.asynchronous) {
            EntryTreeFilter.computeWillStartForTesting.withValue({
                XCTAssertFalse(Thread.isMainThread)
                gate.pauseOnce()
            }) { controller.setFilterQuery(query) }
        }
        return try XCTUnwrap(controller.filterTaskForTesting)
    }

    @MainActor func testRequestKeepsAppliedRowsAndStatusUntilOneSwap() async throws {
        let fixture = try Interface(), controller = fixture.controller, gate = ScenarioGate()
        defer { gate.release(); controller.close() }
        let oldPaths = paths(controller), oldStatus = controller.statusBar.stringValue
        let task = try request("a", on: controller, gate: gate)
        XCTAssertEqual(controller.requestedFilterQuery, "a")
        XCTAssertEqual(controller.filterConfiguration.query, "a")
        XCTAssertEqual(controller.searchField.stringValue, "a")
        XCTAssertEqual(controller.filterQuery, "")
        XCTAssertEqual(paths(controller), oldPaths)
        XCTAssertEqual(controller.statusBar.stringValue, oldStatus)
        try await scenarioWait { gate.isEntered }
        gate.release()
        await task.value
        XCTAssertEqual(controller.filterQuery, controller.requestedFilterQuery)
        XCTAssertEqual(controller.filterSwapCountForTesting, 1)
        let synchronous = try Interface()
        defer { synchronous.controller.close() }
        ArchiveWindowController.filterExecution.withValue(.synchronous) { synchronous.controller.setFilterQuery("a") }
        XCTAssertEqual(paths(controller), paths(synchronous.controller))
        XCTAssertEqual(controller.statusBar.stringValue, synchronous.controller.statusBar.stringValue)
    }

    @MainActor func testOnlyNewestRequestAppliesWhenOlderComputeFinishesLast() async throws {
        let fixture = try Interface(), controller = fixture.controller, gate = ScenarioGate()
        defer { gate.release(); controller.close() }
        let first = try request("a", on: controller, gate: gate)
        try await scenarioWait { gate.isEntered }
        let second = try request("b", on: controller, gate: gate)
        await second.value
        XCTAssertEqual(controller.filterQuery, "b")
        gate.release()
        await first.value
        XCTAssertEqual(controller.filterQuery, "b")
        XCTAssertEqual(controller.filterSwapCountForTesting, 1)
        XCTAssertFalse(controller.isFilterPendingVisible)
    }

    @MainActor func testDisplayAdoptsRequestAndDiscardsOldTreeResult() async throws {
        let fixture = try Interface(), controller = fixture.controller, gate = ScenarioGate()
        defer { gate.release(); controller.close() }
        let task = try request("a", on: controller, gate: gate)
        try await scenarioWait { gate.isEntered }
        let replacement = EntryNode.tree(from: [archiveColumnEntry("new/a.txt"), archiveColumnEntry("new/b.txt", index: 1)])
        controller.display(replacement, generation: 2)
        XCTAssertEqual(controller.filterQuery, "a")
        XCTAssertEqual(paths(controller), ["new", "new/a.txt"])
        gate.release()
        await task.value
        XCTAssertEqual(controller.filterSwapCountForTesting, 0)
        for row in 0..<controller.outlineView.numberOfRows {
            var ancestor = try XCTUnwrap(controller.outlineView.item(atRow: row) as? EntryNode)
            while let parent = ancestor.parent { ancestor = parent }
            XCTAssertTrue(ancestor === replacement)
        }
    }

    @MainActor func testPreparedFiltersRequireBothRootAndRequestedConfiguration() throws {
        let fixture = try Interface(), controller = fixture.controller
        defer { controller.close() }
        controller.setFilterQuery("a")
        let other = EntryNode.tree(from: fixture.root.archiveEntries)
        controller.display(fixture.root, preparedFilter: EntryTreeFilter(root: other, query: "a"))
        XCTAssertEqual(controller.preparedFilterMissesForTesting, 1)
        XCTAssertEqual(paths(controller).count, 102)
        controller.display(fixture.root, preparedFilter: EntryTreeFilter(root: fixture.root, query: "b"))
        XCTAssertEqual(controller.preparedFilterMissesForTesting, 2)
        controller.display(fixture.root, preparedFilter: EntryTreeFilter(root: fixture.root, query: "a", showsHiddenFiles: true))
        XCTAssertEqual(controller.preparedFilterMissesForTesting, 3)
        controller.display(fixture.root, preparedFilter: EntryTreeFilter(root: fixture.root, query: "a"))
        XCTAssertEqual(controller.preparedFilterMissesForTesting, 3)
        controller.display(fixture.root)
        XCTAssertEqual(controller.preparedFilterMissesForTesting, 4)
        XCTAssertEqual(controller.filterQuery, "a")
    }

    @MainActor func testHiddenSettingCancelsOldConfigurationDuringQuery() async throws {
        let fixture = try Interface(entries: [archiveColumnEntry("a.txt"), archiveColumnEntry(".git/a.txt", index: 1)])
        let controller = fixture.controller, gate = ScenarioGate()
        defer { gate.release(); controller.close() }
        let first = try request("a", on: controller, gate: gate)
        try await scenarioWait { gate.isEntered }
        ArchiveWindowController.filterExecution.withValue(.asynchronous) { fixture.store.preferences.showsHiddenFiles = true }
        XCTAssertTrue(controller.filterConfiguration.showsHiddenFiles)
        await controller.filterTaskForTesting?.value
        gate.release()
        await first.value
        XCTAssertEqual(paths(controller), [".git", ".git/a.txt", "a.txt"])
        XCTAssertEqual(controller.filterQuery, "a")
        XCTAssertEqual(controller.filterSwapCountForTesting, 1)
    }

    @MainActor func testSelectionMadeDuringComputeSurvivesSwap() async throws {
        let fixture = try Interface(), controller = fixture.controller, gate = ScenarioGate()
        defer { gate.release(); controller.close() }
        let task = try request("a", on: controller, gate: gate)
        try await scenarioWait { gate.isEntered }
        let folder = try XCTUnwrap(fixture.root.children.first)
        controller.outlineView.expandItem(folder)
        let selected = try XCTUnwrap(folder.children.first { $0.name == "a0.txt" })
        controller.outlineView.selectRowIndexes(IndexSet(integer: controller.outlineView.row(forItem: selected)), byExtendingSelection: false)
        gate.release()
        await task.value
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["d0/a0.txt"])
    }

    @MainActor func testClearingQueryCancelsComputeAndRestoresUnfilteredStateSynchronously() async throws {
        let fixture = try Interface(), controller = fixture.controller, gate = ScenarioGate()
        defer { gate.release(); controller.close() }
        let folder = fixture.root.children[0]
        controller.outlineView.expandItem(folder)
        controller.outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let original = paths(controller), selected = controller.selectedNodes.map(\.path)
        controller.setFilterQuery("a")
        let task = try request("b", on: controller, gate: gate)
        try await scenarioWait { gate.isEntered }
        ArchiveWindowController.filterExecution.withValue(.asynchronous) { controller.setFilterQuery("") }
        XCTAssertEqual(controller.filterQuery, "")
        XCTAssertEqual(paths(controller), original)
        XCTAssertEqual(controller.selectedNodes.map(\.path), selected)
        gate.release()
        await task.value
        XCTAssertEqual(paths(controller), original)
        XCTAssertEqual(controller.filterSwapCountForTesting, 0)
    }

    @MainActor func testReturningToAppliedEmptyQueryDoesNotReload() async throws {
        let fixture = try Interface(), controller = fixture.controller, gate = ScenarioGate()
        defer { gate.release(); controller.close() }
        let applies = controller.filterApplyCountForTesting
        let task = try request("a", on: controller, gate: gate)
        try await scenarioWait { gate.isEntered }
        controller.setFilterQuery("")
        XCTAssertEqual(controller.filterApplyCountForTesting, applies)
        gate.release()
        await task.value
        XCTAssertEqual(controller.filterApplyCountForTesting, applies)
        XCTAssertEqual(controller.filterSwapCountForTesting, 0)
    }

    @MainActor func testHiddenExpansionMemoryMatchesSynchronousToggles() async throws {
        let entries = [archiveColumnEntry(".git/x.txt"), archiveColumnEntry("folder/x.txt", index: 1)]
        var expansions: [Set<String>] = []
        for execution in [ArchiveWindowController.FilterExecution.synchronous, .asynchronous] {
            let fixture = try Interface(entries: entries, hidden: true), controller = fixture.controller
            defer { controller.close() }
            try await ArchiveWindowController.filterExecution.withValue(execution) {
                controller.setFilterQuery("x")
                await controller.filterTaskForTesting?.value
                let hidden = try XCTUnwrap(fixture.root.children.first { $0.name == ".git" })
                controller.outlineView.expandItem(hidden)
                fixture.store.preferences.showsHiddenFiles = false
                await controller.filterTaskForTesting?.value
                XCTAssertFalse(paths(controller).contains(".git"))
                fixture.store.preferences.showsHiddenFiles = true
                await controller.filterTaskForTesting?.value
                XCTAssertTrue(controller.outlineView.isItemExpanded(hidden))
                expansions.append(Set(fixture.root.directoryNodes.filter { controller.outlineView.isItemExpanded($0) }.map(\.path)))
            }
        }
        XCTAssertEqual(expansions[0], expansions[1])
    }

    @MainActor func testClosingOrLockingOrSwitchingCancelsPendingSwap() async throws {
        for action in 0..<3 {
            let fixture = try Interface(), controller = fixture.controller, gate = ScenarioGate()
            defer { gate.release(); controller.close() }
            let task = try request("a", on: controller, gate: gate)
            try await scenarioWait { gate.isEntered }
            if action == 0 { controller.close() }
            else if action == 1 { controller.displayLocked() }
            else { controller.prepareForBackingFileSwitch() }
            gate.release()
            await task.value
            XCTAssertTrue(task.isCancelled)
            XCTAssertEqual(controller.filterSwapCountForTesting, 0)
            XCTAssertFalse(controller.isFilterPendingVisible)
        }
    }

    @MainActor func testDelayedStatusAndLoadingPriorityShareIndicator() async throws {
        let fixture = try Interface(), controller = fixture.controller, gate = ScenarioGate()
        defer { gate.release(); controller.close() }
        let status = controller.statusBar.stringValue
        let task = try request("a", on: controller, gate: gate)
        XCTAssertEqual(controller.statusBar.stringValue, status)
        XCTAssertFalse(controller.isFilterPendingVisible)
        try await scenarioWait { controller.isFilterPendingVisible }
        XCTAssertEqual(controller.statusBar.stringValue, String(localized: "検索しています…"))
        XCTAssertEqual(controller.listLoadingIndicator.accessibilityLabel(), String(localized: "検索しています…"))
        XCTAssertFalse(controller.listLoadingIndicator.isHidden)
        XCTAssertFalse(controller.isListLoadingVisible)
        let loading = controller.beginListLoading()
        try await scenarioWait { controller.isListLoadingVisible }
        XCTAssertEqual(controller.statusBar.stringValue, String(localized: "項目を読み込んでいます…"))
        XCTAssertEqual(controller.listLoadingIndicator.accessibilityLabel(), String(localized: "項目を読み込んでいます…"))
        controller.finishListLoading(loading)
        XCTAssertEqual(controller.statusBar.stringValue, String(localized: "検索しています…"))
        gate.release()
        await task.value
        XCTAssertFalse(controller.isFilterPendingVisible)
        XCTAssertTrue(controller.listLoadingIndicator.isHidden)
        XCTAssertEqual(controller.statusBar.stringValue, ArchiveStatusBarText.text(totalCount: 202, totalSize: 200, filteredCount: 102))
    }

    @MainActor func testRenameHoldsCompletedFilter() async throws {
        try await assertInteractionHolds("rename")
    }

    @MainActor func testDragHoldsCompletedFilter() async throws {
        try await assertInteractionHolds("drag")
    }

    @MainActor func testQuickLookHoldsCompletedFilter() async throws {
        try await assertInteractionHolds("preview")
    }

    @MainActor func testPasswordPromptHoldsCompletedFilter() async throws {
        try await assertInteractionHolds("password")
    }

    @MainActor func testAttachedSheetHoldsCompletedFilter() async throws {
        try await assertInteractionHolds("sheet")
    }

    @MainActor func testEntryMenuHoldsCompletedFilter() async throws {
        try await assertInteractionHolds("menu")
    }

    @MainActor func testBlankAreaMenuHoldsCompletedFilter() async throws {
        try await assertInteractionHolds("blankMenu")
    }

    @MainActor func testColumnsMenuHoldsCompletedFilter() async throws {
        try await assertInteractionHolds("columnsMenu")
    }

    @MainActor private func assertInteractionHolds(_ interaction: String) async throws {
        if ["preview", "password", "sheet"].contains(interaction), Bundle.main.bundleURL.pathExtension != "app" {
            throw XCTSkip("Quick Look and modal sheets require the Xcode application test host")
        }
        if interaction == "preview", NSScreen.screens.isEmpty {
            throw XCTSkip("Quick Look needs a screen; the direct XCTest process has none")
        }
        let fixture = try Interface(), controller = fixture.controller, gate = ScenarioGate()
        defer { gate.release(); controller.close() }
        let computed = Mutex(false)
        if interaction == "preview" {
            let archive = try DeferredSaveFixture(behavior: .immediate, files: [("a.txt", "preview")])
            archive.document.addWindowController(controller)
            let session = try XCTUnwrap(archive.document.session), snapshot = await session.snapshot()
            controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
            controller.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            addTeardownBlock { @MainActor in
                archive.document.close()
                await archive.document.materializationCleanup?.value
                await archive.document.sessionCleanup?.value
                withExtendedLifetime(archive) {}
            }
        }
        let task = try ArchiveStageDiagnostics.observer.withValue({ event in
            if case .ended(_, .filterCompute, _) = event { computed.withLock { $0 = true } }
        }) { try request("a", on: controller, gate: gate) }
        try await scenarioWait { gate.isEntered }
        var finish: () -> Void = {}
        var password: Task<String, any Error>?
        var field: NSTextField?
        var editor: NSText?
        switch interaction {
        case "rename":
            controller.window?.makeKeyAndOrderFront(nil)
            controller.outlineView.beginRenaming(fixture.root.children[0], validate: { _ in nil }, commit: { _ in })
            field = try XCTUnwrap(controller.outlineView.renameField)
            editor = try XCTUnwrap(field?.currentEditor())
            finish = { controller.outlineView.cancelRenaming() }
        case "drag":
            controller.setDraggedNodesForTesting([fixture.root.children[0]])
            finish = { controller.setDraggedNodesForTesting([]) }
        case "preview":
            controller.window?.makeKeyAndOrderFront(nil)
            let panel = try XCTUnwrap(QLPreviewPanel.shared())
            controller.beginPreviewPanelControl(panel)
            panel.orderFront(nil)
            XCTAssertTrue(panel.isVisible)
            finish = { controller.endPreviewPanelControl(panel); panel.orderOut(nil) }
        case "password":
            controller.window?.makeKeyAndOrderFront(nil)
            password = Task { try await controller.requestPassword(.required) }
            try await scenarioWait { controller.passwordPrompt != nil }
            controller.searchField.stringValue = "ignored"
            controller.filterEntries(controller.searchField)
            XCTAssertEqual(controller.searchField.stringValue, controller.requestedFilterQuery)
            finish = { password?.cancel() }
        case "sheet":
            let window = try XCTUnwrap(controller.window), sheet = NSWindow()
            window.makeKeyAndOrderFront(nil)
            window.beginSheet(sheet, completionHandler: nil)
            finish = { window.endSheet(sheet); sheet.orderOut(nil) }
        default:
            let menu = try XCTUnwrap(interaction == "menu" ? controller.outlineView.menu :
                interaction == "blankMenu" ? controller.outlineView.blankAreaMenu : controller.outlineView.headerView?.menu)
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            finish = { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu) }
        }
        defer { finish() }
        gate.release()
        try await scenarioWait { computed.withLock { $0 } && controller.isFilterPendingVisible }
        XCTAssertEqual(controller.filterQuery, "", interaction)
        XCTAssertEqual(controller.filterSwapCountForTesting, 0, interaction)
        if interaction == "rename" {
            XCTAssertTrue(controller.outlineView.renameField === field)
            XCTAssertTrue(field?.currentEditor() === editor)
        }
        finish()
        finish = {}
        _ = try? await password?.value
        try await scenarioWait { controller.filterQuery == "a" }
        await task.value
        XCTAssertEqual(controller.filterSwapCountForTesting, 1, interaction)
    }

    @MainActor func testInitialDisplaysPrepareRequestedQueryOffMainInBothSaveModes() async throws {
        for behavior in [ArchivePreferences.SaveBehavior.immediate, .onSave] {
            let fixture = try DeferredSaveFixture(behavior: behavior), document = fixture.document
            addTeardownBlock { @MainActor in
                document.close()
                await document.undoCleanup?.value
                await document.materializationCleanup?.value
                await document.sessionCleanup?.value
                withExtendedLifetime(fixture) {}
            }
            let counter = ArchiveTestCounter()
            ArchiveTestCounters.mainThreadFilters.withValue(counter) { document.makeWindowControllers() }
            let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
            controller.setFilterQuery("a.txt")
            await document.waitForDeferredPreparationForTesting()
            XCTAssertEqual(paths(controller), ["a.txt"])
            XCTAssertEqual(controller.filterQuery, "a.txt")
            XCTAssertEqual(counter.value, 0)
            XCTAssertEqual(controller.preparedFilterMissesForTesting, 0)
            await controller.renameIndexTask?.value
        }
    }

    @MainActor func testAutomaticThresholdAndImmediateMutationReloadsNeverFilterOnMain() async throws {
        let files = (0..<25_000).map { ("d\($0 / 100)/file\($0).txt", "x") }
        let fixture = try DeferredSaveFixture(behavior: .immediate, files: files), document = fixture.document
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            withExtendedLifetime(fixture) {}
        }
        document.makeWindowControllers()
        await document.waitForDeferredPreparationForTesting()
        let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        let counter = ArchiveTestCounter()
        try await ArchiveTestCounters.mainThreadFilters.withValue(counter) {
            controller.setFilterQuery("file24999")
            await controller.filterTaskForTesting?.value
            XCTAssertEqual(controller.filterQuery, "file24999")
            XCTAssertEqual(counter.value, 0)
            fixture.store.preferences.showsHiddenFiles = true
            await controller.filterTaskForTesting?.value
            XCTAssertEqual(counter.value, 0)
            XCTAssertEqual(controller.filterSwapCountForTesting, 2)

            let original = "d249/file24999.txt", renamed = "d249/file24999-renamed.txt"
            _ = try await document.rename(fixture.node(original), to: "file24999-renamed.txt", progress: Progress())
            XCTAssertTrue(paths(controller).contains(renamed))
            XCTAssertEqual(counter.value, 0, "rename")
            document.undo(nil)
            await document.undoTask?.value
            XCTAssertTrue(paths(controller).contains(original))
            XCTAssertEqual(counter.value, 0, "undo rename")

            _ = try await document.remove([fixture.node(original)], progress: Progress())
            XCTAssertTrue(paths(controller).isEmpty)
            XCTAssertEqual(counter.value, 0, "delete")
            document.undo(nil)
            await document.undoTask?.value
            XCTAssertTrue(paths(controller).contains(original))
            XCTAssertEqual(counter.value, 0, "undo delete")

            let addition = try fixture.file("file24999-added.txt")
            _ = try await document.append(urls: [addition], to: "", progress: Progress())
            XCTAssertTrue(paths(controller).contains("file24999-added.txt"))
            XCTAssertEqual(counter.value, 0, "add")
            document.undo(nil)
            await document.undoTask?.value
            XCTAssertFalse(paths(controller).contains("file24999-added.txt"))
            XCTAssertEqual(counter.value, 0, "undo add")

            try fixture.original.write(to: fixture.archive, options: .atomic)
            try await document.reloadAfterMutation()
            XCTAssertTrue(paths(controller).contains(original))
            XCTAssertEqual(counter.value, 0, "external reload")
            XCTAssertEqual(controller.preparedFilterMissesForTesting, 0)
        }
        await controller.renameIndexTask?.value
    }

    // 旧名: M6bSearchTests
    @MainActor func testSearchTypingCostAt100kEntries() async throws {
        let defaults = try ArchivePreferencesTestDefaults()
        let controller = ArchiveWindowController(preferencesStore: ArchivePreferencesStore(defaults: defaults.defaults))
        defer { controller.close() }
        let entries = (0..<100_000).map { index in
            archiveColumnEntry("d\(index / 100)/file\(index).txt", index: index, size: 1)
        }
        let root = EntryNode.tree(from: entries)
        controller.display(root)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(controller.searchField))
        let editor = try XCTUnwrap(controller.searchField.currentEditor() as? NSTextView)
        let mode = controller.searchField.sendsSearchStringImmediately ? "before" : "after"
        XCTAssertFalse(controller.searchField.sendsSearchStringImmediately)
        XCTAssertFalse(controller.searchField.sendsWholeSearchString)
        for character in ["f", "i", "l", "e"] {
            let start = ContinuousClock.now
            editor.insertText(character, replacementRange: editor.selectedRange())
            // insertText は AppKit のキーイベント配送を行わないため、即時モードの action を再現する。
            if controller.searchField.sendsSearchStringImmediately {
                XCTAssertTrue(controller.searchField.sendAction(controller.searchField.action, to: controller.searchField.target))
            }
            print("SEARCH \(mode) entries=100000 key=\(character) ms=\(milliseconds(start.duration(to: .now))) query=\(controller.filterQuery)")
        }
        let start = ContinuousClock.now
        controller.filterEntries(controller.searchField)
        await controller.filterTaskForTesting?.value
        print("SEARCH \(mode) entries=100000 final-filter ms=\(milliseconds(start.duration(to: .now)))")
        XCTAssertEqual(controller.filterQuery, "file")
        XCTAssertEqual(controller.outlineView.numberOfRows, 101_000)
        controller.setFilterQuery("file99999")
        await controller.filterTaskForTesting?.value
        XCTAssertEqual(controller.outlineView.numberOfRows, 2)
        controller.setFilterQuery("")
        await controller.filterTaskForTesting?.value
        XCTAssertEqual(controller.outlineView.numberOfRows, 1_000)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
