import AppKit
import XCTest
@testable import KaitoFinder

/// NSWindow のフラグだけでなく、実際に表示されたタブ群と文書の同一性を検証する。
nonisolated final class ArchiveTabTests: XCTestCase {
    @MainActor func testOpeningPreferenceChangesOnlyNewWindowsAndKeepsNativeTabCommands() async throws {
        preserveArchiveWindowFrame()
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let identifier = "KaitoFinder.tabs.test." + UUID().uuidString
        var controllers: [ArchiveWindowController] = []
        defer { controllers.forEach { $0.close() } }
        NSApp.activate(ignoringOtherApps: true)
        func open() throws -> NSWindow {
            let controller = ArchiveWindowController(preferencesStore: store)
            controllers.append(controller)
            let window = try XCTUnwrap(controller.window)
            window.tabbingIdentifier = identifier
            controller.showWindow(nil)
            window.makeMain()
            return window
        }
        store.preferences.openingBehavior = .newWindow
        let first = try open()
        let originalFrame = first.frame
        store.preferences.openingBehavior = .newTab
        let second = try open()
        try await scenarioWait { first.tabGroup?.windows.count == 2 }
        XCTAssertTrue(first.tabGroup === second.tabGroup)
        XCTAssertEqual(first.frame.minX, originalFrame.minX, accuracy: 1)
        XCTAssertEqual(first.frame.maxY, originalFrame.maxY, accuracy: 1)
        XCTAssertTrue(second.tabGroup?.selectedWindow === second)

        // 設定の変更では今あるタブを分離しない。次の文書だけが別窓になる。
        store.preferences.openingBehavior = .newWindow
        XCTAssertEqual(first.tabGroup?.windows.count, 2)
        let third = try open()
        XCTAssertFalse(third.tabGroup === first.tabGroup)
        XCTAssertEqual(first.tabGroup?.windows.count, 2)

        // ウインドウとして開いたものも、後からタブに結合できる。
        first.makeKeyAndOrderFront(nil)
        try await scenarioWait { first.isKeyWindow }
        let menu = try XCTUnwrap(NSApp.windowsMenu)
        await showMenu(menu)
        try performMenuItem(menuItem(#selector(NSWindow.mergeAllWindows(_:)), in: menu))
        try await scenarioWait { first.tabGroup?.windows.count == 3 }
        first.tabGroup?.selectedWindow = first
        first.makeKeyAndOrderFront(nil)
        try await scenarioWait { first.isKeyWindow }
        await showMenu(menu)
        for action in [#selector(NSWindow.selectNextTab(_:)), #selector(NSWindow.selectPreviousTab(_:)),
                       #selector(NSWindow.moveTabToNewWindow(_:))] {
            XCTAssertTrue(try menuItem(action, in: menu).isEnabled)
        }
        try performMenuItem(menuItem(#selector(NSWindow.selectNextTab(_:)), in: menu))
        try await scenarioWait { first.tabGroup?.selectedWindow !== first }
        try performMenuItem(menuItem(#selector(NSWindow.selectPreviousTab(_:)), in: menu))
        try await scenarioWait { first.tabGroup?.selectedWindow === first }
        try performMenuItem(menuItem(#selector(NSWindow.moveTabToNewWindow(_:)), in: menu))
        try await scenarioWait { first.tabGroup !== second.tabGroup }
        XCTAssertEqual(second.tabGroup?.windows.count, 2)
    }

    @MainActor func testDocumentControllerOpeningAndReopeningUsesSelectedPolicyWithoutDuplicatingDocuments() async throws {
        preserveArchiveWindowFrame()
        let key = ArchivePreferencesStore.Key.openingBehavior
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let fixture = try ScenarioFixture()
        let secondURL = try fixture.pythonArchive("second.zip", script: "with zipfile.ZipFile(p, 'w') as z: z.writestr('second.txt', b'second')")
        let thirdURL = try fixture.pythonArchive("third.zip", script: "with zipfile.ZipFile(p, 'w') as z: z.writestr('third.txt', b'third')")
        var documents: [ArchiveDocument] = []
        addTeardownBlock { @MainActor in
            for document in documents {
                document.close()
                await document.undoCleanup?.value
                await document.materializationCleanup?.value
                await document.sessionCleanup?.value
            }
            withExtendedLifetime(fixture) {}
        }
        NSApp.activate()
        func open(_ url: URL) async throws -> (ArchiveDocument, Bool) {
            let (document, wasOpen, error) = await withCheckedContinuation {
                (continuation: CheckedContinuation<(NSDocument?, Bool, (any Error)?), Never>) in
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, wasOpen, error in
                    continuation.resume(returning: (document, wasOpen, error))
                }
            }
            XCTAssertNil(error)
            let archive = try XCTUnwrap(document as? ArchiveDocument)
            if !documents.contains(where: { $0 === archive }) { documents.append(archive) }
            return (archive, wasOpen)
        }
        UserDefaults.standard.set("newWindow", forKey: key)
        let (first, _) = try await open(fixture.archive)
        let firstWindow = try XCTUnwrap(first.windowControllers.first?.window)
        firstWindow.makeMain()
        UserDefaults.standard.set("newTab", forKey: key)
        let (second, _) = try await open(secondURL)
        let secondWindow = try XCTUnwrap(second.windowControllers.first?.window)
        try await scenarioWait { firstWindow.tabGroup === secondWindow.tabGroup }
        XCTAssertEqual(firstWindow.tabGroup?.windows.count, 2)

        UserDefaults.standard.set("newWindow", forKey: key)
        let (reopened, wasOpen) = try await open(fixture.archive)
        XCTAssertTrue(wasOpen)
        XCTAssertTrue(reopened === first)
        XCTAssertEqual(reopened.windowControllers.count, 1)
        XCTAssertEqual(firstWindow.tabGroup?.windows.count, 2)
        XCTAssertTrue(firstWindow.tabGroup?.selectedWindow === firstWindow)
        let (third, _) = try await open(thirdURL)
        let thirdWindow = try XCTUnwrap(third.windowControllers.first?.window)
        XCTAssertFalse(thirdWindow.tabGroup === firstWindow.tabGroup)
        XCTAssertEqual(firstWindow.tabGroup?.windows.count, 2)
        XCTAssertEqual(documents.count, 3)
    }

    @MainActor func testLaunchServicesOpenEventsFollowPreferenceWithSettingsInFront() async throws {
        preserveArchiveWindowFrame()
        NSApp.activate(ignoringOtherApps: true)
        let key = ArchivePreferencesStore.Key.openingBehavior
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let fixture = try ScenarioFixture()
        let urls = try [fixture.archive] + (1...3).map { index in
            try fixture.pythonArchive("event-\(index).zip", script: "with zipfile.ZipFile(p, 'w') as z: z.writestr('note.txt', b'contents')")
        }
        addTeardownBlock { @MainActor in
            for url in urls {
                guard let document = NSDocumentController.shared.document(for: url) as? ArchiveDocument else { continue }
                document.close()
                await document.undoCleanup?.value
                await document.materializationCleanup?.value
                await document.sessionCleanup?.value
            }
            withExtendedLifetime(fixture) {}
        }
        func openEvent(_ urls: [URL]) async throws -> [NSWindow] {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = false
            let error = await withCheckedContinuation { (continuation: CheckedContinuation<(any Error)?, Never>) in
                // Finder の「このアプリケーションで開く」と同じ LaunchServices の open-documents event。
                NSWorkspace.shared.open(urls, withApplicationAt: Bundle.main.bundleURL, configuration: configuration) { _, error in
                    continuation.resume(returning: error)
                }
            }
            XCTAssertNil(error)
            try await scenarioWait {
                urls.allSatisfy { NSDocumentController.shared.document(for: $0)?.windowControllers.first?.window != nil }
            }
            return try urls.map { try XCTUnwrap(NSDocumentController.shared.document(for: $0)?.windowControllers.first?.window) }
        }
        UserDefaults.standard.set("newTab", forKey: key)
        let first = try await openEvent([urls[0]])[0]
        let settings = PreferencesWindowController()
        defer { settings.close() }
        settings.showWindow(nil)
        let second = try await openEvent([urls[1]])[0]
        try await scenarioWait { first.tabGroup === second.tabGroup }
        XCTAssertEqual(first.tabGroup?.windows.count, 2)
        UserDefaults.standard.set("newWindow", forKey: key)
        let others = try await openEvent(Array(urls[2...]))
        XCTAssertFalse(others[0].tabGroup === first.tabGroup)
        XCTAssertFalse(others[1].tabGroup === first.tabGroup)
        XCTAssertFalse(others[0].tabGroup === others[1].tabGroup)
        XCTAssertEqual(first.tabGroup?.windows.count, 2)
    }
}
