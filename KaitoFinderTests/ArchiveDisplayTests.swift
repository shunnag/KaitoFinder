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
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier.rawValue),
                       ["extract", "addFiles", "newFolder", "delete", "quickLook", NSToolbarItem.Identifier.flexibleSpace.rawValue, "search"])
        let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "search" } as? NSSearchToolbarItem)
        XCTAssertTrue(controller.searchField === item.searchField)
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        XCTAssertEqual(window.toolbarStyle, .unified)
        let search = controller.searchField
        XCTAssertEqual(search.placeholderString, String(localized: "検索"))
        XCTAssertEqual(search.accessibilityLabel(), String(localized: "検索"))
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

    @MainActor func testToolbarItemsExposeLabelsActionsAndCustomization() async throws {
        let (_, controller, _) = try await interface()
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        XCTAssertEqual(toolbar.identifier, "ArchiveToolbar")
        XCTAssertTrue(toolbar.allowsUserCustomization)
        XCTAssertTrue(toolbar.autosavesConfiguration)
        XCTAssertEqual(controller.toolbarDefaultItemIdentifiers(toolbar), toolbar.items.map(\.itemIdentifier))
        XCTAssertEqual(Set(controller.toolbarAllowedItemIdentifiers(toolbar)), Set(toolbar.items.map(\.itemIdentifier) + [.space]))
        let expected: [(String, String, Selector?)] = [
            ("extract", String(localized: "展開"), #selector(ArchiveWindowController.extractFromToolbar(_:))),
            ("addFiles", String(localized: "追加…"), #selector(ArchiveWindowController.addFiles(_:))),
            ("newFolder", String(localized: "新規フォルダ"), #selector(ArchiveWindowController.newFolder(_:))),
            ("delete", String(localized: "削除"), #selector(ArchiveWindowController.deleteEntries(_:))),
            ("quickLook", String(localized: "クイックルック"), #selector(ArchiveWindowController.togglePreviewPanel(_:))),
            ("search", String(localized: "検索"), nil)
        ]
        for (identifier, title, action) in expected {
            let item = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == identifier })
            XCTAssertEqual(item.label, title)
            XCTAssertEqual(item.paletteLabel, title)
            XCTAssertEqual(item.toolTip, title)
            XCTAssertTrue(item.isBordered)
            XCTAssertTrue(item.target === controller)
            if let action {
                XCTAssertEqual(item.action, action)
                XCTAssertNotNil(item.image)
            }
            XCTAssertNotNil(controller.toolbar(toolbar, itemForItemIdentifier: item.itemIdentifier, willBeInsertedIntoToolbar: false))
        }
        XCTAssertNil(controller.toolbar(toolbar, itemForItemIdentifier: .init("unknown"), willBeInsertedIntoToolbar: false))
    }

    @MainActor func testContextMenuRoutesBlankAreaAndRowsAndPreservesMultipleSelection() async throws {
        let (_, controller, _) = try await interface(), view = controller.outlineView
        let blank = try XCTUnwrap(view.contextMenu(forRow: -1))
        XCTAssertTrue(blank === view.blankAreaMenu)
        XCTAssertEqual(blank.items.map(\.title), [String(localized: "新規フォルダ"), String(localized: "ペースト"), "",
            String(localized: "すべて展開…"), "", String(localized: "新規アーカイブ…"), String(localized: "アーカイブをFinderに表示")])
        XCTAssertEqual(blank.items.map(\.isSeparatorItem), [false, false, true, false, true, false, false])
        XCTAssertEqual(blank.items.map(\.action), [#selector(ArchiveWindowController.newFolder(_:)),
            #selector(ArchiveWindowController.paste(_:)), nil, #selector(ArchiveWindowController.extractAll(_:)), nil,
            #selector(AppDelegate.newArchive(_:)), #selector(ArchiveWindowController.revealArchiveInFinder(_:))])
        for item in blank.items where !item.isSeparatorItem {
            if item.action == #selector(AppDelegate.newArchive(_:)) { XCTAssertNil(item.target) }
            else { XCTAssertTrue(item.target === controller) }
        }
        view.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        XCTAssertTrue(view.contextMenu(forRow: 0) === view.menu)
        XCTAssertEqual(view.selectedRowIndexes, IndexSet(integer: 0))
        view.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        XCTAssertTrue(view.contextMenu(forRow: 0) === view.menu)
        XCTAssertEqual(view.selectedRowIndexes, IndexSet([0, 1]))
        XCTAssertTrue(view.contextMenu(forRow: -1) === blank)
        XCTAssertEqual(view.selectedRowIndexes, IndexSet([0, 1]))

        // 実際のイベントも同じ分岐へ届くことを、メニューを表示せずに確認する。
        let point = NSPoint(x: 10, y: view.rect(ofRow: view.numberOfRows - 1).maxY + 10)
        XCTAssertEqual(view.row(at: point), -1)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: try XCTUnwrap(controller.window).windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(view.menu(for: event) === blank)
        view.deselectAll(nil)
        controller.display(EntryNode.tree(from: []))
        XCTAssertTrue(view.contextMenu(forRow: -1) === blank)
    }

    @MainActor func testRevealArchiveInFinderValidatesOpenDocumentWithoutSelection() async throws {
        let (document, controller, _) = try await interface()
        XCTAssertNotNil(document.fileURL)
        controller.outlineView.deselectAll(nil)
        let item = try XCTUnwrap(controller.outlineView.blankAreaMenu.items.first {
            $0.action == #selector(ArchiveWindowController.revealArchiveInFinder(_:))
        })
        XCTAssertTrue(controller.validateMenuItem(item))
        controller.displayLocked()
        XCTAssertTrue(controller.validateMenuItem(item))
        let unopened = ArchiveWindowController()
        defer { unopened.close() }
        XCTAssertFalse(unopened.validateMenuItem(item))
    }

    @MainActor func testToolbarExtractionUsesAllEntriesWithoutSelectionAndSelectedEntriesOtherwise() async throws {
        let (_, controller, root) = try await interface()
        var selections: [[String]] = []
        controller.extractionDestinationHandler = { nodes in
            selections.append(ExtractionSelection(nodes: nodes).entries.map(\.name).sorted())
        }
        controller.setFilterQuery("c.txt")
        controller.outlineView.deselectAll(nil)
        controller.extractFromToolbar(nil)
        XCTAssertEqual(selections, [["a/b/c.txt", "note.txt"]])
        let a = try child("a", in: root), b = try child("b", in: a), c = try child("c.txt", in: b)
        controller.outlineView.selectRowIndexes(IndexSet(integer: controller.outlineView.row(forItem: c)), byExtendingSelection: false)
        controller.extractFromToolbar(nil)
        XCTAssertEqual(selections, [["a/b/c.txt", "note.txt"], ["a/b/c.txt"]])
        controller.extractAll(nil)
        XCTAssertEqual(selections.last, ["a/b/c.txt", "note.txt"])
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertNil(controller.extractionTask)
    }

    @MainActor func testToolbarWithoutSessionKeepsOnlySearchEnabled() throws {
        let controller = ArchiveWindowController()
        defer { controller.close() }
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        for item in toolbar.items where item.itemIdentifier != .flexibleSpace {
            XCTAssertEqual(controller.validateToolbarItem(item), item.itemIdentifier.rawValue == "search", item.label)
        }
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

    @MainActor func testLockedPlaceholderRestoresListToolbarAndStatusAfterUnlock() async throws {
        let (document, controller, root) = try await interface()
        let session = try XCTUnwrap(document.session), window = try XCTUnwrap(controller.window)
        controller.displayLocked()
        XCTAssertFalse(controller.lockedPlaceholder.isHidden)
        XCTAssertTrue(controller.outlineView.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(controller.searchField.isEnabled)
        XCTAssertTrue(controller.statusBar.isHidden)
        XCTAssertTrue(window.defaultButtonCell === controller.unlockButton.cell)
        controller.display(root, session: session)
        XCTAssertTrue(controller.lockedPlaceholder.isHidden)
        XCTAssertFalse(controller.outlineView.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(controller.searchField.isEnabled)
        XCTAssertFalse(controller.statusBar.isHidden)
        XCTAssertNil(window.defaultButtonCell)
        XCTAssertEqual(controller.unlockButton.keyEquivalent, "")
        XCTAssertEqual(controller.outlineView.numberOfRows, 2)
        let extract = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "extract" })
        XCTAssertTrue(controller.validateToolbarItem(extract))
    }

    @MainActor func testStatusBarUpdatesCountsFilterSelectionAndAvoidsDoubleCountingSize() async throws {
        let (_, controller, root) = try await interface()
        func expected(filtered: Int? = nil, selected: Int = 0, size: UInt64? = nil) -> String {
            ArchiveStatusBarText.text(totalCount: 4, totalSize: 10, filteredCount: filtered,
                                      selectedCount: selected, selectedSize: size)
        }
        XCTAssertEqual(controller.statusBar.stringValue, expected())
        controller.setFilterQuery("c.txt")
        XCTAssertEqual(controller.statusBar.stringValue, expected(filtered: 3))
        controller.setFilterQuery("missing")
        XCTAssertEqual(controller.statusBar.stringValue, expected(filtered: 0))
        controller.setFilterQuery("")
        let a = try child("a", in: root), b = try child("b", in: a), c = try child("c.txt", in: b)
        let view = controller.outlineView
        view.expandItem(nil, expandChildren: true)
        view.selectRowIndexes(IndexSet([view.row(forItem: a), view.row(forItem: c)]), byExtendingSelection: false)
        XCTAssertEqual(controller.statusBar.stringValue, expected(selected: 2, size: 6))
        view.deselectAll(nil)
        XCTAssertEqual(controller.statusBar.stringValue, expected())
        controller.setFilterQuery("note")
        view.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(controller.statusBar.stringValue, expected(filtered: 1, selected: 1, size: 4))
    }

    @MainActor func testStatusBarTextInJapaneseAndEnglish() throws {
        let app = Bundle(for: ArchiveDocument.self)
        let size = ByteCountFormatter.string(fromByteCount: 1024, countStyle: .file)
        for language in ["ja", "en"] {
            let bundle = try XCTUnwrap(Bundle(url: XCTUnwrap(app.url(forResource: language, withExtension: "lproj"))))
            XCTAssertEqual(ArchiveStatusBarText.text(totalCount: 12, totalSize: 1024, bundle: bundle),
                           language == "ja" ? "12項目、\(size)" : "12 items, \(size)")
            XCTAssertEqual(ArchiveStatusBarText.text(totalCount: 12, totalSize: 1024, filteredCount: 3, bundle: bundle),
                           language == "ja" ? "3/12項目" : "3 of 12 items")
            XCTAssertEqual(ArchiveStatusBarText.text(totalCount: 12, totalSize: 1024, selectedCount: 2, selectedSize: 1024, bundle: bundle),
                           language == "ja" ? "2項目を選択中(\(size))" : "2 items selected (\(size))")
            XCTAssertEqual(ArchiveStatusBarText.text(totalCount: 12, totalSize: nil, selectedCount: 1, selectedSize: nil, bundle: bundle),
                           language == "ja" ? "1項目を選択中(—)" : "1 items selected (—)")
        }
    }

}
