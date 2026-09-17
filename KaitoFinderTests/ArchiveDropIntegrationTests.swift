import AppKit
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

@MainActor private final class ArchiveDropProbe: NSObject, NSOutlineViewDataSource {
    let controller: ArchiveWindowController
    var proposedOperation: NSDragOperation = []
    var accepted = false
    init(_ controller: ArchiveWindowController) { self.controller = controller }
    func outlineView(_ view: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        controller.outlineView(view, numberOfChildrenOfItem: item)
    }
    func outlineView(_ view: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        controller.outlineView(view, child: index, ofItem: item)
    }
    func outlineView(_ view: NSOutlineView, isItemExpandable item: Any) -> Bool {
        controller.outlineView(view, isItemExpandable: item)
    }
    func outlineView(_ view: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        proposedOperation = controller.outlineView(view, validateDrop: info, proposedItem: item, proposedChildIndex: index)
        return proposedOperation
    }
    func outlineView(_ view: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        accepted = controller.outlineView(view, acceptDrop: info, item: item, childIndex: index)
        return accepted
    }
}

/// OS が与える drag 情報だけを差し替え、pasteboard → acceptDrop → 文書更新は実物を使う。
@MainActor private final class FileURLDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    var draggingSource: Any?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(urls: [URL], window: NSWindow?, location: NSPoint) {
        draggingPasteboard = .withUniqueName()
        draggingDestinationWindow = window
        draggingLocation = location
        super.init()
        XCTAssertTrue(draggingPasteboard.writeObjects(urls.map { $0 as NSURL }))
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

nonisolated final class ArchiveDropIntegrationTests: XCTestCase {
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
        let info = FileURLDragInfo(urls: urls, window: controller.window,
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
        XCTAssertEqual(try fixture.directory.run("/usr/bin/unzip", ["-tqq", fixture.archive.path]), "")
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

    @MainActor private func assertNativeCopy(tabbed: Bool, corruptSource: Bool = false) async throws {
        NSApp.activate(ignoringOtherApps: true)
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('tree/deep/child.txt', b'child')
            z.writestr('tree/other.txt', b'other')
            z.writestr('tree/empty/', b'')
            for i in range(100): z.writestr(f'file-{i:03}.txt', f'contents {i}'.encode())
        """)
        if corruptSource {
            try fixture.directory.run("/usr/bin/python3", ["-c", """
            import sys, struct
            p = sys.argv[1]
            raw = bytearray(open(p, 'rb').read())
            struct.pack_into('<I', raw, raw.index(b'PK\\x01\\x02') + 16, 0)
            open(p, 'wb').write(raw)
            """, fixture.archive.path])
        }
        let target = try ScenarioFixture()
        let (sourceDocument, source) = try await scenarioDocument(fixture)
        let (targetDocument, destination) = try await scenarioDocument(target)
        let probe = ArchiveDropProbe(destination)
        destination.outlineView.dataSource = probe
        defer { destination.outlineView.dataSource = destination }
        let originalSource = try ScenarioFixture.digest(fixture.archive)
        let originalTarget = try ScenarioFixture.digest(target.archive)
        let first = try XCTUnwrap(source.window), second = try XCTUnwrap(destination.window)
        first.tabbingIdentifier = UUID().uuidString
        second.tabbingIdentifier = UUID().uuidString
        destination.showWindow(nil)
        source.showWindow(nil)
        first.setFrame(NSRect(x: 40, y: 240, width: 680, height: 500), display: true)
        second.setFrame(NSRect(x: 750, y: 240, width: 680, height: 500), display: true)
        second.makeKeyAndOrderFront(nil)
        first.makeKeyAndOrderFront(nil)
        first.makeMain()
        if tabbed {
            first.addTabbedWindow(second, ordered: .above)
            first.makeKeyAndOrderFront(nil)
            XCTAssertTrue(first.tabGroup === second.tabGroup)
        }
        source.outlineView.expandItem(nil, expandChildren: true)
        source.outlineView.selectAll(nil)
        first.contentView?.layoutSubtreeIfNeeded()
        second.contentView?.layoutSubtreeIfNeeded()
        try await scenarioWait { first.isKeyWindow }
        let rect = source.outlineView.rect(ofRow: 0)
        let start = first.convertPoint(toScreen: source.outlineView.convert(NSPoint(x: 120, y: rect.midY), to: nil))
        let end = second.convertPoint(toScreen: destination.outlineView.convert(NSPoint(x: 120, y: 150), to: nil))
        var switchedTab = false
        func post(_ type: NSEvent.EventType, at point: NSPoint) throws {
            let window = tabbed ? (switchedTab ? second : first) : (second.frame.contains(point) ? second : first)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
                                                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            NSApp.postEvent(event, atStart: false)
        }
        try post(.mouseMoved, at: start)
        try await Task.sleep(for: .milliseconds(50))
        try post(.leftMouseDown, at: start)
        try await Task.sleep(for: .milliseconds(80))
        try post(.leftMouseDragged, at: NSPoint(x: start.x + 8, y: start.y))
        try await scenarioWait { source.draggedNodes.count == 101 }
        for step in 1...20 {
            try await Task.sleep(for: .milliseconds(40))
            if tabbed, step == 6 {
                XCTAssertEqual(source.draggedNodes.count, 101)
                // 実際のドラッグを継続したまま、別の文書タブを前面にする。
                second.makeKeyAndOrderFront(nil)
                switchedTab = true
                XCTAssertTrue(first.tabGroup?.selectedWindow === second)
            }
            let fraction = CGFloat(step) / 20
            try post(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * fraction,
                                                   y: start.y + (end.y - start.y) * fraction))
        }
        for _ in 0..<20 where probe.proposedOperation != .copy {
            try await Task.sleep(for: .milliseconds(50))
            try post(.leftMouseDragged, at: end)
        }
        XCTAssertEqual(probe.proposedOperation, .copy)
        XCTAssertEqual(source.draggedNodes.count, 101, "子孫の二重送信を防ぎ、全ファイルを運ぶ")
        try post(.leftMouseUp, at: end)
        try await scenarioWait { destination.extractionTask != nil || targetDocument.session?.generation == 1
            || second.attachedSheet != nil }
        XCTAssertTrue(probe.accepted)
        await destination.extractionTask?.value
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), originalSource)
        XCTAssertFalse(sourceDocument.undoManager?.canUndo == true)
        if corruptSource {
            XCTAssertEqual(try ScenarioFixture.digest(target.archive), originalTarget)
            XCTAssertEqual(targetDocument.session?.generation, 0)
            XCTAssertFalse(targetDocument.undoManager?.canUndo == true)
            try await scenarioWait { second.attachedSheet != nil }
            if let sheet = second.attachedSheet { second.endSheet(sheet); sheet.orderOut(nil) }
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
}
