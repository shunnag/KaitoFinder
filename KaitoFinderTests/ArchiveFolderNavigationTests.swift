import AppKit
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveFolderNavigationTests: XCTestCase {
    @MainActor private func interface(behavior: ArchivePreferences.SaveBehavior = .immediate,
                                      opening: ArchivePreferences.FolderOpening = .enter) async throws
        -> (DeferredSaveFixture, ArchiveWindowController) {
        try await folderNavigationInterface(behavior: behavior, opening: opening)
    }

    @MainActor private func paths(_ controller: ArchiveWindowController) -> [String] {
        let view = controller.outlineView
        return (0..<view.numberOfRows).compactMap { (view.item(atRow: $0) as? EntryNode)?.path }
    }

    @MainActor @discardableResult
    private func select(_ path: String, in controller: ArchiveWindowController) throws -> EntryNode {
        let view = controller.outlineView
        let row = try XCTUnwrap(paths(controller).firstIndex(of: path), path)
        view.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return try XCTUnwrap(view.item(atRow: row) as? EntryNode)
    }

    @MainActor private func enter(_ path: String, in controller: ArchiveWindowController) throws {
        try select(path, in: controller)
        controller.openEntry(nil)
        XCTAssertEqual(controller.currentFolderPath, path)
    }

    @MainActor func testEnterBackForwardEnclosingAndPathBar() async throws {
        let (_, controller) = try await interface()
        try enter("a", in: controller)
        XCTAssertEqual(paths(controller), ["a/b", "a/d.txt"])
        XCTAssertEqual(controller.pathControl.pathItems.map(\.title), ["original.zip", "a"])
        XCTAssertTrue(controller.navigationEnabled(#selector(ArchiveWindowController.goBack(_:))))
        XCTAssertFalse(controller.navigationEnabled(#selector(ArchiveWindowController.goForward(_:))))
        try enter("a/b", in: controller)
        XCTAssertEqual(paths(controller), ["a/b/c.txt"])
        controller.goBack(nil)
        XCTAssertEqual(controller.currentFolderPath, "a")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a/b"])
        controller.goBack(nil)
        XCTAssertEqual(controller.currentFolderPath, "")
        controller.goForward(nil)
        XCTAssertEqual(controller.currentFolderPath, "a")
        try enter("a/b", in: controller)
        XCTAssertTrue(controller.forwardStack.isEmpty)
        controller.goToEnclosingFolder(nil)
        XCTAssertEqual(controller.currentFolderPath, "a")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a/b"])
        let count = controller.backStack.count
        controller.selectPathItem(controller.pathControl.pathItems[1])
        XCTAssertEqual(controller.backStack.count, count)
        XCTAssertTrue(controller.selectedNodes.isEmpty)
        try enter("a/b", in: controller)
        controller.selectPathItem(controller.pathControl.pathItems[0])
        XCTAssertEqual(controller.currentFolderPath, "")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a"])
        let history = controller.backStack
        controller.goToEnclosingFolder(nil)
        XCTAssertEqual(controller.backStack, history)
    }

    @MainActor func testOpenMenuValidationAllowsASingleFolderInEnterMode() async throws {
        let (_, controller) = try await interface()
        let item = NSMenuItem(title: "", action: #selector(ArchiveWindowController.openEntry(_:)), keyEquivalent: "o")
        XCTAssertFalse(controller.validateMenuItem(item))
        let folder = try select("a", in: controller)
        XCTAssertTrue(folder.isDirectory)
        XCTAssertNil(controller.selectionOpenRefusal(skippingDirectories: true))
        XCTAssertTrue(controller.validateMenuItem(item))
        controller.openEntry(item)
        XCTAssertEqual(controller.currentFolderPath, "a")
    }

    // 旧名: M6bReviewTests
    @MainActor func testOpenValidationStopsAtFirstRefusalInLargeSelection() async throws {
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document
        defer { document.close() }
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        document.addWindowController(controller)
        let entries = [archiveColumnEntry("000-directory/", kind: .directory)] + (1..<100_000).map {
            archiveColumnEntry("file\($0).txt", index: $0, method: "stored")
        }
        controller.display(EntryNode.tree(from: entries), session: try XCTUnwrap(document.session))
        controller.outlineView.selectAll(nil)
        XCTAssertEqual(controller.outlineView.numberOfSelectedRows, 100_000)
        let start = ContinuousClock.now
        let item = NSMenuItem(title: "", action: #selector(ArchiveWindowController.togglePreviewPanel(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item))
        let elapsed = start.duration(to: .now)
        print("M6b VALIDATION selected=100000 first-refusal duration=\(elapsed)")
        XCTAssertEqual(item.toolTip, EntryReadCapability.Refusal.directory.message())
        XCTAssertLessThan(elapsed, .milliseconds(200))
        XCTAssertNil(controller.selectionOpenRefusal(skippingDirectories: true))
        let open = NSMenuItem(title: "", action: #selector(ArchiveWindowController.openEntry(_:)), keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(open))
        let rename = NSMenuItem(title: "", action: #selector(ArchiveWindowController.renameEntry(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(rename))
    }

    @MainActor func testToolbarControlAndTextSubitemsNavigateAndValidate() async throws {
        let (_, controller) = try await interface()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        let group = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "navigation" } as? ArchiveNavigationToolbarItemGroup)
        let segments = try XCTUnwrap(group.view as? NSSegmentedControl)
        XCTAssertTrue(segments.target === controller)
        XCTAssertEqual(segments.action, #selector(ArchiveWindowController.navigateFromToolbar(_:)))
        XCTAssertEqual(segments.trackingMode, .momentary)

        func check(_ group: ArchiveNavigationToolbarItemGroup, back: Bool, forward: Bool,
                   file: StaticString = #filePath, line: UInt = #line) throws {
            group.validate()
            let control = try XCTUnwrap(group.view as? NSSegmentedControl, file: file, line: line)
            XCTAssertEqual(group.isEnabled, back || forward, file: file, line: line)
            XCTAssertEqual(control.isEnabled, back || forward, file: file, line: line)
            XCTAssertEqual(group.subitems.map(\.isEnabled), [back, forward], file: file, line: line)
            XCTAssertEqual((0..<control.segmentCount).map { control.isEnabled(forSegment: $0) },
                           [back, forward], file: file, line: line)
        }

        try check(group, back: false, forward: false)
        try enter("a", in: controller)
        for mode: NSToolbar.DisplayMode in [.iconOnly, .iconAndLabel, .labelOnly] {
            toolbar.displayMode = mode
            try check(group, back: true, forward: false)
            // momentary の選択値は performClick の action 中にだけ読み取れる。
            segments.selectedSegment = 0
            segments.performClick(nil)
            XCTAssertEqual(controller.currentFolderPath, "")
            try check(group, back: false, forward: true)
            segments.selectedSegment = 1
            segments.performClick(nil)
            XCTAssertEqual(controller.currentFolderPath, "a")
        }
        // ラベルだけの表示で AppKit が使う subitem も、個別の action を持つ。
        try check(group, back: true, forward: false)
        for (index, path) in [(0, ""), (1, "a")] {
            let item = group.subitems[index]
            XCTAssertTrue(item.isEnabled)
            XCTAssertTrue(item.target === controller)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(controller.currentFolderPath, path)
            try check(group, back: index == 1, forward: index == 0)
        }
        controller.displayLocked()
        XCTAssertFalse(controller.validateToolbarItem(group))
        try check(group, back: false, forward: false)

        let unopened = ArchiveWindowController()
        defer { unopened.close() }
        let emptyToolbar = try XCTUnwrap(unopened.window?.toolbar)
        let emptyGroup = try XCTUnwrap(emptyToolbar.items.first { $0.itemIdentifier.rawValue == "navigation" } as? ArchiveNavigationToolbarItemGroup)
        XCTAssertFalse(unopened.validateToolbarItem(emptyGroup))
        try check(emptyGroup, back: false, forward: false)
    }

    @MainActor func testExpandModeKeepsOutlineOpeningAndParentSelection() async throws {
        let (_, controller) = try await interface(opening: .expand)
        let a = try select("a", in: controller)
        controller.openEntry(nil)
        XCTAssertTrue(controller.outlineView.isItemExpanded(a))
        XCTAssertEqual(controller.currentFolderPath, "")
        try select("a/b", in: controller)
        controller.goToEnclosingFolder(nil)
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a"])
        controller.goToEnclosingFolder(nil)
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a"])
        XCTAssertTrue(controller.backStack.isEmpty)
        XCTAssertFalse(controller.navigate(to: a, history: .push))
    }

    @MainActor func testMultipleFoldersExpandInPlaceAndInvalidRenameDoesNotConsumeHistory() async throws {
        let (fixture, controller) = try await interface()
        fixture.store.preferences.showsHiddenFiles = true
        let a = try select("a", in: controller), hidden = try select(".hidden", in: controller)
        let view = controller.outlineView
        view.selectRowIndexes(IndexSet([view.row(forItem: a), view.row(forItem: hidden)]), byExtendingSelection: false)
        controller.openEntry(nil)
        XCTAssertEqual(controller.currentFolderPath, "")
        XCTAssertTrue(view.isItemExpanded(a))
        XCTAssertTrue(view.isItemExpanded(hidden))
        try enter("a", in: controller)
        try select("a/d.txt", in: controller)
        controller.renameEntry(nil)
        let field = try XCTUnwrap(view.renameField)
        field.stringValue = "/"
        let history = controller.backStack
        controller.goBack(nil)
        XCTAssertEqual(controller.currentFolderPath, "a")
        XCTAssertEqual(controller.backStack, history)
        XCTAssertTrue(view.isRenaming)
        view.cancelRenaming()
    }

    @MainActor func testSearchUsesArchiveRootAndClearingRestoresFolderSelection() async throws {
        let (_, controller) = try await interface()
        try enter("a", in: controller)
        try select("a/d.txt", in: controller)
        controller.setFilterQuery("c")
        XCTAssertEqual(paths(controller), ["a", "a/b", "a/b/c.txt"])
        XCTAssertEqual(controller.currentFolderPath, "a")
        controller.setFilterQuery("")
        XCTAssertEqual(paths(controller), ["a/b", "a/d.txt"])
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a/d.txt"])
        controller.setFilterQuery("c")
        try enter("a/b", in: controller)
        XCTAssertEqual(controller.searchField.stringValue, "")
        XCTAssertEqual(controller.filterQuery, "")
        XCTAssertEqual(paths(controller), ["a/b/c.txt"])
        controller.goBack(nil)
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a/d.txt"])
    }

    @MainActor func testNavigationCancelsAnOutstandingAsynchronousSearch() async throws {
        let (_, controller) = try await interface(), gate = ScenarioGate()
        defer { gate.release() }
        try enter("a", in: controller)
        ArchiveWindowController.filterExecution.withValue(.asynchronous) {
            EntryTreeFilter.computeWillStartForTesting.withValue({ gate.pauseOnce() }) {
                controller.setFilterQuery("e")
            }
        }
        let task = try XCTUnwrap(controller.filterTaskForTesting)
        try await scenarioWait { gate.isEntered }
        try enter("a/b", in: controller)
        gate.release()
        await task.value
        XCTAssertEqual(controller.filterQuery, "")
        XCTAssertEqual(controller.requestedFilterQuery, "")
        XCTAssertEqual(controller.filterSwapCountForTesting, 0)
        XCTAssertEqual(paths(controller), ["a/b/c.txt"])
    }

    @MainActor func testReloadFallsBackToTheNearestSurvivingAncestorWithoutChangingHistory() async throws {
        let (fixture, controller) = try await interface()
        try enter("a", in: controller)
        try enter("a/b", in: controller)
        let history = controller.backStack
        for (files, expected) in [(["a/d.txt", "e.txt"], "a"), (["e.txt"], "")] {
            let previous = controller.currentFolderPath
            let replacement = fixture.directory.url.appendingPathComponent(UUID().uuidString + ".zip")
            let writer = try ArchiveWriter.create(url: replacement, format: .zip)
            for name in files { try writer.add(data: Data("replacement".utf8), as: name) }
            try writer.finish()
            try Data(contentsOf: replacement).write(to: fixture.archive, options: .atomic)
            var events: [ArchiveWindowController.NavigationEvent] = []
            try await ArchiveWindowController.navigationObserver.withValue({ events.append($0) }) {
                try await fixture.document.reloadAfterMutation()
            }
            XCTAssertTrue(events.contains(.fellBack(from: previous, to: expected)))
            XCTAssertEqual(controller.currentFolderPath, expected)
            XCTAssertEqual(controller.backStack, history)
        }
        controller.goBack(nil)
        XCTAssertTrue(controller.backStack.isEmpty, "A removed folder is discarded when traversing history")
    }

    @MainActor func testRenamingAncestorFollowsFolderAndRewritesHistoryButUndoFallsBack() async throws {
        let (fixture, controller) = try await interface()
        try enter("a", in: controller)
        try enter("a/b", in: controller)
        controller.setFilterQuery("a")
        try select("a", in: controller)
        controller.renameEntry(nil)
        let field = try XCTUnwrap(controller.outlineView.renameField)
        field.stringValue = "x"
        XCTAssertTrue(controller.outlineView.commitRenaming())
        await controller.extractionTask?.value
        XCTAssertEqual(controller.currentFolderPath, "x/b")
        XCTAssertEqual(controller.backStack, ["", "x"])
        XCTAssertNotNil(controller.folderViewStates["x"])
        XCTAssertNil(controller.folderViewStates["a"])
        controller.setFilterQuery("")
        XCTAssertEqual(paths(controller), ["x/b/c.txt"])
        fixture.document.undo(nil)
        await fixture.document.undoTask?.value
        XCTAssertEqual(controller.currentFolderPath, "")
        XCTAssertTrue(paths(controller).contains("a"))
    }

    @MainActor func testMovingAncestorFollowsFolderAndHistory() async throws {
        let (fixture, controller) = try await interface()
        fixture.store.preferences.showsHiddenFiles = true
        try enter("a", in: controller)
        try enter("a/b", in: controller)
        controller.setFilterQuery("a")
        let a = try select("a", in: controller)
        controller.setFilterQuery("")
        controller.setFilterQuery(".")
        let hidden = try select(".hidden", in: controller)
        controller.setDraggedNodesForTesting([a])
        let info = TestDraggingInfo(urls: [], window: controller.window, location: .zero)
        defer { info.draggingPasteboard.releaseGlobally() }
        info.draggingSource = controller.outlineView
        info.draggingSourceOperationMask = .move
        XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: hidden, childIndex: -1))
        controller.setDraggedNodesForTesting([])
        await controller.extractionTask?.value
        XCTAssertEqual(controller.currentFolderPath, ".hidden/a/b")
        XCTAssertEqual(controller.backStack, ["", ".hidden/a"])
        controller.setFilterQuery("")
        XCTAssertEqual(paths(controller), [".hidden/a/b/c.txt"])
        fixture.document.undo(nil)
        await fixture.document.undoTask?.value
        XCTAssertEqual(controller.currentFolderPath, ".hidden")
    }

    @MainActor func testDeletingAndUndoingAFileKeepsTheCurrentFolder() async throws {
        let (fixture, controller) = try await interface()
        // 実体のある空フォルダが削除後も残る。
        _ = try await fixture.document.createFolder(in: "a/b", baseName: "empty", progress: Progress())
        try enter("a", in: controller)
        try enter("a/b", in: controller)
        try select("a/b/c.txt", in: controller)
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(controller.currentFolderPath, "a/b")
        XCTAssertFalse(paths(controller).contains("a/b/c.txt"))
        fixture.document.undo(nil)
        await fixture.document.undoTask?.value
        XCTAssertEqual(controller.currentFolderPath, "a/b")
        XCTAssertTrue(paths(controller).contains("a/b/c.txt"))
    }

    @MainActor func testHidingCurrentFolderFallsBackEvenWhileSearchIsApplied() async throws {
        let (fixture, controller) = try await interface()
        for query in ["", "f"] {
            fixture.store.preferences.showsHiddenFiles = true
            controller.setFilterQuery("")
            try enter(".hidden", in: controller)
            controller.setFilterQuery(query)
            fixture.store.preferences.showsHiddenFiles = false
            XCTAssertEqual(controller.currentFolderPath, "")
            controller.setFilterQuery("")
            XCTAssertEqual(paths(controller), ["a", "e.txt"])
        }
    }

    @MainActor func testDiscardingPendingFolderFallsBackToArchiveRoot() async throws {
        let (fixture, controller) = try await interface(behavior: .onSave)
        _ = try await fixture.document.createFolder(in: "", baseName: "n", progress: Progress())
        try enter("n", in: controller)
        try await fixture.document.revertPending()
        XCTAssertEqual(controller.currentFolderPath, "")
        XCTAssertEqual(paths(controller), ["a", "e.txt"])
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testPasteUsesDisplayedLocationInBothSaveModes() async throws {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
        for behavior in ArchivePreferences.SaveBehavior.allCases {
            let (fixture, controller) = try await interface(behavior: behavior)
            try enter("a", in: controller)
            let source = try fixture.file("pasted.txt")
            pasteboard.clearContents()
            guard pasteboard.writeObjects([source as NSURL]) else {
                throw XCTSkip("The pasteboard service is unavailable in this test host")
            }
            controller.paste(nil)
            await controller.extractionTask?.value
            let names = try await fixture.document.projectedEntries().map(\.name)
            XCTAssertTrue(names.contains("a/pasted.txt"))
            if behavior == .onSave { XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original) }
        }
    }

    @MainActor func testNewFolderUsesDisplayedLocationWithoutExpandingTheDisplayRoot() async throws {
        for behavior in ArchivePreferences.SaveBehavior.allCases {
            let (fixture, controller) = try await interface(behavior: behavior)
            try enter("a", in: controller)
            for fromBlankMenu in [false, true] {
                controller.outlineView.deselectAll(nil)
                let item = controller.outlineView.blankAreaMenu.items.first { $0.action == #selector(ArchiveWindowController.newFolder(_:)) }
                XCTAssertNotNil(item)
                controller.newFolder(fromBlankMenu ? item : nil)
                await controller.extractionTask?.value
                let created = try XCTUnwrap(controller.selectedNodes.first)
                XCTAssertEqual(created.parent?.path, "a")
                XCTAssertTrue(controller.outlineView.isRenaming)
                let displayed = try XCTUnwrap(created.parent)
                XCTAssertFalse(controller.outlineView.isItemExpanded(displayed))
                XCTAssertEqual(controller.outlineView.numberOfRows, displayed.children.count)
                controller.outlineView.cancelRenaming()
                let names = try await fixture.document.projectedEntries().map(\.name)
                XCTAssertTrue(names.contains(created.path + "/"))
            }
            if behavior == .onSave { XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original) }
        }
    }

    @MainActor func testAddPanelCapturesLocationBeforeNavigationAndSearchImportsAtRoot() async throws {
        let (fixture, controller) = try await interface()
        try enter("a", in: controller)
        var complete: (([URL]) -> Void)?
        controller.addFilesPanelForTesting = { complete = $0 }
        controller.addFiles(nil)
        controller.goToEnclosingFolder(nil)
        try XCTUnwrap(complete)([fixture.file("captured.txt")])
        await controller.extractionTask?.value
        let captured = try await fixture.document.projectedEntries()
        XCTAssertTrue(captured.contains { $0.name == "a/captured.txt" })
        try enter("a", in: controller)
        controller.setFilterQuery("c")
        controller.addFiles(nil)
        try XCTUnwrap(complete)([fixture.file("searched.txt")])
        await controller.extractionTask?.value
        let searched = try await fixture.document.projectedEntries()
        XCTAssertTrue(searched.contains { $0.name == "searched.txt" })
        XCTAssertEqual(controller.currentFolderPath, "a")
    }

    @MainActor func testStaleAddPanelRefusesDeletedDestinationBeforeStartingImport() async throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw XCTSkip("An application test host is required for the failure sheet") }
        let (fixture, controller) = try await interface()
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        try enter("a", in: controller)
        var complete: (([URL]) -> Void)?
        controller.addFilesPanelForTesting = { complete = $0 }
        controller.addFiles(nil)
        let replacement = fixture.directory.url.appendingPathComponent("replacement.zip")
        let writer = try ArchiveWriter.create(url: replacement, format: .zip)
        try writer.add(data: Data("E".utf8), as: "e.txt")
        try writer.finish()
        try Data(contentsOf: replacement).write(to: fixture.archive, options: .atomic)
        try await fixture.document.reloadAfterMutation()
        let before = try ScenarioFixture.digest(fixture.archive), generation = fixture.document.generation
        try XCTUnwrap(complete)([fixture.file("refused.txt")])
        XCTAssertNil(controller.extractionTask)
        XCTAssertFalse(fixture.document.hasWorkInFlight)
        XCTAssertEqual(fixture.document.generation, generation)
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        try await scenarioWait { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        defer { window.endSheet(sheet); sheet.orderOut(nil) }
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        let reason = String(localized: "追加先フォルダが見つからないか、ファイルと衝突しています: \("a")。")
        XCTAssertTrue(labels(try XCTUnwrap(sheet.contentView)).contains(ArchiveAlertText.informativeText(reason)))
    }

    @MainActor func testExtractionStillUsesTheWholeArchive() async throws {
        let (_, controller) = try await interface()
        let a = try select("a", in: controller)
        let rootChildren = try XCTUnwrap(a.parent).children
        try enter("a", in: controller)
        var calls = 0
        controller.extractionDestinationHandler = { nodes in
            calls += 1
            XCTAssertEqual(nodes.map(ObjectIdentifier.init), rootChildren.map(ObjectIdentifier.init))
        }
        controller.extractAll(nil)
        controller.extractFromToolbar(nil)
        XCTAssertEqual(calls, 2)
    }

    @MainActor func testPreferenceChangesResetEveryOpenWindowAndToolbarIgnoresTextFocus() async throws {
        let (fixture, first) = try await interface()
        let second = ArchiveWindowController(preferencesStore: fixture.store)
        defer { second.close() }
        let session = try XCTUnwrap(fixture.document.session)
        second.display(EntryNode.tree(from: await session.entries()), session: session)
        try enter("a", in: first)
        try enter("a", in: second)
        let toolbar = try XCTUnwrap(first.window?.toolbar)
        let group = try XCTUnwrap(first.toolbar(toolbar, itemForItemIdentifier: .init("navigation"), willBeInsertedIntoToolbar: true) as? ArchiveNavigationToolbarItemGroup)
        XCTAssertTrue(group.target === first)
        let segments = try XCTUnwrap(group.view as? NSSegmentedControl)
        XCTAssertEqual(segments.segmentCount, 2)
        XCTAssertTrue(segments.target === first)
        XCTAssertEqual(segments.action, #selector(ArchiveWindowController.navigateFromToolbar(_:)))
        for (index, label) in [String(localized: "戻る"), String(localized: "進む")].enumerated() {
            XCTAssertEqual(group.subitems[index].toolTip, label)
            XCTAssertEqual(segments.toolTip(forSegment: index), label)
            XCTAssertEqual(segments.image(forSegment: index)?.accessibilityDescription, label)
        }
        group.validate()
        XCTAssertTrue(group.subitems[0].isEnabled)
        XCTAssertFalse(group.subitems[1].isEnabled)
        let text = NSTextView()
        first.window?.contentView?.addSubview(text)
        first.window?.makeFirstResponder(text)
        XCTAssertTrue(first.window?.firstResponder is NSText)
        for action in [#selector(ArchiveWindowController.goBack(_:)), #selector(ArchiveWindowController.goForward(_:)),
                       #selector(ArchiveWindowController.goToEnclosingFolder(_:))] {
            XCTAssertFalse(first.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        }
        group.validate()
        XCTAssertTrue(group.subitems[0].isEnabled)
        segments.selectedSegment = 0
        segments.performClick(nil)
        XCTAssertEqual(first.currentFolderPath, "")
        try enter("a", in: first)
        fixture.store.preferences.folderOpening = .expand
        for controller in [first, second] {
            XCTAssertEqual(controller.currentFolderPath, "")
            XCTAssertTrue(controller.backStack.isEmpty)
            XCTAssertTrue(controller.forwardStack.isEmpty)
            XCTAssertTrue(controller.folderViewStates.isEmpty)
        }
        fixture.store.preferences.folderOpening = .enter
        try enter("a", in: first)
        try enter("a", in: second)
    }

    @MainActor func testHistoryAndFolderStateLimitsAndForeignNodes() async throws {
        let (_, controller) = try await interface()
        let root = EntryNode.tree(from: (0..<120).map { archiveColumnEntry("d\($0)/f.txt", index: $0) })
        controller.display(root)
        for folder in root.children { XCTAssertTrue(controller.navigate(to: folder, history: .push)) }
        XCTAssertEqual(controller.backStack.count, 100)
        XCTAssertEqual(controller.folderViewStates.count, 32)
        XCTAssertNil(controller.folderViewStates[""])
        for _ in 0..<100 { controller.goBack(nil) }
        XCTAssertEqual(controller.forwardStack.count, 100)
        XCTAssertTrue(controller.backStack.isEmpty)
        controller.goForward(nil)
        let foreign = EntryNode.tree(from: [archiveColumnEntry("foreign/file.txt")])
        XCTAssertFalse(controller.navigate(to: foreign.children[0], history: .push))
        let history = controller.backStack
        controller.displayLocked()
        XCTAssertFalse(history.isEmpty)
        XCTAssertEqual(controller.currentFolderPath, "")
        XCTAssertTrue(controller.backStack.isEmpty)
        XCTAssertTrue(controller.folderViewStates.isEmpty)
        XCTAssertFalse(controller.navigate(to: root.children[0], history: .push))
    }

    @MainActor func testBackRestoresExpansionSelectionAndScroll() async throws {
        let (_, controller) = try await interface()
        let root = EntryNode.tree(from: (0..<200).map { archiveColumnEntry("a/d\($0)/f.txt", index: $0) }
            + [archiveColumnEntry("other/file.txt", index: 200)])
        controller.display(root)
        try enter("a", in: controller)
        let selected = try select("a/d50", in: controller)
        controller.outlineView.expandItem(selected)
        try select("a/d50/f.txt", in: controller)
        controller.outlineView.scrollRowToVisible(controller.outlineView.selectedRow)
        let visible = controller.outlineView.rows(in: controller.outlineView.visibleRect)
        let top = controller.outlineView.item(atRow: visible.location) as? EntryNode
        XCTAssertTrue(controller.navigate(to: try XCTUnwrap(root.nodes(at: "other").first), history: .push))
        controller.goBack(nil)
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a/d50/f.txt"])
        XCTAssertTrue(controller.outlineView.isItemExpanded(selected))
        let restored = controller.outlineView.rows(in: controller.outlineView.visibleRect)
        XCTAssertEqual((controller.outlineView.item(atRow: restored.location) as? EntryNode)?.path, top?.path)
    }
}
