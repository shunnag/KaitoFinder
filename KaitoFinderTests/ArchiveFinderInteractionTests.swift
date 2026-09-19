import AppKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveFinderInteractionTests: XCTestCase {
    @MainActor private func interface() async throws -> (ArchiveDocument, ArchiveWindowController, ArchivePreferencesStore) {
        guard ProcessInfo.processInfo.environment["KAITOFINDER_FINDER_INPUT_REQUEST"] != nil else {
            throw XCTSkip("Run Tools/verify_finder_interactions.py for native Finder-style input")
        }
        preserveArchiveWindowFrame()
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('first.txt', b'First')
            z.writestr('second.txt', b'Second')
            z.writestr('folder.ext/nested.txt', b'Nested')
        """)
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let document = ArchiveDocument()
        try document.read(from: fixture.archive, ofType: "public.zip-archive")
        document.fileURL = fixture.archive
        let session = try XCTUnwrap(document.session)
        let controller = ArchiveWindowController(preferencesStore: store)
        document.addWindowController(controller)
        controller.display(EntryNode.tree(from: await session.entries()), session: session,
                           materializationController: document.materializationController())
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1040, height: 600))
        controller.outlineView.autosaveTableColumns = false
        controller.outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate()
        try await nativeInput(window, events: [])
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.outlineView)
        try await scenarioWait { window.isKeyWindow && NSApp.isActive }
        window.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            document.close()
            await controller.extractionTask?.value
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            withExtendedLifetime((fixture, suite)) {}
        }
        return (document, controller, store)
    }

    @MainActor private func row(_ name: String, in view: ArchiveOutlineView) throws -> Int {
        try XCTUnwrap((0..<view.numberOfRows).first { (view.item(atRow: $0) as? EntryNode)?.name == name })
    }

    @MainActor private func point(_ name: String, in view: ArchiveOutlineView, part: String = "name") throws -> NSPoint {
        let row = try row(name, in: view)
        let column = try XCTUnwrap(view.tableColumns.firstIndex { $0.identifier.rawValue == (part == "size" ? "size" : "name") })
        let cell = try XCTUnwrap(view.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)
        let target = try XCTUnwrap(part == "icon" ? cell.imageView : cell.textField)
        let x = part == "blank" ? target.bounds.maxX - 8 : min(12, target.bounds.midX)
        return target.convert(NSPoint(x: x, y: target.bounds.midY), to: nil)
    }

    @MainActor private func click(_ name: String, in view: ArchiveOutlineView, count: Int = 1,
                                  modifiers: NSEvent.ModifierFlags = [], part: String = "name") async throws {
        let window = try XCTUnwrap(view.window), point = try point(name, in: view, part: part)
        let screen = window.convertPoint(toScreen: point)
        try await nativeInput(window, events: ["down", "up"].map {
            ["type": $0, "x": screen.x, "y": screen.y, "count": count, "modifiers": modifiers.rawValue]
        })
    }

    @MainActor private func nativeInput(_ window: NSWindow, events: [[String: Any]], capture: String? = nil) async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["KAITOFINDER_FINDER_INPUT_REQUEST"])
        let request = URL(fileURLWithPath: path), done = request.deletingPathExtension().appendingPathExtension("done")
        var value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "bundle": try XCTUnwrap(Bundle.main.bundleIdentifier), "window": window.windowNumber, "events": events]
        if let capture { value["capture"] = capture }
        try JSONSerialization.data(withJSONObject: value).write(to: request, options: .atomic)
        try await scenarioWait { FileManager.default.fileExists(atPath: done.path) }
        try FileManager.default.removeItem(at: done)
    }

    @MainActor private func waitForClick() async throws {
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15))
    }

    @MainActor func testSelectedFilenameClickRenamesPreservesExtensionAndCanUndo() async throws {
        let (document, controller, _) = try await interface(), view = controller.outlineView
        try await click("first.txt", in: view)
        try await waitForClick()
        XCTAssertFalse(view.isRenaming, "The first click only selects")
        XCTAssertEqual(controller.selectedNodes.map(\.name), ["first.txt"])
        try await click("first.txt", in: view)
        try await scenarioWait { view.isRenaming }
        let editor = try XCTUnwrap(view.renameField?.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 5))
        try await nativeInput(XCTUnwrap(controller.window), events: [], capture: "rename-selected-name")
        editor.insertText("renamed", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        await controller.extractionTask?.value
        XCTAssertFalse(view.isRenaming)
        XCTAssertEqual(controller.selectedNodes.map(\.name), ["renamed.txt"])
        XCTAssertEqual(try ArchiveReader.open(url: XCTUnwrap(document.fileURL)).entries.map(\.name).sorted(),
                       ["folder.ext/nested.txt", "renamed.txt", "second.txt"])
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertEqual(try ArchiveReader.open(url: XCTUnwrap(document.fileURL)).entries.map(\.name).sorted(),
                       ["first.txt", "folder.ext/nested.txt", "second.txt"])
    }

    @MainActor func testDoubleClickOpensFolderWithoutStartingRename() async throws {
        let (_, controller, _) = try await interface(), view = controller.outlineView
        let row = try row("folder.ext", in: view), folder = try XCTUnwrap(view.item(atRow: row) as? EntryNode)
        view.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try await click("folder.ext", in: view)
        try await click("folder.ext", in: view, count: 2)
        try await waitForClick()
        XCTAssertTrue(view.isItemExpanded(folder))
        XCTAssertFalse(view.isRenaming)
    }

    @MainActor func testIconBlankColumnAndModifiedClicksDoNotRename() async throws {
        let (_, controller, _) = try await interface(), view = controller.outlineView
        for part in ["icon", "blank", "size"] {
            view.selectRowIndexes(IndexSet(integer: try row("first.txt", in: view)), byExtendingSelection: false)
            try await click("first.txt", in: view, part: part)
            try await waitForClick()
            XCTAssertFalse(view.isRenaming, part)
        }
        for modifier in [NSEvent.ModifierFlags.command, .shift, .option] {
            view.selectRowIndexes(IndexSet(integer: try row("first.txt", in: view)), byExtendingSelection: false)
            try await click("first.txt", in: view, modifiers: modifier)
            try await waitForClick()
            XCTAssertFalse(view.isRenaming, "\(modifier)")
        }
    }

    @MainActor func testMultipleSelectionClickOnlySelectsAndLegacySettingKeepsReturnRename() async throws {
        let (_, controller, store) = try await interface(), view = controller.outlineView
        view.selectRowIndexes(IndexSet([try row("first.txt", in: view), try row("second.txt", in: view)]), byExtendingSelection: false)
        try await click("first.txt", in: view)
        try await waitForClick()
        XCTAssertFalse(view.isRenaming)
        store.preferences.renamesOnClick = false
        XCTAssertFalse(view.renamesOnClick)
        try await click("first.txt", in: view)
        try await waitForClick()
        XCTAssertFalse(view.isRenaming)
        XCTAssertTrue(view.handleEntryKey("\r", modifiers: []))
        XCTAssertNotNil(view.renameField?.currentEditor())
        view.cancelRenaming()
        store.preferences.renamesOnClick = true
        try await click("first.txt", in: view)
        try await scenarioWait { view.isRenaming }
    }

    @MainActor func testPendingClickDoesNotRenameAfterSelectionSortFilterFocusOrPreferenceChange() async throws {
        let (_, controller, store) = try await interface(), view = controller.outlineView
        for action in ["selection", "sort", "filter", "focus", "setting", "menu", "reload", "close"] {
            controller.setFilterQuery("")
            store.preferences.renamesOnClick = true
            controller.window?.makeFirstResponder(view)
            view.selectRowIndexes(IndexSet(integer: try row("first.txt", in: view)), byExtendingSelection: false)
            try await click("first.txt", in: view)
            switch action {
            case "selection":
                view.selectRowIndexes(IndexSet(integer: try row("second.txt", in: view)), byExtendingSelection: false)
                view.selectRowIndexes(IndexSet(integer: try row("first.txt", in: view)), byExtendingSelection: false)
            case "sort": view.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
            case "filter": controller.setFilterQuery("first")
            case "focus": controller.window?.makeFirstResponder(controller.searchField)
            case "setting": store.preferences.renamesOnClick = false
            case "menu": _ = view.contextMenu(forRow: try row("first.txt", in: view))
            case "reload": view.reloadData()
            default: controller.window?.orderOut(nil)
            }
            try await waitForClick()
            XCTAssertFalse(view.isRenaming, action)
        }
    }

    @MainActor func testRenameSelectionHandlesFoldersHiddenNamesAndUTF16() {
        for (name, directory, selected) in [
            ("photo.jpg", false, "photo"), ("README", false, "README"), (".gitignore", false, ".gitignore"),
            (".config.json", false, ".config"), ("旅行📷.png", false, "旅行📷"), ("folder.ext", true, "folder.ext")
        ] {
            let range = ArchiveOutlineView.renameSelectionRange(name: name, isDirectory: directory)
            XCTAssertEqual((name as NSString).substring(with: range), selected)
        }
    }

    @MainActor func testCommandArrowKeysOpenFoldersAndSelectTheirParent() async throws {
        let (_, controller, _) = try await interface(), view = controller.outlineView
        let window = try XCTUnwrap(controller.window)
        func press(_ key: Int) async throws {
            try await nativeInput(window, events: ["keyDown", "keyUp"].map {
                ["type": $0, "key": key, "modifiers": NSEvent.ModifierFlags.command.rawValue]
            })
        }
        let folderRow = try row("folder.ext", in: view), folder = try XCTUnwrap(view.item(atRow: folderRow) as? EntryNode)
        view.selectRowIndexes(IndexSet(integer: folderRow), byExtendingSelection: false)
        XCTAssertTrue(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(ArchiveWindowController.openEntry(_:)), keyEquivalent: "o")))
        try await press(125)
        XCTAssertTrue(view.isItemExpanded(folder))
        XCTAssertNil(controller.failureAlert)
        view.selectRowIndexes(IndexSet(integer: try row("nested.txt", in: view)), byExtendingSelection: false)
        try await press(126)
        XCTAssertEqual(controller.selectedNodes.map(\.name), ["folder.ext"])
        try await press(126)
        XCTAssertEqual(controller.selectedNodes.map(\.name), ["folder.ext"], "The archive root is the navigation boundary")
        var opens = 0
        view.openSelection = { opens += 1 }
        view.selectRowIndexes(IndexSet(integer: try row("first.txt", in: view)), byExtendingSelection: false)
        try await press(125)
        XCTAssertEqual(opens, 1)
        XCTAssertFalse(view.handleEntryKey("\u{f701}", modifiers: [.command, .option]))
    }

    @MainActor func testFolderClickSelectsWholeNameAndEscapeDoesNotChangeArchive() async throws {
        let (document, controller, _) = try await interface(), view = controller.outlineView
        view.selectRowIndexes(IndexSet(integer: try row("folder.ext", in: view)), byExtendingSelection: false)
        try await click("folder.ext", in: view)
        try await scenarioWait { view.isRenaming }
        let editor = try XCTUnwrap(view.renameField?.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 10))
        editor.insertText("changed", replacementRange: editor.selectedRange())
        let window = try XCTUnwrap(controller.window)
        try await nativeInput(window, events: [["type": "keyDown", "key": 53], ["type": "keyUp", "key": 53]])
        try await scenarioWait { !view.isRenaming }
        XCTAssertEqual(controller.selectedNodes.map(\.name), ["folder.ext"])
        XCTAssertEqual(document.generation, 0)
    }

    @MainActor func testDraggingSelectedFilenameDoesNotStartRename() async throws {
        let (document, controller, _) = try await interface(), view = controller.outlineView
        let window = try XCTUnwrap(controller.window)
        view.selectRowIndexes(IndexSet(integer: try row("first.txt", in: view)), byExtendingSelection: false)
        let point = try point("first.txt", in: view), screen = window.convertPoint(toScreen: point)
        let steps = (0...8).map { step -> [String: Any] in
            ["type": step == 0 ? "down" : step == 8 ? "up" : "drag", "x": screen.x + Double(step) * 2, "y": screen.y]
        }
        try await nativeInput(window, events: steps)
        try await waitForClick()
        XCTAssertFalse(view.isRenaming)
        XCTAssertEqual(document.generation, 0)
    }

    @MainActor func testClickToActivateAnotherWindowDoesNotRename() async throws {
        let (_, controller, _) = try await interface(), view = controller.outlineView
        let window = try XCTUnwrap(controller.window)
        view.selectRowIndexes(IndexSet(integer: try row("first.txt", in: view)), byExtendingSelection: false)
        let other = NSWindow(contentRect: NSRect(x: window.frame.minX + 100, y: window.frame.minY + 40,
                                                 width: 250, height: 100),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.tabbingMode = .disallowed
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        XCTAssertFalse(window.isKeyWindow)
        try await click("first.txt", in: view)
        try await waitForClick()
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertFalse(view.isRenaming, "A click to activate a window must not rename its existing selection")
    }

    @MainActor func testSettingsSwitchUpdatesAllOpenArchiveWindows() async throws {
        let (_, first, store) = try await interface()
        let second = ArchiveWindowController(preferencesStore: store)
        defer { second.close() }
        let preferences = PreferencesWindowController(store: store)
        defer { preferences.close() }
        XCTAssertTrue(first.outlineView.renamesOnClick)
        XCTAssertTrue(second.outlineView.renamesOnClick)
        preferences.showWindow(nil)
        let window = try XCTUnwrap(preferences.window)
        window.setFrameAutosaveName("")
        window.makeKeyAndOrderFront(nil)
        try await nativeInput(window, events: [], capture: "finder-rename-setting")
        preferences.renamesOnClickCheckbox.performClick(nil)
        XCTAssertFalse(first.outlineView.renamesOnClick)
        XCTAssertFalse(second.outlineView.renamesOnClick)
        preferences.renamesOnClickCheckbox.performClick(nil)
        XCTAssertTrue(first.outlineView.renamesOnClick)
        XCTAssertTrue(second.outlineView.renamesOnClick)
    }

    @MainActor func testQuickLookDoesNotConsumeModifiedSpaceOrRenameTyping() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z: z.writestr('first.txt', b'First')")
        let (_, controller) = try await scenarioDocument(fixture), view = controller.outlineView
        controller.window?.makeFirstResponder(view)
        var previews = 0
        view.previewSelection = { previews += 1 }
        XCTAssertTrue(view.handleEntryKey(" ", modifiers: []))
        XCTAssertEqual(previews, 1)
        for modifiers in [NSEvent.ModifierFlags.command, .option, .control, .shift, [.command, .option]] {
            XCTAssertFalse(view.handleEntryKey(" ", modifiers: modifiers))
        }
        view.selectRowIndexes(IndexSet(integer: try row("first.txt", in: view)), byExtendingSelection: false)
        controller.renameEntry(nil)
        XCTAssertFalse(view.handleEntryKey(" ", modifiers: []))
        XCTAssertEqual(previews, 1)
    }
}
