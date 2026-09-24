import AppKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ExtractionProgressSheetTests: XCTestCase {
    @MainActor func testFastDeferredEditFinishesWithoutAttachingOrRevealingItsSheet() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        preserveArchiveWindowFrame()
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session)
        controller.display(EntryNode.tree(from: try await document.projectedEntries()), session: session)
        controller.newFolder(nil)
        let sheet = try XCTUnwrap(controller.editProgressSheet), panel = try XCTUnwrap(sheet.window)
        let task = try XCTUnwrap(controller.extractionTask)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertTrue(ExtractionProgressSheet.hasPendingSheet(on: controller.window))
        XCTAssertTrue(controller.operationInFlight)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertEqual(panel.alphaValue, 0)
        let revealed = Mutex(false)
        let observation = panel.observe(\.alphaValue, options: [.new]) { _, change in
            if change.newValue == 1 { revealed.withLock { $0 = true } }
        }
        await task.value
        controller.outlineView.cancelRenaming()
        XCTAssertFalse(ExtractionProgressSheet.hasPendingSheet(on: controller.window))
        XCTAssertFalse(document.pendingChanges.createdFolders.isEmpty)
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertFalse(revealed.withLock { $0 })
        try await Task.sleep(for: ExtractionProgressSheet.revealDelay)
        XCTAssertEqual(panel.alphaValue, 0)
        XCTAssertFalse(revealed.withLock { $0 })
        withExtendedLifetime(observation) {}
    }

    @MainActor func testUnknownTotalAnimatesWithoutCountsAndBecomesDeterminate() throws {
        let progress = Progress(totalUnitCount: 0)
        let sheet = ExtractionProgressSheet(progress: progress, revealDelay: .zero)
        defer { sheet.finish() }
        sheet.beginStandalone()
        XCTAssertTrue(sheet.indicator.isIndeterminate)
        XCTAssertTrue(sheet.statusLabel.isHidden)
        progress.totalUnitCount = 8
        progress.completedUnitCount = 2
        sheet.refresh()
        XCTAssertFalse(sheet.indicator.isIndeterminate)
        XCTAssertFalse(sheet.statusLabel.isHidden)
        XCTAssertEqual(sheet.indicator.doubleValue, 0.25)
        progress.totalUnitCount = -1
        sheet.refresh()
        XCTAssertTrue(sheet.indicator.isIndeterminate)
        XCTAssertTrue(sheet.statusLabel.isHidden)
    }

    @MainActor func testStandalonePanelDoesNotOrderInBeforeRevealAndFinishCancelsReveal() async throws {
        let sheet = ExtractionProgressSheet(progress: Progress())
        defer { sheet.finish() }
        sheet.beginStandalone()
        let panel = try XCTUnwrap(sheet.window)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 0)
        sheet.finish()
        try await Task.sleep(for: ExtractionProgressSheet.revealDelay)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 0)
    }

    @MainActor func testSuspendingUnrevealedSheetCancelsRevealAndResumeUsesOriginalDeadline() async throws {
        let parent = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = ExtractionProgressSheet(progress: Progress())
        defer { sheet.finish(); parent.orderOut(nil) }
        sheet.begin(on: parent)
        let panel = try XCTUnwrap(sheet.window)
        XCTAssertNil(parent.attachedSheet)
        XCTAssertEqual(panel.alphaValue, 0)
        sheet.finish()
        try await Task.sleep(for: ExtractionProgressSheet.revealDelay)
        XCTAssertEqual(panel.alphaValue, 0)
        sheet.begin(on: parent)
        XCTAssertTrue(parent.attachedSheet === panel)
        XCTAssertEqual(panel.alphaValue, 1)
    }
}
