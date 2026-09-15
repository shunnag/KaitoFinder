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
        let otherWindows = NSApp.orderedWindows.filter { $0.windowController is ArchiveWindowController && $0.isVisible }
        for window in otherWindows { window.orderOut(nil) }
        var controllers: [ArchiveWindowController] = []
        defer {
            for controller in controllers { controller.window?.close() }
            for window in otherWindows.reversed() { window.orderFront(nil) }
        }
        func makeController() -> ArchiveWindowController {
            let controller = ArchiveWindowController()
            controllers.append(controller)
            return controller
        }
        func checkTopLeft(_ window: NSWindow, matches expected: NSPoint, line: UInt = #line) {
            XCTAssertEqual(window.frame.minX, expected.x, accuracy: 0.5, line: line)
            XCTAssertEqual(window.frame.maxY, expected.y, accuracy: 0.5, line: line)
        }

        let a = makeController(), aWindow = try XCTUnwrap(a.window)
        // 保存済みの画面端に左右されず、連続するカスケードの余地を作る。
        aWindow.setFrame(NSRect(x: screen.minX + 40, y: screen.maxY - 400, width: 600, height: 300), display: false)
        a.showWindow(nil)
        let aFrame = aWindow.frame

        let b = makeController(), bWindow = try XCTUnwrap(b.window)
        let expectedB = aWindow.cascadeTopLeft(from: .zero)
        b.showWindow(nil)
        XCTAssertGreaterThan(bWindow.frame.origin.x, aFrame.origin.x)
        XCTAssertLessThan(bWindow.frame.maxY, aFrame.maxY)
        checkTopLeft(bWindow, matches: expectedB)
        XCTAssertEqual(aWindow.frame, aFrame)

        bWindow.setFrameOrigin(NSPoint(x: bWindow.frame.minX + 20, y: bWindow.frame.minY - 15))
        let movedBFrame = bWindow.frame
        let c = makeController(), cWindow = try XCTUnwrap(c.window)
        let expectedC = bWindow.cascadeTopLeft(from: .zero)
        c.showWindow(nil)
        checkTopLeft(cWindow, matches: expectedC)
        XCTAssertEqual(bWindow.frame, movedBFrame)

        bWindow.close()
        cWindow.close()
        let d = makeController(), dWindow = try XCTUnwrap(d.window)
        d.showWindow(nil)
        checkTopLeft(dWindow, matches: aWindow.cascadeTopLeft(from: .zero))

        // 表示済みのウインドウは、隠して再表示しても位置を決め直さない。
        let dFrame = dWindow.frame
        d.showWindow(nil)
        XCTAssertEqual(dWindow.frame, dFrame)
        dWindow.orderOut(nil)
        aWindow.setFrameOrigin(NSPoint(x: aFrame.minX + 50, y: aFrame.minY))
        d.showWindow(nil)
        XCTAssertEqual(dWindow.frame, dFrame)

        aWindow.close()
        dWindow.close()
        let e = makeController(), eWindow = try XCTUnwrap(e.window)
        let eFrame = eWindow.frame
        e.showWindow(nil)
        XCTAssertEqual(eWindow.frame, eFrame)
    }
}
