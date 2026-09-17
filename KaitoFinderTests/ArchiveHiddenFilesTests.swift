import AppKit
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveHiddenFilesTests: XCTestCase {
    @MainActor private func interface(store: ArchivePreferencesStore) async throws
        -> (ArchiveTestDirectory, ArchiveDocument, ArchiveWindowController, EntryNode) {
        preserveArchiveWindowFrame()
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent("hidden.zip")
        let writer = try ArchiveWriter.create(url: archive)
        for path in ["folder/public.txt", "folder/.secret/inside.txt", ".gitignore", ".DS_Store", "__MACOSX/._folder", "visible.txt"] {
            try writer.add(data: Data(path.utf8), as: path)
        }
        try writer.finish()
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        try document.read(from: archive, ofType: "public.zip-archive")
        document.fileURL = archive
        document.fileType = "public.zip-archive"
        let controller = ArchiveWindowController(preferencesStore: store)
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session)
        let snapshot = await session.snapshot()
        let root = EntryNode.tree(from: snapshot.entries)
        controller.display(root, session: session, materializationController: document.materializationController())
        addTeardownBlock { @MainActor in
            document.close()
            await document.sessionCleanup?.value
            await document.materializationCleanup?.value
            await document.undoCleanup?.value
            withExtendedLifetime(directory) {}
        }
        return (directory, document, controller, root)
    }

    @MainActor private func rowPaths(_ controller: ArchiveWindowController) -> [String] {
        (0..<controller.outlineView.numberOfRows).compactMap { (controller.outlineView.item(atRow: $0) as? EntryNode)?.path }
    }

    @MainActor func testMenuAndSettingsShareHiddenPreferenceAndShortcut() throws {
        preserveApplicationMenus()
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let app = AppDelegate(preferencesStore: store), menu = app.makeMenu()
        let settings = PreferencesWindowController(store: store)
        defer { settings.close() }
        let view = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == String(localized: "表示") })
        let item = try XCTUnwrap(view.items.first)
        XCTAssertEqual(item.title, String(localized: "隠しファイルを表示"))
        XCTAssertEqual(item.keyEquivalent, ".")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(item.target === app)
        XCTAssertTrue(app.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        try performMenuItem(item)
        XCTAssertEqual(settings.showsHiddenFilesCheckbox.state, .on)
        XCTAssertTrue(app.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        settings.showsHiddenFilesCheckbox.state = .off
        XCTAssertTrue(settings.showsHiddenFilesCheckbox.sendAction(settings.showsHiddenFilesCheckbox.action,
                                                                    to: settings.showsHiddenFilesCheckbox.target))
        XCTAssertTrue(app.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
    }

    @MainActor func testEveryWindowRefiltersAndPreservesExpandedAndCollapsedFolders() async throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.showsHiddenFiles = true
        let (_, _, first, root) = try await interface(store: store)
        let (_, _, second, _) = try await interface(store: store)
        let folder = try XCTUnwrap(root.children.first { $0.name == "folder" })
        let secret = try XCTUnwrap(folder.children.first { $0.name == ".secret" })
        first.outlineView.expandItem(folder)
        first.outlineView.expandItem(secret)
        store.preferences.showsHiddenFiles = false
        XCTAssertTrue(first.outlineView.isItemExpanded(folder))
        XCTAssertFalse(rowPaths(first).contains("folder/.secret"))
        XCTAssertFalse(rowPaths(second).contains(".gitignore"))
        XCTAssertEqual(first.statusBar.stringValue, ArchiveStatusBarText.text(totalCount: 3, totalSize: root.size))
        first.outlineView.selectAll(nil)
        XCTAssertEqual(Set(first.selectedNodes.map(\.path)), ["folder", "folder/public.txt", "visible.txt"])
        first.outlineView.deselectAll(nil)
        store.preferences.showsHiddenFiles = true
        XCTAssertTrue(first.outlineView.isItemExpanded(secret))
        XCTAssertTrue(rowPaths(first).contains("folder/.secret/inside.txt"))
        XCTAssertTrue(rowPaths(second).contains(".gitignore"))
        first.outlineView.collapseItem(folder)
        store.preferences.showsHiddenFiles = false
        store.preferences.showsHiddenFiles = true
        XCTAssertFalse(first.outlineView.isItemExpanded(folder))
    }

    @MainActor func testHiddenToggleComposesWithSearchWithoutChangingQuery() async throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let (_, _, controller, _) = try await interface(store: store)
        controller.setFilterQuery("inside")
        XCTAssertTrue(rowPaths(controller).isEmpty)
        store.preferences.showsHiddenFiles = true
        XCTAssertEqual(controller.filterQuery, "inside")
        controller.outlineView.expandItem(nil, expandChildren: true)
        XCTAssertEqual(rowPaths(controller), ["folder", "folder/.secret", "folder/.secret/inside.txt"])
        store.preferences.showsHiddenFiles = false
        XCTAssertTrue(rowPaths(controller).isEmpty)
        controller.setFilterQuery("")
        XCTAssertEqual(rowPaths(controller), ["folder", "visible.txt"])
        controller.setFilterQuery("folder")
        let folder = try XCTUnwrap(controller.outlineView.item(atRow: 0) as? EntryNode)
        controller.outlineView.collapseItem(folder)
        store.preferences.showsHiddenFiles = true
        store.preferences.showsHiddenFiles = false
        XCTAssertFalse(controller.outlineView.isItemExpanded(folder))
    }

    @MainActor func testHiddenEntriesStillCollideAndFolderEditsKeepTheirChildren() async throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let (directory, document, _, root) = try await interface(store: store)
        let archive = try XCTUnwrap(document.fileURL), before = try Data(contentsOf: archive)
        let source = directory.url.appendingPathComponent(".gitignore")
        try Data("replacement".utf8).write(to: source)
        let result = try await document.append(urls: [source], to: "", progress: Progress())
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.addedPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: archive), before)
        let visible = try XCTUnwrap(root.children.first { $0.name == "visible.txt" })
        do {
            _ = try await document.rename(visible, to: ".gitignore", progress: Progress())
            XCTFail("Hidden name collision must be refused")
        } catch { XCTAssertEqual(try Data(contentsOf: archive), before) }
        let existing = ExtractionSelection(nodes: [root]).entries
        XCTAssertEqual(try ArchiveNewFolderPlan.build(in: "", baseName: "__MACOSX", existing: existing).path, "__MACOSX 2/")
        let folder = try XCTUnwrap(root.children.first { $0.name == "folder" })
        XCTAssertEqual(Set(ExtractionSelection(nodes: [folder]).entries.map(\.name)),
                       ["folder/public.txt", "folder/.secret/inside.txt"])
        _ = try await document.remove([folder], progress: Progress())
        XCTAssertFalse(try ArchiveReader.open(url: archive).entries.contains { $0.name.hasPrefix("folder/") })
    }

    func testImportExclusionsApplyAtTopLevelAndRecursivelyForEveryCombination() throws {
        let directory = try ArchiveTestDirectory()
        let paths = [".DS_Store", ".gitignore", "._file", "__MACOSX/item", ".hidden/child", "plain.txt",
                     "Docs/.DS_Store", "Docs/.gitignore", "Docs/._file", "Docs/__MACOSX/item", "Docs/.hidden/child", "Docs/plain.txt"]
        for path in paths {
            let url = directory.url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(path.utf8).write(to: url)
        }
        let sources = try FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
        for excludesDSStore in [true, false] {
            for excludesHiddenFiles in [true, false] {
                let options = ArchiveImportPlan.Options(excludesDSStore: excludesDSStore, excludesHiddenFiles: excludesHiddenFiles)
                let plan = try ArchiveImportPlan.build(urls: sources, folder: "", existing: [], progress: Progress(), options: options)
                XCTAssertTrue(plan.failures.isEmpty)
                let names = Set(plan.items.filter { !$0.isDirectory }.map(\.path))
                let expected = Set(paths.filter { path in
                    let leaf = path.split(separator: "/").last ?? ""
                    // macOS の contentsOfDirectory(at:) は、除外設定に関係なく AppleDouble を列挙しない。
                    return !leaf.hasPrefix("._") &&
                    !(excludesDSStore && leaf == ".DS_Store") &&
                    !(excludesHiddenFiles && path.split(separator: "/").contains { EntryNode.isHiddenName(String($0)) })
                })
                XCTAssertEqual(names, expected)
            }
        }
    }

    @MainActor func testImportPreferencesReachCreationAndExistingDocumentAfterNotification() async throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let (directory, document, _, _) = try await interface(store: store)
        let source = directory.url.appendingPathComponent(".new-hidden")
        try Data("new".utf8).write(to: source)
        let creator = ArchiveCreationController(store: store)
        store.preferences.excludesHiddenFiles = true
        store.preferences.excludesDSStore = false
        let plan = creator.creationPlan(sources: [source], destination: directory.url.appendingPathComponent("created.zip"), format: .zip)
        XCTAssertEqual(plan.importOptions, store.preferences.importOptions)
        _ = try ArchiveCreationTransaction.run(plan: plan, progress: Progress())
        XCTAssertTrue(try ArchiveReader.open(url: plan.destination).entries.isEmpty)
        let skipped = try await document.append(urls: [source], to: "", progress: Progress())
        XCTAssertTrue(skipped.addedPaths.isEmpty)
        store.preferences.excludesHiddenFiles = false
        let included = try await document.append(urls: [source], to: "", progress: Progress())
        XCTAssertEqual(included.addedPaths, [".new-hidden"])
    }

    @MainActor func testConversionRetainsExistingHiddenEntriesRegardlessOfImportPreferences() async throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let (directory, document, _, _) = try await interface(store: store)
        store.preferences.excludesHiddenFiles = true
        let session = try XCTUnwrap(document.session)
        let existing = try await ArchiveCreationController.existingArchive(from: session, progress: Progress())
        let plan = ArchiveCreationController(store: store).creationPlan(sources: [],
            destination: directory.url.appendingPathComponent("converted.zip"), format: .zip, existing: existing)
        _ = try ArchiveCreationTransaction.run(plan: plan, progress: Progress())
        XCTAssertEqual(Set(try ArchiveReader.open(url: plan.destination).entries.map(\.name)), Set(existing.entries.map(\.name)))
    }

    @MainActor func testImportCheckboxesPersistIndependentlyOfDisplay() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let settings = PreferencesWindowController(store: store)
        defer { settings.close() }
        XCTAssertEqual(settings.excludesDSStoreCheckbox.state, .on)
        XCTAssertEqual(settings.excludesHiddenFilesCheckbox.state, .off)
        for (button, state) in [(settings.excludesDSStoreCheckbox, NSControl.StateValue.off),
                                (settings.excludesHiddenFilesCheckbox, NSControl.StateValue.on)] {
            button.state = state
            XCTAssertTrue(button.sendAction(button.action, to: button.target))
        }
        let saved = ArchivePreferencesStore(defaults: suite.defaults).preferences
        XCTAssertFalse(saved.excludesDSStore)
        XCTAssertTrue(saved.excludesHiddenFiles)
        XCTAssertFalse(saved.showsHiddenFiles)
    }
}
