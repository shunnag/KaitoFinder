import AppKit
import CryptoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ApplicationCommandIntegrationTests: XCTestCase {
    @MainActor func testViewOptionsCommandJTracksMainArchiveWhilePanelIsKey() async throws {
        guard Bundle(for: AppDelegate.self).url(forResource: "RecentDocumentsMenu", withExtension: "nib") != nil else {
            throw XCTSkip("The application test host with compiled menu resources is required")
        }
        preserveApplicationMenus()
        let fixture = try ScenarioFixture()
        let (_, first) = try await scenarioDocument(fixture)
        let (_, second) = try await scenarioDocument(fixture)
        let window = try XCTUnwrap(first.window)
        var mainWindow: NSWindow? = window
        let delegate = AppDelegate()
        delegate.mainWindowForTesting = { mainWindow }
        let menu = delegate.makeMenu()
        defer { delegate.viewOptionsController?.close(); withExtendedLifetime(delegate) {} }
        NSApp.mainMenu = menu
        window.tabbingMode = .disallowed
        second.window?.tabbingMode = .disallowed
        let item = try menuItem(#selector(AppDelegate.toggleViewOptions(_:)), in: menu)
        XCTAssertTrue(delegate.validateMenuItem(item))
        XCTAssertEqual(item.title, String(localized: "表示オプションを表示"))
        XCTAssertEqual(item.keyEquivalent, "j")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(item.target === delegate)
        func commandJ(in eventWindow: NSWindow) throws {
            item.menu?.update()
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: eventWindow.windowNumber, context: nil,
                characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
            XCTAssertTrue(menu.performKeyEquivalent(with: event))
        }
        try commandJ(in: window)
        let panel = try XCTUnwrap(delegate.viewOptionsController)
        let panelWindow = try XCTUnwrap(panel.window)
        XCTAssertTrue(panelWindow.isVisible)
        XCTAssertTrue(panelWindow.canBecomeKey)
        XCTAssertFalse(panelWindow.canBecomeMain)
        // パネルに入力フォーカスがあっても、注入した main archive を操作する。
        XCTAssertTrue(panelWindow.makeFirstResponder(panel.sortPopup))
        XCTAssertTrue(mainWindow === window)
        XCTAssertTrue(panel.target === first)
        XCTAssertTrue(delegate.validateMenuItem(item))
        XCTAssertEqual(item.title, String(localized: "表示オプションを隠す"))
        for (popup, index) in [(panel.sortPopup, 2), (panel.orderPopup, 1)] {
            popup.selectItem(at: index)
            XCTAssertTrue(popup.sendAction(try XCTUnwrap(popup.action), to: popup.target))
        }
        XCTAssertEqual(first.outlineView.sortDescriptors.first?.key, "compressedSize")
        XCTAssertEqual(first.outlineView.sortDescriptors.first?.ascending, false)
        XCTAssertEqual(second.outlineView.sortDescriptors.first?.key, "name")
        XCTAssertTrue(mainWindow === window)
        XCTAssertTrue(panel.target === first)
        XCTAssertTrue(panelWindow.initialFirstResponder === panel.sortPopup)
        XCTAssertTrue(panelWindow.makeFirstResponder(panel.sortPopup))
        // popup 間の Tab 移動は macOS の「キーボードナビゲーション」が有効な場合だけ。
        if NSApp.isFullKeyboardAccessEnabled {
            panelWindow.selectNextKeyView(nil)
            XCTAssertTrue(panelWindow.firstResponder === panel.orderPopup)
        } else {
            print("Skipping only popup Tab navigation: macOS Keyboard navigation is disabled.")
        }
        mainWindow = try XCTUnwrap(second.window)
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: mainWindow)
        XCTAssertTrue(panel.target === second)
        XCTAssertEqual(panel.sortPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(panel.orderPopup.indexOfSelectedItem, 0)
        try commandJ(in: panelWindow)
        XCTAssertFalse(panelWindow.isVisible)
        XCTAssertTrue(delegate.validateMenuItem(item))
        XCTAssertEqual(item.title, String(localized: "表示オプションを表示"))
        try commandJ(in: try XCTUnwrap(second.window))
        XCTAssertTrue(delegate.viewOptionsController === panel)
        XCTAssertTrue(panelWindow.isVisible)
        second.displayLocked()
        XCTAssertFalse(delegate.validateMenuItem(item))
        XCTAssertFalse(panel.sortPopup.isEnabled)
        XCTAssertFalse(panel.orderPopup.isEnabled)
    }

    @MainActor func testGoMenuCommandsAndToolbarNavigateTheActiveArchive() async throws {
        guard Bundle(for: AppDelegate.self).url(forResource: "RecentDocumentsMenu", withExtension: "nib") != nil else {
            throw XCTSkip("The application test host with compiled menu resources is required")
        }
        preserveApplicationMenus()
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z: z.writestr('a/b/c.txt', b'C')")
        let (_, controller) = try await scenarioDocument(fixture)
        let window = try XCTUnwrap(controller.window)
        let delegate = AppDelegate(), menu = delegate.makeMenu()
        defer { withExtendedLifetime(delegate) {} }
        NSApp.mainMenu = menu
        window.tabbingMode = .disallowed
        XCTAssertTrue(window.makeFirstResponder(controller.outlineView))
        let open = try menuItem(#selector(ArchiveWindowController.openEntry(_:)), in: menu)
        let back = try menuItem(#selector(ArchiveWindowController.goBack(_:)), in: menu)
        let forward = try menuItem(#selector(ArchiveWindowController.goForward(_:)), in: menu)
        let enclosing = try menuItem(#selector(ArchiveWindowController.goToEnclosingFolder(_:)), in: menu)
        let goMenu = try XCTUnwrap(back.menu)
        XCTAssertEqual(goMenu.title, String(localized: "移動", table: "GoMenu"))
        for (item, title, key) in [(back, String(localized: "戻る"), "["),
                                   (forward, String(localized: "進む"), "]"),
                                   (enclosing, String(localized: "内包フォルダ"), "\u{f700}")] {
            XCTAssertTrue(item.menu === goMenu)
            XCTAssertEqual(item.title, title)
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
        }
        // 非アクティブな host でも、実ウインドウの responder chain を通す。
        func perform(_ item: NSMenuItem) throws {
            XCTAssertNil(item.target)
            XCTAssertTrue(controller.validateMenuItem(item), item.title)
            let responder = try XCTUnwrap(window.firstResponder)
            XCTAssertTrue(responder.tryToPerform(try XCTUnwrap(item.action), with: item), item.title)
        }
        controller.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a"])
        XCTAssertTrue(controller.validateMenuItem(open))
        XCTAssertNil(open.target)
        try perform(open)
        XCTAssertEqual(controller.currentFolderPath, "a")
        XCTAssertTrue(controller.validateMenuItem(back))
        XCTAssertFalse(controller.validateMenuItem(forward))
        try perform(back)
        XCTAssertEqual(controller.currentFolderPath, "")
        XCTAssertFalse(controller.validateMenuItem(back))
        XCTAssertTrue(controller.validateMenuItem(forward))
        try perform(forward)
        XCTAssertEqual(controller.currentFolderPath, "a")
        try perform(enclosing)
        XCTAssertEqual(controller.currentFolderPath, "")
        XCTAssertEqual(controller.selectedNodes.map(\.path), ["a"])
        let toolbar = try XCTUnwrap(window.toolbar)
        let group = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "navigation" } as? NSToolbarItemGroup)
        XCTAssertEqual(group.action, #selector(ArchiveWindowController.navigateFromToolbar(_:)))
        XCTAssertTrue(group.target === controller)
        let segments = try XCTUnwrap(group.view as? NSSegmentedControl)
        XCTAssertTrue(segments.target === controller)
        XCTAssertEqual(segments.action, #selector(ArchiveWindowController.navigateFromToolbar(_:)))
        group.validate()
        XCTAssertTrue(segments.isEnabled(forSegment: 0))
        segments.selectedSegment = 0
        segments.performClick(nil)
        XCTAssertEqual(controller.currentFolderPath, "a")
        group.validate()
        XCTAssertTrue(segments.isEnabled(forSegment: 1))
        segments.selectedSegment = 1
        segments.performClick(nil)
        XCTAssertEqual(controller.currentFolderPath, "")

        toolbar.displayMode = .labelOnly
        for (index, path) in [(0, "a"), (1, "")] {
            group.validate()
            let item = group.subitems[index]
            XCTAssertTrue(item.isEnabled)
            XCTAssertTrue(item.target === controller)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(controller.currentFolderPath, path)
        }
    }

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
