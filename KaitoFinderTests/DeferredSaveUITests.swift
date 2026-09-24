import AppKit
import QuickLookThumbnailing
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSaveUITests: XCTestCase {
    @MainActor func testMenusAreVisibleInOrderAndEnabledOnlyForIdleEditedDeferredDocument() async throws {
        preserveApplicationMenus()
        let fixture = try DeferredSaveFixture(), immediate = try DeferredSaveFixture(behavior: .immediate)
        defer { fixture.document.close(); immediate.document.close() }
        let menu = AppDelegate().makeMenu()
        let file = try XCTUnwrap(menu.items.compactMap(\.submenu).first { submenu in
            submenu.items.contains { $0.action == #selector(ArchiveDocument.saveArchiveDocument(_:)) }
        })
        let save = try XCTUnwrap(file.items.first { $0.action == #selector(ArchiveDocument.saveArchiveDocument(_:)) })
        let saveAs = try XCTUnwrap(file.items.first { $0.action == #selector(ArchiveWindowController.saveArchiveAs(_:)) })
        let revert = try XCTUnwrap(file.items.first { $0.action == #selector(NSDocument.revertToSaved(_:)) })
        XCTAssertEqual(file.index(of: save) + 1, file.index(of: saveAs))
        XCTAssertEqual(file.index(of: saveAs) + 1, file.index(of: revert))
        XCTAssertEqual(save.keyEquivalent, "s")
        XCTAssertEqual(save.keyEquivalentModifierMask, [.command])
        XCTAssertNil(save.target)
        XCTAssertFalse(file.items.contains { $0.action == #selector(NSDocument.save(_:)) })
        XCTAssertFalse(save.isHidden)
        XCTAssertFalse(revert.isHidden)
        XCTAssertFalse(fixture.document.validateUserInterfaceItem(save))
        _ = try await fixture.document.createFolder(in: "", progress: Progress())
        XCTAssertTrue(fixture.document.validateUserInterfaceItem(save))
        XCTAssertTrue(fixture.document.validateUserInterfaceItem(revert))
        XCTAssertFalse(immediate.document.validateUserInterfaceItem(save))
        XCTAssertFalse(immediate.document.validateUserInterfaceItem(revert))
    }

    @MainActor func testMenuAndNativeSaveEntrypointsPublishPendingChanges() async throws {
        let routes: [(String, (ArchiveDocument) -> Void)] = [
            ("File Save", { document in
                XCTAssertTrue(NSApp.sendAction(#selector(ArchiveDocument.saveArchiveDocument(_:)), to: document, from: nil))
            }),
            ("Native Save", { document in
                XCTAssertTrue(NSApp.sendAction(#selector(NSDocument.save(_:)), to: document, from: nil))
            }),
            // NSDocument's close/quit prompts use this native save entry point.
            ("Native delegate Save", { $0.save(withDelegate: nil, didSave: nil, contextInfo: nil) })
        ]
        for (route, startSave) in routes {
            let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
            defer { gate.release(); document.close() }
            let items = [#selector(ArchiveDocument.saveArchiveDocument(_:)), #selector(NSDocument.save(_:)),
                         #selector(NSDocument.revertToSaved(_:))].map {
                NSMenuItem(title: "", action: $0, keyEquivalent: "")
            }
            _ = try await document.append(urls: [fixture.file("added.txt", contents: "pending bytes")],
                                          to: "", progress: Progress())
            for item in items { XCTAssertTrue(document.validateUserInterfaceItem(item), route) }
            document.deferredWillPublish = { gate.pauseOnce() }
            startSave(document)
            try await scenarioWait { gate.isEntered }
            let saving = try XCTUnwrap(document.deferredSaveTask, route)
            for item in items { XCTAssertFalse(document.validateUserInterfaceItem(item), route) }
            XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original, route)
            gate.release()
            try await saving.value
            XCTAssertEqual(try DeferredSaveFixture.contents(fixture.archive)["added.txt"], Data("pending bytes".utf8), route)
            XCTAssertTrue(document.pendingChanges.isEmpty, route)
            XCTAssertFalse(document.isDocumentEdited, route)
            XCTAssertNil(document.deferredSaveTask, route)
            for item in items { XCTAssertFalse(document.validateUserInterfaceItem(item), route) }
            document.close()
            for item in items { XCTAssertFalse(document.validateUserInterfaceItem(item), route) }
            document.saveArchiveDocument(nil)
            XCTAssertNil(document.deferredSaveTask, route)
        }
    }

    @MainActor func testProjectionRefreshesNoticeAndEnablesPendingExtractionActions() async throws {
        let fixture = try DeferredSaveFixture(format: .tarGzip), document = fixture.document
        defer { document.close() }
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session)
        controller.display(EntryNode.tree(from: try await document.projectedEntries()), session: session)
        XCTAssertEqual(controller.capabilityNotice.stringValue, String(localized: "保存するとアーカイブ全体を再圧縮します"))
        _ = try await document.append(urls: [fixture.file("added")], to: "", progress: Progress())
        XCTAssertTrue(controller.capabilityNotice.stringValue.contains(String(localized: "未保存の変更\(1)件")))
        let entry = try XCTUnwrap((0..<controller.outlineView.numberOfRows).compactMap { controller.outlineView.item(atRow: $0) as? EntryNode }.first { $0.name == "added" })
        let row = controller.outlineView.row(forItem: entry)
        XCTAssertGreaterThanOrEqual(row, 0)
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        for selector in [#selector(ArchiveWindowController.copy(_:)), #selector(ArchiveWindowController.openEntry(_:)),
                         #selector(ArchiveWindowController.openWithEntry(_:)), #selector(ArchiveWindowController.togglePreviewPanel(_:)),
                         #selector(ArchiveWindowController.extractSelected(_:)), #selector(ArchiveWindowController.extractAll(_:))] {
            XCTAssertTrue(controller.validateMenuItem(NSMenuItem(title: "", action: selector, keyEquivalent: "")))
        }
        XCTAssertNil(controller.thumbnailProvider?.thumbnail(for: entry))
        controller.deleteEntries(nil)
        XCTAssertNil(controller.deletionConfirmation)
        await controller.extractionTask?.value
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertTrue(controller.capabilityNotice.stringValue.contains(String(localized: "未保存の変更\(0)件")))
        try await fixture.save()
        XCTAssertEqual(controller.capabilityNotice.stringValue, String(localized: "保存するとアーカイブ全体を再圧縮します"))
    }

    @MainActor func testPendingSidebarOpenWithMenuAndDragCarryCurrentOriginAndBytes() async throws {
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let source = try fixture.file("added.txt", contents: "staged preview")
        _ = try await document.append(urls: [source], to: "", progress: Progress())
        try Data("changed source".utf8).write(to: source)
        let session = try XCTUnwrap(document.session), controller = ArchiveWindowController(preferencesStore: fixture.store)
        document.addWindowController(controller)
        let materialization = try XCTUnwrap(document.materializationController())
        controller.display(EntryNode.tree(from: try await document.projectedEntries()), session: session,
                           materializationController: materialization)
        let row = try XCTUnwrap((0..<controller.outlineView.numberOfRows).first {
            (controller.outlineView.item(atRow: $0) as? EntryNode)?.name == "added.txt"
        })
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let node = try XCTUnwrap(controller.outlineView.item(atRow: row) as? EntryNode)
        let provider = try XCTUnwrap(controller.outlineView(controller.outlineView, pasteboardWriterForItem: node) as? NSFilePromiseProvider)
        let delegate = try XCTUnwrap(provider.delegate as? ArchiveFilePromise)
        XCTAssertEqual(delegate.payload.revision, document.pendingChanges.revision)
        XCTAssertEqual(delegate.payload.origin, .pending(try XCTUnwrap(node.entry?.pendingID)))
        let promised = fixture.directory.url.appendingPathComponent("promised.txt")
        let failure: (any Error)? = await withCheckedContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: promised) { @Sendable error in
                continuation.resume(returning: error)
            }
        }
        XCTAssertNil(failure)
        XCTAssertEqual(try Data(contentsOf: promised), Data("staged preview".utf8))
        controller.togglePreviewSidebar(nil)
        try await scenarioWait { controller.previewSidebar.state == .ready }
        let sidebarURL = try XCTUnwrap(controller.previewSidebar.selectedItem?.previewItemURL)
        XCTAssertEqual(try Data(contentsOf: sidebarURL), Data("staged preview".utf8))
        let openWith = try XCTUnwrap(controller.outlineView.menu?.items.first {
            $0.action == #selector(ArchiveWindowController.openWithEntry(_:))
        }?.submenu)
        // Build the actual Open With copy without launching an external application.
        controller.menuNeedsUpdate(openWith)
        await materialization.task?.value
        let item = try XCTUnwrap(materialization.item(at: 0)), openURL = try XCTUnwrap(item.previewItemURL)
        XCTAssertEqual(item.payload, delegate.payload)
        XCTAssertEqual(try Data(contentsOf: openURL), Data("staged preview".utf8))
        XCTAssertTrue(ArchiveTemporaryCopy.contains(openURL))
        let revision = item.payload.revision
        _ = try await document.rename(fixture.node("added.txt"), to: "renamed.txt", progress: Progress())
        let fresh = try XCTUnwrap(document.materializationController())
        XCTAssertFalse(fresh === materialization)
        XCTAssertNil(fresh.cachedItem(for: item.payload))
        XCTAssertNotEqual(document.pendingChanges.revision, revision)
        await materialization.close().value
        XCTAssertFalse(FileManager.default.fileExists(atPath: openURL.path))
    }

    @MainActor func testPendingThumbnailCacheAndLateResultsAreInvalidatedByRevision() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let source = try fixture.file("image.png", contents: "old image")
        _ = try await document.append(urls: [source], to: "", progress: Progress())
        let session = try XCTUnwrap(document.session), node = try await fixture.node("image.png")
        let worker = EntryMaterializer(session: session,
            temporaryDirectory: .init(root: fixture.directory.url.appendingPathComponent("thumbnails")))
        let cached = ArchiveThumbnailProvider(materializer: worker, session: session, generation: document.generation) { url, _ in
            XCTAssertEqual(try Data(contentsOf: url), Data("old image".utf8))
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        _ = cached.thumbnail(for: node)
        try await scenarioWait { cached.isIdle }
        XCTAssertNotNil(cached.cachedThumbnail(for: node))
        var release: CheckedContinuation<NSImage, Never>?
        let late = ArchiveThumbnailProvider(materializer: worker, session: session, generation: document.generation) { url, _ in
            XCTAssertEqual(try Data(contentsOf: url), Data("old image".utf8))
            return await withCheckedContinuation { release = $0 }
        }
        defer { release?.resume(returning: NSImage()); release = nil }
        _ = late.thumbnail(for: node)
        try await scenarioWait { release != nil }
        try Data("new image".utf8).write(to: source)
        _ = try await document.append(urls: [source], to: "", progress: Progress(), resolveConflict: { _ in .init(choice: .replace) })
        XCTAssertNil(cached.cachedThumbnail(for: node))
        release?.resume(returning: NSImage(size: NSSize(width: 16, height: 16))); release = nil
        try await scenarioWait { late.isIdle }
        XCTAssertNil(late.cachedThumbnail(for: node))
        let current = try await fixture.node("image.png")
        let fresh = ArchiveThumbnailProvider(materializer: worker, session: session, generation: document.generation) { url, _ in
            XCTAssertEqual(try Data(contentsOf: url), Data("new image".utf8))
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        _ = fresh.thumbnail(for: current)
        try await scenarioWait { fresh.isIdle }
        XCTAssertNotNil(fresh.cachedThumbnail(for: current))
        await cached.cancelAll().value
        await late.cancelAll().value
        await fresh.cancelAll().value
        await worker.close()
    }
}
