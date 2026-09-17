import AppKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveDisplayTests: XCTestCase {
    @MainActor private func interface() async throws -> (ArchiveDocument, ArchiveWindowController, EntryNode) {
        preserveArchiveWindowFrame()
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

    @MainActor func testDuplicateRecordSelectionSurvivesSortAndDisplayButFallsBackAfterMutation() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('dup.txt', b'first')
            z.writestr('dup.txt', b'second')
        """)
        let (document, controller) = try await scenarioDocument(fixture)
        let session = try XCTUnwrap(document.session), snapshot = await session.snapshot()
        let view = controller.outlineView
        view.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        let duplicates = (0..<view.numberOfRows).compactMap { view.item(atRow: $0) as? EntryNode }
            .filter { $0.path == "dup.txt" }
        XCTAssertEqual(duplicates.count, 2)
        let first = try XCTUnwrap(duplicates.first), index = try XCTUnwrap(first.entry?.index)
        view.selectRowIndexes(IndexSet(integer: view.row(forItem: first)), byExtendingSelection: false)
        XCTAssertEqual(controller.selectedNodes.count, 1)
        XCTAssertEqual(controller.selectedNodes.first?.entry?.index, index)

        view.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        XCTAssertEqual(controller.selectedNodes.count, 1)
        XCTAssertEqual(controller.selectedNodes.first?.entry?.index, index)

        let root = EntryNode.tree(from: snapshot.entries)
        controller.display(root, session: session, generation: snapshot.generation)
        XCTAssertEqual(controller.selectedNodes.count, 1)
        XCTAssertEqual(controller.selectedNodes.first?.entry?.index, index)

        // 検索の開始で captureViewState を保存し、公開後の検索解除で古い状態を restoreViewState に渡す。
        controller.setFilterQuery("dup")
        let result = try await document.createFolder(in: "", baseName: "added", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["added/"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(document.generation, snapshot.generation + 1)
        view.deselectAll(nil)
        controller.setFilterQuery("")
        XCTAssertEqual(controller.selectedNodes.count, 2)
        XCTAssertEqual(Set(controller.selectedNodes.map(\.path)), ["dup.txt"])
        XCTAssertEqual(Set(controller.selectedNodes.compactMap { $0.entry?.index }),
                       Set(duplicates.compactMap { $0.entry?.index }))

        // 世代や index を持たない既存のパス指定も、同名レコードをすべて解決する。
        let pathOnly = ArchiveViewState(selectedPaths: ["dup.txt"], expandedPaths: [], topPath: nil)
        XCTAssertEqual(pathOnly.resolve(in: root).selected.count, 2)
    }

    @MainActor func testToolbarSearchFieldPreservesFilterConfigurationAndAction() async throws {
        let (_, controller, _) = try await interface()
        let window = try XCTUnwrap(controller.window), toolbar = try XCTUnwrap(window.toolbar)
        XCTAssertEqual(toolbar.items.filter { $0.itemIdentifier != .space }.map(\.itemIdentifier.rawValue),
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

    @MainActor func testAppendPreservesCollapsedMatchingFolderAndSearchQuery() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('first/show.txt', b'first')
            z.writestr('second/show.txt', b'second')
        """)
        let (document, controller) = try await scenarioDocument(fixture), view = controller.outlineView
        controller.setFilterQuery("show")
        func folder(_ path: String) throws -> EntryNode {
            try XCTUnwrap((0..<view.numberOfRows).compactMap { view.item(atRow: $0) as? EntryNode }
                .first { $0.path == path })
        }
        let first = try folder("first")
        XCTAssertTrue(view.isItemExpanded(first))
        XCTAssertTrue(view.isItemExpanded(try folder("second")))
        view.collapseItem(first)
        XCTAssertFalse(view.isItemExpanded(first))
        let source = try fixture.file("third/show.txt").deletingLastPathComponent()
        let result = try await document.append(urls: [source], to: "", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["third", "third/show.txt"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(result.reloadFailure)

        XCTAssertEqual(controller.filterQuery, "show")
        XCTAssertEqual(controller.searchField.stringValue, "show")
        XCTAssertFalse(view.isItemExpanded(try folder("first")))
        XCTAssertTrue(view.isItemExpanded(try folder("second")))
        XCTAssertTrue(view.isItemExpanded(try folder("third")))
        XCTAssertTrue((0..<view.numberOfRows).contains { (view.item(atRow: $0) as? EntryNode)?.path == "third/show.txt" })

        document.undo(nil)
        let undo = try XCTUnwrap(document.undoTask)
        await undo.value
        XCTAssertNil(document.undoFailure)
        XCTAssertFalse(view.isItemExpanded(try folder("first")))
        XCTAssertFalse((0..<view.numberOfRows).contains { (view.item(atRow: $0) as? EntryNode)?.path == "third" })

        document.redo(nil)
        let redo = try XCTUnwrap(document.undoTask)
        await redo.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(controller.filterQuery, "show")
        XCTAssertEqual(controller.searchField.stringValue, "show")
        XCTAssertFalse(view.isItemExpanded(try folder("first")))
        XCTAssertTrue(view.isItemExpanded(try folder("second")))
        XCTAssertTrue(view.isItemExpanded(try folder("third")))
        XCTAssertTrue((0..<view.numberOfRows).contains { (view.item(atRow: $0) as? EntryNode)?.path == "third/show.txt" })

        // 検索語の変更では、従来どおり新しい一致をすべて展開する。
        controller.setFilterQuery("txt")
        XCTAssertTrue(view.isItemExpanded(try folder("first")))
    }

    @MainActor func testAppendPreservesHorizontalScrollPosition() async throws {
        let fixture = try ScenarioFixture()
        let (document, controller) = try await scenarioDocument(fixture), view = controller.outlineView
        let window = try XCTUnwrap(controller.window), scroll = try XCTUnwrap(view.enclosingScrollView)
        window.setContentSize(NSSize(width: 600, height: 300))
        // 保存済みの列幅に依存せず、必ず横スクロールできるようにする。
        view.autosaveTableColumns = false
        for column in view.tableColumns { column.width = 200 }
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.bounds.width, scroll.contentView.bounds.width + 100)
        scroll.contentView.scroll(to: NSPoint(x: 100, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scrollX = scroll.contentView.bounds.origin.x
        XCTAssertGreaterThan(scrollX, 0)
        let result = try await document.append(urls: [fixture.file("added.txt")], to: "", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["added.txt"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(scroll.contentView.bounds.origin.x, scrollX, accuracy: 0.5)
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

    @MainActor func testWindowChromeAndFirstRowRemainReadableAtMinimumSizeInBothAppearances() async throws {
        let (_, controller, _) = try await interface()
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.orderFront(nil)
        let content = try XCTUnwrap(window.contentView)
        for width: CGFloat in [1040, 600] {
            window.setContentSize(NSSize(width: width, height: width == 600 ? 300 : 600))
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                window.layoutIfNeeded()
                // ツールバーのマテリアルとヘッダも外観変更後に描画させる。
                try await Task.sleep(for: .milliseconds(60))
                window.displayIfNeeded()
                let firstRow = controller.outlineView.convert(controller.outlineView.rect(ofRow: 0), to: content)
                XCTAssertLessThanOrEqual(firstRow.maxY, window.contentLayoutRect.maxY + 0.5)
                XCTAssertGreaterThanOrEqual(firstRow.minY, controller.pathControl.frame.maxY)
                let violations = UISnapshot.overflowViolations(in: content)
                XCTAssertTrue(violations.isEmpty, violations.joined(separator: "\n"))
                try UISnapshot.render(try XCTUnwrap(content.superview), name: "archive-window-\(Int(width))-\(name)")
            }
        }
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
        let frameAutosave = ArchiveWindowFrameAutosave()
        defer { frameAutosave.restore() }
        let controller = ArchiveWindowController()
        defer { controller.close() }
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        for item in toolbar.items where item.itemIdentifier != .flexibleSpace && item.itemIdentifier != .space {
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
        let frameAutosave = ArchiveWindowFrameAutosave()
        defer { frameAutosave.restore() }
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
        XCTAssertGreaterThanOrEqual(path.frame.height, path.intrinsicContentSize.height)
        XCTAssertGreaterThan(path.frame.minX, content.bounds.minX)
        XCTAssertLessThan(path.frame.maxX, content.bounds.maxX)
        XCTAssertEqual(scroll.frame.maxY, content.bounds.maxY, accuracy: 0.5)
        XCTAssertGreaterThan(scroll.frame.minY, path.frame.maxY)
        let footer = try XCTUnwrap(content.subviews.compactMap { $0 as? NSStackView }.first)
        XCTAssertEqual(path.frame.minY, footer.frame.maxY + 6, accuracy: 0.5)
    }

    @MainActor func testArchiveWindowUsesAutomaticTabbing() throws {
        let frameAutosave = ArchiveWindowFrameAutosave()
        defer { frameAutosave.restore() }
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
