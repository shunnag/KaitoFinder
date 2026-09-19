import AppKit
import KaitoKit
import QuickLookUI
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePreviewSidebarTests: XCTestCase {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    @MainActor private func fixture() async throws -> (ScenarioFixture, ArchiveDocument, ArchiveWindowController) {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('first.txt', b'First preview')
            z.writestr('second.txt', b'Second preview')
            z.writestr('folder/nested.txt', b'Nested preview')
        """)
        let (document, controller) = try await scenarioDocument(fixture)
        controller.outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        return (fixture, document, controller)
    }

    @MainActor private func select(_ names: [String], in controller: ArchiveWindowController) throws {
        let rows = (0..<controller.outlineView.numberOfRows).filter {
            names.contains((controller.outlineView.item(atRow: $0) as? EntryNode)?.name ?? "")
        }
        XCTAssertEqual(rows.count, names.count)
        controller.outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    @MainActor func testDefaultOffDoesNotMaterializeSelectionAndEachWindowStartsOff() async throws {
        let (_, _, first) = try await fixture()
        try select(["first.txt"], in: first)
        XCTAssertFalse(first.showsPreviewSidebar)
        XCTAssertNil(first.previewSidebar.materialization?.task)
        XCTAssertNil(first.previewSidebar.previewView)
        first.togglePreviewSidebar(nil)
        try await scenarioWait { first.previewSidebar.state == .ready }
        let (_, _, second) = try await fixture()
        XCTAssertFalse(second.showsPreviewSidebar)
        XCTAssertTrue(first.showsPreviewSidebar)
        let url = try XCTUnwrap(first.previewSidebar.previewView?.previewItem?.previewItemURL)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "First preview")
    }

    @MainActor func testMenuToolbarAndKeyboardToggleTheActiveArchive() async throws {
        preserveApplicationMenus()
        let (_, _, controller) = try await fixture()
        let window = try XCTUnwrap(controller.window)
        window.tabbingMode = .disallowed
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate()
        window.makeFirstResponder(controller.outlineView)
        let delegate = AppDelegate(), menu = delegate.makeMenu()
        NSApp.mainMenu = menu
        let item = try menuItem(#selector(ArchiveWindowController.togglePreviewSidebar(_:)), in: menu)
        XCTAssertNil(item.target)
        XCTAssertEqual(item.keyEquivalent, "p")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        try performMenuItem(item)
        XCTAssertTrue(controller.showsPreviewSidebar)
        item.menu?.update()
        XCTAssertEqual(item.state, .on)
        XCTAssertEqual(item.title, String(localized: "プレビューを非表示"))
        let toolbar = try XCTUnwrap(window.toolbar)
        let button = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "previewSidebar" })
        toolbar.validateVisibleItems()
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.toolTip, item.title)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        XCTAssertFalse(controller.showsPreviewSidebar)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "P", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        XCTAssertTrue(controller.showsPreviewSidebar)
        withExtendedLifetime(delegate) {}
    }

    @MainActor func testSelectionChangeMultipleSelectionAndSearchClearStalePreview() async throws {
        let (_, _, controller) = try await fixture()
        controller.togglePreviewSidebar(nil)
        XCTAssertEqual(controller.previewSidebar.state, .empty)
        try select(["first.txt"], in: controller)
        try await scenarioWait { controller.previewSidebar.state == .ready }
        let firstView = try XCTUnwrap(controller.previewSidebar.previewView)
        controller.outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        XCTAssertTrue(controller.previewSidebar.previewView === firstView)
        try select(["second.txt"], in: controller)
        try await scenarioWait { controller.previewSidebar.state == .ready }
        XCTAssertEqual(controller.previewSidebar.nameLabel.stringValue, "second.txt")
        let url = try XCTUnwrap(controller.previewSidebar.previewView?.previewItem?.previewItemURL)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Second preview")
        try select(["first.txt", "second.txt"], in: controller)
        XCTAssertEqual(controller.previewSidebar.state, .empty)
        XCTAssertNil(controller.previewSidebar.previewView)
        try select(["folder"], in: controller)
        XCTAssertEqual(controller.previewSidebar.state, .unavailable)
        XCTAssertNil(controller.previewSidebar.materialization?.task)
        try select(["first.txt"], in: controller)
        controller.setFilterQuery("second")
        XCTAssertTrue(controller.selectedNodes.isEmpty)
        XCTAssertNil(controller.previewSidebar.previewView)
        XCTAssertEqual(controller.previewSidebar.state, .empty)
    }

    @MainActor func testHidingStopsPreviewButKeepsReusableCopyAndDocumentCloseDeletesIt() async throws {
        let (_, document, controller) = try await fixture()
        try select(["first.txt"], in: controller)
        controller.togglePreviewSidebar(nil)
        try await scenarioWait { controller.previewSidebar.state == .ready }
        let url = try XCTUnwrap(controller.previewSidebar.previewView?.previewItem?.previewItemURL)
        controller.togglePreviewSidebar(nil)
        XCTAssertNil(controller.previewSidebar.previewView)
        XCTAssertNil(controller.previewSidebar.materialization?.task)
        controller.togglePreviewSidebar(nil)
        XCTAssertEqual(controller.previewSidebar.state, .ready)
        XCTAssertEqual(controller.previewSidebar.previewView?.previewItem?.previewItemURL, url)
        document.close()
        await document.materializationCleanup?.value
        XCTAssertNil(controller.previewSidebar.previewView)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor func testHiddenSidebarDiscardsLateExtractionAndDoesNotReplaceNewSelection() async throws {
        let (fixture, _, controller) = try await fixture()
        let session = try XCTUnwrap((controller.document as? ArchiveDocument)?.session)
        let started = expectation(description: "first extraction started")
        let gate = Gate(), calls = Mutex<[String]>([])
        let stale = try fixture.file("stale/first.txt")
        let second = try fixture.file("fresh/second.txt")
        let owner = ArchiveMaterializationController { payload, _ in
            calls.withLock { $0.append(payload.path) }
            if payload.path == "first.txt" {
                started.fulfill()
                await gate.wait() // 意図的に取消しを無視して成功を返す。
                return stale
            }
            return second
        }
        controller.display(EntryNode.tree(from: await session.entries()), session: session, materializationController: owner)
        try select(["first.txt"], in: controller)
        controller.togglePreviewSidebar(nil)
        await fulfillment(of: [started], timeout: 5)
        controller.togglePreviewSidebar(nil)
        try select(["second.txt"], in: controller)
        controller.togglePreviewSidebar(nil)
        await gate.release()
        try await scenarioWait { controller.previewSidebar.state == .ready }
        XCTAssertEqual(controller.previewSidebar.previewView?.previewItem?.previewItemURL, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(calls.withLock { $0 }, ["first.txt", "second.txt"])
        controller.previewSidebar.reset()
        await owner.close().value
    }

    @MainActor func testQuickLookAndSidebarUseIndependentSelectionAndCancellation() async throws {
        let (_, document, controller) = try await fixture()
        let owner = try XCTUnwrap(document.materializationController())
        try select(["first.txt"], in: controller)
        controller.togglePreviewSidebar(nil)
        try await scenarioWait { controller.previewSidebar.state == .ready }
        let item = try XCTUnwrap(controller.previewSidebar.selectedItem)
        owner.setSelection([ArchivePreviewItem(payload: item.payload, capability: item.capability, requiresProgress: false)])
        var opened: URL?
        owner.display(index: 0) { opened = $0.previewItemURL }
        await owner.task?.value
        let url = try XCTUnwrap(opened)
        controller.togglePreviewSidebar(nil)
        XCTAssertEqual(owner.currentIndex, 0)
        XCTAssertEqual(owner.item(at: 0)?.previewItemURL, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        controller.togglePreviewSidebar(nil)
        owner.setSelection([])
        XCTAssertEqual(controller.previewSidebar.state, .ready)
        XCTAssertNotNil(controller.previewSidebar.previewView?.previewItem?.previewItemURL)
    }

    @MainActor func testOwnerCloseDrainsIndependentWriterBeforeDeletingTemporaryDirectory() async throws {
        let (fixture, _, controller) = try await fixture()
        try select(["first.txt"], in: controller)
        controller.togglePreviewSidebar(nil)
        let item = try XCTUnwrap(controller.previewSidebar.selectedItem)
        controller.togglePreviewSidebar(nil)
        let started = expectation(description: "independent writer started")
        let gate = Gate(), disposed = Mutex(false)
        let late = try fixture.file("independent/late.txt")
        let owner = ArchiveMaterializationController(dispose: { disposed.withLock { $0 = true } }) { _, _ in
            started.fulfill()
            await gate.wait()
            return late
        }
        var child: ArchiveMaterializationController? = owner.makeIndependentController()
        child?.setSelection([item])
        child?.display(index: 0) { _ in XCTFail("閉じた文書へ結果を返さない") }
        await fulfillment(of: [started], timeout: 5)
        // 表示世代の変更で UI が子を手放しても、親は子の drain を待つ。
        child?.close()
        child = nil
        let cleanup = owner.close()
        XCTAssertFalse(disposed.withLock { $0 })
        await gate.release()
        await cleanup.value
        XCTAssertTrue(disposed.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: late.path))
    }

    @MainActor private func capture(_ window: NSWindow, name: String, drag: [NSPoint]? = nil) async throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOFINDER_PREVIEW_CAPTURE_REQUEST"] else { return }
        // QLPreviewView の非同期描画を待つ。キャプチャは外部ツールが検証用ウインドウだけに限定する。
        try await Task.sleep(for: .milliseconds(750))
        let request = URL(fileURLWithPath: path), done = request.deletingPathExtension().appendingPathExtension("done")
        var value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "bundle": try XCTUnwrap(Bundle.main.bundleIdentifier), "window": window.windowNumber, "name": name]
        if let drag { value["drag"] = drag.map { [$0.x, $0.y] } }
        try JSONSerialization.data(withJSONObject: value).write(to: request, options: .atomic)
        try await scenarioWait { FileManager.default.fileExists(atPath: done.path) }
        try FileManager.default.removeItem(at: done)
    }

    @MainActor func testImagePDFAndTextPreviewsRenderAndCloseInBothAppearances() async throws {
        let fixture = try ScenarioFixture()
        let image = NSImage(size: NSSize(width: 480, height: 320), flipped: false) { rect in
            NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: rect, angle: -30)
            let title = NSAttributedString(string: "KaitoFinder", attributes: [
                .font: NSFont.systemFont(ofSize: 36, weight: .semibold), .foregroundColor: NSColor.white])
            title.draw(at: NSPoint(x: 40, y: 140))
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        _ = try fixture.file("Preview.png", bytes: XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
        _ = try fixture.file("Read Me.txt", bytes: Data("KaitoFinder Preview\n\nBrowse the archive and preview a selected file.\n\n画像・PDF・テキストをその場で確認できます。\n".utf8))
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 480))
        let title = NSTextField(labelWithString: "Archive Preview")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        title.frame = NSRect(x: 30, y: 400, width: 300, height: 45)
        page.addSubview(title)
        let detail = NSTextField(wrappingLabelWithString: "PDF documents appear here.\n\nKeep browsing your archive while reading the selected document.")
        detail.frame = NSRect(x: 30, y: 220, width: 300, height: 160)
        page.addSubview(detail)
        _ = try fixture.file("Document.pdf", bytes: page.dataWithPDF(inside: page.bounds))
        try fixture.directory.run("/usr/bin/zip", ["-q", fixture.archive.path, "Preview.png", "Read Me.txt", "Document.pdf"])
        let (_, controller) = try await scenarioDocument(fixture)
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1040, height: 600))
        window.appearance = NSAppearance(named: .aqua)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        try await capture(window, name: "preview-off")
        controller.togglePreviewSidebar(nil)
        try await capture(window, name: "preview-empty")
        for (file, name) in [("Preview.png", "preview-image-light"), ("Read Me.txt", "preview-text"), ("Document.pdf", "preview-pdf")] {
            try select([file], in: controller)
            try await scenarioWait { controller.previewSidebar.state == .ready }
            XCTAssertEqual(controller.previewSidebar.previewView?.previewItem?.previewItemURL?.pathExtension,
                           (file as NSString).pathExtension)
            try await capture(window, name: name)
        }
        try select(["Preview.png"], in: controller)
        try await scenarioWait { controller.previewSidebar.state == .ready }
        window.appearance = NSAppearance(named: .darkAqua)
        try await capture(window, name: "preview-image-dark")
        let split = try XCTUnwrap(controller.previewSidebar.parent as? NSSplitViewController)
        split.splitView.setPosition(620, ofDividerAt: 0)
        try await scenarioWait { controller.previewSidebar.view.bounds.width > 410 }
        try await Task.sleep(for: .milliseconds(500))
        let divider = try XCTUnwrap(split.splitView.accessibilityChildren()?.compactMap { $0 as? any NSAccessibilityProtocol }
            .first { $0.accessibilityRole() == .splitter })
        let dividerFrame = divider.accessibilityFrame()
        let start = NSPoint(x: dividerFrame.midX, y: dividerFrame.midY)
        let end = NSPoint(x: start.x - 100, y: start.y)
        if ProcessInfo.processInfo.environment["KAITOFINDER_PREVIEW_CAPTURE_REQUEST"] != nil {
            try await capture(window, name: "preview-resized", drag: [start, end])
        } else {
            split.splitView.setPosition(520, ofDividerAt: 0)
        }
        try await scenarioWait { controller.previewSidebar.view.bounds.width > 450 }
        window.setContentSize(NSSize(width: 600, height: 300))
        try await capture(window, name: "preview-minimum")
        controller.togglePreviewSidebar(nil)
        try await capture(window, name: "preview-hidden")
        XCTAssertNil(controller.previewSidebar.previewView)
    }

    @MainActor func testEncryptedUnsupportedAndIncompleteEntriesNeverPassivelyExtractOrPrompt() async throws {
        let (_, document, controller) = try await fixture()
        let session = try XCTUnwrap(document.session)
        let owner = ArchiveMaterializationController { _, _ in
            XCTFail("受動的なプレビューで読めない項目を抽出しない")
            throw CancellationError()
        }
        for (encrypted, incomplete, method, expected) in [
            (true, false, "stored", ArchivePreviewSidebar.State.locked),
            (false, true, "stored", .unavailable), (false, false, "jpeg", .unavailable)
        ] {
            let entry = ArchiveEntry(index: 0, rawName: RawName(bytes: Array("a.txt".utf8)), name: "a.txt", pathComponents: ["a.txt"],
                kind: .file, uncompressedSize: 1, compressedSize: 1, modificationDate: nil, posixPermissions: nil,
                isEncrypted: encrypted, solidGroup: -1, crc32: nil, methodDescription: method, formatSpecific: [:], isIncomplete: incomplete)
            controller.display(EntryNode.tree(from: [entry]), session: session, materializationController: owner)
            if !controller.showsPreviewSidebar { controller.togglePreviewSidebar(nil) }
            try select(["a.txt"], in: controller)
            XCTAssertEqual(controller.previewSidebar.state, expected)
            XCTAssertNil(controller.previewSidebar.materialization?.task)
            XCTAssertNil(controller.passwordPrompt)
            XCTAssertNil(controller.window?.attachedSheet)
        }
        await owner.close().value
    }

    @MainActor func testExtractionFailureStaysInsideSidebar() async throws {
        let (_, document, controller) = try await fixture()
        let session = try XCTUnwrap(document.session)
        let owner = ArchiveMaterializationController { _, _ in throw ExtractionFailure.refused("broken preview") }
        controller.display(EntryNode.tree(from: await session.entries()), session: session, materializationController: owner)
        try select(["first.txt"], in: controller)
        controller.togglePreviewSidebar(nil)
        try await scenarioWait { controller.previewSidebar.state == .failed }
        XCTAssertTrue(controller.previewSidebar.messageLabel.stringValue.contains("broken preview"), controller.previewSidebar.messageLabel.stringValue)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertNil(controller.previewSidebar.previewView)
        await owner.close().value
    }

    @MainActor func testArchiveMutationRefreshesPreviewAndReleasesOldURL() async throws {
        let (_, document, controller) = try await fixture()
        try select(["first.txt"], in: controller)
        controller.togglePreviewSidebar(nil)
        try await scenarioWait { controller.previewSidebar.state == .ready }
        let old = try XCTUnwrap(controller.previewSidebar.previewView?.previewItem?.previewItemURL)
        // モデルの公開経路を通し、同じ名前でも新しい世代のコピーに切り替わることを確認。
        _ = try await document.createFolder(in: "", baseName: "added", progress: Progress())
        try await scenarioWait { controller.previewSidebar.state == .ready }
        let new = try XCTUnwrap(controller.previewSidebar.previewView?.previewItem?.previewItemURL)
        XCTAssertNotEqual(old, new)
        await document.materializationCleanup?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: new, encoding: .utf8), "First preview")
    }

    @MainActor func testMinimumSizeDividerAndRepeatedTogglesKeepWindowFrameAndSelection() async throws {
        let (_, _, controller) = try await fixture()
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 600, height: 300))
        window.makeKeyAndOrderFront(nil)
        try select(["first.txt"], in: controller)
        let frame = window.frame
        for _ in 0..<4 {
            controller.togglePreviewSidebar(nil)
            window.layoutIfNeeded()
            XCTAssertEqual(window.frame, frame)
            XCTAssertEqual(controller.selectedNodes.map(\.name), ["first.txt"])
        }
        controller.togglePreviewSidebar(nil)
        try await scenarioWait { controller.previewSidebar.state == .ready }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.layoutIfNeeded()
            let sidebar = controller.previewSidebar.view
            let list = try XCTUnwrap(controller.outlineView.enclosingScrollView)
            XCTAssertGreaterThanOrEqual(sidebar.frame.width, 260)
            XCTAssertGreaterThanOrEqual(sidebar.frame.height, 180)
            XCTAssertGreaterThanOrEqual(list.frame.width, 280)
            XCTAssertGreaterThanOrEqual(sidebar.convert(sidebar.bounds, to: window.contentView).minX,
                                        list.convert(list.bounds, to: window.contentView).maxX)
            let violations = UISnapshot.overflowViolations(in: sidebar)
            XCTAssertTrue(violations.isEmpty, violations.joined(separator: "\n"))
            try UISnapshot.render(try XCTUnwrap(window.contentView?.superview), name: "preview-minimum-\(appearance.rawValue)")
        }
        // 境界のドラッグでも表示状態とメニューが一致する。
        let split = try XCTUnwrap(controller.previewSidebar.parent as? NSSplitViewController)
        split.splitViewItems[1].isCollapsed = true
        XCTAssertFalse(controller.showsPreviewSidebar)
        XCTAssertNil(controller.previewSidebar.previewView)
    }

    @MainActor func testPreviewStringsAndEmptyAndLockedLayoutInEveryLanguage() async throws {
        let (_, document, _) = try await fixture()
        let session = try XCTUnwrap(document.session)
        let entry = ArchiveEntry(index: 0, rawName: RawName(bytes: Array("encrypted.txt".utf8)), name: "encrypted.txt", pathComponents: ["encrypted.txt"],
            kind: .file, uncompressedSize: 1, compressedSize: 1, modificationDate: nil, posixPermissions: nil,
            isEncrypted: true, solidGroup: -1, crc32: nil, methodDescription: "stored", formatSpecific: [:])
        let nodes = EntryNode.tree(from: [entry]).children
        let catalog = try LocalizationAcceptance.catalog()
        let keys = ["プレビュー", "プレビューを表示", "プレビューを非表示", "ファイルを1つ選択するとプレビューが表示されます。"]
        for key in keys { XCTAssertEqual(Set(try XCTUnwrap(catalog.strings[key]).localizations.keys), Set(LocalizationAcceptance.languages)) }
        for language in LocalizationAcceptance.languages {
            let bundle = try LocalizationAcceptance.bundle(language)
            let sidebar = ArchivePreviewSidebar(bundle: bundle)
            sidebar.view.setFrameSize(NSSize(width: 260, height: 200))
            sidebar.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(sidebar.nameLabel.stringValue, String(localized: "プレビュー", bundle: bundle))
            let violations = UISnapshot.overflowViolations(in: sidebar.view)
            XCTAssertTrue(violations.isEmpty, language + "\n" + violations.joined(separator: "\n"))
            sidebar.display(nodes, session: session, generation: 0)
            XCTAssertEqual(sidebar.state, .locked)
            let locked = UISnapshot.overflowViolations(in: sidebar.view)
            XCTAssertTrue(locked.isEmpty, language + "\n" + locked.joined(separator: "\n"))
            sidebar.close()
        }
    }
}


extension ArchivePreviewSidebarTests {
    @MainActor func testSmallSolidMemberWaitsForExplicitPreviewAction() async throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("solid-preview.zip")
        try ReleaseReviewFixtures.zip([("a.txt", Data("preview".utf8))]).write(to: archive)
        let session = try ArchiveSession(url: archive)
        let calls = Mutex(0), output = directory.url.appendingPathComponent("preview.txt")
        try Data("preview".utf8).write(to: output)
        let gate = Gate(), started = expectation(description: "Explicit solid-member materialization")
        let owner = ArchiveMaterializationController { _, _ in
            calls.withLock { $0 += 1 }
            started.fulfill()
            await gate.wait()
            return output
        }
        let sidebar = ArchivePreviewSidebar()
        sidebar.configure(materialization: owner)
        let entry = ArchiveEntry(index: 0, rawName: RawName(bytes: Array("a.txt".utf8)), name: "a.txt", pathComponents: ["a.txt"],
            kind: .file, uncompressedSize: 7, compressedSize: 1, modificationDate: nil, posixPermissions: nil,
            isEncrypted: false, solidGroup: 0, crc32: nil, methodDescription: "stored", formatSpecific: [:])
        sidebar.display(EntryNode.tree(from: [entry]).children, session: session, generation: 0)
        XCTAssertEqual(sidebar.state, .awaitingLoad, "Solid members must wait for an explicit preview action")
        XCTAssertNil(owner.task, "Selecting a solid member must not start materialization")
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertEqual(sidebar.messageLabel.stringValue,
                       String(localized: "大きなファイルです。プレビューを表示するには読み込みが必要です。"))
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        let button = try XCTUnwrap(buttons(sidebar.view).first { !$0.isHidden })
        XCTAssertEqual(button.title, String(localized: "プレビューを表示"))
        button.performClick(nil)
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(sidebar.state, .loading)
        XCTAssertEqual(calls.withLock { $0 }, 1, "The explicit action must load the solid member once")
        sidebar.close()
        await gate.release()
        await owner.close().value
        await session.close()
    }

    @MainActor func testLargeAndUnknownPreviewsWaitForExplicitActionButSmallFilesLoadAutomatically() async throws {
        // 実ウインドウ内のサイドバーを使う。QLPreviewView は window に属さないと close() で abort する。
        let (fixture, document, controller) = try await self.fixture()
        controller.togglePreviewSidebar(nil)
        let sidebar = controller.previewSidebar
        let session = try XCTUnwrap(document.session)
        for size in [UInt64?](arrayLiteral: 64 * 1024 * 1024 + 1, nil, 64 * 1024 * 1024, 1) {
            // 一時コピーの回収は親フォルダごと削除するため、反復ごとに専用フォルダへ置く。
            let calls = Mutex(0), output = try fixture.folder(UUID().uuidString).appendingPathComponent("a.txt")
            try Data("preview".utf8).write(to: output)
            let owner = ArchiveMaterializationController { _, _ in calls.withLock { $0 += 1 }; return output }
            sidebar.configure(materialization: owner)
            let entry = ArchiveEntry(index: 0, rawName: RawName(bytes: Array("a.txt".utf8)), name: "a.txt", pathComponents: ["a.txt"],
                kind: .file, uncompressedSize: size, compressedSize: 1, modificationDate: nil, posixPermissions: nil,
                isEncrypted: false, solidGroup: -1, crc32: nil, methodDescription: "stored", formatSpecific: [:])
            sidebar.display(EntryNode.tree(from: [entry]).children, session: session, generation: 0)
            if size == nil || size! > 64 * 1024 * 1024 {
                XCTAssertNotEqual(sidebar.state, .loading, "Large previews must wait for explicit action")
                XCTAssertNotEqual(sidebar.state, .ready)
                XCTAssertNil(owner.task)
                XCTAssertEqual(calls.withLock { $0 }, 0)
                func buttons(_ view: NSView) -> [NSButton] {
                    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
                }
                let button = try XCTUnwrap(buttons(sidebar.view).first { !$0.isHidden })
                XCTAssertEqual(button.title, String(localized: "プレビューを表示"))
                button.performClick(nil)
            }
            XCTAssertTrue(sidebar.state == .loading || sidebar.state == .ready)
            await owner.task?.value
            XCTAssertEqual(sidebar.state, .ready)
            XCTAssertEqual(calls.withLock { $0 }, 1)
            sidebar.reset()
            await owner.close().value
        }
        sidebar.close()
        document.close()
        await document.materializationCleanup?.value
    }
}
