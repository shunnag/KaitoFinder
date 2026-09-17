import AppKit
import XCTest

@MainActor func postNativeMouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws {
    let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: point),
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    NSApp.postEvent(event, atStart: false)
}

/// 標準タブの実際の表示位置。タイトルの重複やタブ幅に依存せず、公開 AX 順序を使う。
@MainActor func nativeTabFrame(for window: NSWindow) throws -> NSRect {
    let group = try XCTUnwrap(window.tabGroup)
    let selected = try XCTUnwrap(group.selectedWindow)
    let index = try XCTUnwrap(group.windows.firstIndex { $0 === window })
    let bar = try XCTUnwrap(selected.accessibilityChildren()?.compactMap { $0 as? any NSAccessibilityProtocol }
        .first { $0.accessibilityRole() == .tabGroup })
    let tabs = (bar.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        .filter { $0.accessibilityRole() == .radioButton }
    XCTAssertEqual(tabs.count, group.windows.count)
    let tab = try XCTUnwrap(tabs.indices.contains(index) ? tabs[index] : nil)
    let frame = tab.accessibilityFrame()
    XCTAssertGreaterThan(frame.width, 0)
    XCTAssertGreaterThan(frame.height, 0)
    return frame
}
