import AppKit
import XCTest
@testable import KaitoFinder

@MainActor private final class ArchiveDropProbe: NSObject, NSOutlineViewDataSource {
    let controller: ArchiveWindowController
    var proposedOperation: NSDragOperation = []
    var accepted = false
    let inspectDrop: ((any NSDraggingInfo) -> Void)?
    init(_ controller: ArchiveWindowController, inspectDrop: ((any NSDraggingInfo) -> Void)?) {
        self.controller = controller
        self.inspectDrop = inspectDrop
    }
    func outlineView(_ view: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        controller.outlineView(view, numberOfChildrenOfItem: item)
    }
    func outlineView(_ view: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        controller.outlineView(view, child: index, ofItem: item)
    }
    func outlineView(_ view: NSOutlineView, isItemExpandable item: Any) -> Bool {
        controller.outlineView(view, isItemExpandable: item)
    }
    func outlineView(_ view: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        proposedOperation = controller.outlineView(view, validateDrop: info, proposedItem: item, proposedChildIndex: index)
        return proposedOperation
    }
    func outlineView(_ view: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        inspectDrop?(info)
        accepted = controller.outlineView(view, acceptDrop: info, item: item, childIndex: index)
        return accepted
    }
}

extension XCTestCase {
    /// 実際の行からマウスイベントでドラッグし、窓間の file promise を受け渡す。
    @MainActor func dragSelection(from source: ArchiveWindowController, to destination: ArchiveWindowController,
                                  tabbed: Bool, expectedCount: Int, paths: Set<String>? = nil,
                                  inspectDrop: ((any NSDraggingInfo) -> Void)? = nil) async throws {
        let probe = ArchiveDropProbe(destination, inspectDrop: inspectDrop)
        destination.outlineView.dataSource = probe
        defer { destination.outlineView.dataSource = destination }
        let first = try XCTUnwrap(source.window), second = try XCTUnwrap(destination.window)
        first.tabbingIdentifier = UUID().uuidString
        second.tabbingIdentifier = UUID().uuidString
        destination.showWindow(nil)
        source.showWindow(nil)
        first.setFrame(NSRect(x: 40, y: 240, width: 680, height: 500), display: true)
        second.setFrame(NSRect(x: 750, y: 240, width: 680, height: 500), display: true)
        second.makeKeyAndOrderFront(nil)
        first.makeKeyAndOrderFront(nil)
        first.makeMain()
        if tabbed {
            first.addTabbedWindow(second, ordered: .above)
            first.tabGroup?.selectedWindow = first
            first.makeKeyAndOrderFront(nil)
            XCTAssertTrue(first.tabGroup === second.tabGroup)
        }
        NSApp.activate(ignoringOtherApps: true)
        first.makeKeyAndOrderFront(nil)
        first.orderFrontRegardless()
        source.outlineView.expandItem(nil, expandChildren: true)
        if let paths {
            let view = source.outlineView
            view.selectRowIndexes(IndexSet((0..<view.numberOfRows).filter { row in
                (view.item(atRow: row) as? EntryNode).map { paths.contains($0.path) } == true
            }), byExtendingSelection: false)
        } else { source.outlineView.selectAll(nil) }
        first.contentView?.layoutSubtreeIfNeeded()
        second.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        let startRow = source.outlineView.selectedRowIndexes.first ?? 0
        source.outlineView.scrollRowToVisible(startRow)
        let rect = source.outlineView.rect(ofRow: startRow)
        let start = first.convertPoint(toScreen: source.outlineView.convert(NSPoint(x: 120, y: rect.midY), to: nil))
        let end = second.convertPoint(toScreen: destination.outlineView.convert(NSPoint(x: 120, y: 150), to: nil))
        func post(_ type: NSEvent.EventType, at point: NSPoint) throws {
            let window = tabbed ? (first.tabGroup?.selectedWindow ?? first) : (second.frame.contains(point) ? second : first)
            try postNativeMouseEvent(type, at: point, in: window)
        }
        try post(.mouseMoved, at: start)
        try await Task.sleep(for: .milliseconds(50))
        var mouseIsDown = true
        defer { if mouseIsDown { try? post(.leftMouseUp, at: start) } }
        try post(.leftMouseDown, at: start)
        try await Task.sleep(for: .milliseconds(80))
        try post(.leftMouseDragged, at: NSPoint(x: start.x + 8, y: start.y))
        try await scenarioWait { source.draggedNodes.count == expectedCount }
        var travelStart = start
        if tabbed {
            let frame = try nativeTabFrame(for: second)
            let hover = NSPoint(x: frame.midX, y: frame.midY)
            for step in 1...8 {
                try await Task.sleep(for: .milliseconds(40))
                let fraction = CGFloat(step) / 8
                try post(.leftMouseDragged, at: NSPoint(x: start.x + (hover.x - start.x) * fraction,
                                                       y: start.y + (hover.y - start.y) * fraction))
            }
            // タブをコードから選ばず、実際にカーソルを保持して選択が変わることを確認する。
            try await scenarioWait { first.tabGroup?.selectedWindow === second }
            XCTAssertEqual(source.draggedNodes.count, expectedCount)
            travelStart = hover
        }
        for step in 1...20 {
            try await Task.sleep(for: .milliseconds(40))
            let fraction = CGFloat(step) / 20
            try post(.leftMouseDragged, at: NSPoint(x: travelStart.x + (end.x - travelStart.x) * fraction,
                                                   y: travelStart.y + (end.y - travelStart.y) * fraction))
        }
        for _ in 0..<20 where probe.proposedOperation != .copy {
            try await Task.sleep(for: .milliseconds(50))
            try post(.leftMouseDragged, at: end)
        }
        XCTAssertEqual(probe.proposedOperation, .copy)
        XCTAssertEqual(source.draggedNodes.count, expectedCount, "子孫の二重送信を防ぎ、全ファイルを運ぶ")
        try post(.leftMouseUp, at: end)
        mouseIsDown = false
        try await scenarioWait { probe.accepted }
        XCTAssertTrue(probe.accepted)
    }
}
