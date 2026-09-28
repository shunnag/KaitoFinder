import AppKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveViewOptionsTests: XCTestCase {
    @MainActor private func interface() async throws -> (DeferredSaveFixture, ArchiveWindowController, ArchiveWindowController) {
        _ = NSApplication.shared
        let files = [("a.txt", "A"), ("z/child.txt", "C"), (".hidden.txt", "H")]
            + (0..<80).map { (String(format: "row%03d.txt", $0), "row") }
        let fixture = try DeferredSaveFixture(behavior: .immediate, files: files)
        let first = ArchiveWindowController(preferencesStore: fixture.store)
        let second = ArchiveWindowController(preferencesStore: fixture.store)
        let session = try XCTUnwrap(fixture.document.session)
        for controller in [first, second] {
            fixture.document.addWindowController(controller)
            controller.outlineView.autosaveTableColumns = false
            controller.display(EntryNode.tree(from: await session.entries()), session: session,
                               materializationController: fixture.document.materializationController())
            controller.outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
            controller.window?.layoutIfNeeded()
        }
        addTeardownBlock { @MainActor in
            first.outlineView.cancelRenaming()
            second.outlineView.cancelRenaming()
            fixture.document.close()
            await fixture.document.undoCleanup?.value
            await fixture.document.materializationCleanup?.value
            await fixture.document.sessionCleanup?.value
            withExtendedLifetime(fixture) {}
        }
        return (fixture, first, second)
    }

    @MainActor private func select(_ index: Int, in popup: NSPopUpButton,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(popup.isEnabled, file: file, line: line)
        popup.selectItem(at: index)
        XCTAssertTrue(popup.sendAction(try XCTUnwrap(popup.action, file: file, line: line), to: popup.target), file: file, line: line)
    }

    @MainActor private func row(_ path: String, in controller: ArchiveWindowController) throws -> Int {
        try XCTUnwrap((0..<controller.outlineView.numberOfRows).first {
            (controller.outlineView.item(atRow: $0) as? EntryNode)?.path == path
        }, path)
    }

    @MainActor func testControlsTrackTargetAndLeaveOtherWindowUnchanged() async throws {
        let (fixture, first, second) = try await interface()
        var main = first.window
        let panel = ArchiveViewOptionsController(store: fixture.store, mainWindow: { main })
        defer { panel.close() }
        XCTAssertTrue(panel.target === first)
        let window = try XCTUnwrap(panel.window as? NSPanel)
        XCTAssertTrue(window.isFloatingPanel)
        XCTAssertTrue(window.hidesOnDeactivate)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        try select(try XCTUnwrap(ArchiveColumn.allCases.firstIndex(of: .compressedSize)), in: panel.sortPopup)
        try select(1, in: panel.orderPopup)
        XCTAssertEqual(first.outlineView.sortDescriptors.first?.key, "compressedSize")
        XCTAssertEqual(first.outlineView.sortDescriptors.first?.ascending, false)
        XCTAssertEqual(second.outlineView.sortDescriptors.first?.key, "name")
        main = second.window
        panel.refreshTarget()
        XCTAssertTrue(panel.target === second)
        XCTAssertEqual(panel.sortPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(panel.orderPopup.indexOfSelectedItem, 0)
        second.outlineView.sortDescriptors = []
        XCTAssertEqual(panel.sortPopup.indexOfSelectedItem, 0)
        main = nil
        panel.refreshTarget()
        XCTAssertNil(panel.target)
        XCTAssertFalse(panel.sortPopup.isEnabled)
        XCTAssertFalse(panel.orderPopup.isEnabled)
        XCTAssertTrue(panel.columnCheckboxes.values.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(panel.columnCheckboxes[.name]?.state, .on)
        for control in [panel.foldersOnTopCheckbox, panel.hiddenFilesCheckbox, panel.iconSizePopup, panel.textSizePopup] {
            XCTAssertTrue(control.isEnabled)
        }
    }

    @MainActor func testHiddenSortColumnAndHeaderChangesRefreshTheControls() async throws {
        let (fixture, first, _) = try await interface()
        let panel = ArchiveViewOptionsController(store: fixture.store, mainWindow: { first.window })
        defer { panel.close() }
        let crc = try XCTUnwrap(first.outlineView.tableColumn(withIdentifier: .init("crc32")))
        XCTAssertTrue(crc.isHidden)
        try select(try XCTUnwrap(ArchiveColumn.allCases.firstIndex(of: .crc32)), in: panel.sortPopup)
        XCTAssertFalse(crc.isHidden)
        XCTAssertEqual(panel.columnCheckboxes[.crc32]?.state, .on)
        let button = try XCTUnwrap(panel.columnCheckboxes[.crc32])
        button.performClick(nil)
        XCTAssertTrue(crc.isHidden)
        let header = try XCTUnwrap(first.outlineView.headerView?.menu)
        first.menuNeedsUpdate(header)
        let item = try XCTUnwrap(header.items.first { $0.representedObject as? String == "crc32" })
        first.toggleColumn(item)
        XCTAssertEqual(button.state, .on)
        first.outlineView.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        XCTAssertEqual(panel.sortPopup.indexOfSelectedItem, ArchiveColumn.allCases.firstIndex(of: .date))
        XCTAssertEqual(panel.orderPopup.indexOfSelectedItem, 1)
    }

    @MainActor func testRejectedRenameRestoresSortAndPanelSelection() async throws {
        let (fixture, first, _) = try await interface()
        let panel = ArchiveViewOptionsController(store: fixture.store, mainWindow: { first.window })
        defer { panel.close() }
        first.outlineView.selectRowIndexes(IndexSet(integer: try row("a.txt", in: first)), byExtendingSelection: false)
        first.renameEntry(nil)
        let field = try XCTUnwrap(first.outlineView.renameField)
        field.stringValue = "/"
        try select(1, in: panel.sortPopup)
        XCTAssertEqual(first.outlineView.sortDescriptors.first?.key, "name")
        XCTAssertEqual(panel.sortPopup.indexOfSelectedItem, 0)
        try select(1, in: panel.orderPopup)
        XCTAssertEqual(first.outlineView.sortDescriptors.first?.ascending, true)
        XCTAssertEqual(panel.orderPopup.indexOfSelectedItem, 0)
        XCTAssertTrue(first.outlineView.isRenaming)
        XCTAssertEqual(field.stringValue, "/")
    }

    @MainActor func testGlobalCheckboxesUpdateBothWindowsAndMenuChecks() async throws {
        let (fixture, first, second) = try await interface()
        let panel = ArchiveViewOptionsController(store: fixture.store, mainWindow: { first.window })
        defer { panel.close() }
        let delegate = AppDelegate(preferencesStore: fixture.store)
        let hidden = NSMenuItem(title: "", action: #selector(AppDelegate.toggleHiddenFiles(_:)), keyEquivalent: "")
        let folders = NSMenuItem(title: "", action: #selector(AppDelegate.toggleFoldersOnTop(_:)), keyEquivalent: "")
        panel.hiddenFilesCheckbox.performClick(nil)
        panel.foldersOnTopCheckbox.performClick(nil)
        XCTAssertTrue(delegate.validateMenuItem(hidden))
        XCTAssertTrue(delegate.validateMenuItem(folders))
        XCTAssertEqual(hidden.state, .on)
        XCTAssertEqual(folders.state, .on)
        for controller in [first, second] {
            XCTAssertEqual((controller.outlineView.item(atRow: 0) as? EntryNode)?.path, "z")
            XCTAssertGreaterThan(try row(".hidden.txt", in: controller), 0)
        }
        delegate.toggleHiddenFiles(nil)
        delegate.toggleFoldersOnTop(nil)
        XCTAssertEqual(panel.hiddenFilesCheckbox.state, .off)
        XCTAssertEqual(panel.foldersOnTopCheckbox.state, .off)
    }

    @MainActor func testSizingPreservesViewStateAndRebuildsOnlyIconThumbnails() async throws {
        let (fixture, first, second) = try await interface()
        let panel = ArchiveViewOptionsController(store: fixture.store, mainWindow: { first.window })
        defer { panel.close() }
        let outline = first.outlineView
        let folder = try XCTUnwrap(outline.item(atRow: try row("z", in: first)) as? EntryNode)
        outline.expandItem(folder)
        let selected = try row("row030.txt", in: first)
        outline.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        outline.scroll(NSPoint(x: 0, y: outline.rect(ofRow: selected).minY))
        func topPath() -> String? { (outline.item(atRow: outline.rows(in: outline.visibleRect).location) as? EntryNode)?.path }
        let top = topPath()
        XCTAssertNotNil(top)
        let defaultHeight = outline.rowHeight
        let provider = try XCTUnwrap(first.thumbnailProvider)
        XCTAssertEqual(provider.pointSize, 16)
        try select(6, in: panel.textSizePopup)
        XCTAssertTrue(first.thumbnailProvider === provider)
        try select(1, in: panel.iconSizePopup)
        XCTAssertFalse(first.thumbnailProvider === provider)
        for controller in [first, second] {
            XCTAssertEqual(controller.outlineView.rowSizeStyle, .custom)
            XCTAssertGreaterThanOrEqual(controller.outlineView.rowHeight, 36)
            XCTAssertEqual(controller.thumbnailProvider?.pointSize, 32)
            let index = try row("row030.txt", in: controller)
            let name = controller.outlineView.column(withIdentifier: .init("name"))
            let cell = try XCTUnwrap(controller.outlineView.view(atColumn: name, row: index, makeIfNecessary: true) as? ArchiveEntryCellView)
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.imageView?.frame.size, NSSize(width: 32, height: 32))
            XCTAssertEqual(cell.textField?.font?.pointSize, 16)
        }
        XCTAssertEqual(first.selectedNodes.map(\.path), ["row030.txt"])
        XCTAssertTrue(outline.isItemExpanded(folder))
        XCTAssertEqual(topPath(), top)
        try select(0, in: panel.iconSizePopup)
        try select(3, in: panel.textSizePopup)
        XCTAssertEqual(outline.rowSizeStyle, .default)
        XCTAssertEqual(outline.rowHeight, defaultHeight)
        XCTAssertEqual(topPath(), top)
        XCTAssertEqual(first.thumbnailProvider?.pointSize, 16)
    }

    @MainActor func testCellsUpdateConstraintsAndFontsWhenReused() throws {
        for column in [ArchiveColumn.name, .crc32, .permissions, .archiveOrder] {
            let cell = ArchiveEntryCellView(column: column)
            cell.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            for (generation, size) in [13, 16, 10, 13].enumerated() {
                let icon: CGFloat = size == 16 ? 32 : 16
                cell.apply(iconSize: icon, textSize: size, generation: UInt64(generation))
                cell.layoutSubtreeIfNeeded()
                XCTAssertEqual(cell.displayGeneration, UInt64(generation))
                XCTAssertEqual(cell.textField?.font, column.usesMonospacedDigits
                    ? .monospacedDigitSystemFont(ofSize: CGFloat(size), weight: .regular) : .systemFont(ofSize: CGFloat(size)))
                if column == .name { XCTAssertEqual(cell.imageView?.frame.size, NSSize(width: icon, height: icon)) }
            }
        }
    }

    @MainActor func testLockedAndClosingTargetsDisableWindowControls() async throws {
        let (fixture, first, _) = try await interface()
        let panel = ArchiveViewOptionsController(store: fixture.store, mainWindow: { first.window })
        defer { panel.close() }
        first.displayLocked()
        XCTAssertFalse(panel.sortPopup.isEnabled)
        XCTAssertFalse(panel.orderPopup.isEnabled)
        XCTAssertTrue(panel.columnCheckboxes.values.allSatisfy { !$0.isEnabled })
        first.close()
        XCTAssertNil(panel.target)
        XCTAssertTrue(panel.hiddenFilesCheckbox.isEnabled)
    }
}
