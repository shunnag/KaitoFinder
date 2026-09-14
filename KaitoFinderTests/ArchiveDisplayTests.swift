import AppKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveDisplayTests: XCTestCase {
    @MainActor private func interface() async throws -> (ArchiveDocument, ArchiveWindowController, EntryNode) {
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent("paths.zip")
        try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: directory.url.appendingPathComponent("a/b/c.txt"))
        try Data("note".utf8).write(to: directory.url.appendingPathComponent("note.txt"))
        try directory.run("/usr/bin/zip", ["-q", "-D", archive.path, "a/b/c.txt", "note.txt"])
        let document = try ArchiveDocument(contentsOf: archive, ofType: "public.zip-archive")
        let controller = ArchiveWindowController()
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session)
        let snapshot = await session.snapshot()
        let root = EntryNode.tree(from: snapshot.entries)
        controller.display(root, session: session, generation: snapshot.generation,
            materializationController: document.materializationController(
                temporaryDirectory: ExtractionTemporaryDirectory(root: directory.url.appendingPathComponent("previews"))))
        controller.outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in
            document.close()
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            await document.undoCleanup?.value
            withExtendedLifetime(directory) {}
        }
        return (document, controller, root)
    }

    @MainActor private func child(_ name: String, in parent: EntryNode) throws -> EntryNode {
        try XCTUnwrap(parent.children.first { $0.name == name })
    }

    @MainActor func testToolbarSearchFieldPreservesFilterConfigurationAndAction() async throws {
        let (_, controller, _) = try await interface()
        let window = try XCTUnwrap(controller.window), toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), [.flexibleSpace, NSToolbarItem.Identifier("search")])
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "search" } as? NSSearchToolbarItem)
        XCTAssertTrue(controller.searchField === item.searchField)
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        XCTAssertEqual(window.toolbarStyle, .unified)
        let search = controller.searchField
        XCTAssertEqual(search.placeholderString, String(localized: "名前で絞り込む"))
        XCTAssertEqual(search.accessibilityLabel(), String(localized: "名前で絞り込む"))
        XCTAssertTrue(search.target === controller)
        XCTAssertEqual(search.action, #selector(ArchiveWindowController.filterEntries(_:)))
        XCTAssertTrue(search.sendsSearchStringImmediately)
        XCTAssertFalse(search.sendsWholeSearchString)
        search.stringValue = "c.txt"
        XCTAssertTrue(search.sendAction(search.action, to: search.target))
        XCTAssertEqual(controller.filterQuery, "c.txt")
        XCTAssertEqual((0..<controller.outlineView.numberOfRows).compactMap {
            (controller.outlineView.item(atRow: $0) as? EntryNode)?.path
        }, ["a", "a/b", "a/b/c.txt"])
        XCTAssertFalse(try XCTUnwrap(window.contentView).subviews.contains { $0 === search })
    }

    @MainActor func testPathBarShowsAncestryAndSelectsNodesOrArchive() async throws {
        let (document, controller, root) = try await interface()
        let archiveName = try XCTUnwrap(document.fileURL).lastPathComponent
        let a = try child("a", in: root), b = try child("b", in: a), c = try child("c.txt", in: b)
        let view = controller.outlineView
        XCTAssertEqual(controller.pathControl.pathItems.map(\.title), [archiveName])
        view.expandItem(nil, expandChildren: true)
        view.selectRowIndexes(IndexSet(integer: view.row(forItem: c)), byExtendingSelection: false)
        let items = controller.pathControl.pathItems
        XCTAssertEqual(items.map(\.title), [archiveName, "a", "b", "c.txt"])
        XCTAssertNil(items[0].representedObject)
        for (item, node) in zip(items.dropFirst(), [a, b, c]) {
            XCTAssertTrue(item.representedObject as? EntryNode === node)
            XCTAssertNotNil(item.image)
            let cell = try XCTUnwrap(controller.outlineView(view, viewFor: view.outlineTableColumn, item: node) as? NSTableCellView)
            XCTAssertTrue(item.image === cell.imageView?.image, "一覧と同じ型アイコンを再利用する")
        }
        XCTAssertNotNil(items[0].image)
        XCTAssertTrue(controller.pathControl.target === controller)
        XCTAssertNotNil(controller.pathControl.action)
        view.deselectAll(nil)
        XCTAssertEqual(controller.pathControl.pathItems.map(\.title), [archiveName])
        controller.selectPathItem(items[1])
        XCTAssertEqual(controller.selectedNodes, [a])
        controller.selectPathItem(items[0])
        XCTAssertTrue(controller.selectedNodes.isEmpty)
        XCTAssertEqual(controller.pathControl.pathItems.map(\.title), [archiveName])
        // 保存した項目を使い、折り畳んだ祖先も展開して葉を選べることを検査する。
        view.collapseItem(nil, collapseChildren: true)
        controller.selectPathItem(items[3])
        XCTAssertTrue(view.isItemExpanded(a))
        XCTAssertTrue(view.isItemExpanded(b))
        XCTAssertEqual(controller.selectedNodes, [c])
        XCTAssertTrue(view.visibleRect.intersects(view.rect(ofRow: view.row(forItem: c))))
    }

    @MainActor func testPathBarUsesFirstSelectionAndRefreshesNodesAfterDisplay() async throws {
        let (document, controller, root) = try await interface()
        let a = try child("a", in: root), b = try child("b", in: a), c = try child("c.txt", in: b)
        let note = try child("note.txt", in: root), view = controller.outlineView
        view.expandItem(nil, expandChildren: true)
        view.selectRowIndexes(IndexSet([view.row(forItem: c), view.row(forItem: note)]), byExtendingSelection: false)
        XCTAssertEqual(controller.pathControl.pathItems.map(\.title), ["paths.zip", "a", "b", "c.txt"])
        let session = try XCTUnwrap(document.session), snapshot = await session.snapshot()
        let replacement = EntryNode.tree(from: snapshot.entries)
        controller.display(replacement, session: session, generation: snapshot.generation,
                           materializationController: document.materializationController())
        let last = try XCTUnwrap(controller.pathControl.pathItems.last?.representedObject as? EntryNode)
        XCTAssertEqual(last.path, "a/b/c.txt")
        XCTAssertFalse(last === c)
        XCTAssertTrue(last === controller.selectedNodes.first)
        view.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        XCTAssertEqual(controller.pathControl.pathItems.map(\.title), ["paths.zip", "note.txt"])
    }

    @MainActor func testPathBarLayoutAndArchiveFallbackWithoutDocumentURL() throws {
        let controller = ArchiveWindowController()
        defer { controller.close() }
        controller.display(EntryNode.tree(from: []))
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let path = controller.pathControl, scroll = try XCTUnwrap(controller.outlineView.enclosingScrollView)
        XCTAssertEqual(path.pathStyle, .standard)
        XCTAssertFalse(path.isEditable)
        XCTAssertEqual(path.pathItems.map(\.title), [String(localized: "アーカイブ")])
        XCTAssertNotNil(path.pathItems.first?.image)
        XCTAssertEqual(path.frame.height, 22, accuracy: 0.5)
        XCTAssertEqual(path.frame.minX, content.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(path.frame.width, content.bounds.width, accuracy: 0.5)
        XCTAssertEqual(scroll.frame.maxY, content.bounds.maxY, accuracy: 0.5)
        XCTAssertEqual(scroll.frame.minY, path.frame.maxY, accuracy: 0.5)
        let footer = try XCTUnwrap(content.subviews.compactMap { $0 as? NSStackView }.first)
        XCTAssertEqual(path.frame.minY, footer.frame.maxY + 6, accuracy: 0.5)
    }

    @MainActor func testArchiveWindowUsesAutomaticTabbing() throws {
        let controller = ArchiveWindowController()
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.tabbingIdentifier, "KaitoFinder.archive")
        XCTAssertEqual(window.tabbingMode, .automatic)
    }
}
