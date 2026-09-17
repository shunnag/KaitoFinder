import AppKit
import XCTest
@testable import KaitoFinder

/// Finder と同じ file URL を運ぶ実 NSDraggingSession。受信処理はアプリのまま。
@MainActor private final class TabFileDragSource: NSView, NSDraggingSource {
    var urls: [URL] = []
    private(set) var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let items = urls.map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(NSRect(x: 20, y: 20, width: 32, height: 32),
                                  contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self).animatesToStartingPositionsOnCancelOrFail = false
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, willBeginAt point: NSPoint) { isDragging = true }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) { isDragging = false }
}

nonisolated final class ArchiveTabSpringLoadingTests: XCTestCase {
    @MainActor private var dragPoint = NSPoint.zero
    @MainActor private func tabs(_ count: Int) async throws -> ([ScenarioFixture], [ArchiveDocument], [ArchiveWindowController]) {
        var fixtures: [ScenarioFixture] = [], documents: [ArchiveDocument] = [], controllers: [ArchiveWindowController] = []
        let identifier = UUID().uuidString
        for _ in 0..<count {
            let fixture = try ScenarioFixture()
            let (document, controller) = try await scenarioDocument(fixture)
            let window = try XCTUnwrap(controller.window)
            window.tabbingIdentifier = identifier
            window.tabbingMode = .disallowed
            controller.showWindow(nil)
            fixtures.append(fixture); documents.append(document); controllers.append(controller)
        }
        let first = try XCTUnwrap(controllers[0].window)
        first.setFrame(NSRect(x: 350, y: 220, width: 800, height: 500), display: true)
        for controller in controllers.dropFirst() { first.addTabbedWindow(try XCTUnwrap(controller.window), ordered: .above) }
        first.tabGroup?.selectedWindow = first
        first.makeKeyAndOrderFront(nil)
        first.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        try await scenarioWait { first.tabGroup?.windows.count == count }
        first.contentView?.layoutSubtreeIfNeeded()
        return (fixtures, documents, controllers)
    }

    @MainActor private func source(urls: [URL]) -> (NSWindow, TabFileDragSource) {
        let view = TabFileDragSource(frame: NSRect(x: 0, y: 0, width: 180, height: 160))
        view.urls = urls
        let window = NSWindow(contentRect: NSRect(x: 100, y: 250, width: 180, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in window.close() }
        return (window, view)
    }

    @MainActor private func start(_ window: NSWindow, view: TabFileDragSource) async throws {
        window.makeKeyAndOrderFront(nil)
        let point = window.convertPoint(toScreen: NSPoint(x: 60, y: 60))
        dragPoint = point
        try postNativeMouseEvent(.leftMouseDown, at: point, in: window)
        try await scenarioWait { view.isDragging }
    }

    @MainActor private func hover(_ window: NSWindow, fraction: CGFloat = 0.5) async throws {
        let frame = try nativeTabFrame(for: window)
        let selected = try XCTUnwrap(window.tabGroup?.selectedWindow)
        let target = NSPoint(x: frame.minX + frame.width * fraction, y: frame.midY)
        for step in 1...8 {
            try await Task.sleep(for: .milliseconds(40))
            let progress = CGFloat(step) / 8
            try postNativeMouseEvent(.leftMouseDragged,
                at: NSPoint(x: dragPoint.x + (target.x - dragPoint.x) * progress, y: dragPoint.y + (target.y - dragPoint.y) * progress),
                in: selected)
        }
        dragPoint = target
    }

    @MainActor private func cancel(_ window: NSWindow) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            NSApp.postEvent(event, atStart: false)
        }
        try? postNativeMouseEvent(.leftMouseUp, at: NSPoint(x: window.frame.midX, y: window.frame.maxY - 8), in: window)
    }

    @MainActor func testFileURLsCanHoverAcrossThreeSameNamedTabsAndCopyOnlyIntoTheFinalArchive() async throws {
        let (fixtures, documents, controllers) = try await tabs(3)
        let windows = try controllers.map { try XCTUnwrap($0.window) }
        let originals = try fixtures.map { try ScenarioFixture.digest($0.archive) }
        let urls = try (0..<3).map { try fixtures[0].file("inputs/new-\($0).txt", bytes: Data("new \($0)".utf8)) }
        let (sourceWindow, view) = source(urls: urls)
        defer { if view.isDragging { cancel(sourceWindow) } }
        try await start(sourceWindow, view: view)
        // タイトルだけでなく、左右の余白でも受ける。切り替え後も同じドラッグを続ける。
        try await hover(windows[1], fraction: 0.2)
        try await scenarioWait { windows[0].tabGroup?.selectedWindow === windows[1] }
        try await hover(windows[2], fraction: 0.95)
        try await scenarioWait { windows[0].tabGroup?.selectedWindow === windows[2] }
        try await hover(windows[1])
        try await scenarioWait { windows[0].tabGroup?.selectedWindow === windows[1] }
        let point = windows[1].convertPoint(toScreen: controllers[1].outlineView.convert(NSPoint(x: 120, y: 150), to: nil))
        try postNativeMouseEvent(.leftMouseDragged, at: point, in: windows[1])
        try await Task.sleep(for: .milliseconds(100))
        try postNativeMouseEvent(.leftMouseUp, at: point, in: windows[1])
        try await scenarioWait { !view.isDragging && documents[1].generation > 0 }
        await controllers[1].extractionTask?.value
        var expected = try ScenarioFixture.contents(fixtures[0].archive)
        for (index, url) in urls.enumerated() { expected[url.lastPathComponent] = Data("new \(index)".utf8) }
        XCTAssertEqual(try ScenarioFixture.contents(fixtures[1].archive), expected)
        XCTAssertEqual(try ScenarioFixture.digest(fixtures[0].archive), originals[0])
        XCTAssertEqual(try ScenarioFixture.digest(fixtures[2].archive), originals[2])
        documents[1].undo(nil)
        await documents[1].undoTask?.value
        XCTAssertEqual(try ScenarioFixture.digest(fixtures[1].archive), originals[1])
    }

    @MainActor func testBriefHoverExitAndEscapeCancelLeaveBothArchivesUnchanged() async throws {
        let (fixtures, documents, controllers) = try await tabs(2)
        let first = try XCTUnwrap(controllers[0].window), second = try XCTUnwrap(controllers[1].window)
        let originals = try fixtures.map { try ScenarioFixture.digest($0.archive) }
        let url = try fixtures[0].file("inputs/new.txt", bytes: Data("new".utf8))
        let (sourceWindow, view) = source(urls: [url])
        defer { if view.isDragging { cancel(sourceWindow) } }
        try await start(sourceWindow, view: view)
        try await hover(second)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(first.tabGroup?.selectedWindow === first, "短い通過では切り替えない")
        let point = first.convertPoint(toScreen: controllers[0].outlineView.convert(NSPoint(x: 100, y: 140), to: nil))
        try postNativeMouseEvent(.leftMouseDragged, at: point, in: first)
        dragPoint = point
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertTrue(first.tabGroup?.selectedWindow === first, "タブから離れた待機は発火しない")
        try await hover(second)
        try await Task.sleep(for: .milliseconds(80))
        cancel(first)
        try await scenarioWait { !view.isDragging }
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertTrue(first.tabGroup?.selectedWindow === first, "取消し後の待機は発火しない")
        XCTAssertEqual(try fixtures.map { try ScenarioFixture.digest($0.archive) }, originals)
        XCTAssertTrue(documents.allSatisfy { $0.undoManager?.canUndo != true })
    }

    @MainActor func testClosingHoveredTabCancelsPendingActivation() async throws {
        let (fixtures, _, controllers) = try await tabs(3)
        let windows = try controllers.map { try XCTUnwrap($0.window) }
        let url = try fixtures[0].file("inputs/new.txt", bytes: Data("new".utf8))
        let (sourceWindow, view) = source(urls: [url])
        defer { if view.isDragging { cancel(sourceWindow) } }
        try await start(sourceWindow, view: view)
        try await hover(windows[1])
        try await Task.sleep(for: .milliseconds(80))
        controllers[1].close()
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertTrue(windows[0].tabGroup?.selectedWindow === windows[0])
        XCTAssertEqual(windows[0].tabGroup?.windows.count, 2)
        // 閉じたタブのタイマーを残さず、残りのタブへ同じドラッグで移れる。
        try await hover(windows[2])
        try await scenarioWait { windows[0].tabGroup?.selectedWindow === windows[2] }
        cancel(windows[2])
        try await scenarioWait { !view.isDragging }
        XCTAssertTrue(controllers.allSatisfy { $0.extractionTask == nil })
    }

    @MainActor func testNativeMouseClickStillSelectsTabsAfterSplittingAndMerging() async throws {
        let (_, _, controllers) = try await tabs(2)
        let first = try XCTUnwrap(controllers[0].window), second = try XCTUnwrap(controllers[1].window)
        for split in [false, true] {
            if split {
                second.moveTabToNewWindow(nil)
                try await scenarioWait { first.tabGroup !== second.tabGroup }
                first.addTabbedWindow(second, ordered: .above)
                first.tabGroup?.selectedWindow = first
            }
            let frame = try nativeTabFrame(for: second)
            let point = NSPoint(x: frame.midX, y: frame.midY)
            try postNativeMouseEvent(.leftMouseDown, at: point, in: first)
            try await Task.sleep(for: .milliseconds(50))
            try postNativeMouseEvent(.leftMouseUp, at: point, in: first)
            try await scenarioWait { first.tabGroup?.selectedWindow === second }
        }
        try UISnapshot.render(try XCTUnwrap(second.contentView?.superview), name: "archive-native-tabs-after-regrouping")
    }
}
