import AppKit
import XCTest
@testable import KaitoFinder

/// ドラッグ画像は行のセルビューに依存せず、アイコンと名前から組み立てる。
nonisolated final class ArchiveDragImageTests: XCTestCase {
    @MainActor func testComponentsHaveIconAndReadableLabelWithinTheRowHeight() throws {
        let icon = NSWorkspace.shared.icon(for: .plainText)
        let components = ArchiveDragImage.components(icon: icon, name: "report-2026-09-19.txt", height: 22)
        XCTAssertEqual(components.map(\.key), [.icon, .label])
        let iconFrame = components[0].frame, labelFrame = components[1].frame
        XCTAssertEqual(iconFrame.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(iconFrame.minY, 3, "icon is vertically centred in a 22 pt row")
        XCTAssertGreaterThan(labelFrame.minX, iconFrame.maxX)
        XCTAssertGreaterThan(labelFrame.width, 60, "label must be wide enough for the name")
        XCTAssertEqual(labelFrame.height, 22)
        let label = try XCTUnwrap(components[1].contents as? NSImage)
        XCTAssertEqual(label.size, labelFrame.size)
        // 描画された画素があること（空の画像でないこと）。
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(label.tiffRepresentation)))
        var opaque = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 {
                opaque += 1
            }
        }
        XCTAssertGreaterThan(opaque, 20, "the label image must contain drawn text")
    }

    @MainActor func testLongNamesAreBoundedAndLayoutWidthCoversBothComponents() {
        let long = String(repeating: "あ", count: 200)
        let layout = ArchiveDragImage.layout(name: long, height: 22)
        XCTAssertLessThanOrEqual(layout.labelFrame.width, ArchiveDragImage.maximumLabelWidth)
        XCTAssertEqual(layout.width, layout.labelFrame.maxX + ArchiveDragImage.labelSpacing)
        let short = ArchiveDragImage.layout(name: "a", height: 22)
        XCTAssertLessThan(short.width, layout.width)
    }
}
