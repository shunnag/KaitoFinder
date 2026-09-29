import AppKit
import Synchronization
import XCTest
@testable import KaitoFinder

/// ArchiveWindowController・ArchiveDocument・ArchiveUndoStack の項目削除を確かめる 10 テスト。
/// ScenarioFixture と SheetRecordingWindow を使い、確認シート・子孫の削除・選択・取り消しとやり直し後の書庫を観測する。
nonisolated final class ArchiveEntryDeleteTests: XCTestCase {
    @MainActor private func editor(_ controller: ArchiveWindowController, text: String) throws -> (NSTextField, NSTextView) {
        let view = controller.outlineView
        XCTAssertTrue(view.handleEntryKey("\r", modifiers: []))
        let field = try XCTUnwrap(view.renameField)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = text
        return (field, editor)
    }

    @MainActor func testMultiSelectionDeletesOnceAndRegistersOneUndoEntryWithoutConfirmation() async throws {
        let fixture = try ScenarioFixture.withEntries(), captures = Mutex(0)
        let stack = ArchiveUndoStack { source, destination in
            captures.withLock { $0 += 1 }
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let (document, controller) = try await interface(fixture, stack: stack)
        XCTAssertTrue(document.canUndoNextMutation)
        try controller.select(paths: ["a.txt", "c.txt"])
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
        let fixture = try ScenarioFixture.withEntries(["virtual/a.txt", "virtual/deep/b.txt", "virtualish/keep.txt"])
        let (document, controller) = try await interface(fixture)
        XCTAssertTrue(try controller.displayedNode("virtual").isVirtual)
        try controller.select(paths: ["virtual", "virtual/a.txt"])
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["virtualish/keep.txt"])
        XCTAssertFalse(controller.displayedPaths.contains("virtual"))
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
    }

    @MainActor func testDeletingRealDirectoryRemovesDirectoryAndDescendants() async throws {
        let fixture = try ScenarioFixture.withEntries(["real/", "real/a.txt", "real/deep/", "real/deep/b.txt", "keep.txt"])
        let (_, controller) = try await interface(fixture)
        XCTAssertFalse(try controller.displayedNode("real").isVirtual)
        try controller.select(paths: ["real"])
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["keep.txt"])
        XCTAssertEqual(controller.displayedPaths, ["keep.txt"])
    }

    @MainActor func testDeleteOverUndoByteLimitRequiresConfirmationWithoutChangingArchive() async throws {
        let fixture = try ScenarioFixture(), stack = ArchiveUndoStack(maximumBytes: 16)
        let (document, controller, window) = try await sheetRecordingDocument(fixture, stack: stack)
        addTeardownBlock { @MainActor in
            for sheet in window.requestedSheets { window.endSheet(sheet, returnCode: .cancel) }
        }
        let before = try ScenarioFixture.digest(fixture.archive)
        XCTAssertGreaterThan(UInt64(try Data(contentsOf: fixture.archive).count), stack.maximumBytes)
        XCTAssertFalse(document.canUndoNextMutation)
        try controller.select(paths: ["original.txt"])

        controller.deleteEntries(nil)

        XCTAssertNotNil(controller.deletionConfirmation)
        XCTAssertNil(controller.extractionTask)
        XCTAssertNil(window.attachedSheet)
        // 退行時に始まった削除も完了させ、原本の変更を検出する。
        await controller.extractionTask?.value
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testDeleteAtUndoByteLimitStartsWithoutConfirmation() async throws {
        let fixture = try ScenarioFixture()
        let stack = ArchiveUndoStack(maximumBytes: UInt64(try Data(contentsOf: fixture.archive).count))
        let (document, controller, window) = try await sheetRecordingDocument(fixture, stack: stack)
        addTeardownBlock { @MainActor in
            for sheet in window.requestedSheets { window.endSheet(sheet, returnCode: .cancel) }
        }
        XCTAssertTrue(document.canUndoNextMutation)
        try controller.select(paths: ["original.txt"])

        controller.deleteEntries(nil)

        XCTAssertNil(controller.deletionConfirmation)
        XCTAssertNil(window.attachedSheet)
        let task = try XCTUnwrap(controller.extractionTask)
        await task.value
        XCTAssertTrue(try ScenarioFixture.contents(fixture.archive).isEmpty)
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(stack.slots.count, 1)
        XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testNonUndoableDeleteRequiresOneConfirmationAndHonorsBothResponses() async throws {
        // 文書のフラグを保持件数から false にする。ボリューム判定は偽装しない。
        let fixture = try ScenarioFixture.withEntries(), stack = ArchiveUndoStack(maximumCount: 0)
        let (document, controller) = try await interface(fixture, stack: stack)
        XCTAssertFalse(document.canUndoNextMutation)
        let before = try ArchiveOracle.digest(fixture.archive)
        try controller.select(paths: ["a.txt", "c.txt"])
        controller.deleteEntries(nil)
        let declined = try XCTUnwrap(controller.deletionConfirmation)
        XCTAssertNil(controller.extractionTask)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        controller.deleteEntries(nil)
        XCTAssertTrue(controller.deletionConfirmation === declined)
        controller.window?.endSheet(declined.window, returnCode: .alertSecondButtonReturn)
        try await waitUntil { controller.deletionConfirmation == nil }
        XCTAssertNil(controller.extractionTask)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
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

    @MainActor func testDeletingMiddleSiblingSelectsFollowingSibling() async throws {
        let fixture = try ScenarioFixture.withEntries(), (_, controller) = try await interface(fixture)
        try controller.select(paths: ["b.txt"])
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["c.txt"])
    }

    @MainActor func testDeletingOnlyChildSelectsSurvivingParent() async throws {
        let fixture = try ScenarioFixture.withEntries(["folder/", "folder/child.txt"])
        let (_, controller) = try await interface(fixture)
        try controller.select(paths: ["folder/child.txt"])
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["folder/"])
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["folder"])
    }

    @MainActor func testUndoAndRedoRebuildOutlineAndRestoreDeleteBytes() async throws {
        let fixture = try ScenarioFixture.withEntries(), (document, controller) = try await interface(fixture)
        let before = try Data(contentsOf: fixture.archive)
        try controller.select(paths: ["b.txt"])
        let oldNode = try controller.displayedNode("b.txt")
        controller.deleteEntries(nil)
        await controller.extractionTask?.value
        let after = try Data(contentsOf: fixture.archive)
        XCTAssertFalse(controller.displayedPaths.contains("b.txt"))
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertEqual(controller.displayedPaths, ["a.txt", "b.txt", "c.txt"])
        XCTAssertFalse(try controller.displayedNode("b.txt") === oldNode)
        try controller.select(paths: ["b.txt"])
        let (field, _) = try editor(controller, text: "stale.txt")
        document.redo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertFalse(controller.outlineView.isRenaming)
        XCTAssertNil(field.currentEditor())
        XCTAssertEqual(try Data(contentsOf: fixture.archive), after)
        XCTAssertFalse(controller.displayedPaths.contains("b.txt"))
        XCTAssertEqual(document.generation, 3)
        XCTAssertNil(controller.extractionTask)
    }

    @MainActor func testFilteredDeleteRemovesEntireRealAndVirtualSubtreesWithUndoRedo() async throws {
        for explicit in [false, true] {
            let initial = ["folder/show.txt", "folder/hidden.txt", "folder/deep/hidden.bin", "outside/show.txt"]
                + (explicit ? ["folder/", "folder/deep/"] : [])
            let fixture = try ScenarioFixture.withEntries(initial), (document, controller) = try await interface(fixture)
            let before = try ArchiveOracle.digest(fixture.archive)
            controller.setFilterQuery("show")
            // 検索語を親の名前に含めない。隠れた子孫がある状態でなければ cascade の検証にならない。
            XCTAssertEqual(controller.displayedPaths, ["folder", "folder/show.txt", "outside", "outside/show.txt"])
            XCTAssertFalse(controller.displayedPaths.contains("folder/hidden.txt"))
            XCTAssertFalse(controller.displayedPaths.contains("folder/deep/hidden.bin"))
            try controller.select(paths: ["folder"])
            XCTAssertEqual(ArchiveEditSelection(try XCTUnwrap(controller.selectedNodes.first)).entries.count, explicit ? 5 : 3)
            controller.deleteEntries(nil)
            await controller.extractionTask?.value
            XCTAssertEqual(try names(fixture), ["outside/show.txt"])
            XCTAssertEqual(controller.filterQuery, "show")
            XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
            let after = try ArchiveOracle.digest(fixture.archive)
            document.undo(nil)
            await document.undoTask?.value
            XCTAssertNil(document.undoFailure)
            XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
            XCTAssertEqual(controller.displayedPaths, ["folder", "folder/show.txt", "outside", "outside/show.txt"])
            document.redo(nil)
            await document.undoTask?.value
            XCTAssertNil(document.undoFailure)
            XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), after)
            XCTAssertEqual(controller.displayedPaths, ["outside", "outside/show.txt"])
        }
    }
}
