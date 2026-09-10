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
            archive = directory.appendingPathComponent(tar ? "archive.tar" : "archive.zip")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-c", """
            import io, sys, tarfile, zipfile
            p, *names = sys.argv[1:]
            if p.endswith('.tar'):
                with tarfile.open(p, 'w') as a:
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
        let sources = ["UI/ArchiveOutlineView.swift", "UI/ArchiveWindowController.swift", "App/AppDelegate.swift", "Model/ArchiveUndoStack.swift"]
        let localized = try NSRegularExpression(pattern: #"String\(localized:\s*"((?:\\.|[^"\\])*)""#)
        let bareUIString = try NSRegularExpression(pattern: #"(?:withTitle:|(?:messageText|informativeText|toolTip)\s*=)\s*"[^"\n]+""#)
        for path in sources {
            let source = try String(contentsOf: root.appendingPathComponent("KaitoFinder/" + path), encoding: .utf8)
            XCTAssertNil(bareUIString.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), path)
            for match in localized.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let literal = String(source[try XCTUnwrap(Range(match.range(at: 1), in: source))])
                let key = literal.replacingOccurrences(of: #"\(actionName)"#, with: "%@")
                let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
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
            ("ja", ["新規フォルダ", "名称未設定フォルダ", "名前で絞り込む", "フォルダを作成しています"]),
            ("en", ["New Folder", "untitled folder", "Filter by Name", "Creating Folder"])
        ] {
            let localized = try XCTUnwrap(Bundle(url: XCTUnwrap(bundle.url(forResource: language, withExtension: "lproj"))))
            XCTAssertEqual(String(localized: "新規フォルダ", bundle: localized), values[0])
            XCTAssertEqual(String(localized: "名称未設定フォルダ", bundle: localized), values[1])
            XCTAssertEqual(String(localized: "名前で絞り込む", bundle: localized), values[2])
            XCTAssertEqual(String(localized: "フォルダを作成しています", bundle: localized), values[3])
            let base = values[1], number = 2
            XCTAssertEqual(String(localized: "\(base) \(number)", bundle: localized), base + " 2")
        }
    }
}
