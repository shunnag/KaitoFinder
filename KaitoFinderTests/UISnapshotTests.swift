import AppKit
import XCTest

@MainActor private final class SnapshotPatternView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height).fill()
        NSColor.blue.setFill()
        NSRect(x: bounds.width / 2, y: 0, width: bounds.width / 2, height: bounds.height).fill()
    }
}

nonisolated final class UISnapshotTests: XCTestCase {
    @MainActor func testDetectsClippedSingleLineLabel() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 80))
        let label = NSTextField(labelWithString: String(repeating: "Wide text ", count: 10))
        label.frame = NSRect(x: 10, y: 10, width: 100, height: 24)
        root.addSubview(label)
        XCTAssertGreaterThanOrEqual(label.intrinsicContentSize.width, 400)
        XCTAssertTrue(UISnapshot.overflowViolations(in: root).contains { $0.contains("内容の幅") && $0.contains("Wide text") })
        label.setFrameSize(label.intrinsicContentSize)
        root.setFrameSize(NSSize(width: label.frame.maxX + 10, height: 80))
        XCTAssertTrue(UISnapshot.overflowViolations(in: root).isEmpty)
    }

    @MainActor func testDetectsWrappingLabelWithInsufficientHeight() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let label = NSTextField(wrappingLabelWithString: String(repeating: "折り返す説明文です。", count: 12))
        label.frame = NSRect(x: 10, y: 10, width: 100, height: 16)
        root.addSubview(label)
        XCTAssertTrue(UISnapshot.overflowViolations(in: root).contains { $0.contains("内容の高さ") && $0.contains("折り返す説明文") })
        let height = label.sizeThatFits(NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude)).height
        label.setFrameSize(NSSize(width: 100, height: height))
        XCTAssertTrue(UISnapshot.overflowViolations(in: root).isEmpty)
    }

    @MainActor func testDetectsClippedButtonsAndPopup() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let button = NSButton(title: "Create New Archive…", target: nil, action: nil)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Same folder as the archive", "Ask every time"])
        for (index, control) in [button, popup].enumerated() {
            control.frame = NSRect(x: 10, y: 10 + index * 60, width: 20, height: 8)
            root.addSubview(control)
        }
        let violations = UISnapshot.overflowViolations(in: root)
        XCTAssertTrue(violations.contains { $0.contains("Create New Archive") && $0.contains("内容の幅") })
        XCTAssertTrue(violations.contains { $0.contains("NSPopUpButton") && $0.contains("内容の幅") })
        XCTAssertTrue(violations.contains { $0.contains("内容の高さ") })
        for control in [button, popup] { control.setFrameSize(control.intrinsicContentSize) }
        XCTAssertTrue(UISnapshot.overflowViolations(in: root).isEmpty)
    }

    @MainActor func testDetectsWrappingCheckboxWithInsufficientHeight() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        let button = NSButton(checkboxWithTitle: String(repeating: "折り返す設定の説明 ", count: 6), target: nil, action: nil)
        let cell = try XCTUnwrap(button.cell)
        cell.wraps = true
        cell.lineBreakMode = .byWordWrapping
        button.frame = NSRect(x: 10, y: 10, width: 180, height: 16)
        root.addSubview(button)
        XCTAssertTrue(UISnapshot.overflowViolations(in: root).contains { $0.contains("内容の高さ") })
        let required = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 180, height: 1000))
        button.setFrameSize(NSSize(width: 180, height: ceil(required.height)))
        XCTAssertTrue(UISnapshot.overflowViolations(in: root).isEmpty)
    }

    @MainActor func testDetectsFramesOutsideParentAndSkipsHiddenSubtrees() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        root.bounds.origin = NSPoint(x: 20, y: 10)
        let child = NSView(frame: NSRect(x: 19, y: 10, width: 100, height: 100))
        root.addSubview(child)
        XCTAssertTrue(UISnapshot.overflowViolations(in: root).contains { $0.contains("親の領域") })
        child.isHidden = true
        let label = NSTextField(labelWithString: "Hidden overflowing text")
        label.frame = NSRect(x: -10, y: -10, width: 1, height: 1)
        child.addSubview(label)
        XCTAssertTrue(UISnapshot.overflowViolations(in: root).isEmpty)
        XCTAssertTrue(UISnapshot.overflowViolations(in: label).isEmpty)
        child.isHidden = false
        label.removeFromSuperview()
        child.frame.origin.x = 19.5
        XCTAssertTrue(UISnapshot.overflowViolations(in: root).isEmpty)
    }

    @MainActor func testScrollViewAllowsLargeDocumentButStillChecksItsControls() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scroll.documentView = document
        XCTAssertTrue(UISnapshot.overflowViolations(in: scroll).isEmpty)
        let label = NSTextField(labelWithString: "Clipped inside the scrollable document")
        label.frame = NSRect(x: 10, y: 10, width: 20, height: 24)
        document.addSubview(label)
        XCTAssertTrue(UISnapshot.overflowViolations(in: scroll).contains { $0.contains("内容の幅") })
    }

    @MainActor func testRenderOverloadsWriteTwoTimesPNGs() throws {
        let view = SnapshotPatternView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        let alert = NSAlert()
        alert.messageText = "Snapshot harness"
        alert.informativeText = "Three render overloads"
        let images = [
            (try UISnapshot.render(view, name: "harness-view"), view.bounds.size),
            (try UISnapshot.render(window, name: "harness-window"), view.bounds.size),
            (try UISnapshot.render(alert, name: "harness-alert"), try XCTUnwrap(alert.window.contentView).bounds.size)
        ]
        for (url, size) in images {
            let data = try Data(contentsOf: url)
            XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(bitmap.pixelsWide, Int(ceil(size.width * 2)))
            XCTAssertEqual(bitmap.pixelsHigh, Int(ceil(size.height * 2)))
            XCTAssertEqual(url.deletingLastPathComponent(), UISnapshot.directory)
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 1, accuracy: 0.01)
            if url.lastPathComponent != "harness-alert.png" {
                let left = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                let right = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(left.redComponent, 0.9)
                XCTAssertLessThan(left.blueComponent, 0.1)
                XCTAssertGreaterThan(right.blueComponent, 0.9)
                XCTAssertLessThan(right.redComponent, 0.1)
            }
        }
    }
}
