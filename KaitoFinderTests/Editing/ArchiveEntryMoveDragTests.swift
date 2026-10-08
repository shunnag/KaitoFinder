import AppKit
import KaitoKit
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import KaitoFinder

/// ArchiveWindowController のドラッグでの移動・コピーを確かめる 13 テスト。
/// ScenarioFixture・ScenarioGate とドラッグの代役を使い、ドロップ検証・競合・選択・書庫と promise の内容を観測する。
nonisolated final class ArchiveEntryMoveDragTests: XCTestCase {
    @MainActor func testClearingFilterAfterMoveRestoresMovedDescendantAndExpandsItsNewAncestors() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('folder/show.txt', b'show')
            z.writestr('destination/show.txt', b'keep')
        """)
        let (document, controller) = try await scenarioDocument(fixture), view = controller.outlineView
        view.expandItem(try controller.displayedNode("folder"))
        try controller.select(paths: ["folder/show.txt"])
        XCTAssertFalse(view.isItemExpanded(try controller.displayedNode("destination")))
        controller.setFilterQuery("show")
        try controller.select(paths: ["folder"])
        let (_, info) = moveDrag(controller.selectedNodes, in: controller)
        let target = try controller.displayedNode("destination")
        XCTAssertTrue(controller.outlineView(view, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        let task = try XCTUnwrap(controller.extractionTask)
        await task.value
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(controller.filterQuery, "show")

        controller.setFilterQuery("")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["destination/folder/show.txt"])
        XCTAssertTrue(view.isItemExpanded(try controller.displayedNode("destination")))
        XCTAssertTrue(view.isItemExpanded(try controller.displayedNode("destination/folder")))
    }

    @MainActor func testFilteredFolderCopyPreparationAndDragPromiseIncludeHiddenEntries() async throws {
        let fixture = try ScenarioFixture.withEntries(["folder/show.txt", "folder/deep/hidden.bin", "outside.txt"])
        let (document, controller) = try await interface(fixture), session = try XCTUnwrap(document.session)
        controller.setFilterQuery("show")
        try controller.select(paths: ["folder"])
        XCTAssertEqual(controller.displayedPaths, ["folder", "folder/show.txt"])
        let folder = try XCTUnwrap(controller.selectedNodes.first)
        let payload = ArchiveEntryPayload(node: folder, archiveURL: fixture.archive, generation: session.generation)
        let prepared = try await ArchiveCopyOut.prepare([payload], from: session, progress: Progress(),
            temporaryDirectory: ExtractionTemporaryDirectory(root: fixture.root.appendingPathComponent("copy")))
        let copy = try XCTUnwrap(prepared.urls.first)
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("show.txt")), Data("folder/show.txt".utf8))
        XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent("deep/hidden.bin")), Data("folder/deep/hidden.bin".utf8))
        // 型サービスが遮断されても、promise の書き込み自体は選択した完全な部分木で検証する。
        let provider = NSFilePromiseProvider(), delegate = ArchiveFilePromise(payload: payload, session: session)
        let output = fixture.root.appendingPathComponent("promised-folder")
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
        let fixture = try ScenarioFixture.withEntries(["folder/show.txt", "folder/hidden.txt", "outside.txt"])
        let (document, controller) = try await interface(fixture), session = try XCTUnwrap(document.session)
        controller.setFilterQuery("show")
        let folder = try controller.displayedNode("folder")
        XCTAssertEqual(controller.displayedPaths, ["folder", "folder/show.txt"])
        let provider = try XCTUnwrap(controller.outlineView(controller.outlineView, pasteboardWriterForItem: folder) as? NSFilePromiseProvider)
        let delegate = try XCTUnwrap(provider.delegate as? ArchiveFilePromise)
        let entries = await session.entries()
        XCTAssertEqual(provider.fileType, UTType.folder.identifier)
        XCTAssertEqual(try delegate.payload.resolve(in: entries, generation: session.generation, syntax: .init(session.format)).map(\.name),
                       ["folder/show.txt", "folder/hidden.txt"])
    }

    nonisolated private final class MoveDraggingSession: NSDraggingSession {
        private let sequence = Int.random(in: Int.min..<0)
        override var draggingSequenceNumber: Int { sequence }
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
        -> (MoveDraggingSession, TestDraggingInfo) {
        let session = MoveDraggingSession(), info = TestDraggingInfo(operationMask: [.move, .copy])
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
        let fixture = try ScenarioFixture.withEntries(["a/x.txt", "b/deep/target.txt"]), (_, controller) = try await interface(fixture)
        let dragged = try controller.displayedNode("a/x.txt"), folder = try controller.displayedNode("b/deep")
        let (session, info) = moveDrag([dragged], in: controller), view = MoveDropOutline()
        view.hovered = try controller.displayedNode("b/deep/target.txt")
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
        let fixture = try ScenarioFixture.withEntries(["a/x.txt", "b/target.txt"]), (_, controller) = try await interface(fixture)
        let otherFixture = try ScenarioFixture.withEntries(), (_, other) = try await interface(otherFixture)
        let (_, info) = moveDrag([try controller.displayedNode("a/x.txt")], in: controller)
        // 実際の型照会を通し、copy だけは引き続き pasteboard を必要とする。
        guard info.pasteboard.writeObjects([fixture.archive as NSURL]) else {
            throw XCTSkip("この実行環境では名前付き pasteboard サービスへ書き込めません")
        }
        let view = MoveDropOutline(), folder = try controller.displayedNode("b")
        view.hovered = try controller.displayedNode("b/target.txt")
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
        let fixture = try ScenarioFixture.withEntries(["a/x.txt", "a/deep/y.txt", "b/"]), (_, controller) = try await interface(fixture)
        let before = try ArchiveOracle.digest(fixture.archive), view = MoveDropOutline()
        for (source, target) in [("a/x.txt", "a"), ("a", "a"), ("a", "a/deep")] {
            let (_, info) = moveDrag([try controller.displayedNode(source)], in: controller)
            view.hovered = try controller.displayedNode(target)
            info.draggingSource = view
            XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), [])
            XCTAssertNil(view.proposedIndex)
            XCTAssertFalse(controller.outlineView(view, acceptDrop: info, item: view.hovered, childIndex: NSOutlineViewDropOnItemIndex))
            XCTAssertNil(controller.extractionTask)
        }
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        let readOnly = try ScenarioFixture.withEntries(["a/x.txt"], readOnly: true), (_, readOnlyController) = try await interface(readOnly)
        let (_, info) = moveDrag([try readOnlyController.displayedNode("a/x.txt")], in: readOnlyController)
        let readOnlyBefore = try ArchiveOracle.digest(readOnly.archive)
        info.draggingSource = view
        view.hovered = nil
        for mask: NSDragOperation in [[.move, .copy], .copy] {
            info.draggingSourceOperationMask = mask
            XCTAssertEqual(readOnlyController.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), [])
            XCTAssertFalse(readOnlyController.outlineView(view, acceptDrop: info, item: nil, childIndex: NSOutlineViewDropOnItemIndex))
            XCTAssertNil(readOnlyController.conversionConfirmation)
            XCTAssertNil(readOnlyController.extractionTask)
        }
        XCTAssertEqual(try ArchiveOracle.digest(readOnly.archive), readOnlyBefore)
    }

    @MainActor func testAcceptLocalMoveMovesMultipleEntriesExpandsDestinationAndSelectsNewPaths() async throws {
        let fixture = try ScenarioFixture.withEntries(["a/x.txt", "a/y.txt", "b/deep/keep.txt"])
        let (document, controller) = try await interface(fixture), before = try ArchiveOracle.digest(fixture.archive)
        let nodes = try [controller.displayedNode("a/x.txt"), controller.displayedNode("a/y.txt")]
        let target = try controller.displayedNode("b/deep/keep.txt")
        try controller.select(paths: ["a/x.txt", "a/y.txt"])
        let (session, info) = moveDrag(nodes, in: controller)
        controller.outlineView.collapseItem(try controller.displayedNode("b"), collapseChildren: true)
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
        XCTAssertTrue(controller.outlineView.isItemExpanded(try controller.displayedNode("b")))
        XCTAssertTrue(controller.outlineView.isItemExpanded(try controller.displayedNode("b/deep")))
        XCTAssertNil(controller.editProgressSheet)
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
        XCTAssertTrue(try XCTUnwrap(document.undoManager).undoMenuItemTitle.contains(String(localized: "移動")))
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testAcceptLocalDirectoryMoveKeepsExpandedDescendantsAndSelectsMovedFolder() async throws {
        let fixture = try ScenarioFixture.withEntries(["a/", "a/deep/", "a/deep/x.txt", "a/y.txt", "b/"])
        let (_, controller) = try await interface(fixture)
        let source = try controller.displayedNode("a"), target = try controller.displayedNode("b")
        let (_, info) = moveDrag([source], in: controller)
        XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        await controller.extractionTask?.value
        XCTAssertEqual(try names(fixture), ["b/", "b/a/", "b/a/deep/", "b/a/deep/x.txt", "b/a/y.txt"])
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["b/a"])
        XCTAssertTrue(controller.outlineView.isItemExpanded(try controller.displayedNode("b/a")))
        XCTAssertTrue(controller.outlineView.isItemExpanded(try controller.displayedNode("b/a/deep")))
        XCTAssertTrue(controller.displayedPaths.contains("b/a/deep/x.txt"))
    }

    @MainActor func testAcceptLocalMoveRevealsSelectionWhenOldParentWasTheOnlyFilterMatch() async throws {
        let fixture = try ScenarioFixture.withEntries(["old/x.txt", "b/old-reference.txt"]), (_, controller) = try await interface(fixture)
        controller.setFilterQuery("old")
        let source = try controller.displayedNode("old/x.txt"), target = try controller.displayedNode("b")
        let (_, info) = moveDrag([source], in: controller)
        XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        await controller.extractionTask?.value
        XCTAssertEqual(controller.filterQuery, "")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["b/x.txt"])
        XCTAssertEqual(try names(fixture), ["b/x.txt", "b/old-reference.txt"])
    }

    @MainActor func testCancelLocalMoveConflictLeavesWholeSelectionAndUndoUnchanged() async throws {
        let fixture = try ScenarioFixture.withEntries(["a/x.txt", "a/y.txt", "b/x.txt"])
        let (document, controller) = try await interface(fixture), before = try ArchiveOracle.digest(fixture.archive)
        try controller.select(paths: ["a/x.txt", "a/y.txt"])
        let (_, info) = moveDrag(controller.selectedNodes, in: controller), target = try controller.displayedNode("b")
        XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        try await scenarioWait { controller.conflictPrompt != nil }
        let prompt = try XCTUnwrap(controller.conflictPrompt)
        XCTAssertEqual(prompt.conflict.path, "b/x.txt")
        prompt.alert.buttons[2].performClick(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertEqual(Set(controller.selectedNodes.map(\.path)), ["a/x.txt", "a/y.txt"])
        XCTAssertNil(controller.conflictPrompt)
        XCTAssertNil(controller.failureAlert)
    }

    @MainActor func testLocalMoveCanReplaceOrSkipConflictAndUndoTheWholeBatch() async throws {
        for replace in [true, false] {
            let fixture = try ScenarioFixture.withEntries(["a/x.txt", "a/y.txt", "b/x.txt"])
            let (document, controller) = try await interface(fixture), before = try ArchiveOracle.digest(fixture.archive)
            try controller.select(paths: ["a/x.txt", "a/y.txt"])
            let (_, info) = moveDrag(controller.selectedNodes, in: controller), target = try controller.displayedNode("b")
            XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: target, childIndex: -1))
            try await scenarioWait { controller.conflictPrompt != nil }
            let prompt = try XCTUnwrap(controller.conflictPrompt)
            prompt.alert.buttons[replace ? 0 : 1].performClick(nil)
            await controller.extractionTask?.value
            XCTAssertNil(controller.failureAlert)
            XCTAssertEqual(try names(fixture), replace ? ["b/x.txt", "b/y.txt"] : ["a/x.txt", "b/x.txt", "b/y.txt"])
            XCTAssertEqual(Set(controller.selectedNodes.map(\.path)), replace ? ["b/x.txt", "b/y.txt"] : ["a/x.txt", "b/y.txt"])
            XCTAssertEqual(document.generation, 1)
            document.undo(nil)
            await document.undoTask?.value
            XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
            XCTAssertFalse(document.undoManager?.canUndo == true)
        }
    }

    @MainActor func testPendingMoveDisablesEditsAndDropsAndCancellationPreservesBytes() async throws {
        let fixture = try ScenarioFixture.withEntries(["a/x.txt", "b/"]), gate = ScenarioGate()
        let stack = ArchiveUndoStack { source, destination in
            let result = ArchiveUndoStack.cloneFile(from: source, to: destination)
            gate.pause()
            return result
        }
        let (document, controller) = try await interface(fixture, stack: stack), before = try ArchiveOracle.digest(fixture.archive)
        try controller.select(paths: ["a/x.txt"])
        let (_, info) = moveDrag(controller.selectedNodes, in: controller), target = try controller.displayedNode("b")
        XCTAssertTrue(controller.outlineView(controller.outlineView, acceptDrop: info, item: target, childIndex: NSOutlineViewDropOnItemIndex))
        let task = try XCTUnwrap(controller.extractionTask)
        defer { gate.release() }
        try await waitUntil { gate.isEntered }
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
        let other = try controller.displayedNode("a")
        do { _ = try await document.move([other], to: "b", progress: Progress()); XCTFail("処理中の移動を受理しました") }
        catch { XCTAssertTrue(error is ExtractionFailure) }
        try XCTUnwrap(controller.editProgressSheet).cancelExtraction(nil)
        gate.release()
        await task.value
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
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
}
