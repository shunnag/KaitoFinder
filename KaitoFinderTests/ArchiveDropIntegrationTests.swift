import AppKit
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveDropIntegrationTests: XCTestCase {
    @MainActor func testBlankLocalMoveRefusesCurrentFolderWithoutPasteboardFiles() async throws {
        _ = NSApplication.shared
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(files: [("a/original.txt", "original")])
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        fixture.document.addWindowController(controller)
        defer { fixture.document.close() }
        let session = try XCTUnwrap(fixture.document.session)
        controller.display(EntryNode.tree(from: try await fixture.document.projectedEntries()), session: session)
        let view = controller.outlineView
        view.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        controller.openEntry(nil)
        XCTAssertEqual(controller.currentFolderPath, "a")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let node = try XCTUnwrap(view.item(atRow: 0) as? EntryNode)
        controller.setDraggedNodesForTesting([node])
        defer { controller.setDraggedNodesForTesting([]) }
        let info = TestDraggingInfo(urls: [], window: controller.window,
            location: view.convert(NSPoint(x: 80, y: view.bounds.maxY - 5), to: nil))
        defer { info.draggingPasteboard.releaseGlobally() }
        info.draggingSource = view
        info.draggingSourceOperationMask = .move
        XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: -1), [])
        XCTAssertFalse(controller.outlineView(view, acceptDrop: info, item: nil, childIndex: -1))
        XCTAssertNil(controller.extractionTask)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testBlankDropUsesCurrentFolderAndRejectsSameLocationMoveInBothSaveModes() async throws {
        _ = NSApplication.shared
        preserveArchiveWindowFrame()
        let probe = NSPasteboard.withUniqueName()
        defer { probe.releaseGlobally() }
        guard probe.writeObjects([URL(fileURLWithPath: "/tmp/probe.txt") as NSURL]) else {
            throw XCTSkip("The pasteboard service is unavailable in this test host")
        }
        for behavior in ArchivePreferences.SaveBehavior.allCases {
            let fixture = try DeferredSaveFixture(behavior: behavior, files: [("a/original.txt", "original")])
            let controller = ArchiveWindowController(preferencesStore: fixture.store)
            fixture.document.addWindowController(controller)
            defer { fixture.document.close() }
            let session = try XCTUnwrap(fixture.document.session)
            controller.display(EntryNode.tree(from: try await fixture.document.projectedEntries()), session: session)
            let view = controller.outlineView
            view.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            controller.openEntry(nil)
            XCTAssertEqual(controller.currentFolderPath, "a")
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let source = try fixture.file("dropped.txt")
            let info = TestDraggingInfo(urls: [source], window: controller.window,
                location: view.convert(NSPoint(x: 80, y: view.bounds.maxY - 5), to: nil))
            defer { info.draggingPasteboard.releaseGlobally() }
            XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: -1), .copy)
            XCTAssertTrue(controller.outlineView(view, acceptDrop: info, item: nil, childIndex: -1))
            await controller.extractionTask?.value
            let entries = try await fixture.document.projectedEntries()
            XCTAssertTrue(entries.contains { $0.name == "a/dropped.txt" })
            XCTAssertFalse(entries.contains { $0.name == "dropped.txt" })
            if behavior == .onSave { XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original) }
            let node = try XCTUnwrap(view.item(atRow: 0) as? EntryNode)
            controller.setDraggedNodesForTesting([node])
            info.draggingSource = view
            info.draggingSourceOperationMask = .move
            XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: -1), [])
            XCTAssertFalse(controller.outlineView(view, acceptDrop: info, item: nil, childIndex: -1))
            controller.setDraggedNodesForTesting([])
            XCTAssertEqual(ArchiveDropTarget.localOperation(dragged: [.init(node)],
                target: ArchiveDropTarget.folder(for: nil, blankArea: "a"), mask: .move,
                capabilities: session.capabilities, busy: false), .none)
        }
    }

    @MainActor func testThousandFileDropIsOneUndoableBatchAndRejectsAnotherDropWhileBusy() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('target/original.txt', b'original')
            z.writestr('untouched.txt', b'untouched')
        """)
        var expected = try ScenarioFixture.contents(fixture.archive)
        var urls: [URL] = []
        for index in 0..<1_000 {
            let name = String(format: "file-%04d.bin", index)
            let bytes = Data("\(index)\0日本語\n".utf8)
            urls.append(try fixture.file("inputs/" + name, bytes: bytes))
            expected["target/" + name] = bytes
        }
        let (document, controller) = try await scenarioDocument(fixture)
        let original = try ScenarioFixture.digest(fixture.archive)
        let view = controller.outlineView
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let folder = try XCTUnwrap((0..<view.numberOfRows).compactMap { view.item(atRow: $0) as? EntryNode }
            .first { $0.path == "target" })
        let rect = view.rect(ofRow: view.row(forItem: folder))
        let info = TestDraggingInfo(urls: urls, window: controller.window,
                                  location: view.convert(NSPoint(x: 90, y: rect.midY), to: nil))
        defer { info.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(controller.outlineView(view, validateDrop: info, proposedItem: nil, proposedChildIndex: -1), .copy)
        XCTAssertTrue(controller.outlineView(view, acceptDrop: info, item: folder, childIndex: -1))
        XCTAssertTrue(controller.operationInFlight)
        XCTAssertFalse(controller.outlineView(view, acceptDrop: info, item: folder, childIndex: -1))
        let task = try XCTUnwrap(controller.extractionTask)
        await task.value
        XCTAssertFalse(controller.operationInFlight)
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), expected)
        XCTAssertEqual(document.session?.generation, 1)
        XCTAssertTrue(document.undoManager?.canUndo == true)
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), original)
        XCTAssertFalse(document.undoManager?.canUndo == true, "一回のドロップは一回の取り消し")
        document.redo(nil)
        await document.undoTask?.value
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), expected)
        XCTAssertEqual(try fixture.directory.run(ExternalTool.unzip, ["-tqq", fixture.archive.path]), "")
    }

    func testBulkAppendAcrossEveryWritableFormatPreservesAllFileContents() async throws {
        let fixture = try ScenarioFixture()
        var expected: [String: Data] = ["original.txt": Data("original".utf8)]
        let original = try fixture.file("original.txt", bytes: expected["original.txt"]!)
        var urls: [URL] = []
        for index in 0..<100 {
            let name = "added-\(index).txt", bytes = Data("内容 \(index)\n".utf8)
            urls.append(try fixture.file("inputs/" + name, bytes: bytes))
            expected[name] = bytes
        }
        _ = try fixture.file("inputs/tree/deep/nested.txt", bytes: Data("nested".utf8))
        _ = try fixture.folder("inputs/tree/empty")
        urls.append(fixture.root.appendingPathComponent("inputs/tree"))
        expected["tree/deep/nested.txt"] = Data("nested".utf8)
        for format in ArchivePreferences.formats {
            let archive = fixture.root.appendingPathComponent("batch." + ArchiveCreationPlan.filenameExtension(for: format))
            let plan = ArchiveCreationPlan(sources: [original], destination: archive, format: format)
            _ = try ArchiveCreationTransaction.run(plan: plan, progress: Progress())
            let session = try ArchiveSession(url: archive)
            let result = try await session.append(urls: urls, to: "", progress: Progress())
            XCTAssertTrue(result.failures.isEmpty, "\(format): \(result.failures)")
            XCTAssertNil(result.reloadFailure)
            XCTAssertEqual(session.generation, 1)
            XCTAssertEqual(try ScenarioFixture.contents(archive), expected, "\(format)")
            let entries = try ArchiveReader.open(url: archive).entries
            XCTAssertEqual(entries.filter { $0.kind == .directory && $0.name.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "tree/empty" }.count, 1)
        }
    }

    @MainActor func testDragProvidersPruneSelectedDescendantsWithoutLosingOtherFiles() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('tree/deep/child.txt', b'child')
            z.writestr('tree/other.txt', b'other')
            z.writestr('loose.txt', b'loose')
        """)
        let (_, controller) = try await scenarioDocument(fixture)
        let view = controller.outlineView
        view.expandItem(nil, expandChildren: true)
        view.selectAll(nil)
        let selected = controller.selectedNodes
        let providers = selected.compactMap { controller.outlineView(view, pasteboardWriterForItem: $0) as? NSFilePromiseProvider }
        XCTAssertEqual(providers.count, 2, "親と子を同時に選んでも tree と loose.txt の二項目だけを運ぶ")
        XCTAssertEqual(Set(providers.compactMap { ($0.delegate as? ArchiveFilePromise)?.payload.path }), ["tree", "loose.txt"])
        // 子だけを選んだドラッグでは、そのファイルを単独で運ぶ。
        let child = try XCTUnwrap(selected.first { $0.path == "tree/deep/child.txt" })
        view.selectRowIndexes(IndexSet(integer: view.row(forItem: child)), byExtendingSelection: false)
        XCTAssertNotNil(controller.outlineView(view, pasteboardWriterForItem: child))
    }

    @MainActor func testNativeDragBetweenArchiveWindowsReceivesEveryPromiseAsOneCopy() async throws {
        try await assertNativeCopy(tabbed: false)
    }

    @MainActor func testNativeDragToAnotherTabKeepsTheSourceAndCopiesTheWholeSelection() async throws {
        try await assertNativeCopy(tabbed: true)
    }

    @MainActor func testNativePromiseFailureRefusesTheWholeBatchWithoutChangingEitherArchive() async throws {
        try await assertNativeCopy(tabbed: false, corruptSource: true)
    }

    @MainActor private func assertNativeCopy(tabbed: Bool, corruptSource: Bool = false, replacing: Bool = false) async throws {
        NSApp.activate(ignoringOtherApps: true)
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('tree/deep/child.txt', b'child')
            z.writestr('tree/other.txt', b'other')
            z.writestr('tree/empty/', b'')
            for i in range(100): z.writestr(f'file-{i:03}.txt', f'contents {i}'.encode())
        """)
        if corruptSource {
            try fixture.directory.run(ExternalTool.python3, ["-c", """
            import sys, struct
            p = sys.argv[1]
            raw = bytearray(open(p, 'rb').read())
            struct.pack_into('<I', raw, raw.index(b'PK\\x01\\x02') + 16, 0)
            open(p, 'wb').write(raw)
            """, fixture.archive.path])
        }
        let target = try ScenarioFixture(script: replacing ? """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('original.txt', b'original')
            z.writestr('tree/outdated.txt', b'outdated')
            for i in range(100): z.writestr(f'file-{i:03}.txt', b'old')
        """ : "with zipfile.ZipFile(p, 'w') as z: z.writestr('original.txt', b'original')")
        let (sourceDocument, source) = try await scenarioDocument(fixture)
        let (targetDocument, destination) = try await scenarioDocument(target)
        let originalSource = try ScenarioFixture.digest(fixture.archive)
        let originalTarget = try ScenarioFixture.digest(target.archive)
        try await dragSelection(from: source, to: destination, tabbed: tabbed, expectedCount: 101)
        if replacing {
            var previous: ArchiveConflictPrompt?
            for _ in 0..<2 {
                try await scenarioWait { destination.conflictPrompt != nil && destination.conflictPrompt !== previous }
                let prompt = try XCTUnwrap(destination.conflictPrompt)
                previous = prompt
                if prompt.conflict.allowsBatchChoice { prompt.applyToRemaining.performClick(nil) }
                prompt.alert.buttons[0].performClick(nil)
            }
        }
        await destination.extractionTask?.value
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), originalSource)
        XCTAssertFalse(sourceDocument.undoManager?.canUndo == true)
        if corruptSource {
            XCTAssertEqual(try ScenarioFixture.digest(target.archive), originalTarget)
            XCTAssertEqual(targetDocument.session?.generation, 0)
            XCTAssertFalse(targetDocument.undoManager?.canUndo == true)
            try await scenarioWait { destination.window?.attachedSheet != nil }
            if let sheet = destination.window?.attachedSheet { destination.window?.endSheet(sheet); sheet.orderOut(nil) }
            return
        }
        var expected = try ScenarioFixture.contents(fixture.archive)
        expected["original.txt"] = Data("original".utf8)
        XCTAssertEqual(try ScenarioFixture.contents(target.archive), expected)
        XCTAssertEqual(targetDocument.session?.generation, 1)
        XCTAssertTrue(try ArchiveReader.open(url: target.archive).entries.contains { $0.name == "tree/empty/" && $0.kind == .directory })
        targetDocument.undo(nil)
        await targetDocument.undoTask?.value
        XCTAssertEqual(try ScenarioFixture.digest(target.archive), originalTarget)
        XCTAssertFalse(targetDocument.undoManager?.canUndo == true)
    }
    @MainActor func testNativeDragCanReplaceOneHundredFilesAndFolderInAnotherTab() async throws {
        try await assertNativeCopy(tabbed: true, replacing: true)
    }

    @MainActor func testNativePromisesWithDuplicateNamesAreReceivedSeparatelyAndCompared() async throws {
        NSApp.activate(ignoringOtherApps: true)
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('one/same.txt', b'first')
            z.writestr('two/same.txt', b'second')
        """)
        let target = try ScenarioFixture()
        let (_, source) = try await scenarioDocument(fixture)
        let (document, destination) = try await scenarioDocument(target)
        let before = try ScenarioFixture.digest(fixture.archive)
        try await dragSelection(from: source, to: destination, tabbed: false, expectedCount: 2,
                                paths: ["one/same.txt", "two/same.txt"])
        try await scenarioWait { destination.conflictPrompt != nil || destination.failureAlert != nil || document.generation > 0 }
        let receivedNames = try ScenarioFixture.contents(target.archive).keys.sorted()
        let prompt = try XCTUnwrap(destination.conflictPrompt,
            "generation=\(document.generation) files=\(receivedNames) failure=\(destination.failureAlert?.informativeText ?? "none")")
        XCTAssertEqual(prompt.conflict.path, "same.txt")
        XCTAssertEqual(prompt.conflict.existing.size, 5)
        XCTAssertEqual(prompt.conflict.incoming.size, 6)
        guard case .file(let first) = prompt.conflict.existing.source,
              case .file(let second) = prompt.conflict.incoming.source else { return XCTFail("受信前に同名ファイルを失った") }
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())
        XCTAssertEqual(try Data(contentsOf: first), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("second".utf8))
        prompt.alert.buttons[0].performClick(nil)
        await destination.extractionTask?.value
        XCTAssertNil(destination.failureAlert)
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(try ScenarioFixture.contents(target.archive), ["original.txt": Data("original".utf8), "same.txt": Data("second".utf8)])
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
    }

}
