import AppKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveColumnsTests: XCTestCase {
    @MainActor private func controller() throws -> ArchiveWindowController {
        preserveArchiveWindowFrame()
        let suite = try ArchivePreferencesTestDefaults()
        let controller = ArchiveWindowController(preferencesStore: ArchivePreferencesStore(defaults: suite.defaults))
        addTeardownBlock { @MainActor in controller.close(); withExtendedLifetime(suite) {} }
        return controller
    }

    @MainActor private func column(_ key: String, in controller: ArchiveWindowController) throws -> NSTableColumn {
        try XCTUnwrap(controller.outlineView.tableColumn(withIdentifier: .init(key)))
    }

    @MainActor func testHeaderMenuListsEveryOptionalColumnAndTogglesVisibility() throws {
        let controller = try controller(), view = controller.outlineView
        let menu = try XCTUnwrap(view.headerView?.menu)
        XCTAssertTrue(menu.delegate === controller)
        controller.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.compactMap { $0.representedObject as? String },
                       ArchiveColumn.allCases.filter { $0 != .name }.map(\.rawValue))
        for item in menu.items {
            let key = try XCTUnwrap(item.representedObject as? String)
            let definition = try XCTUnwrap(ArchiveColumn(rawValue: key))
            XCTAssertEqual(item.title, definition.title(bundle: .main))
            XCTAssertEqual(item.state, definition.hiddenByDefault ? .off : .on)
            XCTAssertTrue(controller.validateMenuItem(item))
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(try column(key, in: controller).isHidden, !definition.hiddenByDefault)
            XCTAssertTrue(controller.validateMenuItem(item))
            XCTAssertEqual(item.state, definition.hiddenByDefault ? .on : .off)
        }
        let name = NSMenuItem(title: "name", action: #selector(ArchiveWindowController.toggleColumn(_:)), keyEquivalent: "")
        name.representedObject = "name"
        controller.toggleColumn(name)
        XCTAssertFalse(controller.validateMenuItem(name))
        XCTAssertFalse(try column("name", in: controller).isHidden)
    }

    @MainActor func testAutosaveRestoresVisibilityOrderWidthAndSortInSecondWindow() throws {
        let first = try controller(), view = first.outlineView
        let menu = try XCTUnwrap(view.headerView?.menu)
        first.menuNeedsUpdate(menu)
        for key in ["ratio", "crc32", "permissions", "archiveOrder", "method"] {
            first.toggleColumn(try XCTUnwrap(menu.items.first { $0.representedObject as? String == key }))
        }
        let crc = try column("crc32", in: first)
        crc.width = 173
        view.moveColumn(view.column(withIdentifier: crc.identifier), toColumn: 1)
        view.sortDescriptors = [NSSortDescriptor(key: "compressedSize", ascending: false)]
        let expectedOrder = view.tableColumns.map(\.identifier)
        let expectedHidden = view.tableColumns.map(\.isHidden)
        first.close()
        let second = try controller()
        XCTAssertEqual(second.outlineView.tableColumns.map(\.identifier), expectedOrder)
        XCTAssertEqual(second.outlineView.tableColumns.map(\.isHidden), expectedHidden)
        XCTAssertEqual(try column("crc32", in: second).width, 173, accuracy: 0.5)
        XCTAssertEqual(second.outlineView.sortDescriptors.first?.key, "compressedSize")
        XCTAssertEqual(second.outlineView.sortDescriptors.first?.ascending, false)
    }

    @MainActor func testLegacyAutosaveKeepsNewColumnsHiddenAndPreservesExistingColumns() throws {
        let legacy = NSOutlineView()
        legacy.columnAutoresizingStyle = .noColumnAutoresizing
        for definition in ArchiveColumn.allCases where !definition.hiddenByDefault {
            let column = NSTableColumn(identifier: .init(definition.rawValue))
            column.width = definition.width
            column.resizingMask = [.userResizingMask]
            column.sortDescriptorPrototype = NSSortDescriptor(key: definition.rawValue, ascending: true)
            legacy.addTableColumn(column)
            if definition == .name { legacy.outlineTableColumn = column }
        }
        legacy.autosaveName = ArchiveWindowController.columnsAutosaveName
        legacy.autosaveTableColumns = true
        let size = try XCTUnwrap(legacy.tableColumn(withIdentifier: .init("size")))
        size.width = 167
        legacy.moveColumn(2, toColumn: 1)
        legacy.tableColumn(withIdentifier: .init("method"))?.isHidden = true
        legacy.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        XCTAssertNotNil(UserDefaults.standard.object(forKey: "NSTableView Columns v3 ArchiveColumns"))
        let next = try controller()
        for definition in ArchiveColumn.allCases where definition.hiddenByDefault {
            let column = try column(definition.rawValue, in: next)
            XCTAssertTrue(column.isHidden, definition.rawValue)
            XCTAssertEqual(column.width, definition.width, accuracy: 0.5)
        }
        XCTAssertEqual(try column("size", in: next).width, 167, accuracy: 0.5)
        XCTAssertTrue(try column("method", in: next).isHidden)
        XCTAssertEqual(next.outlineView.tableColumns.prefix(7).map(\.identifier), legacy.tableColumns.map(\.identifier))
        XCTAssertEqual(next.outlineView.sortDescriptors.first?.key, "size")
        XCTAssertEqual(next.outlineView.sortDescriptors.first?.ascending, false)
    }

    @MainActor func testViewSubmenuTracksMainWindowWhilePanelIsKeyAndSharesHeaderActions() throws {
        preserveApplicationMenus()
        let first = try controller(), second = try controller()
        let window = try XCTUnwrap(first.window)
        var mainWindow: NSWindow? = window
        let app = AppDelegate()
        app.mainWindowForTesting = { mainWindow }
        let menu = app.makeMenu()
        NSApp.mainMenu = menu
        let viewMenu = try XCTUnwrap(menu.items.first { $0.title == String(localized: "表示") }?.submenu)
        XCTAssertEqual(Array(viewMenu.items.prefix(3).map(\.title)),
                       [String(localized: "プレビューを表示"), "", String(localized: "隠しファイルを表示")])
        let columns = try XCTUnwrap(viewMenu.items.first { $0.title == String(localized: "列") }?.submenu)
        window.tabbingMode = .disallowed
        let panel = ArchiveViewOptionsController(mainWindow: { mainWindow })
        defer { panel.close() }
        panel.showWindow(nil)
        let panelWindow = try XCTUnwrap(panel.window)
        XCTAssertTrue(panelWindow.canBecomeKey)
        XCTAssertFalse(panelWindow.canBecomeMain)
        XCTAssertTrue(panelWindow.makeFirstResponder(panel.sortPopup))
        XCTAssertTrue(panel.target === first)
        app.menuNeedsUpdate(columns)
        let item = try XCTUnwrap(columns.items.first { $0.representedObject as? String == "ratio" })
        XCTAssertTrue(app.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertFalse(try column("ratio", in: first).isHidden)
        let header = try XCTUnwrap(first.outlineView.headerView?.menu)
        first.menuNeedsUpdate(header)
        XCTAssertEqual(header.items.map(\.title), columns.items.map(\.title))
        XCTAssertEqual(header.items.first { $0.representedObject as? String == "ratio" }?.state, .on)
        second.window?.tabbingMode = .disallowed
        mainWindow = try XCTUnwrap(second.window)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: mainWindow)
        XCTAssertTrue(panel.target === second)
        XCTAssertTrue(app.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        app.toggleArchiveColumn(item)
        XCTAssertFalse(try column("ratio", in: second).isHidden)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        mainWindow = other
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: other)
        XCTAssertNil(panel.target)
        XCTAssertFalse(app.validateMenuItem(item))
        app.toggleArchiveColumn(item)
        XCTAssertFalse(try column("ratio", in: first).isHidden)
    }

    @MainActor func testNewCellsFormatMetadataAndExposeAccessibleText() throws {
        let controller = try controller()
        controller.outlineView.autosaveTableColumns = false
        let entries = [
            archiveColumnEntry("file", index: 7, size: 100, compressed: 38, permissions: 0o755, crc: 0x00ABCDEF),
            archiveColumnEntry("solid", compressed: nil, permissions: nil, crc: nil, solidGroup: 0),
            archiveColumnEntry("folder/", kind: .directory, permissions: 0o2750),
            archiveColumnEntry("folder/child", size: nil, compressed: nil),
            archiveColumnEntry("link", kind: .symlink, permissions: 0o777),
            archiveColumnEntry("hard", kind: .hardlink, permissions: 0o644),
            archiveColumnEntry("special", permissions: 0o7644),
            archiveColumnEntry("virtual/child", size: nil, compressed: nil)
        ]
        let root = EntryNode.tree(from: entries)
        func text(_ name: String, _ key: String) throws -> String {
            let column = try column(key, in: controller)
            column.isHidden = false
            let node = try XCTUnwrap(root.children.first { $0.name == name })
            let cell = try XCTUnwrap(controller.outlineView(controller.outlineView, viewFor: column, item: node) as? NSTableCellView)
            let field = try XCTUnwrap(cell.textField)
            XCTAssertEqual(field.accessibilityValue(), field.stringValue)
            let definition = try XCTUnwrap(ArchiveColumn(rawValue: key))
            XCTAssertEqual(field.alignment, definition.isNumeric ? .right : .left)
            if definition.usesMonospacedDigits {
                XCTAssertEqual(field.font, .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
            }
            return field.stringValue
        }
        let percent = NumberFormatter()
        percent.numberStyle = .percent
        percent.maximumFractionDigits = 0
        XCTAssertEqual(try text("file", "ratio"), percent.string(from: 0.62))
        XCTAssertEqual(try text("file", "crc32"), "00ABCDEF")
        XCTAssertEqual(try text("file", "permissions"), "-rwxr-xr-x")
        XCTAssertEqual(try text("file", "archiveOrder"), "8")
        XCTAssertEqual(try text("folder", "permissions"), "drwxr-s---")
        XCTAssertEqual(try text("link", "permissions"), "lrwxrwxrwx")
        XCTAssertEqual(try text("hard", "permissions"), "-rw-r--r--")
        XCTAssertEqual(try text("special", "permissions"), "-rwSr-Sr-T")
        for key in ["ratio", "crc32", "permissions"] { XCTAssertEqual(try text("solid", key), "—") }
        for key in ["ratio", "crc32", "permissions", "archiveOrder"] { XCTAssertEqual(try text("virtual", key), "—") }
        XCTAssertEqual(try text("folder", "ratio"), "—")
        XCTAssertEqual(try text("folder", "crc32"), "—")
        XCTAssertEqual(try text("folder", "archiveOrder"), "1")
        XCTAssertEqual(try text("solid", "archiveOrder"), "1")
        XCTAssertEqual(try text("link", "ratio"), percent.string(from: 0.5))
        XCTAssertEqual(try text("link", "crc32"), "—")
        XCTAssertEqual(try text("link", "archiveOrder"), "1")
    }

    @MainActor func testHiddenCellsAndUnusedSortKeysDoNotResolveKinds() throws {
        let controller = try controller(), resolver = controller.kindResolver
        let root = EntryNode.tree(from: [archiveColumnEntry("sample.unknown-m5"), archiveColumnEntry("other.txt")])
        let kind = try column("kind", in: controller)
        kind.isHidden = true
        let before = resolver.resolutionCount
        for column in controller.outlineView.tableColumns where column.isHidden {
            XCTAssertNil(controller.outlineView(controller.outlineView, viewFor: column, item: root.children[0]))
        }
        _ = ArchiveEntrySort.sorted(root.children, descriptors: [NSSortDescriptor(key: "size", ascending: true)],
                                    foldersOnTop: false, kindResolver: resolver)
        XCTAssertEqual(resolver.resolutionCount, before)
        kind.isHidden = false
        for _ in 0..<20 {
            _ = controller.outlineView(controller.outlineView, viewFor: kind, item: root.children[0])
            _ = controller.outlineView(controller.outlineView, viewFor: try column("name", in: controller), item: root.children[0])
        }
        XCTAssertEqual(resolver.resolutionCount - before, 1)
    }
}

nonisolated func archiveColumnEntry(_ path: String, index: Int = 0, kind: EntryKind = .file,
                                    size: UInt64? = 10, compressed: UInt64? = 5, date: Date? = nil,
                                    permissions: UInt16? = nil, crc: UInt32? = nil, solidGroup: Int = -1,
                                    encrypted: Bool = false, method: String = "Stored") -> ArchiveEntry {
    ArchiveEntry(index: index, rawName: RawName(bytes: Array(path.utf8)), name: path,
                 pathComponents: path.split(separator: "/").map(String.init), kind: kind,
                 uncompressedSize: size, compressedSize: compressed, modificationDate: date,
                 posixPermissions: permissions, isEncrypted: encrypted, solidGroup: solidGroup,
                 crc32: crc, methodDescription: method, formatSpecific: [:])
}
