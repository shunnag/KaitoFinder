import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import KaitoFinder

nonisolated final class WelcomeWindowTests: XCTestCase {
    @MainActor private func controller(store: ArchivePreferencesStore? = nil) throws -> WelcomeWindowController {
        let suite = try ArchivePreferencesTestDefaults()
        addTeardownBlock { _ = suite }
        let result = WelcomeWindowController(store: store ?? ArchivePreferencesStore(defaults: suite.defaults),
            bundle: try LocalizationAcceptance.bundle("ja"), createAction: {}, createDropAction: { _, _ in })
        addTeardownBlock { @MainActor in result.close() }
        return result
    }

    @MainActor func testControllerBuildsFixedClosableWindowWithAccessibleDropZones() throws {
        let controller = try controller()
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 720, height: 440))
        XCTAssertEqual(window.title, "ようこそKaitoFinderへ")
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertEqual(window.frameAutosaveName, "")
        XCTAssertTrue(window.initialFirstResponder === controller.openDropZone)
        XCTAssertTrue(controller.openDropZone.nextKeyView === controller.createDropZone)
        XCTAssertTrue(controller.createDropZone.nextKeyView === controller.showsWelcomeWindowAtLaunchCheckbox)
        XCTAssertEqual(controller.showsWelcomeWindowAtLaunchCheckbox.title, "KaitoFinderの起動時にこのウインドウを表示")
        for zone in [controller.openDropZone, controller.createDropZone] {
            XCTAssertTrue(zone.acceptsFirstResponder)
            XCTAssertEqual(zone.accessibilityRole(), .button)
            XCTAssertEqual(zone.accessibilityLabel(), zone.headingLabel.stringValue)
            XCTAssertEqual(zone.accessibilityHelp(), zone.captionLabel.stringValue)
            XCTAssertEqual(zone.focusRingType, .exterior)
            XCTAssertTrue(zone.registeredDraggedTypes.contains(.fileURL))
        }
    }

    func testLaunchDecisionRequiresNoFilesNoDocumentsAndEnabledPreference() {
        for files in [false, true] {
            for documents in [false, true] {
                for preference in [false, true] {
                    XCTAssertEqual(AppDelegate.shouldShowWelcome(argumentsHadFiles: files, hasDocuments: documents,
                        preference: preference), !files && !documents && preference,
                        "files=\(files), documents=\(documents), preference=\(preference)")
                }
            }
        }
    }

    @MainActor func testDockReopenWithoutWindowsIgnoresPreferenceAndReusesController() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.showsWelcomeWindowAtLaunch = false
        let delegate = AppDelegate(preferencesStore: store)
        defer { delegate.welcomeWindowController?.close() }
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        let controller = try XCTUnwrap(delegate.welcomeWindowController)
        XCTAssertEqual(controller.window?.isVisible, true)
        controller.close()
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        XCTAssertTrue(delegate.welcomeWindowController === controller)
        XCTAssertEqual(controller.window?.isVisible, true)
        XCTAssertEqual(controller.showsWelcomeWindowAtLaunchCheckbox.state, .off)
    }

    @MainActor func testDockReopenWithVisibleWindowsDoesNotCreateWelcome() throws {
        let suite = try ArchivePreferencesTestDefaults()
        let delegate = AppDelegate(preferencesStore: ArchivePreferencesStore(defaults: suite.defaults))
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertNil(delegate.welcomeWindowController)
    }

    @MainActor func testMenuActionReopensSameWindowWithLaunchPreferenceOff() throws {
        preserveApplicationMenus()
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.showsWelcomeWindowAtLaunch = false
        let delegate = AppDelegate(preferencesStore: store)
        defer { delegate.welcomeWindowController?.close() }
        let menu = delegate.makeMenu()
        let item = try menuItem(#selector(AppDelegate.showWelcome(_:)), in: menu)
        try performMenuItem(item)
        let controller = try XCTUnwrap(delegate.welcomeWindowController)
        controller.close()
        try performMenuItem(item)
        XCTAssertTrue(delegate.welcomeWindowController === controller)
        XCTAssertEqual(controller.window?.isVisible, true)
        XCTAssertFalse(store.preferences.showsWelcomeWindowAtLaunch)
    }

    @MainActor func testCheckboxAndGeneralSettingsSynchronizeBothDirectionsAndRoundTrip() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let controller = try controller(store: store)
        let settings = PreferencesWindowController(store: store, bundle: try LocalizationAcceptance.bundle("ja"))
        defer { settings.close() }
        XCTAssertEqual(controller.showsWelcomeWindowAtLaunchCheckbox.state, .on)
        XCTAssertEqual(settings.showsWelcomeWindowAtLaunchCheckbox.state, .on)
        XCTAssertEqual(settings.showsWelcomeWindowAtLaunchCheckbox.title, "起動時にようこそウインドウを表示")
        let checkbox = controller.showsWelcomeWindowAtLaunchCheckbox
        checkbox.state = .off
        XCTAssertTrue(checkbox.sendAction(checkbox.action, to: checkbox.target))
        XCTAssertFalse(store.preferences.showsWelcomeWindowAtLaunch)
        XCTAssertFalse(suite.defaults.bool(forKey: "ArchiveShowsWelcomeAtLaunch"))
        XCTAssertEqual(settings.showsWelcomeWindowAtLaunchCheckbox.state, .off)
        XCTAssertFalse(ArchivePreferencesStore(defaults: suite.defaults).preferences.showsWelcomeWindowAtLaunch)
        settings.showsWelcomeWindowAtLaunchCheckbox.state = .on
        XCTAssertTrue(settings.showsWelcomeWindowAtLaunchCheckbox.sendAction(
            settings.showsWelcomeWindowAtLaunchCheckbox.action, to: settings.showsWelcomeWindowAtLaunchCheckbox.target))
        XCTAssertTrue(store.preferences.showsWelcomeWindowAtLaunch)
        XCTAssertEqual(checkbox.state, .on)
        store.preferences.showsWelcomeWindowAtLaunch = false
        XCTAssertEqual(checkbox.state, .off)
        XCTAssertEqual(settings.showsWelcomeWindowAtLaunchCheckbox.state, .off)
    }

    @MainActor func testOnlyArchiveMainWindowClosesWelcomeAndClosingItDoesNotReopenWelcome() throws {
        let controller = try controller()
        controller.showWindow(nil)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: other)
        XCTAssertEqual(controller.window?.isVisible, true)
        let autosave = ArchiveWindowFrameAutosave()
        defer { autosave.restore() }
        let archive = ArchiveWindowController()
        defer { archive.close() }
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: archive.window)
        XCTAssertEqual(controller.window?.isVisible, false)
        archive.close()
        XCTAssertEqual(controller.window?.isVisible, false)
    }

    @MainActor func testEscapeClosesWelcome() throws {
        let controller = try controller()
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        window.cancelOperation(nil)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testArchiveMainWindowKeepsWelcomeOpenUntilAttachedProgressSheetFinishes() async throws {
        let controller = try controller()
        controller.showWindow(nil)
        let window = try XCTUnwrap(controller.window)
        let sheet = ExtractionProgressSheet(progress: Progress(totalUnitCount: 1))
        defer { sheet.finish() }
        sheet.begin(on: window)
        XCTAssertTrue(window.attachedSheet === sheet.window)
        let autosave = ArchiveWindowFrameAutosave()
        defer { autosave.restore() }
        let archive = ArchiveWindowController()
        defer { archive.close() }

        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: archive.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(window.attachedSheet === sheet.window)
        sheet.finish()
        try await scenarioWait { window.attachedSheet == nil }
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: archive.window)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor private func fixtureURLs() throws -> (archive: URL, otherArchive: URL, folder: URL, text: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KaitoFinder-Welcome-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("photos.zip"), otherArchive = root.appendingPathComponent("more.zip")
        let text = root.appendingPathComponent("notes.txt"), folder = root.appendingPathComponent("folder.zip")
        try Data().write(to: archive)
        try Data().write(to: otherArchive)
        try Data("notes".utf8).write(to: text)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (archive, otherArchive, folder, text)
    }

    @MainActor private func dragging(_ urls: [URL]) throws -> WelcomeDraggingInfo {
        let info = WelcomeDraggingInfo()
        addTeardownBlock { @MainActor in info.pasteboard.releaseGlobally() }
        if !urls.isEmpty, !info.pasteboard.writeObjects(urls.map { $0 as NSURL }) {
            // 入力自体を用意できない環境で、空ペーストボードの拒否を成功と取り違えない。
            throw XCTSkip("テスト用ペーストボードへ書き込めません。sandbox 外でドラッグ検証を再実行してください。")
        }
        return info
    }

    @MainActor private func zone(_ kind: WelcomeDropZoneView.Kind,
                                 click: @escaping () -> Void = {}, drop: @escaping ([URL]) -> Void = { _ in }) -> WelcomeDropZoneView {
        WelcomeDropZoneView(kind: kind,
            archiveTypes: ArchiveBatchExtractionController.archiveContentTypes(bundle: Bundle(for: ArchiveDocument.self)),
            clickAction: click, dropAction: drop)
    }

    @MainActor func testOpenDropAcceptsArchivesAndPassesEveryURLThenResetsHighlight() throws {
        let urls = try fixtureURLs()
        var received: [URL] = []
        let zone = zone(.open, drop: { received = $0 })
        let info = try dragging([urls.archive, urls.otherArchive])
        XCTAssertEqual(zone.draggingEntered(info), .copy)
        XCTAssertTrue(zone.isDragHighlighted)
        XCTAssertEqual(zone.draggingUpdated(info), .copy)
        XCTAssertTrue(zone.prepareForDragOperation(info))
        XCTAssertTrue(zone.performDragOperation(info))
        XCTAssertEqual(received, [urls.archive, urls.otherArchive])
        XCTAssertFalse(zone.isDragHighlighted)
    }

    @MainActor func testOpenDropRejectsDirectoriesNonArchivesMixedAndEmptyPasteboards() throws {
        let urls = try fixtureURLs()
        var calls = 0
        let zone = zone(.open, drop: { _ in calls += 1 })
        for candidates in [[urls.folder], [urls.text], [urls.archive, urls.text], [urls.archive, urls.folder], []] {
            let info = try dragging(candidates)
            XCTAssertEqual(zone.draggingEntered(info), [])
            XCTAssertFalse(zone.isDragHighlighted)
            XCTAssertFalse(zone.prepareForDragOperation(info))
            XCTAssertFalse(zone.performDragOperation(info))
        }
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testDragUpdatedExitAndEndClearHighlightAndRevalidateTheDrop() throws {
        let urls = try fixtureURLs()
        var calls = 0
        let zone = zone(.open, drop: { _ in calls += 1 })
        let info = try dragging([urls.archive])
        XCTAssertEqual(zone.draggingEntered(info), .copy)
        zone.draggingExited(info)
        XCTAssertFalse(zone.isDragHighlighted)
        XCTAssertEqual(zone.draggingEntered(info), .copy)
        zone.draggingEnded(info)
        XCTAssertFalse(zone.isDragHighlighted)
        XCTAssertEqual(zone.draggingEntered(info), .copy)
        info.pasteboard.clearContents()
        info.pasteboard.writeObjects([urls.text as NSURL])
        XCTAssertEqual(zone.draggingUpdated(info), [])
        XCTAssertFalse(zone.isDragHighlighted)
        XCTAssertFalse(zone.performDragOperation(info))
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testCreateDropAcceptsFilesAndFoldersButRejectsNonFileURLsAndUnsupportedOperations() throws {
        let urls = try fixtureURLs()
        var received: [URL] = []
        let zone = zone(.create, drop: { received = $0 })
        let info = try dragging([urls.folder, urls.text, urls.archive])
        XCTAssertEqual(zone.draggingEntered(info), .copy)
        XCTAssertTrue(zone.performDragOperation(info))
        XCTAssertEqual(received, [urls.folder, urls.text, urls.archive])
        XCTAssertFalse(zone.isDragHighlighted)
        let web = try dragging([XCTUnwrap(URL(string: "https://example.com/archive.zip"))])
        XCTAssertEqual(zone.draggingEntered(web), [])
        XCTAssertFalse(zone.performDragOperation(web))
        info.draggingSourceOperationMask = .move
        XCTAssertEqual(zone.draggingEntered(info), [])
        XCTAssertFalse(zone.performDragOperation(info))
    }

    @MainActor func testCreateDropPassesWelcomeAsSheetParentAndStaysOpenUntilADocumentAppears() throws {
        let suite = try ArchivePreferencesTestDefaults()
        let urls = try fixtureURLs()
        var sources: [URL] = [], parent: NSWindow?
        let controller = WelcomeWindowController(store: ArchivePreferencesStore(defaults: suite.defaults),
            createAction: {}, createDropAction: { sources = $0; parent = $1 })
        defer { controller.close() }
        controller.showWindow(nil)
        let info = try dragging([urls.folder, urls.text])
        XCTAssertTrue(controller.createDropZone.performDragOperation(info))
        XCTAssertEqual(sources, [urls.folder, urls.text])
        XCTAssertTrue(parent === controller.window)
        // 保存が取り消された場合も文書の表示通知はなく、そのまま操作を続けられる。
        XCTAssertEqual(controller.window?.isVisible, true)
    }

    @MainActor func testCreateDropRechecksCanCreateAtEveryDragStage() throws {
        let suite = try ArchivePreferencesTestDefaults(), urls = try fixtureURLs()
        var canCreate = false, received: [[URL]] = []
        let controller = WelcomeWindowController(store: ArchivePreferencesStore(defaults: suite.defaults),
            createAction: {}, canCreate: { canCreate }, createDropAction: { sources, _ in received.append(sources) })
        defer { controller.close() }
        let zone = controller.createDropZone, info = try dragging([urls.folder, urls.text])

        XCTAssertEqual(zone.draggingEntered(info), [])
        XCTAssertEqual(zone.draggingUpdated(info), [])
        XCTAssertFalse(zone.isDragHighlighted)
        XCTAssertFalse(zone.prepareForDragOperation(info))
        XCTAssertFalse(zone.performDragOperation(info))
        XCTAssertTrue(received.isEmpty)

        canCreate = true
        XCTAssertEqual(zone.draggingEntered(info), .copy)
        XCTAssertTrue(zone.isDragHighlighted)
        canCreate = false
        XCTAssertEqual(zone.draggingUpdated(info), [])
        XCTAssertFalse(zone.isDragHighlighted)
        canCreate = true
        XCTAssertTrue(zone.prepareForDragOperation(info))
        canCreate = false
        XCTAssertFalse(zone.performDragOperation(info))
        XCTAssertTrue(received.isEmpty)
        XCTAssertFalse(zone.isDragHighlighted)

        canCreate = true
        XCTAssertEqual(zone.draggingEntered(info), .copy)
        XCTAssertEqual(zone.draggingUpdated(info), .copy)
        XCTAssertTrue(zone.prepareForDragOperation(info))
        XCTAssertTrue(zone.performDragOperation(info))
        XCTAssertEqual(received, [[urls.folder, urls.text]])
        XCTAssertFalse(zone.isDragHighlighted)
    }

    @MainActor func testFileTypeValidationWithRealFilesWithoutPasteboardService() throws {
        let urls = try fixtureURLs()
        do {
            _ = try urls.archive.resourceValues(forKeys: [.contentTypeKey])
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            guard underlying?.domain == NSOSStatusErrorDomain, underlying?.code == -10813 else { throw error }
            throw XCTSkip("LaunchServices がファイル型を返せません。sandbox 外で実ファイルの型検証を再実行してください。")
        }
        let open = zone(.open), create = zone(.create)
        XCTAssertTrue(open.accepts([urls.archive]))
        XCTAssertTrue(open.accepts([urls.archive, urls.otherArchive]))
        for candidates in [[urls.folder], [urls.text], [urls.archive, urls.text], [urls.archive, urls.folder]] {
            XCTAssertFalse(open.accepts(candidates))
            XCTAssertTrue(create.accepts(candidates))
        }
        XCTAssertTrue(create.accepts([urls.archive, urls.folder, urls.text]))
        let web = try XCTUnwrap(URL(string: "https://example.com/archive.zip"))
        for zone in [open, create] {
            XCTAssertFalse(zone.accepts([]))
            XCTAssertFalse(zone.accepts([web]))
            XCTAssertFalse(zone.accepts([urls.archive, web]))
        }
    }

    @MainActor private func mouse(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @MainActor private func key(_ text: String, repeat isRepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: isRepeat, keyCode: 0))
    }

    @MainActor func testPlainClicksOnBothZonesInvokeOnlyTheirInjectedActions() throws {
        let suite = try ArchivePreferencesTestDefaults()
        var opened = 0, created = 0
        let controller = WelcomeWindowController(store: ArchivePreferencesStore(defaults: suite.defaults),
            openAction: { opened += 1 }, createAction: { created += 1 }, createDropAction: { _, _ in })
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        for zone in [controller.openDropZone, controller.createDropZone] {
            let point = zone.convert(NSPoint(x: zone.bounds.midX, y: zone.bounds.midY), to: nil)
            zone.mouseDown(with: try mouse(.leftMouseDown, at: point, window: window))
            zone.mouseUp(with: try mouse(.leftMouseUp, at: point, window: window))
        }
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(created, 1)
    }

    @MainActor func testDraggingOrReleasingOutsideDoesNotFireClickEvenWhenPointerReturns() throws {
        var calls = 0
        let zone = zone(.create, click: { calls += 1 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 316, height: 190),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = zone
        let start = NSPoint(x: 150, y: 90), moved = NSPoint(x: 180, y: 90), outside = NSPoint(x: 400, y: 90)
        zone.mouseDown(with: try mouse(.leftMouseDown, at: start, window: window))
        zone.mouseDragged(with: try mouse(.leftMouseDragged, at: moved, window: window))
        zone.mouseDragged(with: try mouse(.leftMouseDragged, at: start, window: window))
        zone.mouseUp(with: try mouse(.leftMouseUp, at: start, window: window))
        zone.mouseDown(with: try mouse(.leftMouseDown, at: start, window: window))
        zone.mouseUp(with: try mouse(.leftMouseUp, at: outside, window: window))
        zone.mouseUp(with: try mouse(.leftMouseUp, at: start, window: window))
        XCTAssertEqual(calls, 0)
    }

    @MainActor func testSpaceReturnAndAccessibilityPressInvokeActionsWithoutKeyRepeat() throws {
        for kind in [WelcomeDropZoneView.Kind.open, .create] {
            var calls = 0
            let zone = zone(kind, click: { calls += 1 })
            zone.keyDown(with: try key(" "))
            zone.keyDown(with: try key("\r"))
            zone.keyDown(with: try key("\u{3}"))
            zone.keyDown(with: try key(" ", repeat: true))
            XCTAssertTrue(zone.accessibilityPerformPress())
            XCTAssertEqual(calls, 4)
        }
    }

    // ArchiveEntryControlsTests の NSDraggingInfo スタブと同じ AppKit 境界を使う。
    @MainActor private final class WelcomeDraggingInfo: NSObject, NSDraggingInfo {
        var draggingDestinationWindow: NSWindow?
        var draggingSourceOperationMask: NSDragOperation = [.copy]
        var draggingLocation: NSPoint = .zero
        var draggedImageLocation: NSPoint { .zero }
        nonisolated var draggedImage: NSImage? { nil }
        let pasteboard = NSPasteboard(name: .init("KaitoFinder-Welcome-" + UUID().uuidString))
        var draggingPasteboard: NSPasteboard { pasteboard }
        var draggingSource: Any?
        var draggingSequenceNumber = 0
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 0
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
            classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        func resetSpringLoading() {}
    }
}
