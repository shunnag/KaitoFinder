import AppKit
import QuickLookUI
import XCTest
@testable import KaitoFinder

/// パネルからの上下矢印は単一選択の一覧へ渡し、通常の選択移動を使う。
nonisolated final class QuickLookArrowNavigationTests: XCTestCase {
    private static let downKeyCode: UInt16 = 125
    private static let upKeyCode: UInt16 = 126
    private static let spaceKeyCode: UInt16 = 49

    @MainActor private func previewContext() async throws
        -> (ArchiveWindowController, QLPreviewPanel, ArchiveQuickLookCoordinator) {
        let fixture = try ScenarioFixture.withEntries(["first.txt", "second.txt"])
        let (_, controller) = try await scenarioDocument(fixture)
        let view = controller.outlineView
        XCTAssertEqual(view.numberOfRows, 2)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.makeFirstResponder(view)
        view.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        // 非表示でも delegate を直接呼び、前面化や描画のタイミングに依存しない。
        panel.orderOut(nil)
        controller.beginPreviewPanelControl(panel)
        addTeardownBlock { @MainActor in controller.endPreviewPanelControl(panel) }
        let coordinator = try XCTUnwrap(panel.delegate as? ArchiveQuickLookCoordinator)
        return (controller, panel, coordinator)
    }

    @MainActor private func keyEvent(_ characters: String, keyCode: UInt16, panel: QLPreviewPanel,
                                    modifiers: NSEvent.ModifierFlags = [.function, .numericPad]) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @MainActor func testSingleSelectionArrowsMoveOutlineSelectionAndStopAtFirstRow() async throws {
        let (controller, panel, coordinator) = try await previewContext()
        let view = controller.outlineView
        let down = try keyEvent("\u{f701}", keyCode: Self.downKeyCode, panel: panel)
        let up = try keyEvent("\u{f700}", keyCode: Self.upKeyCode, panel: panel)
        XCTAssertEqual(view.selectedRow, 0)
        XCTAssertTrue(coordinator.previewPanel(panel, handle: down))
        XCTAssertEqual(view.selectedRow, 1)
        XCTAssertTrue(coordinator.previewPanel(panel, handle: up))
        XCTAssertEqual(view.selectedRow, 0)
        XCTAssertTrue(coordinator.previewPanel(panel, handle: up))
        XCTAssertEqual(view.selectedRow, 0)
    }

    @MainActor func testMultipleSelectionDownIsNotForwarded() async throws {
        let (controller, panel, coordinator) = try await previewContext()
        let view = controller.outlineView, selection = IndexSet([0, 1])
        view.selectRowIndexes(selection, byExtendingSelection: false)
        let down = try keyEvent("\u{f701}", keyCode: Self.downKeyCode, panel: panel)
        XCTAssertFalse(coordinator.previewPanel(panel, handle: down))
        XCTAssertEqual(view.selectedRowIndexes, selection)
    }

    @MainActor func testModifiedArrowsDoNotInvokeOutlineActions() async throws {
        let (controller, panel, coordinator) = try await previewContext()
        let view = controller.outlineView, selection = view.selectedRowIndexes
        var opens = 0, enclosingFolders = 0
        view.openSelection = { opens += 1 }
        view.selectEnclosingFolder = { enclosingFolders += 1 }
        for modifier in [NSEvent.ModifierFlags.command, .shift, .option, .control] {
            for (characters, keyCode) in [("\u{f701}", Self.downKeyCode), ("\u{f700}", Self.upKeyCode)] {
                let event = try keyEvent(characters, keyCode: keyCode, panel: panel,
                    modifiers: [.function, .numericPad, modifier])
                XCTAssertFalse(coordinator.previewPanel(panel, handle: event))
                XCTAssertEqual(view.selectedRowIndexes, selection)
            }
        }
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(enclosingFolders, 0)
    }

    @MainActor func testDownIsNotForwardedWhenInteractionIsDisabled() async throws {
        let (controller, panel, coordinator) = try await previewContext()
        let view = controller.outlineView
        view.permitsInteraction = { false }
        let down = try keyEvent("\u{f701}", keyCode: Self.downKeyCode, panel: panel)
        XCTAssertFalse(coordinator.previewPanel(panel, handle: down))
        XCTAssertEqual(view.selectedRow, 0)
    }

    @MainActor func testDownIsNotForwardedWhileRenaming() async throws {
        let (controller, panel, coordinator) = try await previewContext()
        let view = controller.outlineView
        let item = try XCTUnwrap(view.item(atRow: 0) as? EntryNode)
        view.beginRenaming(item, validate: { _ in nil }, commit: { _ in XCTFail("矢印で改名を確定しない") })
        defer { view.cancelRenaming() }
        XCTAssertTrue(view.isRenaming)
        let down = try keyEvent("\u{f701}", keyCode: Self.downKeyCode, panel: panel)
        XCTAssertFalse(coordinator.previewPanel(panel, handle: down))
        XCTAssertEqual(view.selectedRow, 0)
        XCTAssertTrue(view.isRenaming)
    }

    @MainActor func testSpaceClosesPreviewPanel() async throws {
        let (_, panel, coordinator) = try await previewContext()
        let space = try keyEvent(" ", keyCode: Self.spaceKeyCode, panel: panel, modifiers: [])
        // 非表示でも制御開始時は active なので、Space が終了処理を通ることを検証できる。
        XCTAssertTrue(coordinator.isActive)
        XCTAssertTrue(coordinator.previewPanel(panel, handle: space))
        XCTAssertFalse(coordinator.isActive)
        XCTAssertFalse(panel.isVisible)
    }
}
