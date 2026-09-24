import AppKit
import KaitoKit
import UniformTypeIdentifiers
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveSortingTests: XCTestCase {
    @MainActor func testEveryColumnSortsBothDirectionsWithMissingValues() {
        let root = EntryNode.tree(from: [
            archiveColumnEntry("a", index: 10, size: 100, compressed: 25, date: Date(timeIntervalSince1970: 200),
                               permissions: 0o755, crc: 0xF0000000, encrypted: true, method: "Z"),
            archiveColumnEntry("z", index: 0, size: 40, compressed: 36, date: Date(timeIntervalSince1970: 100),
                               permissions: 0o644, crc: 1, method: "A"),
            archiveColumnEntry("missing/child", size: nil, compressed: nil)
        ])
        let resolver = ArchiveKindResolver()
        let expected: [String: ([String], [String])] = [
            "name": (["a", "missing", "z"], ["z", "missing", "a"]),
            "size": (["missing", "z", "a"], ["a", "z", "missing"]),
            "compressedSize": (["missing", "a", "z"], ["z", "a", "missing"]),
            "date": (["missing", "z", "a"], ["a", "z", "missing"]),
            "encrypted": (["missing", "z", "a"], ["a", "z", "missing"]),
            "ratio": (["missing", "z", "a"], ["a", "z", "missing"]),
            "crc32": (["missing", "z", "a"], ["a", "z", "missing"]),
            "permissions": (["missing", "z", "a"], ["a", "z", "missing"]),
            "archiveOrder": (["missing", "z", "a"], ["a", "z", "missing"])
        ]
        for (key, orders) in expected {
            for ascending in [true, false] {
                XCTAssertEqual(ArchiveEntrySort.sorted(root.children,
                    descriptors: [NSSortDescriptor(key: key, ascending: ascending)], foldersOnTop: false,
                    kindResolver: resolver).map(\.name), ascending ? orders.0 : orders.1, "\(key), \(ascending)")
            }
        }
        for key in ["kind", "method"] {
            let values = key == "kind"
                ? Dictionary(uniqueKeysWithValues: root.children.map { ($0.name, resolver.kind(for: $0).description) })
                : ["a": "Z", "z": "A", "missing": "—"]
            for ascending in [true, false] {
                let expected = values.keys.sorted {
                    let result = values[$0]!.localizedStandardCompare(values[$1]!)
                    if result == .orderedSame { return $0.localizedStandardCompare($1) == .orderedAscending }
                    return result == (ascending ? .orderedAscending : .orderedDescending)
                }
                XCTAssertEqual(ArchiveEntrySort.sorted(root.children,
                    descriptors: [NSSortDescriptor(key: key, ascending: ascending)], foldersOnTop: false,
                    kindResolver: resolver).map(\.name), expected, "\(key), \(ascending)")
            }
        }
    }

    @MainActor func testNumericPrecisionNegativeSavingsEmptyFilesAndNameTieBreaks() {
        let root = EntryNode.tree(from: [
            archiveColumnEntry("file10", size: UInt64.max, compressed: UInt64.max),
            archiveColumnEntry("file2", size: UInt64.max - 1, compressed: UInt64.max - 1),
            archiveColumnEntry("empty", size: 0, compressed: 0),
            archiveColumnEntry("overhead", size: 10, compressed: 20)
        ])
        let resolver = ArchiveKindResolver()
        func names(_ key: String, ascending: Bool = true) -> [String] {
            ArchiveEntrySort.sorted(root.children, descriptors: [NSSortDescriptor(key: key, ascending: ascending)],
                                    foldersOnTop: false, kindResolver: resolver).map(\.name)
        }
        XCTAssertEqual(names("size"), ["empty", "overhead", "file2", "file10"])
        XCTAssertEqual(names("size", ascending: false), ["file10", "file2", "overhead", "empty"])
        XCTAssertEqual(names("ratio"), ["overhead", "empty", "file2", "file10"])
        XCTAssertEqual(names("ratio", ascending: false), ["empty", "file2", "file10", "overhead"])
        XCTAssertEqual(names("date", ascending: false), ["empty", "file2", "file10", "overhead"])
        XCTAssertEqual(ArchiveEntrySort.sorted(root.children,
            descriptors: [NSSortDescriptor(key: "date", ascending: false), NSSortDescriptor(key: "size", ascending: false)],
            foldersOnTop: false, kindResolver: resolver).map(\.name), ["file10", "file2", "overhead", "empty"])
    }

    @MainActor func testFoldersOnTopForEveryColumnAndDirection() {
        let root = EntryNode.tree(from: [archiveColumnEntry("a-file"), archiveColumnEntry("z-folder/", kind: .directory),
                                         archiveColumnEntry("m-folder/child")])
        let resolver = ArchiveKindResolver()
        for column in ArchiveColumn.allCases {
            for ascending in [true, false] {
                let sorted = ArchiveEntrySort.sorted(root.children,
                    descriptors: [NSSortDescriptor(key: column.rawValue, ascending: ascending)], foldersOnTop: true,
                    kindResolver: resolver)
                XCTAssertEqual(sorted.map(\.isDirectory), [true, true, false], "\(column), \(ascending)")
            }
        }
        XCTAssertEqual(ArchiveEntrySort.sorted(root.children, descriptors: [NSSortDescriptor(key: "name", ascending: true)],
            foldersOnTop: false, kindResolver: resolver).map(\.name), ["a-file", "m-folder", "z-folder"])
    }

    @MainActor func testFoldersPreferencePersistsUpdatesAllWindowsAndPreservesSelectionAndExpansion() throws {
        preserveArchiveWindowFrame()
        preserveApplicationMenus()
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        XCTAssertFalse(store.preferences.keepsFoldersOnTop)
        let controllers = [ArchiveWindowController(preferencesStore: store), ArchiveWindowController(preferencesStore: store)]
        let settings = PreferencesWindowController(store: store)
        defer { controllers.forEach { $0.close() }; settings.close() }
        for controller in controllers {
            let root = EntryNode.tree(from: [archiveColumnEntry("a-file", index: 0), archiveColumnEntry("z-folder/child", index: 1)])
            controller.display(root)
            let folder = try XCTUnwrap(root.children.first { $0.isDirectory })
            controller.outlineView.expandItem(folder)
            let child = try XCTUnwrap(folder.children.first)
            controller.outlineView.selectRowIndexes(IndexSet(integer: controller.outlineView.row(forItem: child)), byExtendingSelection: false)
            XCTAssertEqual((controller.outlineView.item(atRow: 0) as? EntryNode)?.name, "a-file")
        }
        let app = AppDelegate(preferencesStore: store), menu = app.makeMenu()
        let item = try menuItem(#selector(AppDelegate.toggleFoldersOnTop(_:)), in: menu)
        XCTAssertTrue(app.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        try performMenuItem(item)
        XCTAssertTrue(ArchivePreferencesStore(defaults: suite.defaults).preferences.keepsFoldersOnTop)
        XCTAssertEqual(settings.keepsFoldersOnTopCheckbox.state, .on)
        XCTAssertTrue(app.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        for controller in controllers {
            let folder = try XCTUnwrap(controller.outlineView.item(atRow: 0) as? EntryNode)
            XCTAssertEqual(folder.name, "z-folder")
            XCTAssertTrue(controller.outlineView.isItemExpanded(folder))
            XCTAssertEqual(controller.selectedNodes.map(\.path), ["z-folder/child"])
        }
        settings.keepsFoldersOnTopCheckbox.state = .off
        XCTAssertTrue(settings.keepsFoldersOnTopCheckbox.sendAction(settings.keepsFoldersOnTopCheckbox.action,
                                                                    to: settings.keepsFoldersOnTopCheckbox.target))
        XCTAssertFalse(store.preferences.keepsFoldersOnTop)
        for controller in controllers {
            XCTAssertEqual((controller.outlineView.item(atRow: 0) as? EntryNode)?.name, "a-file")
            XCTAssertEqual(controller.selectedNodes.map(\.path), ["z-folder/child"])
        }
    }

    @MainActor func testKindSortResolvesOnlyDistinctKeysAcrossRepeatedSorts() {
        let entries = (0..<100_000).map { index in
            let number = (index * 7919) % 100_000
            return archiveColumnEntry("item\(number).\(number.isMultiple(of: 2) ? "TXT" : "pdf")", index: index)
        }
        let root = EntryNode.tree(from: entries), resolver = ArchiveKindResolver()
        for ascending in [true, false, true] {
            XCTAssertEqual(ArchiveEntrySort.sorted(root.children, descriptors: [NSSortDescriptor(key: "kind", ascending: ascending)],
                foldersOnTop: false, kindResolver: resolver).count, entries.count)
            XCTAssertEqual(resolver.resolutionCount, 2)
        }
    }

    @MainActor func testKindDescriptionsTypesAndIconsForDocumentsExecutablesAndLinks() throws {
        let root = EntryNode.tree(from: [
            archiveColumnEntry("README", permissions: 0o644), archiveColumnEntry("run", permissions: 0o755),
            archiveColumnEntry("group-run", permissions: 0o010), archiveColumnEntry("other-run", permissions: 0o001),
            archiveColumnEntry("folder/", kind: .directory),
            archiveColumnEntry("ordinary.txt/", kind: .directory),
            archiveColumnEntry("unknown.m5packageprobe/", kind: .directory),
            archiveColumnEntry("symbolic", kind: .symlink), archiveColumnEntry("hard", kind: .hardlink)
        ])
        let resolver = ArchiveKindResolver()
        for node in root.children {
            let kind = resolver.kind(for: node)
            switch node.name {
            case "README":
                XCTAssertEqual(kind.type, .data)
                XCTAssertEqual(kind.description, String(localized: "書類"))
            case "run", "group-run", "other-run":
                XCTAssertEqual(kind.type, .unixExecutable)
                XCTAssertEqual(kind.description, UTType.unixExecutable.localizedDescription ?? String(localized: "書類"))
            case "folder", "ordinary.txt", "unknown.m5packageprobe":
                XCTAssertEqual(kind.type, .folder)
                XCTAssertEqual(kind.description, String(localized: "フォルダ"))
            case "symbolic": XCTAssertEqual(kind.type, .symbolicLink)
            case "hard": XCTAssertEqual(kind.description, String(localized: "ハードリンク"))
            default: XCTFail(node.name)
            }
            XCTAssertEqual(resolver.icon(for: node).tiffRepresentation, NSWorkspace.shared.icon(for: kind.type).tiffRepresentation)
        }
        let fresh = EntryNode.tree(from: [archiveColumnEntry("new", permissions: 0o755)])
        resolver.resetNodes()
        XCTAssertEqual(resolver.kind(for: fresh.children[0]).type, .unixExecutable)
    }

    @MainActor func testPackagesUseSystemTypesDescriptionsAndIconsAndStayExpandable() throws {
        guard UTType.folder.conforms(to: .directory) else {
            throw XCTSkip("Launch Services is unavailable in this test environment")
        }
        let root = EntryNode.tree(from: [archiveColumnEntry("Foo.app/", kind: .directory),
            archiveColumnEntry("Doc.rtfd/", kind: .directory), archiveColumnEntry("Book.pages/", kind: .directory)])
        let controller = ArchiveWindowController()
        defer { controller.close() }
        for node in root.children {
            let type = try XCTUnwrap(UTType(filenameExtension: (node.name as NSString).pathExtension, conformingTo: .package))
            XCTAssertFalse(type.isDynamic, node.name)
            XCTAssertTrue(type.conforms(to: .package), node.name)
            let kind = controller.kindResolver.kind(for: node)
            XCTAssertEqual(kind.type, type, node.name)
            XCTAssertEqual(kind.description, type.localizedDescription, node.name)
            XCTAssertEqual(controller.kindResolver.icon(for: node).tiffRepresentation,
                           NSWorkspace.shared.icon(for: type).tiffRepresentation)
            XCTAssertTrue(controller.outlineView(controller.outlineView, isItemExpandable: node))
        }
    }

    @MainActor func testThumbnailEligibilityUsesTheSharedKindCache() async throws {
        let fixture = try ScenarioFixture(), session = try ArchiveSession(url: fixture.archive)
        let materialization = ArchiveMaterializationController(session: session)
        let resolver = ArchiveKindResolver()
        let provider = ArchiveThumbnailProvider(materializer: try XCTUnwrap(materialization.entryMaterializer),
            session: session, generation: 0, kindResolver: resolver) { _, _ in
                XCTFail("A document must not request an image thumbnail")
                return NSImage(size: .zero)
            }
        let root = EntryNode.tree(from: [archiveColumnEntry("one.txt"), archiveColumnEntry("two.TXT")])
        for _ in 0..<20 {
            for node in root.children {
                XCTAssertNil(provider.thumbnail(for: node))
                _ = resolver.kind(for: node)
                _ = resolver.icon(for: node)
            }
        }
        XCTAssertEqual(resolver.resolutionCount, 1)
        await provider.cancelAll().value
        await materialization.close().value
        withExtendedLifetime(fixture) {}
    }

    @MainActor func testSidebarAndListShareKindDescriptionsAndCache() throws {
        let fixture = try ScenarioFixture(), session = try ArchiveSession(url: fixture.archive)
        let controller = ArchiveWindowController()
        defer { controller.close(); withExtendedLifetime(fixture) {} }
        let root = EntryNode.tree(from: [archiveColumnEntry("README", permissions: 0o644),
            archiveColumnEntry("run", permissions: 0o755), archiveColumnEntry("Foo.app/", kind: .directory),
            archiveColumnEntry("Doc.rtfd/", kind: .directory), archiveColumnEntry("hard", kind: .hardlink)])
        let column = try XCTUnwrap(controller.outlineView.tableColumn(withIdentifier: .init("kind")))
        column.isHidden = false
        for node in root.children {
            let cell = try XCTUnwrap(controller.outlineView(controller.outlineView, viewFor: column, item: node) as? NSTableCellView)
            let count = controller.kindResolver.resolutionCount
            controller.previewSidebar.display([node], session: session, generation: 0)
            XCTAssertTrue(controller.previewSidebar.detailLabel.stringValue.hasPrefix(try XCTUnwrap(cell.textField).stringValue))
            XCTAssertEqual(controller.kindResolver.resolutionCount, count)
            XCTAssertEqual(controller.outlineView(controller.outlineView, isItemExpandable: node), node.isDirectory)
        }
    }
}
