import AppKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveWindowCascadeTests: XCTestCase {
    @MainActor func testFirstShowCascadesFromFrontmostVisibleArchiveWindow() throws {
        let frameAutosave = ArchiveWindowFrameAutosave()
        defer { frameAutosave.restore() }
        _ = NSApplication.shared
        guard let screen = NSScreen.main?.visibleFrame else {
            throw XCTSkip("カスケードの検証には利用可能な画面が必要です")
        }
        var controllers: [ArchiveWindowController] = []
        defer {
            for controller in controllers { controller.window?.close() }
        }
        func closeStrayArchiveWindows() {
            for window in NSApp.windows where window.windowController is ArchiveWindowController
                && !controllers.contains(where: { $0.window === window }) {
                window.close()
            }
        }
        closeStrayArchiveWindows()
        func makeController() -> ArchiveWindowController {
            let controller = ArchiveWindowController()
            controllers.append(controller)
            return controller
        }
        func show(_ controller: ArchiveWindowController, expectsReference: Bool = true,
                  cascades: Bool = true, line: UInt = #line) throws {
            let window = try XCTUnwrap(controller.window, line: line)
            // 先行テストの非同期 open が遅れて完了しても、そのウインドウを参照に使わない。
            closeStrayArchiveWindows()
            let frame = window.frame
            let reference = ArchiveWindowController.cascadeReferenceWindow(excluding: window)
            let expected = reference?.cascadeTopLeft(from: .zero)
            controller.showWindow(nil)
            XCTAssertEqual(reference != nil, expectsReference, line: line)
            if cascades, let expected {
                XCTAssertEqual(window.frame.minX, expected.x, accuracy: 0.5, line: line)
                XCTAssertEqual(window.frame.maxY, expected.y, accuracy: 0.5, line: line)
            } else {
                XCTAssertEqual(window.frame, frame, line: line)
            }
        }

        let a = makeController(), aWindow = try XCTUnwrap(a.window)
        // 保存済みの画面端に左右されず、連続するカスケードの余地を作る。
        aWindow.setFrame(NSRect(x: screen.minX + 40, y: screen.maxY - 400, width: 600, height: 300), display: false)
        try show(a, expectsReference: false)
        let aFrame = aWindow.frame

        let b = makeController(), bWindow = try XCTUnwrap(b.window)
        try show(b)
        XCTAssertEqual(aWindow.frame, aFrame)

        bWindow.setFrameOrigin(NSPoint(x: bWindow.frame.minX + 20, y: bWindow.frame.minY - 15))
        let movedBFrame = bWindow.frame
        let c = makeController(), cWindow = try XCTUnwrap(c.window)
        try show(c)
        XCTAssertEqual(bWindow.frame, movedBFrame)

        bWindow.close()
        cWindow.close()
        let d = makeController(), dWindow = try XCTUnwrap(d.window)
        try show(d)

        // 表示済みのウインドウは、隠して再表示しても位置を決め直さない。
        let dFrame = dWindow.frame
        try show(d, cascades: false)
        XCTAssertEqual(dWindow.frame, dFrame)
        dWindow.orderOut(nil)
        aWindow.setFrameOrigin(NSPoint(x: aFrame.minX + 50, y: aFrame.minY))
        try show(d, cascades: false)
        XCTAssertEqual(dWindow.frame, dFrame)

        aWindow.close()
        dWindow.close()
        let e = makeController(), eWindow = try XCTUnwrap(e.window)
        let eFrame = eWindow.frame
        try show(e, expectsReference: false)
        XCTAssertEqual(eWindow.frame, eFrame)
    }
}
