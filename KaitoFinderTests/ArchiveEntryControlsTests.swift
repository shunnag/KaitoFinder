import AppKit
import CryptoKit
import Darwin
import KaitoKit
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveEntryControlsTests: XCTestCase {
    private final class Fixture {
        let directory: URL
        let archive: URL

        init(_ names: [String] = ["a.txt", "b.txt", "c.txt"], tar: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("KaitoFinder-Controls-" + UUID().uuidString)
            archive = directory.appendingPathComponent(tar ? "archive.tar.bz2" : "archive.zip")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
            import io, sys, tarfile, zipfile
            p, *names = sys.argv[1:]
            if p.endswith('.tar.bz2'):
                with tarfile.open(p, 'w:bz2') as a:
                    for name in names:
                        item = tarfile.TarInfo(name)
                        data = name.encode()
                        item.size = len(data)
                        a.addfile(item, io.BytesIO(data))
            else:
                with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as a:
                    for name in names:
                        a.writestr(name, b'' if name.endswith('/') else name.encode())
            """, archive.path] + names
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
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

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    @MainActor private func interface(_ fixture: Fixture, stack: ArchiveUndoStack = ArchiveUndoStack()) async throws
        -> (ArchiveDocument, ArchiveWindowController) {
        preserveArchiveWindowFrame()
        let document = ArchiveDocument(undoStack: stack)
        try document.read(from: fixture.archive, ofType: "archive")
        let controller = ArchiveWindowController()
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session)
        let snapshot = await session.snapshot()
        controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
        controller.outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        controller.outlineView.expandItem(nil, expandChildren: true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.makeFirstResponder(controller.outlineView)
        addTeardownBlock { @MainActor in
            document.close()
            await controller.extractionTask?.value
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            withExtendedLifetime(fixture) {}
        }
        return (document, controller)
    }

    @MainActor private func node(_ path: String, in controller: ArchiveWindowController) throws -> EntryNode {
        let view = controller.outlineView
        return try XCTUnwrap((0..<view.numberOfRows).compactMap { view.item(atRow: $0) as? EntryNode }.first { $0.path == path })
    }

    @MainActor private func select(_ paths: [String], in controller: ArchiveWindowController) throws {
        let rows = try paths.map { controller.outlineView.row(forItem: try node($0, in: controller)) }
        controller.outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    @MainActor private func paths(_ controller: ArchiveWindowController) -> Set<String> {
        let view = controller.outlineView
        return Set((0..<view.numberOfRows).compactMap { (view.item(atRow: $0) as? EntryNode)?.path })
    }

    private func names(_ fixture: Fixture) throws -> Set<String> {
        Set(try ArchiveReader.open(url: fixture.archive).entries.map(\.name))
    }

    private func digest(_ fixture: Fixture) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: fixture.archive)))
    }

    @MainActor private func editor(_ controller: ArchiveWindowController, text: String) throws -> (NSTextField, NSTextView) {
        let view = controller.outlineView
        XCTAssertTrue(view.handleEntryKey("\r", modifiers: []))
        let field = try XCTUnwrap(view.renameField)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = text
        return (field, editor)
    }

    @MainActor private func commit(_ controller: ArchiveWindowController, field: NSTextField, editor: NSTextView) {
        XCTAssertTrue(controller.outlineView.control(field, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }

    @MainActor func testMultiSelectionDeletesOnceAndRegistersOneUndoEntryWithoutConfirmation() async throws {
        let fixture = try Fixture(), captures = Mutex(0)
        let stack = ArchiveUndoStack { source, destination in
            captures.withLock { $0 += 1 }
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let (document, controller) = try await interface(fixture, stack: stack)
        XCTAssertTrue(document.canUndoNextMutation)
        try select(["a.txt", "c.txt"], in: controller)
        XCTAssertTrue(controller.outlineView.handleEntryKey("\u{7f}", modifiers: .command))
        XCTAssertNil(controller.deletionConfirmation)
        XCTAssertNotNil(controller.editProgressSheet)
        let task = try XCTUnwrap(controller.extractionTask)
        await task.value
        XCTAssertEqual(try names(fixture), ["b.txt"])
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(captures.withLock { $0 }, 1)
        XCTAssertEqual(stack.slots.count, 1)
        XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testDeletingVirtualFolderRemovesAllDescendants() async throws {
        let fixture = try Fixture(["virtual/a.txt", "virtual/deep/b.txt", "virtualish/keep.txt"])
        let (document, controller) = try await interface(fixture)
        XCTAssertTrue(try node("virtual", in: controller).isVirtual)
        try select(["virtual", "virtual/a.txt"], in: controller)
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["virtualish/keep.txt"])
        XCTAssertFalse(paths(controller).contains("virtual"))
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
    }

    @MainActor func testDeletingRealDirectoryRemovesDirectoryAndDescendants() async throws {
        let fixture = try Fixture(["real/", "real/a.txt", "real/deep/", "real/deep/b.txt", "keep.txt"])
        let (_, controller) = try await interface(fixture)
        XCTAssertFalse(try node("real", in: controller).isVirtual)
        try select(["real"], in: controller)
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["keep.txt"])
        XCTAssertEqual(paths(controller), ["keep.txt"])
    }

    @MainActor func testReturnCommitsInlineRenameAndPreservesSelection() async throws {
        let fixture = try Fixture(), (document, controller) = try await interface(fixture)
        try select(["b.txt"], in: controller)
        let (field, editor) = try editor(controller, text: "renamed.txt")
        commit(controller, field: field, editor: editor)
        let task = try XCTUnwrap(controller.extractionTask)
        await task.value
        XCTAssertFalse(controller.outlineView.isRenaming)
        XCTAssertNil(field.currentEditor())
        XCTAssertEqual(try names(fixture), ["a.txt", "renamed.txt", "c.txt"])
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["renamed.txt"])
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
    }

    @MainActor func testEscapeCancelsInlineRenameWithoutChangingArchive() async throws {
        let fixture = try Fixture(), (document, controller) = try await interface(fixture)
        let before = try digest(fixture)
        try select(["b.txt"], in: controller)
        let (field, editor) = try editor(controller, text: "renamed.txt")
        XCTAssertTrue(controller.outlineView.control(field, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(controller.outlineView.isRenaming)
        XCTAssertNil(field.currentEditor())
        XCTAssertNil(controller.extractionTask)
        XCTAssertEqual(field.stringValue, "b.txt")
        XCTAssertEqual(try digest(fixture), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testFocusLossCommitsInlineRename() async throws {
        let fixture = try Fixture(), (_, controller) = try await interface(fixture)
        try select(["b.txt"], in: controller)
        let (field, _) = try editor(controller, text: "focus.txt")
        // Window の responder 移動を使い、終了通知だけを偽造しない。
        XCTAssertTrue(try XCTUnwrap(controller.window).makeFirstResponder(controller.outlineView))
        await controller.extractionTask?.value
        XCTAssertNil(field.currentEditor())
        XCTAssertFalse(controller.outlineView.isRenaming)
        XCTAssertEqual(try names(fixture), ["a.txt", "focus.txt", "c.txt"])
    }

    @MainActor private final class RenameCommitWindow: NSWindow {
        var didMakeFirstResponder: (() -> Void)?
        var requestedSheets: [NSWindow] = []

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            let result = super.makeFirstResponder(responder)
            didMakeFirstResponder?()
            return result
        }

        override func beginSheet(_ sheetWindow: NSWindow,
                                 completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
            // 進捗も含めてシートは表示せず、要求されたシートだけを記録する。
            requestedSheets.append(sheetWindow)
        }
    }

    @MainActor private func scenarioDocument(_ fixture: ScenarioFixture, stack: ArchiveUndoStack) async throws
        -> (ArchiveDocument, ArchiveWindowController, RenameCommitWindow) {
        preserveArchiveWindowFrame()
        let document = ArchiveDocument(undoStack: stack)
        try document.read(from: fixture.archive, ofType: "public.zip-archive")
        document.fileURL = fixture.archive
        let controller = ArchiveWindowController()
        let originalWindow = try XCTUnwrap(controller.window)
        let window = RenameCommitWindow(contentRect: originalWindow.contentRect(forFrameRect: originalWindow.frame),
                                       styleMask: originalWindow.styleMask, backing: .buffered, defer: false)
        window.contentView = originalWindow.contentView
        window.delegate = originalWindow.delegate
        controller.window = window
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session), snapshot = await session.snapshot()
        controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(controller.outlineView))
        addTeardownBlock { @MainActor in
            document.close()
            await controller.extractionTask?.value
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            withExtendedLifetime(fixture) {}
        }
        return (document, controller, window)
    }

    @MainActor private func assertRenameSurvivesFollowingOperation(password: Bool) async throws {
        let fixture = try ScenarioFixture(), gate = ScenarioGate()
        defer { gate.release() }
        let stack = ArchiveUndoStack(clone: { source, destination in
            gate.pauseOnce()
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        })
        let (document, controller, window) = try await scenarioDocument(fixture, stack: stack)
        let action = password ? #selector(ArchiveWindowController.setArchivePassword(_:))
            : #selector(ArchiveWindowController.saveArchiveAs(_:))
        XCTAssertTrue(controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        try select(["original.txt"], in: controller)
        let (_, editor) = try editor(controller, text: "renamed.txt")
        XCTAssertEqual(editor.string, "renamed.txt")
        var renameTask: Task<Void, Never>?
        window.didMakeFirstResponder = {
            if !controller.outlineView.isRenaming { renameTask = controller.extractionTask }
        }
        if password { controller.setArchivePassword(nil) }
        else { controller.saveArchiveAs(nil) }
        window.didMakeFirstResponder = nil

        let committedTask = try XCTUnwrap(renameTask)
        let retainedTask = try XCTUnwrap(controller.extractionTask)
        XCTAssertEqual(retainedTask, committedTask, "確定した改名 Task を後続の操作で上書きしない")
        // 退行時も、上書きした Task が実際のパネルを開く前に同期的に取り消す。
        if retainedTask != committedTask { retainedTask.cancel() }
        XCTAssertFalse(controller.outlineView.isRenaming)
        XCTAssertNil(controller.creationController)
        XCTAssertNil(controller.creationController?.savePanel)
        XCTAssertNil(controller.passwordEditor)
        XCTAssertEqual(window.requestedSheets.count, 1)
        XCTAssertTrue(window.requestedSheets.first === controller.editProgressSheet?.window)
        XCTAssertNil(window.attachedSheet)

        try await scenarioWait { gate.isEntered }
        XCTAssertEqual(document.generation, 0)
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), ["original.txt": Data("original".utf8)])
        XCTAssertEqual(controller.extractionTask, committedTask)
        XCTAssertNil(controller.creationController)
        XCTAssertNil(controller.passwordEditor)
        gate.release()
        await committedTask.value
        if retainedTask != committedTask { await retainedTask.value }
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), ["renamed.txt": Data("original".utf8)])
        XCTAssertEqual(document.generation, 1)
        XCTAssertNil(controller.extractionTask)
        XCTAssertNil(controller.creationController)
        XCTAssertNil(controller.passwordEditor)
        XCTAssertEqual(window.requestedSheets.count, 1)
        XCTAssertNil(window.attachedSheet)
    }

    @MainActor func testSaveAsAfterInlineRenameKeepsRenameTaskAndDoesNotOpenSavePanel() async throws {
        try await assertRenameSurvivesFollowingOperation(password: false)
    }

    @MainActor func testPasswordAfterInlineRenameKeepsRenameTaskAndDoesNotOpenPasswordEditor() async throws {
        try await assertRenameSurvivesFollowingOperation(password: true)
    }

    @MainActor private func assertRejected(_ name: String, focusLoss: Bool = false) async throws {
        let fixture = try Fixture(), (document, controller) = try await interface(fixture)
        let before = try digest(fixture)
        try select(["b.txt"], in: controller)
        let (field, editor) = try editor(controller, text: name)
        if focusLoss {
            // AppKit は終了可否の delegate を通さず移動できる。終了処理後に同じ editor を戻す。
            XCTAssertTrue(try XCTUnwrap(controller.window).makeFirstResponder(controller.outlineView))
            XCTAssertNil(controller.extractionTask)
            XCTAssertNil(controller.window?.attachedSheet)
            try await waitUntil { field.currentEditor() === editor && controller.window?.firstResponder === editor }
        } else { commit(controller, field: field, editor: editor) }
        XCTAssertTrue(controller.outlineView.isRenaming)
        XCTAssertTrue(field.isEditable)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertTrue(controller.window?.firstResponder === editor)
        XCTAssertEqual(editor.string, name)
        XCTAssertFalse(try XCTUnwrap(field.toolTip).isEmpty)
        XCTAssertNil(controller.extractionTask)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertEqual(try digest(fixture), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
    }

    @MainActor func testCollidingTypedNameKeepsFieldEditorAndArchiveBytes() async throws {
        try await assertRejected("a.txt")
    }

    @MainActor func testCollidingTypedNameAlsoRejectsFocusLoss() async throws {
        try await assertRejected("a.txt", focusLoss: true)
    }

    @MainActor func testSortingCommitsValidRenameAndKeepsInvalidNameEditing() async throws {
        let fixture = try Fixture(), (_, controller) = try await interface(fixture)
        let before = try digest(fixture)
        try select(["b.txt"], in: controller)
        let (field, editor) = try editor(controller, text: "a.txt")
        let view = controller.outlineView
        view.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertTrue(try XCTUnwrap(view.sortDescriptors.first).ascending)
        XCTAssertEqual(try digest(fixture), before)
        editor.string = "sorted.txt"
        view.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        await controller.extractionTask?.value
        XCTAssertFalse(view.isRenaming)
        XCTAssertEqual(try names(fixture), ["a.txt", "sorted.txt", "c.txt"])
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["sorted.txt"])
    }

    @MainActor func testEmptyTypedNameKeepsFieldEditorAndArchiveBytes() async throws {
        try await assertRejected("")
    }

    @MainActor func testDotDotTypedNameKeepsFieldEditorAndArchiveBytes() async throws {
        try await assertRejected("..")
    }

    @MainActor func testSlashTypedNameKeepsFieldEditorAndArchiveBytes() async throws {
        try await assertRejected("bad/name")
    }

    @MainActor func testNULTypedNameKeepsFieldEditorAndArchiveBytes() async throws {
        try await assertRejected("bad\0name")
    }

    @MainActor func testOverlongTypedNameKeepsFieldEditorAndArchiveBytes() async throws {
        try await assertRejected(String(repeating: "あ", count: Int(UInt16.max) / 3 + 1))
    }

    @MainActor func testRejectedNameCanBeCorrectedAndCommittedInSameEditor() async throws {
        let fixture = try Fixture(), (_, controller) = try await interface(fixture)
        try select(["b.txt"], in: controller)
        let (field, editor) = try editor(controller, text: "a.txt")
        commit(controller, field: field, editor: editor)
        XCTAssertTrue(field.currentEditor() === editor)
        editor.string = "corrected.txt"
        commit(controller, field: field, editor: editor)
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["a.txt", "corrected.txt", "c.txt"])
    }

    @MainActor func testRenameRejectsVirtualFolderCollisionAndRenamesWholeSubtree() async throws {
        let fixture = try Fixture(["source/a.txt", "source/deep/b.txt", "occupied/keep.txt"])
        let (document, controller) = try await interface(fixture)
        let before = try digest(fixture)
        try select(["source"], in: controller)
        let (field, editor) = try editor(controller, text: "occupied")
        commit(controller, field: field, editor: editor)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(try digest(fixture), before)
        editor.string = "renamed"
        commit(controller, field: field, editor: editor)
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["renamed/a.txt", "renamed/deep/b.txt", "occupied/keep.txt"])
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["renamed"])
        XCTAssertTrue(paths(controller).contains("renamed/deep/b.txt"))
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
    }

    @MainActor func testNonUndoableDeleteRequiresOneConfirmationAndHonorsBothResponses() async throws {
        // 文書のフラグを保持件数から false にする。ボリューム判定は偽装しない。
        let fixture = try Fixture(), stack = ArchiveUndoStack(maximumCount: 0)
        let (document, controller) = try await interface(fixture, stack: stack)
        XCTAssertFalse(document.canUndoNextMutation)
        let before = try digest(fixture)
        try select(["a.txt", "c.txt"], in: controller)
        controller.deleteEntries(nil)
        let declined = try XCTUnwrap(controller.deletionConfirmation)
        XCTAssertNil(controller.extractionTask)
        XCTAssertEqual(try digest(fixture), before)
        controller.deleteEntries(nil)
        XCTAssertTrue(controller.deletionConfirmation === declined)
        controller.window?.endSheet(declined.window, returnCode: .alertSecondButtonReturn)
        try await waitUntil { controller.deletionConfirmation == nil }
        XCTAssertNil(controller.extractionTask)
        XCTAssertEqual(try digest(fixture), before)
        controller.deleteEntries(nil)
        let accepted = try XCTUnwrap(controller.deletionConfirmation)
        controller.window?.endSheet(accepted.window, returnCode: .alertFirstButtonReturn)
        try await waitUntil { controller.deletionConfirmation == nil }
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["b.txt"])
        XCTAssertEqual(document.generation, 1)
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testEditAndContextMenusValidateSelectionAndShortcuts() async throws {
        let fixture = try Fixture(), (_, controller) = try await interface(fixture)
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
            try select(["a.txt"], in: controller)
            XCTAssertTrue(controller.validateMenuItem(main))
            XCTAssertTrue(controller.validateMenuItem(item))
            try select(["a.txt", "b.txt"], in: controller)
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
        let fixture = try Fixture(tar: true), (document, controller) = try await interface(fixture)
        let before = try digest(fixture)
        try select(["a.txt"], in: controller)
        XCTAssertFalse(try XCTUnwrap(document.session).capabilities.canAppend)
        for action in [#selector(ArchiveWindowController.deleteEntries(_:)), #selector(ArchiveWindowController.renameEntry(_:))] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item))
            XCTAssertFalse(try XCTUnwrap(item.toolTip).isEmpty)
        }
        controller.deleteEntries(nil)
        controller.renameEntry(nil)
        XCTAssertNil(controller.extractionTask)
        XCTAssertFalse(controller.outlineView.isRenaming)
        XCTAssertEqual(try digest(fixture), before)
    }

    @MainActor func testReadOnlyBlankMenuKeepsEditRefusalAndPasteConversionValidation() async throws {
        let fixture = try Fixture(tar: true), (document, controller) = try await interface(fixture)
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
            let fixture = try Fixture(["a.txt", "folder/b.txt"], tar: readOnly)
            let (document, controller) = try await interface(fixture)
            let toolbar = try XCTUnwrap(controller.window?.toolbar)
            func item(_ identifier: String) throws -> NSToolbarItem {
                try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == identifier })
            }
            let extract = try item("extract"), add = try item("addFiles"), folder = try item("newFolder")
            let delete = try item("delete"), preview = try item("quickLook"), search = try item("search")
            try select(["a.txt"], in: controller)
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
            try select(["folder"], in: controller)
            XCTAssertFalse(controller.validateToolbarItem(preview))
            XCTAssertEqual(preview.toolTip, String(localized: "フォルダはプレビューまたは外部アプリケーションで開けません。"))
            try select(["a.txt"], in: controller)
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
        let fixture = try Fixture(), gate = Gate()
        let stack = ArchiveUndoStack { source, destination in
            let result = ArchiveUndoStack.cloneFile(from: source, to: destination)
            gate.wait()
            return result
        }
        let (document, controller) = try await interface(fixture, stack: stack)
        let before = try digest(fixture)
        try select(["b.txt"], in: controller)
        controller.deleteEntries(nil)
        let task = try XCTUnwrap(controller.extractionTask)
        defer { gate.release.signal() }
        try await waitUntil { gate.entered.withLock { $0 } }
        for action in [#selector(ArchiveWindowController.deleteEntries(_:)), #selector(ArchiveWindowController.renameEntry(_:))] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item))
            XCTAssertFalse(try XCTUnwrap(item.toolTip).isEmpty)
        }
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        for item in toolbar.items where item.itemIdentifier != .flexibleSpace {
            XCTAssertEqual(controller.validateToolbarItem(item), item.itemIdentifier.rawValue == "search", item.label)
        }
        controller.deleteEntries(nil)
        controller.renameEntry(nil)
        XCTAssertFalse(controller.outlineView.isRenaming)
        let sheet = try XCTUnwrap(controller.editProgressSheet)
        sheet.cancelExtraction(nil)
        XCTAssertTrue(sheet.progress.isCancelled)
        gate.release.signal()
        await task.value
        XCTAssertEqual(try digest(fixture), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["b.txt"])
    }

    @MainActor func testDocumentMutationOutsideControllerDisablesBothEditActions() async throws {
        let fixture = try Fixture(), gate = Gate()
        let (document, controller) = try await interface(fixture)
        try select(["a.txt"], in: controller)
        let target = try node("c.txt", in: controller)
        let progress = Progress()
        let task = Task { try await document.remove([target], progress: progress, willPublish: { gate.wait() }) }
        defer { gate.release.signal() }
        try await waitUntil { gate.entered.withLock { $0 } }
        XCTAssertNil(controller.extractionTask)
        for action in [#selector(ArchiveWindowController.deleteEntries(_:)), #selector(ArchiveWindowController.renameEntry(_:))] {
            XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        }
        progress.cancel()
        gate.release.signal()
        do { _ = try await task.value; XCTFail("取消しを公開しない") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor func testDeletingMiddleSiblingSelectsFollowingSibling() async throws {
        let fixture = try Fixture(), (_, controller) = try await interface(fixture)
        try select(["b.txt"], in: controller)
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["c.txt"])
    }

    @MainActor func testDeletingOnlyChildSelectsSurvivingParent() async throws {
        let fixture = try Fixture(["folder/", "folder/child.txt"])
        let (_, controller) = try await interface(fixture)
        try select(["folder/child.txt"], in: controller)
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["folder/"])
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["folder"])
    }

    @MainActor func testUndoAndRedoRebuildOutlineAndRestoreDeleteBytes() async throws {
        let fixture = try Fixture(), (document, controller) = try await interface(fixture)
        let before = try Data(contentsOf: fixture.archive)
        try select(["b.txt"], in: controller)
        let oldNode = try node("b.txt", in: controller)
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        let after = try Data(contentsOf: fixture.archive)
        XCTAssertFalse(paths(controller).contains("b.txt"))
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertEqual(paths(controller), ["a.txt", "b.txt", "c.txt"])
        XCTAssertFalse(try node("b.txt", in: controller) === oldNode)
        try select(["b.txt"], in: controller)
        let (field, _) = try editor(controller, text: "stale.txt")
        document.redo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertFalse(controller.outlineView.isRenaming)
        XCTAssertNil(field.currentEditor())
        XCTAssertEqual(try Data(contentsOf: fixture.archive), after)
        XCTAssertFalse(paths(controller).contains("b.txt"))
        XCTAssertEqual(document.generation, 3)
        XCTAssertNil(controller.extractionTask)
    }

    func testAllEditUIAndUndoStringsHaveCatalogEntriesAndTranslations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("KaitoFinder/Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let sources = ["UI/ArchiveOutlineView.swift", "UI/ArchiveWindowController.swift", "App/AppDelegate.swift", "Model/ArchiveUndoStack.swift",
                       "UI/ExtractionProgressSheet.swift", "Extraction/EntryMaterializer.swift", "Extraction/ArchiveFilePromise.swift"]
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
            if path == "Model/ArchiveUndoStack.swift" {
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
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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
            let fixture = try Fixture(initial), (document, controller) = try await interface(fixture)
            try select(selection, in: controller)
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
        let fixture = try Fixture(["parent/match.txt", "parent/" + leaf + "/", "parent/" + leaf + " 2/hidden.txt"])
        let (_, controller) = try await interface(fixture)
        controller.setFilterQuery("match")
        XCTAssertEqual(paths(controller), ["parent", "parent/match.txt"])
        try select(["parent/match.txt"], in: controller)
        controller.newFolder(nil)
        await controller.extractionTask?.value
        XCTAssertTrue(try names(fixture).contains("parent/" + leaf + " 3/"))
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["parent/" + leaf + " 3"])
        XCTAssertTrue(controller.outlineView.isRenaming)
        XCTAssertEqual(controller.filterQuery, "")
        XCTAssertEqual(controller.searchField.stringValue, "")
    }

    @MainActor func testNewFolderMenusUseShiftCommandNAndExposeReadOnlyReason() async throws {
        let (_, controller) = try await interface(Fixture())
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
        let fixture = try Fixture(tar: true), before = try digest(fixture)
        let (document, readOnly) = try await interface(fixture)
        readOnly.setFilterQuery("a")
        XCTAssertFalse(readOnly.validateMenuItem(item))
        XCTAssertEqual(item.toolTip, document.session?.capabilities.readOnlyReason)
        XCTAssertFalse(try XCTUnwrap(item.toolTip).isEmpty)
        readOnly.newFolder(nil)
        XCTAssertNil(readOnly.extractionTask)
        XCTAssertEqual(try digest(fixture), before)
    }

    @MainActor func testFilterClearRestoresExpansionAndMultipleSelectionAfterQueryChangesAndReload() async throws {
        let fixture = try Fixture(["a/top.txt", "a/deep/leaf.txt", "b/leaf.txt", "c/keep.txt"])
        let (document, controller) = try await interface(fixture), view = controller.outlineView
        view.collapseItem(try node("a/deep", in: controller))
        view.collapseItem(try node("b", in: controller))
        try select(["a/top.txt", "c/keep.txt"], in: controller)
        let previous = paths(controller)
        controller.searchField.stringValue = "leaf"
        controller.filterEntries(controller.searchField)
        XCTAssertEqual(paths(controller), ["a", "a/deep", "a/deep/leaf.txt", "b", "b/leaf.txt"])
        XCTAssertTrue(view.isItemExpanded(try node("a/deep", in: controller)))
        controller.setFilterQuery("b")
        try select(["b/leaf.txt"], in: controller)
        view.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        try await document.reloadAfterMutation()
        XCTAssertEqual(controller.filterQuery, "b")
        controller.searchField.stringValue = ""
        controller.filterEntries(controller.searchField)
        XCTAssertEqual(paths(controller), previous)
        XCTAssertEqual(Set(controller.selectedNodes.map(\.path)), ["a/top.txt", "c/keep.txt"])
        XCTAssertTrue(view.isItemExpanded(try node("a", in: controller)))
        XCTAssertTrue(view.isItemExpanded(try node("c", in: controller)))
        XCTAssertFalse(view.isItemExpanded(try node("a/deep", in: controller)))
        XCTAssertFalse(view.isItemExpanded(try node("b", in: controller)))
    }

    @MainActor func testFilteredDeleteRemovesEntireRealAndVirtualSubtreesWithUndoRedo() async throws {
        for explicit in [false, true] {
            let initial = ["folder/show.txt", "folder/hidden.txt", "folder/deep/hidden.bin", "outside/show.txt"]
                + (explicit ? ["folder/", "folder/deep/"] : [])
            let fixture = try Fixture(initial), (document, controller) = try await interface(fixture)
            let before = try digest(fixture)
            controller.setFilterQuery("show")
            // 検索語を親の名前に含めない。隠れた子孫がある状態でなければ cascade の検証にならない。
            XCTAssertEqual(paths(controller), ["folder", "folder/show.txt", "outside", "outside/show.txt"])
            XCTAssertFalse(paths(controller).contains("folder/hidden.txt"))
            XCTAssertFalse(paths(controller).contains("folder/deep/hidden.bin"))
            try select(["folder"], in: controller)
            XCTAssertEqual(ArchiveEditSelection(try XCTUnwrap(controller.selectedNodes.first)).entries.count, explicit ? 5 : 3)
            controller.deleteEntries(nil)
            await controller.extractionTask?.value
            XCTAssertEqual(try names(fixture), ["outside/show.txt"])
            XCTAssertEqual(controller.filterQuery, "show")
            XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
            let after = try digest(fixture)
            document.undo(nil)
            await document.undoTask?.value
            XCTAssertNil(document.undoFailure)
            XCTAssertEqual(try digest(fixture), before)
            XCTAssertEqual(paths(controller), ["folder", "folder/show.txt", "outside", "outside/show.txt"])
            document.redo(nil)
            await document.undoTask?.value
            XCTAssertNil(document.undoFailure)
            XCTAssertEqual(try digest(fixture), after)
            XCTAssertEqual(paths(controller), ["outside", "outside/show.txt"])
        }
    }

    @MainActor func testFilteredInlineRenameRewritesHiddenDescendantsOfRealAndVirtualFolders() async throws {
        for explicit in [false, true] {
            let initial = ["folder/show.txt", "folder/hidden.txt", "folder/deep/hidden.bin", "outside/show.txt"]
                + (explicit ? ["folder/", "folder/deep/"] : [])
            let fixture = try Fixture(initial), (document, controller) = try await interface(fixture)
            let before = try digest(fixture)
            controller.setFilterQuery("show")
            XCTAssertEqual(paths(controller), ["folder", "folder/show.txt", "outside", "outside/show.txt"])
            try select(["folder"], in: controller)
            let (field, editor) = try editor(controller, text: "renamed")
            commit(controller, field: field, editor: editor)
            await controller.extractionTask?.value
            let expected = initial.map { $0.hasPrefix("folder/") ? "renamed/" + $0.dropFirst("folder/".count) : $0 }
            XCTAssertEqual(try names(fixture), Set(expected))
            XCTAssertEqual(paths(controller), ["renamed", "renamed/show.txt", "outside", "outside/show.txt"])
            XCTAssertEqual(controller.selectedNodes.map(\.path), ["renamed"])
            XCTAssertEqual(controller.filterQuery, "show")
            document.undo(nil)
            await document.undoTask?.value
            XCTAssertNil(document.undoFailure)
            XCTAssertEqual(try digest(fixture), before)
            XCTAssertEqual(paths(controller), ["folder", "folder/show.txt", "outside", "outside/show.txt"])
        }
    }

    @MainActor func testClearingFilterAfterRenameRestoresRenamedFolderSelectionAndExpansion() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('folder/show.txt', b'show')
            z.writestr('folder/deep/hidden.txt', b'hidden')
        """)
        let (document, controller) = try await scenarioDocument(fixture), view = controller.outlineView
        view.expandItem(nil, expandChildren: true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.makeFirstResponder(view)
        try select(["folder"], in: controller)
        controller.setFilterQuery("show")
        let (field, editor) = try editor(controller, text: "renamed")
        commit(controller, field: field, editor: editor)
        let task = try XCTUnwrap(controller.extractionTask)
        await task.value
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(controller.filterQuery, "show")

        controller.setFilterQuery("")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["renamed"])
        XCTAssertTrue(view.isItemExpanded(try node("renamed", in: controller)))
        XCTAssertTrue(view.isItemExpanded(try node("renamed/deep", in: controller)))
    }

    @MainActor func testClearingFilterAfterMoveRestoresMovedDescendantAndExpandsItsNewAncestors() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('folder/show.txt', b'show')
            z.writestr('destination/show.txt', b'keep')
        """)
        let (document, controller) = try await scenarioDocument(fixture), view = controller.outlineView
        view.expandItem(try node("folder", in: controller))
        try select(["folder/show.txt"], in: controller)
        XCTAssertFalse(view.isItemExpanded(try node("destination", in: controller)))
        controller.setFilterQuery("show")
        try select(["folder"], in: controller)
        let (_, info) = moveDrag(controller.selectedNodes, in: controller)
        let target = try node("destination", in: controller)
        XCTAssertTrue(controller.outlineView(view, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        let task = try XCTUnwrap(controller.extractionTask)
        await task.value
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(controller.filterQuery, "show")

        controller.setFilterQuery("")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["destination/folder/show.txt"])
        XCTAssertTrue(view.isItemExpanded(try node("destination", in: controller)))
        XCTAssertTrue(view.isItemExpanded(try node("destination/folder", in: controller)))
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
        try select(["broken.zip"], in: controller)
        controller.openEntry(nil)
        try await scenarioWait {
            guard let alert = controller.failureAlert else { return false }
            return window.attachedSheet === alert.window
        }
        let extracted = try XCTUnwrap(materialization.item(at: 0)?.previewItemURL)
        XCTAssertEqual(try Data(contentsOf: extracted), Data([0x50, 0x4b, 0x03, 0x04]) + Data("garbage".utf8))
        XCTAssertEqual(try XCTUnwrap(controller.failureAlert).messageText, "項目を開けませんでした")
    }

    @MainActor func testFilterChangePreservesInvalidInlineRenameUntilCorrected() async throws {
        let fixture = try Fixture(), (_, controller) = try await interface(fixture)
        controller.setFilterQuery(".txt")
        try select(["b.txt"], in: controller)
        let (field, editor) = try editor(controller, text: "a.txt")
        controller.searchField.stringValue = "c"
        controller.filterEntries(controller.searchField)
        XCTAssertEqual(controller.filterQuery, ".txt")
        XCTAssertEqual(controller.searchField.stringValue, ".txt")
        XCTAssertTrue(controller.outlineView.isRenaming)
        XCTAssertEqual(editor.string, "a.txt")
        XCTAssertNotNil(field.toolTip)
        XCTAssertNil(controller.extractionTask)
        editor.string = "corrected.txt"
        commit(controller, field: field, editor: editor)
        await controller.extractionTask?.value
        XCTAssertTrue(try names(fixture).contains("corrected.txt"))
    }

    @MainActor func testFilteredFolderCopyPreparationAndDragPromiseIncludeHiddenEntries() async throws {
        let fixture = try Fixture(["folder/show.txt", "folder/deep/hidden.bin", "outside.txt"])
        let (document, controller) = try await interface(fixture), session = try XCTUnwrap(document.session)
        controller.setFilterQuery("show")
        try select(["folder"], in: controller)
        XCTAssertEqual(paths(controller), ["folder", "folder/show.txt"])
        let folder = try XCTUnwrap(controller.selectedNodes.first)
        let payload = ArchiveEntryPayload(node: folder, archiveURL: fixture.archive, generation: session.generation)
        let prepared = try await ArchiveCopyOut.prepare([payload], from: session, progress: Progress(),
            temporaryDirectory: ExtractionTemporaryDirectory(root: fixture.directory.appendingPathComponent("copy")))
        let copy = try XCTUnwrap(prepared.urls.first)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("show.txt")), Data("folder/show.txt".utf8))
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("deep/hidden.bin")), Data("folder/deep/hidden.bin".utf8))
        // 型サービスが遮断されても、promise の書き込み自体は選択した完全な部分木で検証する。
        let provider = NSFilePromiseProvider(), delegate = ArchiveFilePromise(payload: payload, session: session)
        let output = fixture.directory.appendingPathComponent("promised-folder")
        let completion = Mutex((calls: 0, failure: Optional<String>.none))
        delegate.filePromiseProvider(provider, writePromiseTo: output) { @Sendable error in
            completion.withLock { $0.calls += 1; $0.failure = error.map(String.init(describing:)) }
        }
        try await waitUntil { completion.withLock { $0.calls > 0 } }
        XCTAssertEqual(completion.withLock { $0.calls }, 1)
        XCTAssertNil(completion.withLock { $0.failure })
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("deep/hidden.bin")), Data("folder/deep/hidden.bin".utf8))
    }

    @MainActor func testFilteredDragSourceBuildsPromiseWithFullSubtreePayload() async throws {
        guard UTType.folder.conforms(to: .directory) else {
            throw XCTSkip("この実行環境では LaunchServices が public.folder を解決できません")
        }
        let fixture = try Fixture(["folder/show.txt", "folder/hidden.txt", "outside.txt"])
        let (document, controller) = try await interface(fixture), session = try XCTUnwrap(document.session)
        controller.setFilterQuery("show")
        let folder = try node("folder", in: controller)
        XCTAssertEqual(paths(controller), ["folder", "folder/show.txt"])
        let provider = try XCTUnwrap(controller.outlineView(controller.outlineView, pasteboardWriterForItem: folder) as? NSFilePromiseProvider)
        let delegate = try XCTUnwrap(provider.delegate as? ArchiveFilePromise)
        let entries = await session.entries()
        XCTAssertEqual(provider.fileType, UTType.folder.identifier)
        XCTAssertEqual(try delegate.payload.resolve(in: entries, generation: session.generation).map(\.name),
                       ["folder/show.txt", "folder/hidden.txt"])
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

    nonisolated private final class MoveDraggingSession: NSDraggingSession {
        private let sequence = Int.random(in: Int.min..<0)
        override var draggingSequenceNumber: Int { sequence }
    }

    @MainActor private final class MoveDraggingInfo: NSObject, NSDraggingInfo {
        var draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation = [.move, .copy]
        var draggingLocation: NSPoint = .zero
        var draggedImageLocation: NSPoint { .zero }
        nonisolated var draggedImage: NSImage? { nil }
        let pasteboard = NSPasteboard(name: .init("KaitoFinder-Move-" + UUID().uuidString))
        var pasteboardReads = 0
        var draggingPasteboard: NSPasteboard { pasteboardReads += 1; return pasteboard }
        var draggingSource: Any?
        var draggingSequenceNumber = 0
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 0
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        func resetSpringLoading() {}
    }

    @MainActor private final class MoveDropOutline: NSOutlineView {
        var hovered: EntryNode?
        private(set) var proposedFolder: EntryNode?
        private(set) var proposedIndex: Int?
        override func row(at point: NSPoint) -> Int { hovered == nil ? -1 : 0 }
        override func item(atRow row: Int) -> Any? { hovered }
        override func setDropItem(_ item: Any?, dropChildIndex index: Int) {
            proposedFolder = item as? EntryNode
            proposedIndex = index
        }
    }

    @MainActor private func moveDrag(_ nodes: [EntryNode], in controller: ArchiveWindowController)
        -> (MoveDraggingSession, MoveDraggingInfo) {
        let session = MoveDraggingSession(), info = MoveDraggingInfo()
        info.draggingSource = controller.outlineView
        info.draggingDestinationWindow = controller.window
        info.draggingSequenceNumber = session.draggingSequenceNumber
        controller.outlineView(controller.outlineView, draggingSession: session, willBeginAt: .zero, forItems: nodes)
        addTeardownBlock { @MainActor in
            controller.outlineView(controller.outlineView, draggingSession: session, endedAt: .zero, operation: [])
            info.pasteboard.releaseGlobally()
        }
        return (session, info)
    }

    @MainActor func testLocalDragValidationReturnsMoveAndHighlightsHoveredFilesParent() async throws {
        let fixture = try Fixture(["a/x.txt", "b/deep/target.txt"]), (_, controller) = try await interface(fixture)
        let dragged = try node("a/x.txt", in: controller), folder = try node("b/deep", in: controller)
        let (session, info) = moveDrag([dragged], in: controller), view = MoveDropOutline()
        view.hovered = try node("b/deep/target.txt", in: controller)
        info.draggingSource = view
        XCTAssertEqual(controller.outlineView.draggingSession(session, sourceOperationMaskFor: .withinApplication), [.move, .copy])
        XCTAssertEqual(controller.outlineView.draggingSession(session, sourceOperationMaskFor: .outsideApplication), .copy)
        XCTAssertTrue(controller.draggedNodes.first === dragged)
        XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: view.hovered, proposedChildIndex: 0), .move)
        XCTAssertTrue(view.proposedFolder === folder)
        XCTAssertEqual(view.proposedIndex, NSOutlineViewDropOnItemIndex)
        view.hovered = folder
        XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), .move)
        XCTAssertTrue(view.proposedFolder === folder)
        view.hovered = nil
        XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), .move)
        XCTAssertNil(view.proposedFolder)
        controller.outlineView(controller.outlineView, draggingSession: session, endedAt: .zero, operation: .move)
        XCTAssertTrue(controller.draggedNodes.isEmpty)
        XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), [])
    }

    @MainActor func testOptionAndCrossArchiveDragValidationRemainCopy() async throws {
        let fixture = try Fixture(["a/x.txt", "b/target.txt"]), (_, controller) = try await interface(fixture)
        let otherFixture = try Fixture(), (_, other) = try await interface(otherFixture)
        let (_, info) = moveDrag([try node("a/x.txt", in: controller)], in: controller)
        // 実際の型照会を通し、copy だけは引き続き pasteboard を必要とする。
        guard info.pasteboard.writeObjects([fixture.archive as NSURL]) else {
            throw XCTSkip("この実行環境では名前付き pasteboard サービスへ書き込めません")
        }
        let view = MoveDropOutline(), folder = try node("b", in: controller)
        view.hovered = try node("b/target.txt", in: controller)
        info.draggingSource = view
        info.draggingSourceOperationMask = .copy
        XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), .copy)
        XCTAssertTrue(view.proposedFolder === folder)
        info.draggingSource = other.outlineView
        info.draggingSourceOperationMask = [.move, .copy]
        XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), .copy)
        XCTAssertTrue(view.proposedFolder === folder)
        info.draggingSource = nil
        XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), .copy)
    }

    @MainActor func testLocalDragValidationAndAcceptanceRefuseSameParentOwnSubtreeAndReadOnlyArchive() async throws {
        let fixture = try Fixture(["a/x.txt", "a/deep/y.txt", "b/"]), (_, controller) = try await interface(fixture)
        let before = try digest(fixture), view = MoveDropOutline()
        for (source, target) in [("a/x.txt", "a"), ("a", "a"), ("a", "a/deep")] {
            let (_, info) = moveDrag([try node(source, in: controller)], in: controller)
            view.hovered = try node(target, in: controller)
            info.draggingSource = view
            XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), [])
            XCTAssertNil(view.proposedIndex)
            XCTAssertFalse(controller.outlineView(view, acceptDrop: info, item: view.hovered, childIndex: NSOutlineViewDropOnItemIndex))
            XCTAssertNil(controller.extractionTask)
        }
        XCTAssertEqual(try digest(fixture), before)
        let readOnly = try Fixture(["a/x.txt"], tar: true), (_, readOnlyController) = try await interface(readOnly)
        let (_, info) = moveDrag([try node("a/x.txt", in: readOnlyController)], in: readOnlyController)
        let readOnlyBefore = try digest(readOnly)
        info.draggingSource = view
        view.hovered = nil
        for mask: NSDragOperation in [[.move, .copy], .copy] {
            info.draggingSourceOperationMask = mask
            XCTAssertEqual(readOnlyController.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), [])
            XCTAssertFalse(readOnlyController.outlineView(view, acceptDrop: info, item: nil, childIndex: NSOutlineViewDropOnItemIndex))
            XCTAssertNil(readOnlyController.conversionConfirmation)
            XCTAssertNil(readOnlyController.extractionTask)
        }
        XCTAssertEqual(try digest(readOnly), readOnlyBefore)
    }

    @MainActor func testAcceptLocalMoveMovesMultipleEntriesExpandsDestinationAndSelectsNewPaths() async throws {
        let fixture = try Fixture(["a/x.txt", "a/y.txt", "b/deep/keep.txt"])
        let (document, controller) = try await interface(fixture), before = try digest(fixture)
        let nodes = try [node("a/x.txt", in: controller), node("a/y.txt", in: controller)]
        let target = try node("b/deep/keep.txt", in: controller)
        try select(["a/x.txt", "a/y.txt"], in: controller)
        let (session, info) = moveDrag(nodes, in: controller)
        controller.outlineView.collapseItem(try node("b", in: controller), collapseChildren: true)
        // move は pasteboard を一度も読まない。drag 終了で配列を消しても Task は選択を保持する。
        XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        XCTAssertEqual(info.pasteboardReads, 0)
        XCTAssertEqual(controller.editProgressSheet?.window?.title, String(localized: "項目を移動中…"))
        let task = try XCTUnwrap(controller.extractionTask)
        controller.outlineView(controller.outlineView, draggingSession: session, endedAt: .zero, operation: .move)
        XCTAssertTrue(controller.draggedNodes.isEmpty)
        await task.value
        XCTAssertEqual(try names(fixture), ["b/deep/x.txt", "b/deep/y.txt", "b/deep/keep.txt"])
        XCTAssertEqual(Set(controller.selectedNodes.map(\.path)), ["b/deep/x.txt", "b/deep/y.txt"])
        XCTAssertTrue(controller.outlineView.isItemExpanded(try node("b", in: controller)))
        XCTAssertTrue(controller.outlineView.isItemExpanded(try node("b/deep", in: controller)))
        XCTAssertNil(controller.editProgressSheet)
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
        XCTAssertTrue(try XCTUnwrap(document.undoManager).undoMenuItemTitle.contains(String(localized: "移動")))
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(try digest(fixture), before)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testAcceptLocalDirectoryMoveKeepsExpandedDescendantsAndSelectsMovedFolder() async throws {
        let fixture = try Fixture(["a/", "a/deep/", "a/deep/x.txt", "a/y.txt", "b/"])
        let (_, controller) = try await interface(fixture)
        let source = try node("a", in: controller), target = try node("b", in: controller)
        let (_, info) = moveDrag([source], in: controller)
        XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["b/", "b/a/", "b/a/deep/", "b/a/deep/x.txt", "b/a/y.txt"])
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["b/a"])
        XCTAssertTrue(controller.outlineView.isItemExpanded(try node("b/a", in: controller)))
        XCTAssertTrue(controller.outlineView.isItemExpanded(try node("b/a/deep", in: controller)))
        XCTAssertTrue(paths(controller).contains("b/a/deep/x.txt"))
    }

    @MainActor func testAcceptLocalMoveRevealsSelectionWhenOldParentWasTheOnlyFilterMatch() async throws {
        let fixture = try Fixture(["old/x.txt", "b/old-reference.txt"]), (_, controller) = try await interface(fixture)
        controller.setFilterQuery("old")
        let source = try node("old/x.txt", in: controller), target = try node("b", in: controller)
        let (_, info) = moveDrag([source], in: controller)
        XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        await controller.extractionTask?.value
        XCTAssertEqual(controller.filterQuery, "")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["b/x.txt"])
        XCTAssertEqual(try names(fixture), ["b/x.txt", "b/old-reference.txt"])
    }

    @MainActor func testAcceptLocalMoveCollisionReportsReasonWithoutChangingArchiveOrUndo() async throws {
        let fixture = try Fixture(["a/x.txt", "a/y.txt", "b/x.txt"])
        let (document, controller) = try await interface(fixture), before = try digest(fixture)
        try select(["a/x.txt", "a/y.txt"], in: controller)
        let (_, info) = moveDrag(controller.selectedNodes, in: controller), target = try node("b", in: controller)
        XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        await controller.extractionTask?.value
        XCTAssertEqual(try digest(fixture), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertEqual(Set(controller.selectedNodes.map(\.path)), ["a/x.txt", "a/y.txt"])
        let sheet = try XCTUnwrap(controller.window?.attachedSheet)
        defer { controller.window?.endSheet(sheet); sheet.orderOut(nil) }
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        let text = labels(try XCTUnwrap(sheet.contentView))
        XCTAssertTrue(text.contains(String(localized: "項目を変更できませんでした")), text.description)
        XCTAssertTrue(text.contains(String(localized: "同じ名前の項目が既にあります。別の名前を入力してください。")), text.description)
    }

    @MainActor func testPendingMoveDisablesEditsAndDropsAndCancellationPreservesBytes() async throws {
        let fixture = try Fixture(["a/x.txt", "b/"]), gate = Gate()
        let stack = ArchiveUndoStack { source, destination in
            let result = ArchiveUndoStack.cloneFile(from: source, to: destination)
            gate.wait()
            return result
        }
        let (document, controller) = try await interface(fixture, stack: stack), before = try digest(fixture)
        try select(["a/x.txt"], in: controller)
        let (_, info) = moveDrag(controller.selectedNodes, in: controller), target = try node("b", in: controller)
        XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        let task = try XCTUnwrap(controller.extractionTask)
        defer { gate.release.signal() }
        try await waitUntil { gate.entered.withLock { $0 } }
        for action in [#selector(ArchiveWindowController.newFolder(_:)), #selector(ArchiveWindowController.deleteEntries(_:)),
                       #selector(ArchiveWindowController.renameEntry(_:))] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item))
            XCTAssertFalse(try XCTUnwrap(item.toolTip).isEmpty)
        }
        let view = MoveDropOutline()
        view.hovered = target
        info.draggingSource = view
        XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), [])
        XCTAssertFalse(controller.outlineView(view, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        let other = try node("a", in: controller)
        do { _ = try await document.move([other], to: "b", progress: Progress()); XCTFail("処理中の移動を受理しました") }
        catch { XCTAssertTrue(error is ExtractionFailure) }
        try XCTUnwrap(controller.editProgressSheet).cancelExtraction(nil)
        gate.release.signal()
        await task.value
        XCTAssertEqual(try digest(fixture), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testMoveStringsHaveExactJapaneseAndEnglishLocalizations() throws {
        let bundle = Bundle(for: ArchiveDocument.self)
        let translations = [
            ("移動", "Move"), ("項目を移動中…", "Moving…"),
            ("同じ場所です。", "The items are already in this folder."),
            ("フォルダを自分自身の中へは移動できません。", "A folder cannot be moved into itself or one of its subfolders."),
            ("移動先のフォルダが見つかりません。", "The destination folder could not be found.")
        ]
        for language in ["ja", "en"] {
            let localized = try XCTUnwrap(Bundle(url: XCTUnwrap(bundle.url(forResource: language, withExtension: "lproj"))))
            for (key, english) in translations {
                XCTAssertEqual(String(localized: String.LocalizationValue(key), bundle: localized), language == "ja" ? key : english)
            }
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
