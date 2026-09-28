import AppKit
import XCTest
@testable import KaitoFinder

/// ArchiveWindowController・ArchiveOutlineView のインライン改名を確かめる 18 テスト。
/// ScenarioFixture・ScenarioGate・SheetRecordingWindow を使い、入力検証・確定と取消し・選択・書庫の内容を観測する。
nonisolated final class ArchiveEntryRenameTests: XCTestCase {
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

    @MainActor func testReturnCommitsInlineRenameAndPreservesSelection() async throws {
        let fixture = try ScenarioFixture.withEntries(), (document, controller) = try await interface(fixture)
        try controller.select(paths: ["b.txt"])
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
        let fixture = try ScenarioFixture.withEntries(), (document, controller) = try await interface(fixture)
        let before = try ArchiveOracle.digest(fixture.archive)
        try controller.select(paths: ["b.txt"])
        let (field, editor) = try editor(controller, text: "renamed.txt")
        XCTAssertTrue(controller.outlineView.control(field, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertFalse(controller.outlineView.isRenaming)
        XCTAssertNil(field.currentEditor())
        XCTAssertNil(controller.extractionTask)
        XCTAssertEqual(field.stringValue, "b.txt")
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testFocusLossCommitsInlineRename() async throws {
        let fixture = try ScenarioFixture.withEntries(), (_, controller) = try await interface(fixture)
        try controller.select(paths: ["b.txt"])
        let (field, _) = try editor(controller, text: "focus.txt")
        // Window の responder 移動を使い、終了通知だけを偽造しない。
        XCTAssertTrue(try XCTUnwrap(controller.window).makeFirstResponder(controller.outlineView))
        await controller.extractionTask?.value
        XCTAssertNil(field.currentEditor())
        XCTAssertFalse(controller.outlineView.isRenaming)
        XCTAssertEqual(try names(fixture), ["a.txt", "focus.txt", "c.txt"])
    }

    @MainActor private func assertRenameSurvivesFollowingOperation(password: Bool) async throws {
        let fixture = try ScenarioFixture(), gate = ScenarioGate()
        defer { gate.release() }
        let stack = ArchiveUndoStack(clone: { source, destination in
            gate.pauseOnce()
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        })
        let (document, controller, window) = try await sheetRecordingDocument(fixture, stack: stack)
        let action = password ? #selector(ArchiveWindowController.setArchivePassword(_:))
            : #selector(ArchiveWindowController.saveArchiveAs(_:))
        XCTAssertTrue(controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")))
        try controller.select(paths: ["original.txt"])
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
        XCTAssertTrue(window.requestedSheets.isEmpty)
        XCTAssertNotNil(controller.editProgressSheet)
        XCTAssertNil(window.attachedSheet)

        try await scenarioWait { gate.isEntered }
        try await scenarioWait { window.requestedSheets.count == 1 }
        XCTAssertTrue(window.requestedSheets.first === controller.editProgressSheet?.window)
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
        let fixture = try ScenarioFixture.withEntries(), (document, controller) = try await interface(fixture)
        let before = try ArchiveOracle.digest(fixture.archive)
        try controller.select(paths: ["b.txt"])
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
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
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
        let fixture = try ScenarioFixture.withEntries(), (_, controller) = try await interface(fixture)
        let before = try ArchiveOracle.digest(fixture.archive)
        try controller.select(paths: ["b.txt"])
        let (field, editor) = try editor(controller, text: "a.txt")
        let view = controller.outlineView
        view.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertTrue(try XCTUnwrap(view.sortDescriptors.first).ascending)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
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
        let fixture = try ScenarioFixture.withEntries(), (_, controller) = try await interface(fixture)
        try controller.select(paths: ["b.txt"])
        let (field, editor) = try editor(controller, text: "a.txt")
        commit(controller, field: field, editor: editor)
        XCTAssertTrue(field.currentEditor() === editor)
        editor.string = "corrected.txt"
        commit(controller, field: field, editor: editor)
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["a.txt", "corrected.txt", "c.txt"])
    }

    @MainActor func testRenameRejectsVirtualFolderCollisionAndRenamesWholeSubtree() async throws {
        let fixture = try ScenarioFixture.withEntries(["source/a.txt", "source/deep/b.txt", "occupied/keep.txt"])
        let (document, controller) = try await interface(fixture)
        let before = try ArchiveOracle.digest(fixture.archive)
        try controller.select(paths: ["source"])
        let (field, editor) = try editor(controller, text: "occupied")
        commit(controller, field: field, editor: editor)
        XCTAssertTrue(field.currentEditor() === editor)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        editor.string = "renamed"
        commit(controller, field: field, editor: editor)
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["renamed/a.txt", "renamed/deep/b.txt", "occupied/keep.txt"])
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["renamed"])
        XCTAssertTrue(controller.displayedPaths.contains("renamed/deep/b.txt"))
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
    }

    @MainActor func testFilteredInlineRenameRewritesHiddenDescendantsOfRealAndVirtualFolders() async throws {
        for explicit in [false, true] {
            let initial = ["folder/show.txt", "folder/hidden.txt", "folder/deep/hidden.bin", "outside/show.txt"]
                + (explicit ? ["folder/", "folder/deep/"] : [])
            let fixture = try ScenarioFixture.withEntries(initial), (document, controller) = try await interface(fixture)
            let before = try ArchiveOracle.digest(fixture.archive)
            controller.setFilterQuery("show")
            XCTAssertEqual(controller.displayedPaths, ["folder", "folder/show.txt", "outside", "outside/show.txt"])
            try controller.select(paths: ["folder"])
            let (field, editor) = try editor(controller, text: "renamed")
            commit(controller, field: field, editor: editor)
            await controller.extractionTask?.value
            let expected = initial.map { $0.hasPrefix("folder/") ? "renamed/" + $0.dropFirst("folder/".count) : $0 }
            XCTAssertEqual(try names(fixture), Set(expected))
            XCTAssertEqual(controller.displayedPaths, ["renamed", "renamed/show.txt", "outside", "outside/show.txt"])
            XCTAssertEqual(controller.selectedNodes.map(\.path), ["renamed"])
            XCTAssertEqual(controller.filterQuery, "show")
            document.undo(nil)
            await document.undoTask?.value
            XCTAssertNil(document.undoFailure)
            XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
            XCTAssertEqual(controller.displayedPaths, ["folder", "folder/show.txt", "outside", "outside/show.txt"])
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
        try controller.select(paths: ["folder"])
        controller.setFilterQuery("show")
        let (field, editor) = try editor(controller, text: "renamed")
        commit(controller, field: field, editor: editor)
        let task = try XCTUnwrap(controller.extractionTask)
        await task.value
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(controller.filterQuery, "show")

        controller.setFilterQuery("")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["renamed"])
        XCTAssertTrue(view.isItemExpanded(try controller.displayedNode("renamed")))
        XCTAssertTrue(view.isItemExpanded(try controller.displayedNode("renamed/deep")))
    }

    @MainActor func testFilterChangePreservesInvalidInlineRenameUntilCorrected() async throws {
        let fixture = try ScenarioFixture.withEntries(), (_, controller) = try await interface(fixture)
        controller.setFilterQuery(".txt")
        try controller.select(paths: ["b.txt"])
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
}
