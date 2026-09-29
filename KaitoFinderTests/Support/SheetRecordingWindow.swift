import AppKit
import KaitoKit
import XCTest
@testable import KaitoFinder

/// ArchiveWindowController の responder 移動を通知し、表示せずに要求されたシートを記録する。
@MainActor final class SheetRecordingWindow: NSWindow {
    var didMakeFirstResponder: (() -> Void)?
    var requestedSheets: [NSWindow] = []

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        didMakeFirstResponder?()
        return result
    }

    override func beginSheet(_ sheetWindow: NSWindow,
                             completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
        // 進捗も含めてシートは表示せず、要求されたシートだけを記録する。
        requestedSheets.append(sheetWindow)
    }
}

extension XCTestCase {
    /// ScenarioFixture を開き、削除・改名のシート要求を記録するウインドウと組にして返す。
    @MainActor func sheetRecordingDocument(_ fixture: ScenarioFixture, stack: ArchiveUndoStack) async throws
        -> (ArchiveDocument, ArchiveWindowController, SheetRecordingWindow) {
        let document = ArchiveDocument(undoStack: stack)
        try document.read(from: fixture.archive, ofType: "public.zip-archive")
        document.fileURL = fixture.archive
        let controller = ArchiveWindowController()
        let originalWindow = try XCTUnwrap(controller.window)
        let window = SheetRecordingWindow(contentRect: originalWindow.contentRect(forFrameRect: originalWindow.frame),
                                          styleMask: originalWindow.styleMask, backing: .buffered, defer: false)
        window.contentView = originalWindow.contentView
        window.delegate = originalWindow.delegate
        controller.window = window
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session), snapshot = await session.snapshot()
        controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(controller.outlineView))
        closeDocumentAfterTest(document, controller: controller, retaining: fixture)
        return (document, controller, window)
    }
}
