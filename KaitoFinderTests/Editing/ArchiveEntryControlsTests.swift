import AppKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

/// ArchiveWindowController・ArchiveDocument の入力抑止・メニューとツールバー・新規フォルダ・検索・失敗表示を確かめる 20 テスト。
/// ScenarioFixture・DeferredSaveFixture と ScenarioGate を使い、key window・選択・書庫の内容・カタログの翻訳を観測する。
nonisolated final class ArchiveEntryControlsTests: XCTestCase {
    @MainActor func testEditAndContextMenusValidateSelectionAndShortcuts() async throws {
        let fixture = try ScenarioFixture.withEntries(), (_, controller) = try await interface(fixture)
        let mainItems = try XCTUnwrap(NSApp.mainMenu).items.compactMap(\.submenu).flatMap(\.items)
        let context = try XCTUnwrap(controller.outlineView.menu)
        let actions = [#selector(ArchiveWindowController.deleteEntries(_:)), #selector(ArchiveWindowController.renameEntry(_:))]
        for action in actions {
            let main = try XCTUnwrap(mainItems.first { $0.action == action })
            let item = try XCTUnwrap(context.items.first { $0.action == action })
            XCTAssertTrue(item.target === controller)
            controller.outlineView.deselectAll(nil)
            XCTAssertFalse(controller.validateMenuItem(main))
            XCTAssertFalse(controller.validateMenuItem(item))
            try controller.select(paths: ["a.txt"])
            XCTAssertTrue(controller.validateMenuItem(main))
            XCTAssertTrue(controller.validateMenuItem(item))
            try controller.select(paths: ["a.txt", "b.txt"])
            XCTAssertEqual(controller.validateMenuItem(main), action == actions[0])
        }
        let delete = try XCTUnwrap(mainItems.first { $0.action == actions[0] })
        XCTAssertEqual(delete.keyEquivalent, "\u{7f}")
        XCTAssertTrue(delete.keyEquivalentModifierMask.contains(.command))
        XCTAssertFalse(controller.outlineView.handleEntryKey("\u{7f}", modifiers: []))
        XCTAssertFalse(controller.outlineView.handleEntryKey("\r", modifiers: .command))
        controller.renameEntry(nil)
        XCTAssertFalse(controller.outlineView.isRenaming)
    }

    @MainActor func testReadOnlyArchiveDisablesBothMenusWithRefusalReason() async throws {
        let fixture = try ScenarioFixture.withEntries(tar: true), (document, controller) = try await interface(fixture)
        let before = try ArchiveOracle.digest(fixture.archive)
        try controller.select(paths: ["a.txt"])
        XCTAssertFalse(try XCTUnwrap(document.session).capabilities.canEdit)
        for action in [#selector(ArchiveWindowController.deleteEntries(_:)), #selector(ArchiveWindowController.renameEntry(_:))] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item))
            XCTAssertFalse(try XCTUnwrap(item.toolTip).isEmpty)
        }
        controller.deleteEntries(nil)
        controller.renameEntry(nil)
        XCTAssertNil(controller.extractionTask)
        XCTAssertFalse(controller.outlineView.isRenaming)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
    }

    @MainActor func testReadOnlyBlankMenuKeepsEditRefusalAndPasteConversionValidation() async throws {
        let fixture = try ScenarioFixture.withEntries(tar: true), (document, controller) = try await interface(fixture)
        let menu = try XCTUnwrap(controller.outlineView.contextMenu(forRow: -1))
        let folder = try XCTUnwrap(menu.items.first { $0.action == #selector(ArchiveWindowController.newFolder(_:)) })
        XCTAssertFalse(controller.validateMenuItem(folder))
        let reason = try XCTUnwrap(document.session?.capabilities.readOnlyReason)
        XCTAssertEqual(folder.toolTip, reason)
        let paste = try XCTUnwrap(menu.items.first { $0.action == #selector(ArchiveWindowController.paste(_:)) })
        XCTAssertEqual(controller.validateMenuItem(paste),
                       ArchiveIncomingPasteboard.canPaste(AppKitArchivePasteboard(pasteboard: .general)))
        XCTAssertEqual(paste.toolTip, reason)
        let extract = try XCTUnwrap(menu.items.first { $0.action == #selector(ArchiveWindowController.extractAll(_:)) })
        XCTAssertTrue(controller.validateMenuItem(extract))
    }

    @MainActor func testToolbarValidationTracksSelectionReadabilityAndArchiveCapabilities() async throws {
        for readOnly in [false, true] {
            let fixture = try ScenarioFixture.withEntries(["a.txt", "folder/b.txt"], tar: readOnly)
            let (document, controller) = try await interface(fixture)
            let toolbar = try XCTUnwrap(controller.window?.toolbar)
            func item(_ identifier: String) throws -> NSToolbarItem {
                try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == identifier })
            }
            let extract = try item("extract"), add = try item("addFiles"), folder = try item("newFolder")
            let delete = try item("delete"), preview = try item("quickLook"), search = try item("search")
            try controller.select(paths: ["a.txt"])
            XCTAssertEqual(controller.validateToolbarItem(folder), !readOnly)
            XCTAssertEqual(controller.validateToolbarItem(delete), !readOnly)
            for item in [extract, add, preview, search] { XCTAssertTrue(controller.validateToolbarItem(item), item.label) }
            if readOnly {
                let reason = try XCTUnwrap(document.session?.capabilities.readOnlyReason)
                XCTAssertEqual(folder.toolTip, reason)
                XCTAssertEqual(delete.toolTip, reason)
                XCTAssertEqual(add.toolTip, reason)
            }
            controller.outlineView.deselectAll(nil)
            XCTAssertFalse(controller.validateToolbarItem(delete))
            XCTAssertFalse(controller.validateToolbarItem(preview))
            XCTAssertEqual(controller.validateToolbarItem(folder), !readOnly)
            for item in [extract, add, search] { XCTAssertTrue(controller.validateToolbarItem(item), item.label) }
            try controller.select(paths: ["folder"])
            XCTAssertFalse(controller.validateToolbarItem(preview))
            XCTAssertEqual(preview.toolTip, String(localized: "フォルダはプレビューまたは外部アプリケーションで開けません。"))
            try controller.select(paths: ["a.txt"])
            XCTAssertTrue(controller.validateToolbarItem(preview))
            XCTAssertEqual(preview.toolTip, preview.label)
            if !readOnly {
                controller.renameEntry(nil)
                XCTAssertTrue(controller.outlineView.isRenaming)
                XCTAssertFalse(controller.validateToolbarItem(folder))
                XCTAssertFalse(controller.validateToolbarItem(delete))
                controller.outlineView.cancelRenaming()
                XCTAssertTrue(controller.validateToolbarItem(folder))
                XCTAssertTrue(controller.validateToolbarItem(delete))
            }
            let manager = try XCTUnwrap(document.undoManager as? ArchiveUndoManager)
            manager.isSuspended = true
            for item in [add, folder, delete] { XCTAssertFalse(controller.validateToolbarItem(item), item.label) }
            manager.isSuspended = false
        }
    }

    @MainActor func testPendingDeleteDisablesBothActionsAndCancellationPreservesBytesAndUndo() async throws {
        let fixture = try ScenarioFixture.withEntries(), gate = ScenarioGate()
        let cancelled = Mutex(false)
        let stack = ArchiveUndoStack { source, destination in
            let result = ArchiveUndoStack.cloneFile(from: source, to: destination)
            gate.pause()
            cancelled.withLock { $0 = Task.isCancelled }
            return result
        }
        let (document, controller) = try await interface(fixture, stack: stack)
        let before = try ArchiveOracle.digest(fixture.archive)
        try controller.select(paths: ["b.txt"])
        controller.deleteEntries(nil)
        let task = try XCTUnwrap(controller.extractionTask)
        defer { gate.release() }
        try await waitUntil { gate.isEntered }
        for action in [#selector(ArchiveWindowController.deleteEntries(_:)), #selector(ArchiveWindowController.renameEntry(_:))] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item))
            XCTAssertFalse(try XCTUnwrap(item.toolTip).isEmpty)
        }
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        for item in toolbar.items where item.itemIdentifier != .flexibleSpace && item.itemIdentifier != .space {
            XCTAssertFalse(controller.validateToolbarItem(item), item.label)
        }
        controller.togglePreviewSidebar(nil)
        XCTAssertFalse(controller.showsPreviewSidebar, "変更処理中はプレビューの表示も開始しない")
        controller.deleteEntries(nil)
        controller.renameEntry(nil)
        XCTAssertFalse(controller.outlineView.isRenaming)
        let sheet = try XCTUnwrap(controller.editProgressSheet)
        sheet.cancelExtraction(nil)
        XCTAssertTrue(sheet.progress.isCancelled)
        try await waitUntil { task.isCancelled }
        gate.release()
        await task.value
        XCTAssertTrue(cancelled.withLock { $0 })
        XCTAssertNil(controller.failureAlert)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["b.txt"])
    }

    @MainActor func testGatedDeleteBlocksInputImmediatelyAndAttachesAfterDelay() async throws {
        let fixture = try ScenarioFixture.withEntries(), gate = ScenarioGate()
        let stack = ArchiveUndoStack { source, destination in
            gate.pauseOnce()
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let (_, controller) = try await interface(fixture, stack: stack)
        defer { gate.release() }
        try controller.select(paths: ["b.txt"])
        let started = ContinuousClock.now
        controller.deleteEntries(nil)
        let sheet = try XCTUnwrap(controller.editProgressSheet), panel = try XCTUnwrap(sheet.window)
        let task = try XCTUnwrap(controller.extractionTask)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertTrue(controller.operationInFlight)
        XCTAssertEqual(panel.alphaValue, 0)
        try await waitUntil { gate.isEntered }
        try await waitUntil { panel.alphaValue == 1 }
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), ArchiveProgressTiming.revealDelay)
        XCTAssertTrue(controller.window?.attachedSheet === panel)
        gate.release()
        await task.value
        XCTAssertEqual(try names(fixture), ["a.txt", "c.txt"])
        XCTAssertNil(controller.failureAlert)
    }

    @MainActor private func makeKeyWindow(_ window: NSWindow) async throws {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        let activationDeadline = ContinuousClock.now + .seconds(5)
        while !NSApp.isActive, ContinuousClock.now < activationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard NSApp.isActive else {
            throw XCTSkip("テスト host が前面になれない環境では key window と入力遮断を検証できない")
        }
        try await waitUntil { window.isKeyWindow }
    }

    @MainActor private func assertDelayedEditBlocksInput(throughApplication: Bool) async throws {
        let fixture = try ScenarioFixture.withEntries(["a.txt", "b.txt", "folder/", "folder/c.txt"]), gate = ScenarioGate()
        let stack = ArchiveUndoStack { source, destination in
            gate.pauseOnce()
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let (document, controller) = try await interface(fixture, stack: stack)
        defer { gate.release() }
        let window = try XCTUnwrap(controller.window), view = controller.outlineView
        try await makeKeyWindow(window)
        try controller.select(paths: ["b.txt"])
        XCTAssertTrue(window.makeFirstResponder(view))
        let selection = view.selectedRowIndexes, before = try ArchiveOracle.digest(fixture.archive)
        let resignations = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                               object: window, queue: nil) { _ in resignations.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.deleteEntries(nil)
        let task = try XCTUnwrap(controller.extractionTask), sheet = try XCTUnwrap(controller.editProgressSheet)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(try XCTUnwrap(sheet.window).canBecomeKey)
        func send(_ event: NSEvent) {
            if throughApplication { NSApp.sendEvent(event) } else { window.sendEvent(event) }
        }
        func key(_ text: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        }
        for (text, code) in [("\u{f701}", UInt16(125)), ("\r", 36), (" ", 49)] { send(try key(text, code: code)) }
        send(try key("a", code: 0, modifiers: .command))
        let target = try controller.displayedNode("a.txt"), row = view.row(forItem: target), rect = view.rect(ofRow: row)
        let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        for clicks in [1, 2] {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                send(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: clicks, pressure: 1)))
            }
        }
        view.selectAll(nil)
        XCTAssertTrue(view.handleEntryKey("\r", modifiers: []))
        XCTAssertEqual(view.selectedRowIndexes, selection)
        XCTAssertFalse(view.isRenaming)
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertEqual(resignations.withLock { $0 }, 0)
        XCTAssertFalse(controller.canReceiveTabDrag)
        XCTAssertNil(controller.outlineView(view, pasteboardWriterForItem: target))
        let drag = TestDraggingInfo(urls: [fixture.archive], window: window, location: point)
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(controller.outlineView(view, validateDrop: drag, proposedItem: nil, proposedChildIndex: -1), [])
        XCTAssertFalse(controller.outlineView(view, acceptDrop: drag, item: nil, childIndex: -1))
        for action in [#selector(controller.paste(_:)), #selector(controller.copy(_:)), #selector(controller.newFolder(_:)),
                       #selector(controller.deleteEntries(_:)), #selector(controller.renameEntry(_:)), #selector(controller.openEntry(_:)),
                       #selector(controller.openWithEntry(_:)), #selector(controller.extractSelected(_:)), #selector(controller.extractAll(_:)),
                       #selector(controller.togglePreviewPanel(_:)), #selector(controller.saveArchiveAs(_:))] {
            XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        }
        for item in try XCTUnwrap(window.toolbar).items where item.itemIdentifier != .flexibleSpace && item.itemIdentifier != .space {
            XCTAssertFalse(controller.validateToolbarItem(item))
        }
        controller.searchField.stringValue = "a"
        controller.filterEntries(controller.searchField)
        XCTAssertTrue(controller.filterQuery.isEmpty)
        send(try key("\u{1b}", code: 53))
        XCTAssertTrue(sheet.progress.isCancelled)
        try await waitUntil { task.isCancelled }
        gate.release()
        await task.value
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertNil(controller.failureAlert)
        XCTAssertEqual(view.selectedRowIndexes, selection)
        XCTAssertFalse(view.isRenaming)
    }

    @MainActor func testDelayedEditKeepsKeyWindowAndBlocksApplicationEventsExceptEscape() async throws {
        try await assertDelayedEditBlocksInput(throughApplication: true)
    }

    @MainActor func testDelayedEditKeepsKeyWindowAndBlocksWindowEventsExceptEscape() async throws {
        try await assertDelayedEditBlocksInput(throughApplication: false)
    }

    @MainActor func testSuspendedUndoAllowsWindowSelectionExceptWhileProgressSheetIsPending() async throws {
        let fixture = try ScenarioFixture.withEntries(), (document, controller) = try await interface(fixture)
        let window = try XCTUnwrap(controller.window), view = controller.outlineView
        try await makeKeyWindow(window)
        XCTAssertTrue(window.makeFirstResponder(view))
        let manager = try XCTUnwrap(document.undoManager as? ArchiveUndoManager)
        manager.isSuspended = true
        defer { manager.isSuspended = false }
        XCTAssertTrue(controller.operationInFlight)
        XCTAssertFalse(ExtractionProgressSheet.hasPendingSheet(on: window))
        XCTAssertNil(window.attachedSheet)

        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)))
        }
        func click(_ path: String) throws {
            let row = view.row(forItem: try controller.displayedNode(path))
            let rect = view.rect(ofRow: row).intersection(view.visibleRect)
            XCTAssertFalse(rect.isEmpty)
            let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            }
            let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
            // NSTableView の tracking loop を終了させる。遮断時の mouseUp も残さない。
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            if let remaining = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .eventTracking, dequeue: true) {
                window.sendEvent(remaining)
            }
        }

        try controller.select(paths: ["a.txt"])
        try click("b.txt")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["b.txt"])
        try key("\u{f701}", code: 125)
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["c.txt"])
        try key("\r", code: 36)
        try key("\u{7f}", code: 51, modifiers: .command)
        XCTAssertFalse(view.isRenaming)
        XCTAssertNil(controller.extractionTask)
        XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(controller.deleteEntries(_:)), keyEquivalent: "")))

        let sheet = ExtractionProgressSheet(progress: Progress(), revealDelay: .seconds(60))
        defer { sheet.finish() }
        sheet.begin(on: window)
        XCTAssertTrue(ExtractionProgressSheet.hasPendingSheet(on: window))
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(sheet.window?.alphaValue, 0)
        try click("a.txt")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["c.txt"])
        try key("\u{f700}", code: 126)
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["c.txt"])
        try key("\u{1b}", code: 53)
        XCTAssertTrue(sheet.progress.isCancelled)

        sheet.finish()
        XCTAssertFalse(ExtractionProgressSheet.hasPendingSheet(on: window))
        XCTAssertTrue(controller.operationInFlight)
        try click("a.txt")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a.txt"])
        try key("\u{f701}", code: 125)
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["b.txt"])
    }

    @MainActor func testDocumentMutationOutsideControllerDisablesBothEditActions() async throws {
        let fixture = try ScenarioFixture.withEntries(), gate = ScenarioGate()
        let (document, controller) = try await interface(fixture)
        try controller.select(paths: ["a.txt"])
        let target = try controller.displayedNode("c.txt")
        let progress = Progress()
        let task = Task { try await document.remove([target], progress: progress, willPublish: { gate.pause() }) }
        defer { gate.release() }
        try await waitUntil { gate.isEntered }
        XCTAssertNil(controller.extractionTask)
        for action in [#selector(ArchiveWindowController.deleteEntries(_:)), #selector(ArchiveWindowController.renameEntry(_:))] {
            XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        }
        progress.cancel()
        gate.release()
        do { _ = try await task.value; XCTFail("取消しを公開しない") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testAllEditUIAndUndoStringsHaveCatalogEntriesAndTranslations() throws {
        let root = TestPaths.repositoryRoot
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("KaitoFinder/Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let sources = ["UI/ArchiveOutlineView.swift", "UI/ArchiveWindowController.swift", "UI/ArchiveToolbarItem.swift",
                       "UI/ArchiveEntryFormatter.swift", "UI/ArchiveLockedPlaceholderView.swift", "UI/ArchiveListLoadingIndicator.swift",
                       "App/AppDelegate.swift", "Documents/ArchiveUndoManager.swift", "UI/ExtractionProgressSheet.swift",
                       "Extraction/EntryMaterializer.swift", "Extraction/ArchiveFilePromise.swift", "Extraction/FilePromiseRegistry.swift",
                       "Extraction/ArchivePromiseExtractionQueue.swift"]
        let localized = try NSRegularExpression(pattern: #"String\(localized:\s*"((?:\\.|[^"\\])*)""#)
        let bareUIString = try NSRegularExpression(pattern: #"(?:withTitle:|(?:messageText|informativeText|toolTip)\s*=)\s*"[^"\n]+""#)
        for path in sources {
            let source = try String(contentsOf: root.appendingPathComponent("KaitoFinder/" + path), encoding: .utf8)
            XCTAssertNil(bareUIString.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), path)
            for match in localized.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let literal = String(source[try XCTUnwrap(Range(match.range(at: 1), in: source))])
                // 補間は種類を問わず「%」に潰し、catalog 側の %@ / %lld / %1$lld も同じ形に正規化して照合する。
                let key = Self.collapsingInterpolations(literal)
                    .replacingOccurrences(of: #"%[0-9]*\$?(lld|ld|d|@)"#, with: "%", options: .regularExpression)
                let normalized = Dictionary(strings.map { name, value in
                    (name.replacingOccurrences(of: #"%[0-9]*\$?(lld|ld|d|@)"#, with: "%", options: .regularExpression), value)
                }, uniquingKeysWith: { first, _ in first })
                let entry = try XCTUnwrap(normalized[key] as? [String: Any], key)
                let translations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
                XCTAssertNotNil(translations["en"], key)
                XCTAssertNotNil(translations["ja"], key)
            }
            if path == "Documents/ArchiveUndoManager.swift" {
                XCTAssertFalse(source.contains(#"? "取り消す""#))
                XCTAssertFalse(source.contains(#"? "やり直す""#))
                XCTAssertTrue(source.contains("super.setActionName(String(localized:"))
            }
            if path == "App/AppDelegate.swift" {
                XCTAssertFalse(source.contains(#"withTitle: "取り消す""#))
                XCTAssertFalse(source.contains(#"withTitle: "やり直す""#))
            }
        }
        for key in ["削除", "名称変更", "追加", "削除・名称変更"] {
            XCTAssertNotNil(strings[key])
        }
    }

    func testExtractionCatalogUsesNewWordingAndCompleteTranslations() throws {
        let root = TestPaths.repositoryRoot
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("KaitoFinder/Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        for (key, value) in strings {
            XCTAssertFalse(key.contains("取り出"), key)
            let entry = try XCTUnwrap(value as? [String: Any], key)
            let translations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for language in ["en", "ja"] {
                let translation = try XCTUnwrap(translations[language] as? [String: Any], key)
                let unit = try XCTUnwrap(translation["stringUnit"] as? [String: String], key)
                let text = try XCTUnwrap(unit["value"], key)
                XCTAssertFalse(text.contains("取り出"), key)
                XCTAssertFalse(text.isEmpty, key)
                XCTAssertEqual(unit["state"], "translated", key)
            }
        }
        let expected = [
            "選択した項目を展開…": "Extract Selected Items…", "すべて展開…": "Expand All…", "展開": "Extract",
            "項目を展開中…": "Extracting…", "項目を展開できませんでした": "Could not extract items",
            "追加…": "Add…", "検索": "Search", "アーカイブをFinderに表示": "Reveal Archive in Finder",
            "単一ファイルを展開できませんでした": "Could not extract a single file",
            "展開する項目の型情報を取得できません: %@。": "Could not get type information for the item to extract: %@."
        ]
        for (key, english) in expected {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let translations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for (language, value) in [("ja", key), ("en", english)] {
                let translation = try XCTUnwrap(translations[language] as? [String: Any], key)
                let unit = try XCTUnwrap(translation["stringUnit"] as? [String: String], key)
                XCTAssertEqual(unit["value"], value, key)
            }
        }
    }

    @MainActor func testNewFolderUsesFirstSelectionAndBeginsInlineRename() async throws {
        let initial = ["folder/", "folder/deep/a.txt", "other/b.txt", "root.txt"]
        let cases: [([String], String)] = [([], ""), (["root.txt"], ""), (["folder"], "folder"),
            (["folder/deep/a.txt"], "folder/deep"), (["folder/deep"], "folder/deep"),
            (["folder/deep/a.txt", "other/b.txt"], "folder/deep"), (["folder", "other/b.txt"], "folder")]
        for (selection, parent) in cases {
            let fixture = try ScenarioFixture.withEntries(initial), (document, controller) = try await interface(fixture)
            try controller.select(paths: selection)
            controller.newFolder(nil)
            await controller.extractionTask?.value
            let leaf = String(localized: "名称未設定フォルダ")
            let path = parent.isEmpty ? leaf : parent + "/" + leaf
            XCTAssertEqual(try names(fixture), Set(initial + [path + "/"]), "\(selection)")
            XCTAssertEqual(controller.selectedNodes.map(\.path), [path])
            XCTAssertTrue(try XCTUnwrap(controller.selectedNodes.first).isDirectory)
            let field = try XCTUnwrap(controller.outlineView.renameField)
            XCTAssertEqual(field.stringValue, leaf)
            XCTAssertNotNil(field.currentEditor())
            XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
            controller.outlineView.cancelRenaming()
        }
    }

    @MainActor func testNewFolderUsesHiddenCollisionsAndRevealsResultForRename() async throws {
        let leaf = String(localized: "名称未設定フォルダ")
        let fixture = try ScenarioFixture.withEntries(["parent/match.txt", "parent/" + leaf + "/", "parent/" + leaf + " 2/hidden.txt"])
        let (_, controller) = try await interface(fixture)
        controller.setFilterQuery("match")
        XCTAssertEqual(controller.displayedPaths, ["parent", "parent/match.txt"])
        try controller.select(paths: ["parent/match.txt"])
        controller.newFolder(nil)
        await controller.extractionTask?.value
        XCTAssertTrue(try names(fixture).contains("parent/" + leaf + " 3/"))
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["parent/" + leaf + " 3"])
        XCTAssertTrue(controller.outlineView.isRenaming)
        XCTAssertEqual(controller.filterQuery, "")
        XCTAssertEqual(controller.searchField.stringValue, "")
    }

    @MainActor func testNewFolderMenusUseShiftCommandNAndExposeReadOnlyReason() async throws {
        preserveApplicationMenus()
        let (_, controller) = try await interface(ScenarioFixture.withEntries())
        let menu = AppDelegate().makeMenu()
        let fileMenu = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == String(localized: "ファイル") })
        let action = #selector(ArchiveWindowController.newFolder(_:))
        let item = try XCTUnwrap(fileMenu.items.first { $0.action == action })
        XCTAssertEqual(item.title, String(localized: "新規フォルダ"))
        XCTAssertEqual(item.keyEquivalent, "n")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(controller.validateMenuItem(item))
        let context = try XCTUnwrap(controller.outlineView.menu?.items.first { $0.action == action })
        XCTAssertEqual(context.title, String(localized: "新規フォルダ"))
        XCTAssertTrue(context.target === controller)
        XCTAssertTrue(controller.validateMenuItem(context))
        let fixture = try ScenarioFixture.withEntries(tar: true), before = try ArchiveOracle.digest(fixture.archive)
        let (document, readOnly) = try await interface(fixture)
        readOnly.setFilterQuery("a")
        XCTAssertFalse(readOnly.validateMenuItem(item))
        XCTAssertEqual(item.toolTip, document.session?.capabilities.readOnlyReason)
        XCTAssertFalse(try XCTUnwrap(item.toolTip).isEmpty)
        readOnly.newFolder(nil)
        XCTAssertNil(readOnly.extractionTask)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
    }

    @MainActor func testBlankAreaNewFolderUsesRootWhileToolbarUsesSelectedFolder() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        document.addWindowController(controller)
        let root = EntryNode.tree(from: try await document.projectedEntries())
        controller.display(root, session: try XCTUnwrap(document.session))
        let folder = try XCTUnwrap(root.nodes(at: "folder").first)
        controller.outlineView.selectRowIndexes(IndexSet(integer: controller.outlineView.row(forItem: folder)), byExtendingSelection: false)
        let menu = try XCTUnwrap(controller.outlineView.contextMenu(forRow: -1))
        let item = try XCTUnwrap(menu.items.first { $0.action == #selector(ArchiveWindowController.newFolder(_:)) })
        XCTAssertEqual(controller.outlineView.clickedRow, -1)
        controller.newFolder(item)
        await controller.extractionTask?.value
        XCTAssertEqual(document.pendingChanges.createdFolders.count, 1)
        XCTAssertEqual(ArchivePath.components(document.pendingChanges.createdFolders[0].path).count, 1)
        controller.outlineView.cancelRenaming()
        let row = try XCTUnwrap((0..<controller.outlineView.numberOfRows).first {
            (controller.outlineView.item(atRow: $0) as? EntryNode)?.path == "folder"
        })
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.newFolder(nil)
        await controller.extractionTask?.value
        XCTAssertTrue(document.pendingChanges.createdFolders.last?.path.hasPrefix("folder/") == true)
    }

    @MainActor func testFilterClearRestoresExpansionAndMultipleSelectionAfterQueryChangesAndReload() async throws {
        let fixture = try ScenarioFixture.withEntries(["a/top.txt", "a/deep/leaf.txt", "b/leaf.txt", "c/keep.txt"])
        let (document, controller) = try await interface(fixture), view = controller.outlineView
        view.collapseItem(try controller.displayedNode("a/deep"))
        view.collapseItem(try controller.displayedNode("b"))
        try controller.select(paths: ["a/top.txt", "c/keep.txt"])
        let previous = controller.displayedPaths
        controller.searchField.stringValue = "leaf"
        controller.filterEntries(controller.searchField)
        XCTAssertEqual(controller.displayedPaths, ["a", "a/deep", "a/deep/leaf.txt", "b", "b/leaf.txt"])
        XCTAssertTrue(view.isItemExpanded(try controller.displayedNode("a/deep")))
        controller.setFilterQuery("b")
        try controller.select(paths: ["b/leaf.txt"])
        view.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        try await document.reloadAfterMutation()
        XCTAssertEqual(controller.filterQuery, "b")
        controller.searchField.stringValue = ""
        controller.filterEntries(controller.searchField)
        XCTAssertEqual(controller.displayedPaths, previous)
        XCTAssertEqual(Set(controller.selectedNodes.map(\.path)), ["a/top.txt", "c/keep.txt"])
        XCTAssertTrue(view.isItemExpanded(try controller.displayedNode("a")))
        XCTAssertTrue(view.isItemExpanded(try controller.displayedNode("c")))
        XCTAssertFalse(view.isItemExpanded(try controller.displayedNode("a/deep")))
        XCTAssertFalse(view.isItemExpanded(try controller.displayedNode("b")))
    }

    @MainActor func testFailureAlertUsesOpenTitleOverrideAndKeepsExtractionTitleByDefault() throws {
        let bundle = try LocalizationAcceptance.bundle("ja")
        let title = String(localized: "項目を開けませんでした", bundle: bundle)
        let alert = ArchiveWindowController.makeFailureAlert("x", title: title, bundle: bundle)
        XCTAssertEqual(alert.messageText, "項目を開けませんでした")
        XCTAssertEqual(alert.informativeText, "x。")
        XCTAssertEqual(ArchiveWindowController.makeFailureAlert("x", bundle: bundle).messageText, "項目を展開できませんでした")
        let translations = try XCTUnwrap(LocalizationAcceptance.catalog().strings["項目を開けませんでした"]).localizations
        XCTAssertEqual(Set(translations.keys), Set(LocalizationAcceptance.languages))
        for language in LocalizationAcceptance.languages {
            XCTAssertEqual(translations[language]?.stringUnit.state, "translated")
        }
    }

    @MainActor func testOpeningBrokenNestedArchiveReportsOpenFailureAfterSuccessfulExtraction() async throws {
        let fixture = try ScenarioFixture(script: #"""
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('broken.zip', b'PK\x03\x04garbage')
        """#)
        let (document, _) = try await scenarioDocument(fixture)
        // 実行環境の言語によらず、シナリオでも日本語の見出しそのものを確認する。
        let controller = ArchiveWindowController(bundle: try LocalizationAcceptance.bundle("ja"))
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session)
        let materialization = try XCTUnwrap(document.materializationController())
        controller.display(EntryNode.tree(from: await session.entries()), session: session,
                           materializationController: materialization)
        let window = try XCTUnwrap(controller.window)
        defer {
            if let alert = controller.failureAlert {
                window.endSheet(alert.window)
                alert.window.orderOut(nil)
            }
        }
        try controller.select(paths: ["broken.zip"])
        controller.openEntry(nil)
        try await scenarioWait {
            guard let alert = controller.failureAlert else { return false }
            return window.attachedSheet === alert.window
        }
        let extracted = try XCTUnwrap(materialization.item(at: 0)?.previewItemURL)
        XCTAssertEqual(try Data(contentsOf: extracted), Data([0x50, 0x4b, 0x03, 0x04]) + Data("garbage".utf8))
        XCTAssertEqual(try XCTUnwrap(controller.failureAlert).messageText, "項目を開けませんでした")
    }

    @MainActor func testNewFolderAndFilterStringsHaveExactJapaneseAndEnglishLocalizations() throws {
        let bundle = Bundle(for: ArchiveDocument.self)
        for (language, values) in [
            ("ja", ["新規フォルダ", "名称未設定フォルダ", "検索", "フォルダを作成中…"]),
            ("en", ["New Folder", "untitled folder", "Search", "Creating Folder…"])
        ] {
            let localized = try XCTUnwrap(Bundle(url: XCTUnwrap(bundle.url(forResource: language, withExtension: "lproj"))))
            XCTAssertEqual(String(localized: "新規フォルダ", bundle: localized), values[0])
            XCTAssertEqual(String(localized: "名称未設定フォルダ", bundle: localized), values[1])
            XCTAssertEqual(String(localized: "検索", bundle: localized), values[2])
            XCTAssertEqual(String(localized: "フォルダを作成中…", bundle: localized), values[3])
            let base = values[1], number = 2
            XCTAssertEqual(String(localized: "\(base) \(number)", bundle: localized), base + " 2")
        }
    }

    // 入れ子の括弧を含む補間 \(f(x)) も一つの「%」に潰す。
    private static func collapsingInterpolations(_ literal: String) -> String {
        var result = "", depth = 0, index = literal.startIndex
        while index < literal.endIndex {
            if depth == 0, literal[index...].hasPrefix("\\(") {
                result += "%"; depth = 1; index = literal.index(index, offsetBy: 2); continue
            }
            if depth > 0 {
                if literal[index] == "(" { depth += 1 } else if literal[index] == ")" { depth -= 1 }
                index = literal.index(after: index); continue
            }
            result.append(literal[index]); index = literal.index(after: index)
        }
        return result
    }
}
