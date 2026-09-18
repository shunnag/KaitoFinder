import AppKit
import CryptoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ApplicationCommandIntegrationTests: XCTestCase {
    @MainActor func testInstalledSystemMenusBelongToMainMenuAndServicesResolve() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let services = try XCTUnwrap(NSApp.servicesMenu)
        let windows = try XCTUnwrap(NSApp.windowsMenu)
        let help = try XCTUnwrap(NSApp.helpMenu)
        XCTAssertTrue(menu.items.contains { $0.submenu === windows })
        XCTAssertTrue(menu.items.contains { $0.submenu === help })
        XCTAssertTrue(menu.items.first?.submenu?.items.contains { $0.submenu === services } == true)
        let provider = try XCTUnwrap(NSApp.servicesProvider as? AppDelegate)
        XCTAssertTrue(provider === NSApp.delegate)
        let declared = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]])
        for service in declared {
            let message = try XCTUnwrap(service["NSMessage"] as? String)
            XCTAssertTrue(provider.responds(to: NSSelectorFromString(message + ":userData:error:")), message)
        }
    }

    @MainActor func testNewArchiveMenuDisablesWhileItsPanelIsOpenAndRecoversOnCancel() async throws {
        preserveApplicationMenus()
        let delegate = AppDelegate(), menu = delegate.makeMenu()
        let item = try menuItem(#selector(AppDelegate.newArchive(_:)), in: menu)
        try performMenuItem(item)
        let panel = try XCTUnwrap(delegate.creationOpenPanel)
        addTeardownBlock { @MainActor in panel.cancel(nil) }
        item.menu?.update()
        XCTAssertFalse(item.isEnabled, "有効なのに押しても何も起きない状態を作らない")
        panel.cancel(nil)
        try await scenarioWait { delegate.creationOpenPanel == nil }
        item.menu?.update()
        XCTAssertTrue(item.isEnabled)
    }

    @MainActor func testBatchExtractionMenuDisablesWhileItsPanelIsOpenAndRecoversOnCancel() async throws {
        preserveApplicationMenus()
        let delegate = AppDelegate(), menu = delegate.makeMenu()
        let item = try menuItem(#selector(AppDelegate.extractArchivesFromMenu(_:)), in: menu)
        try performMenuItem(item)
        let panel = try XCTUnwrap(delegate.batchExtractionOpenPanel)
        addTeardownBlock { @MainActor in panel.cancel(nil) }
        item.menu?.update()
        XCTAssertFalse(item.isEnabled)
        panel.cancel(nil)
        try await scenarioWait { delegate.batchExtractionOpenPanel == nil }
        item.menu?.update()
        XCTAssertTrue(item.isEnabled)
    }

    @MainActor func testPreferencesAndWelcomeMenuActionsShowAndReuseWindows() throws {
        preserveApplicationMenus()
        let suite = try ArchivePreferencesTestDefaults()
        let delegate = AppDelegate(preferencesStore: ArchivePreferencesStore(defaults: suite.defaults))
        let menu = delegate.makeMenu()
        defer { delegate.preferencesWindowController?.close(); delegate.welcomeWindowController?.close() }
        for (action, controller) in [
            (#selector(AppDelegate.showPreferences(_:)), { delegate.preferencesWindowController as NSWindowController? }),
            (#selector(AppDelegate.showWelcome(_:)), { delegate.welcomeWindowController as NSWindowController? })
        ] {
            let item = try menuItem(action, in: menu)
            try performMenuItem(item)
            let first = try XCTUnwrap(controller())
            XCTAssertTrue(first.window?.isVisible == true)
            first.close()
            try performMenuItem(item)
            XCTAssertTrue(controller() === first)
            XCTAssertTrue(first.window?.isVisible == true)
        }
    }

    @MainActor func testServiceWorkDisablesMatchingMenuUntilCompletion() async throws {
        preserveApplicationMenus()
        let fixture = try ScenarioFixture(), delegate = AppDelegate(), menu = delegate.makeMenu()
        let gate = AsyncStream<Void>.makeStream()
        let pasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { @MainActor in
            gate.continuation.finish()
            await delegate.batchExtractionTask?.value
            pasteboard.releaseGlobally()
            withExtendedLifetime(fixture) {}
        }
        XCTAssertTrue(pasteboard.writeObjects([fixture.archive as NSURL]))
        var received: [URL] = []
        delegate.batchExtractionHandler = { urls in
            received = urls
            for await _ in gate.stream {}
        }
        var error: NSString = ""
        delegate.extractArchives(pasteboard, userData: "", error: &error)
        XCTAssertEqual(error, "")
        let task = try XCTUnwrap(delegate.batchExtractionTask)
        try await scenarioWait { !received.isEmpty }
        XCTAssertEqual(received, [fixture.archive])
        let item = try menuItem(#selector(AppDelegate.extractArchivesFromMenu(_:)), in: menu)
        item.menu?.update()
        XCTAssertFalse(item.isEnabled)
        gate.continuation.finish()
        await task.value
        item.menu?.update()
        XCTAssertTrue(item.isEnabled)
    }

    @MainActor func testPasswordRemovalMenuDisablesUntilCompletionAndClearsInjectedVault() async throws {
        preserveApplicationMenus()
        let directory = try ArchiveTestDirectory()
        let vault = ArchivePasswordVault(key: SymmetricKey(size: .bits256), directory: directory.url)
        let key = ArchivePasswordVault.Key.file(directory.url.appendingPathComponent("fixture.zip"))
        let saved = await vault.save("test-password", for: key)
        XCTAssertTrue(saved)
        let delegate = AppDelegate(passwordVault: vault), menu = delegate.makeMenu()
        let item = try menuItem(#selector(AppDelegate.forgetArchivePasswords(_:)), in: menu)
        try performMenuItem(item)
        let task = try XCTUnwrap(delegate.forgetPasswordsTask)
        item.menu?.update()
        XCTAssertFalse(item.isEnabled)
        await task.value
        let password = await vault.password(for: key)
        XCTAssertNil(password)
        item.menu?.update()
        XCTAssertTrue(item.isEnabled)
    }

    @MainActor func testToolbarAndResponderChainApplyEditsAndRespectTextFocus() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('first.txt', b'first')
            z.writestr('second.txt', b'second')
        """)
        let (document, controller) = try await scenarioDocument(fixture)
        let window = try XCTUnwrap(controller.window), toolbar = try XCTUnwrap(window.toolbar)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        XCTAssertTrue(window.makeFirstResponder(controller.outlineView))
        let main = try XCTUnwrap(NSApp.mainMenu)
        let selectAll = try menuItem(#selector(NSText.selectAll(_:)), in: main)
        // 非アクティブな XCTest host でも、実ウインドウの first responder から
        // 公開 AppKit API で辿る。NSApp 全体の前面時の dispatch は文書オープンテストで確認する。
        func perform(_ item: NSMenuItem) throws {
            let responder = try XCTUnwrap(window.firstResponder)
            XCTAssertTrue(responder.tryToPerform(try XCTUnwrap(item.action), with: item), item.title)
        }
        try perform(selectAll)
        XCTAssertEqual(controller.selectedNodes.count, 2)
        controller.outlineView.deselectAll(nil)
        toolbar.validateVisibleItems()
        let delete = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "delete" })
        XCTAssertFalse(delete.isEnabled)
        let create = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "newFolder" })
        XCTAssertTrue(create.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(create.action), to: create.target, from: create))
        await controller.extractionTask?.value
        XCTAssertEqual(controller.outlineView.numberOfRows, 3)
        controller.outlineView.cancelRenaming()
        XCTAssertTrue(window.makeFirstResponder(controller.outlineView))
        try perform(menuItem(#selector(ArchiveDocument.undo(_:)), in: main))
        await document.undoTask?.value
        XCTAssertEqual(controller.outlineView.numberOfRows, 2)
        try perform(menuItem(#selector(ArchiveDocument.redo(_:)), in: main))
        await document.undoTask?.value
        XCTAssertEqual(controller.outlineView.numberOfRows, 3)

        controller.searchField.stringValue = "first"
        XCTAssertTrue(window.makeFirstResponder(controller.searchField))
        let editor = try XCTUnwrap(controller.searchField.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try perform(selectAll)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 5))
    }

    @MainActor func testWindowMenuAddsRenamesAndRemovesVisibleArchiveWindows() async throws {
        preserveArchiveWindowFrame()
        let first = ArchiveWindowController(), second = ArchiveWindowController()
        defer { first.close(); second.close() }
        let firstWindow = try XCTUnwrap(first.window), secondWindow = try XCTUnwrap(second.window)
        firstWindow.tabbingMode = .disallowed
        secondWindow.tabbingMode = .disallowed
        let prefix = "Menu-" + UUID().uuidString
        firstWindow.title = prefix + "-first"
        secondWindow.title = prefix + "-second"
        first.showWindow(nil)
        second.showWindow(nil)
        let menu = try XCTUnwrap(NSApp.windowsMenu)
        await showMenu(menu) {
            menu.items.contains { $0.title == firstWindow.title }
                && menu.items.contains { $0.title == secondWindow.title }
        }
        let original = firstWindow.title
        firstWindow.title = prefix + "-renamed"
        second.close()
        await showMenu(menu) {
            menu.items.contains { $0.title == firstWindow.title }
                && !menu.items.contains { $0.title == original || $0.title == secondWindow.title }
        }
    }

    @MainActor func testReadOnlyContextMenuAndToolbarValidateAndRouteExtraction() async throws {
        let fixture = try ScenarioFixture(script: """
        with tarfile.open(p, 'w') as z:
            for name in ('first.txt', 'second.txt'):
                item = tarfile.TarInfo(name)
                item.size = 4
                z.addfile(item, io.BytesIO(b'data'))
        import lzma; raw=open(p,'rb').read(); open(p,'wb').write(lzma.compress(raw,format=lzma.FORMAT_ALONE))
        """, suffix: "tar.lzma")
        let (_, controller) = try await scenarioDocument(fixture)
        let menu = try XCTUnwrap(controller.outlineView.menu)
        let window = try XCTUnwrap(controller.window)
        // validateVisibleItems は非表示・overflow 項目を更新しない。保存された狭い
        // ウインドウサイズに依存せず、実際に見えるボタンの接続を検査する。
        window.setContentSize(NSSize(width: 1100, height: 600))
        controller.showWindow(nil)
        window.layoutIfNeeded()
        let toolbar = try XCTUnwrap(window.toolbar)
        controller.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        menu.update()
        toolbar.validateVisibleItems()
        for action in [#selector(ArchiveWindowController.newFolder(_:)),
                       #selector(ArchiveWindowController.deleteEntries(_:)),
                       #selector(ArchiveWindowController.renameEntry(_:))] {
            XCTAssertFalse(try menuItem(action, in: menu).isEnabled)
        }
        for identifier in ["newFolder", "delete"] {
            XCTAssertTrue(toolbar.visibleItems?.contains { $0.itemIdentifier.rawValue == identifier } == true)
            XCTAssertFalse(try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == identifier }).isEnabled)
        }
        var requested: [EntryNode] = []
        controller.extractionDestinationHandler = { requested = $0 }
        let extract = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "extract" })
        XCTAssertTrue(extract.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(extract.action), to: extract.target, from: extract))
        XCTAssertEqual(requested.map(\.path), ["first.txt"])
        controller.outlineView.deselectAll(nil)
        toolbar.validateVisibleItems()
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(extract.action), to: extract.target, from: extract))
        XCTAssertEqual(Set(requested.map(\.path)), ["first.txt", "second.txt"])
    }

    @MainActor func testOpenWithMenuPopulatesDuringTracking() async throws {
        let fixture = try ScenarioFixture()
        let (_, controller) = try await scenarioDocument(fixture)
        controller.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let context = try XCTUnwrap(controller.outlineView.menu)
        let parent = try menuItem(#selector(ArchiveWindowController.openWithEntry(_:)), in: context)
        let submenu = try XCTUnwrap(parent.submenu)
        await showMenu(submenu) {
            submenu.items.contains { $0.action == #selector(ArchiveWindowController.openWithEntry(_:)) }
        }
        let applications = submenu.items.filter { $0.action == #selector(ArchiveWindowController.openWithEntry(_:)) }
        XCTAssertFalse(applications.isEmpty)
        for item in applications {
            XCTAssertTrue(item.target === controller)
            XCTAssertNotNil(item.representedObject as? URL)
            XCTAssertTrue(item.isEnabled)
        }
    }
}
