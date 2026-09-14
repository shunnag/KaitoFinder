import AppKit
import KaitoKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveThumbnailTests: XCTestCase {
    @MainActor private final class Fixture {
        let directory: ArchiveTestDirectory
        let archive: URL
        let temporary: ExtractionTemporaryDirectory

        init(images: [String] = ["small.png"]) throws {
            directory = try ArchiveTestDirectory()
            archive = directory.url.appendingPathComponent("thumbnails.zip")
            temporary = ExtractionTemporaryDirectory(root: directory.url.appendingPathComponent("thumbnails"))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            for y in 0..<64 {
                for x in 0..<64 {
                    bitmap.setColor(NSColor(deviceRed: CGFloat(x) / 64, green: CGFloat(y) / 64,
                                            blue: 0.5, alpha: 1), atX: x, y: y)
                }
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            for name in images + ["encrypted.png"] { try png.write(to: directory.url.appendingPathComponent(name)) }
            try Data(repeating: 0, count: 9 * 1024 * 1024).write(to: directory.url.appendingPathComponent("big.png"))
            try Data("not an image".utf8).write(to: directory.url.appendingPathComponent("note.txt"))
            try directory.run("/usr/bin/zip", ["-q", "-D", archive.path] + images + ["big.png", "note.txt"])
            try directory.run("/usr/bin/zip", ["-q", "-P", "secret", archive.path, "encrypted.png"])
        }

        func files() -> [URL] {
            guard let entries = FileManager.default.enumerator(at: temporary.root, includingPropertiesForKeys: [.isRegularFileKey])
            else { return [] }
            return entries.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        }
    }

    private enum Failure: Error { case generation }

    /// 抽出後の一時コピーを保持して待ち、生成の完了順序を時間や QL サービスの速度から切り離す。
    @MainActor private final class GenerationGate {
        var urls: [URL] = []
        var maximumActiveCount = 0
        private var cancelled = false
        private var waiting: [String: CheckedContinuation<NSImage, any Error>] = [:]

        func generate(_ url: URL, request: QLThumbnailGenerator.Request) async throws -> NSImage {
            guard !cancelled else { throw CancellationError() }
            urls.append(url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(request.size, CGSize(width: 16, height: 16))
            XCTAssertEqual(request.scale, 2)
            XCTAssertEqual(request.representationTypes, .thumbnail)
            return try await withCheckedThrowingContinuation { continuation in
                XCTAssertNil(waiting[url.lastPathComponent])
                waiting[url.lastPathComponent] = continuation
                maximumActiveCount = max(maximumActiveCount, waiting.count)
            }
        }

        func succeed(_ name: String) throws {
            let continuation = try XCTUnwrap(waiting.removeValue(forKey: name))
            continuation.resume(returning: NSImage(size: NSSize(width: 64, height: 64)))
        }

        func fail(_ name: String) throws {
            try XCTUnwrap(waiting.removeValue(forKey: name)).resume(throwing: Failure.generation)
        }

        func cancelPending() {
            cancelled = true
            let continuations = Array(waiting.values)
            waiting.removeAll()
            for continuation in continuations { continuation.resume(throwing: CancellationError()) }
        }
    }

    @MainActor private func interface(_ fixture: Fixture) async throws
        -> (document: ArchiveDocument, controller: ArchiveWindowController, session: ArchiveSession,
            root: EntryNode, materialization: ArchiveMaterializationController) {
        let document = try ArchiveDocument(contentsOf: fixture.archive, ofType: "public.zip-archive")
        let controller = ArchiveWindowController()
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session), snapshot = await session.snapshot()
        let root = EntryNode.tree(from: snapshot.entries)
        let materialization = try XCTUnwrap(document.materializationController(temporaryDirectory: fixture.temporary))
        controller.display(root, session: session, generation: snapshot.generation, materializationController: materialization)
        session.setPasswordPrompt { _ in
            XCTFail("サムネイルはパスワード入力を要求しない")
            throw CancellationError()
        }
        addTeardownBlock { @MainActor in
            document.close()
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            await document.undoCleanup?.value
            withExtendedLifetime(fixture) {}
        }
        return (document, controller, session, root, materialization)
    }

    @MainActor private func provider(_ fixture: Fixture, generate: @escaping ArchiveThumbnailProvider.Generate) async throws
        -> (ArchiveThumbnailProvider, ArchiveSession, EntryNode, EntryMaterializer) {
        let session = try ArchiveSession(url: fixture.archive), snapshot = await session.snapshot()
        session.setPasswordPrompt { _ in
            XCTFail("サムネイルはパスワード入力を要求しない")
            throw CancellationError()
        }
        let worker = EntryMaterializer(session: session, temporaryDirectory: fixture.temporary)
        let provider = ArchiveThumbnailProvider(materializer: worker, session: session, generation: snapshot.generation, generate: generate)
        addTeardownBlock { @MainActor in
            await provider.cancelAll().value
            await worker.close()
            await session.close()
            withExtendedLifetime(fixture) {}
        }
        return (provider, session, EntryNode.tree(from: snapshot.entries), worker)
    }

    @MainActor private func node(_ name: String, in root: EntryNode) throws -> EntryNode {
        try XCTUnwrap(root.children.first { $0.name == name })
    }

    @MainActor private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "処理が 5 秒以内に完了すること", file: file, line: line)
    }

    @MainActor private func nameCell(_ node: EntryNode, in controller: ArchiveWindowController) throws -> NSTableCellView {
        try XCTUnwrap(controller.outlineView(controller.outlineView,
            viewFor: controller.outlineView.outlineTableColumn, item: node) as? NSTableCellView)
    }

    @MainActor func testPNGThumbnailReplacesNameIconWithoutPasswordProgressOrTemporaryCopies() async throws {
        let fixture = try Fixture(), ui = try await interface(fixture)
        let provider = try XCTUnwrap(ui.controller.thumbnailProvider)
        let small = try node("small.png", in: ui.root), note = try node("note.txt", in: ui.root)
        let excluded = try ["big.png", "note.txt", "encrypted.png"].map { try node($0, in: ui.root) }
        XCTAssertEqual(excluded[0].entry?.uncompressedSize, 9 * 1024 * 1024)
        XCTAssertEqual(excluded[2].entry?.isEncrypted, true)
        let ready = expectation(description: "64×64 PNG のサムネイル")
        let unexpected = expectation(description: "対象外の項目は生成しない")
        unexpected.isInverted = true
        var produced: [EntryNode] = [], progressRequests = 0
        let refresh = provider.didProduce, started = ui.materialization.started
        provider.didProduce = { node in
            MainActor.assertIsolated()
            refresh?(node)
            produced.append(node)
            if node === small { ready.fulfill() }
            else { unexpected.fulfill() }
        }
        ui.materialization.started = { item, progress in
            progressRequests += 1
            started?(item, progress)
        }
        let generic = try XCTUnwrap(nameCell(small, in: ui.controller).imageView?.image)
        XCTAssertNil(provider.thumbnail(for: small))
        for node in excluded { XCTAssertNil(provider.thumbnail(for: node)) }
        await fulfillment(of: [ready], timeout: 5)
        let image = try XCTUnwrap(provider.thumbnail(for: small))
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertLessThanOrEqual(image.size.width, 16.5)
        XCTAssertLessThanOrEqual(image.size.height, 16.5)
        XCTAssertTrue(try nameCell(small, in: ui.controller).imageView?.image === image)
        XCTAssertFalse(image === generic)
        let noteIcon = try XCTUnwrap(nameCell(note, in: ui.controller).imageView?.image)
        let textType = try XCTUnwrap(UTType(filenameExtension: "txt"))
        XCTAssertEqual(noteIcon.tiffRepresentation, NSWorkspace.shared.icon(for: textType).tiffRepresentation)
        for _ in 0..<3 {
            XCTAssertTrue(provider.thumbnail(for: small) === image)
            for node in excluded { XCTAssertNil(provider.thumbnail(for: node)) }
        }
        await fulfillment(of: [unexpected], timeout: 0.2)
        XCTAssertEqual(produced, [small])
        XCTAssertEqual(progressRequests, 0)
        XCTAssertNil(ui.controller.window?.attachedSheet)
        XCTAssertNil(ui.controller.passwordPrompt)
        XCTAssertNil(ui.controller.extractionSheet)
        XCTAssertTrue(fixture.files().isEmpty)
        let directories = try FileManager.default.contentsOfDirectory(at: fixture.temporary.root, includingPropertiesForKeys: nil)
        XCTAssertEqual(directories.count, 1)
        for directory in directories {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    private func entry(_ path: String, kind: EntryKind = .file, size: UInt64? = 1,
                       encrypted: Bool = false, incomplete: Bool = false) -> ArchiveEntry {
        ArchiveEntry(index: 0, rawName: RawName(bytes: Array(path.utf8)), name: path,
            pathComponents: path.split(separator: "/").map(String.init), kind: kind, uncompressedSize: size,
            compressedSize: 1, modificationDate: nil, posixPermissions: nil, isEncrypted: encrypted,
            solidGroup: -1, crc32: nil, methodDescription: "stored", formatSpecific: [:], isIncomplete: incomplete)
    }

    @MainActor func testThumbnailEligibilityRejectsUnsafeOrNonImageNodesSynchronously() async throws {
        let fixture = try Fixture()
        let (provider, _, _, _) = try await provider(fixture) { _, _ in
            XCTFail("対象外の項目は生成しない")
            throw Failure.generation
        }
        let root = EntryNode.tree(from: [entry("folder.png", kind: .directory), entry("link.png", kind: .symlink),
            entry("hardlink.png", kind: .hardlink), entry("encrypted.png", encrypted: true),
            entry("incomplete.png", incomplete: true), entry("unknown.png", size: nil),
            entry("large.png", size: 8 * 1024 * 1024 + 1), entry("note.txt"), entry("virtual.png/child.txt")])
        for node in [root] + root.children {
            XCTAssertNil(provider.thumbnail(for: node))
            XCTAssertTrue(provider.isIdle, node.name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporary.root.path))
    }

    @MainActor func testThumbnailQueueIsFIFOWithTwoProductionsAndOneRequestPerNode() async throws {
        let names = (0..<5).map { "image\($0).png" }, fixture = try Fixture(images: names), gate = GenerationGate()
        defer { gate.cancelPending() }
        let (provider, _, root, _) = try await provider(fixture, generate: gate.generate)
        let nodes = try names.map { try node($0, in: root) }
        var produced: [EntryNode] = []
        provider.didProduce = { produced.append($0) }
        for node in nodes {
            for _ in 0..<3 { XCTAssertNil(provider.thumbnail(for: node)) }
        }
        try await waitUntil { gate.urls.count == 2 }
        XCTAssertEqual(Set(gate.urls.map(\.lastPathComponent)), Set(names.prefix(2)))
        XCTAssertEqual(fixture.files().count, 2)
        try gate.succeed(names[0])
        for index in 2..<5 {
            try await waitUntil { gate.urls.count == index + 1 }
            XCTAssertEqual(gate.urls.last?.lastPathComponent, names[index])
            XCTAssertEqual(fixture.files().count, 2)
            try gate.succeed(names[index])
        }
        try gate.succeed(names[1])
        try await waitUntil { provider.isIdle }
        XCTAssertEqual(gate.maximumActiveCount, 2)
        XCTAssertEqual(gate.urls.count, 5)
        XCTAssertEqual(Set(produced), Set(nodes))
        XCTAssertEqual(produced.count, 5)
        for node in nodes {
            let image = try XCTUnwrap(provider.thumbnail(for: node))
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
            XCTAssertTrue(provider.thumbnail(for: node) === image)
        }
        XCTAssertTrue(provider.isIdle)
        XCTAssertTrue(fixture.files().isEmpty)
    }

    @MainActor func testThumbnailGenerationFailureIsDiscardedAndNeverRetried() async throws {
        let fixture = try Fixture(), gate = GenerationGate()
        defer { gate.cancelPending() }
        let (provider, _, root, _) = try await provider(fixture, generate: gate.generate)
        let small = try node("small.png", in: root)
        provider.didProduce = { _ in XCTFail("失敗した画像を公開しない") }
        XCTAssertNil(provider.thumbnail(for: small))
        try await waitUntil { gate.urls.count == 1 }
        try gate.fail("small.png")
        try await waitUntil { provider.isIdle }
        for _ in 0..<3 { XCTAssertNil(provider.thumbnail(for: small)) }
        XCTAssertTrue(provider.isIdle)
        XCTAssertEqual(gate.urls.count, 1)
        XCTAssertTrue(fixture.files().isEmpty)
    }

    @MainActor func testMaterializationFailureIsNotRetriedUntilANewProvider() async throws {
        let fixture = try Fixture()
        var generated = 0
        let generate: ArchiveThumbnailProvider.Generate = { _, _ in
            generated += 1
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        let (provider, session, _, worker) = try await provider(fixture, generate: generate)
        let missing = try XCTUnwrap(EntryNode.tree(from: [entry("missing.png")]).children.first)
        XCTAssertNil(provider.thumbnail(for: missing))
        try await waitUntil { provider.isIdle }
        XCTAssertEqual(generated, 0)
        XCTAssertTrue(fixture.files().isEmpty)
        try Data(contentsOf: fixture.directory.url.appendingPathComponent("small.png"))
            .write(to: fixture.directory.url.appendingPathComponent("missing.png"))
        try fixture.directory.run("/usr/bin/zip", ["-q", fixture.archive.path, "missing.png"])
        try await session.reloadAfterMutation()
        XCTAssertNil(provider.thumbnail(for: missing))
        XCTAssertTrue(provider.isIdle)
        let fresh = ArchiveThumbnailProvider(materializer: worker, session: session, generation: session.generation, generate: generate)
        addTeardownBlock { @MainActor in await fresh.cancelAll().value }
        XCTAssertNil(fresh.thumbnail(for: missing))
        try await waitUntil { fresh.isIdle }
        XCTAssertNotNil(fresh.thumbnail(for: missing))
        XCTAssertEqual(generated, 1)
        XCTAssertTrue(fixture.files().isEmpty)
    }

    @MainActor func testEightMiBBoundaryIsEligibleAndCacheUsesNodeIdentity() async throws {
        let fixture = try Fixture()
        var generated = 0
        let (provider, _, _, _) = try await provider(fixture) { _, _ in
            generated += 1
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        let entries = [entry("small.png", size: 8 * 1024 * 1024), entry("small.png", size: 8 * 1024 * 1024)]
        let nodes = EntryNode.tree(from: entries).children
        for node in nodes { XCTAssertNil(provider.thumbnail(for: node)) }
        try await waitUntil { provider.isIdle }
        XCTAssertEqual(generated, 2)
        let images = try nodes.map { try XCTUnwrap(provider.thumbnail(for: $0)) }
        XCTAssertFalse(images[0] === images[1])
        XCTAssertTrue(fixture.files().isEmpty)
    }

    @MainActor func testCancelAllDiscardsInFlightCopiesAndDropsQueuedThumbnails() async throws {
        let names = (0..<4).map { "image\($0).png" }, fixture = try Fixture(images: names), gate = GenerationGate()
        defer { gate.cancelPending() }
        let (provider, _, root, _) = try await provider(fixture, generate: gate.generate)
        let nodes = try names.map { try node($0, in: root) }
        var produced = 0
        provider.didProduce = { _ in produced += 1 }
        for node in nodes { XCTAssertNil(provider.thumbnail(for: node)) }
        try await waitUntil { gate.urls.count == 2 }
        let cleanup = provider.cancelAll()
        // 生成器が取消しを無視して成功を返しても、コピーも通知も残さない。
        for name in gate.urls.map(\.lastPathComponent) { try gate.succeed(name) }
        await cleanup.value
        XCTAssertEqual(produced, 0)
        XCTAssertEqual(gate.urls.count, 2)
        XCTAssertTrue(provider.isIdle)
        XCTAssertTrue(fixture.files().isEmpty)
        for node in nodes { XCTAssertNil(provider.thumbnail(for: node)) }
        XCTAssertTrue(provider.isIdle)
    }

    @MainActor func testCancelAllBeforeProductionSuppressesCallbacksAndWindowClosesSafely() async throws {
        let fixture = try Fixture(), ui = try await interface(fixture)
        let provider = try XCTUnwrap(ui.controller.thumbnailProvider), small = try node("small.png", in: ui.root)
        var produced = 0
        provider.didProduce = { _ in produced += 1 }
        XCTAssertNil(provider.thumbnail(for: small))
        let cleanup = provider.cancelAll()
        ui.controller.window?.close()
        await cleanup.value
        XCTAssertEqual(produced, 0)
        XCTAssertTrue(provider.isIdle)
        XCTAssertNil(provider.thumbnail(for: small))
        XCTAssertTrue(fixture.files().isEmpty)
    }

    @MainActor func testDisplayReplacesAndCancelsThePreviousThumbnailProvider() async throws {
        let fixture = try Fixture(), ui = try await interface(fixture)
        let previous = try XCTUnwrap(ui.controller.thumbnailProvider), oldNode = try node("small.png", in: ui.root)
        previous.didProduce = { _ in XCTFail("古い一覧へ通知しない") }
        XCTAssertNil(previous.thumbnail(for: oldNode))
        let replacement = EntryNode.tree(from: ui.root.children.compactMap(\.entry))
        ui.controller.display(replacement, session: ui.session, generation: ui.session.generation,
                              materializationController: ui.materialization)
        let current = try XCTUnwrap(ui.controller.thumbnailProvider)
        XCTAssertFalse(current === previous)
        XCTAssertNil(previous.didProduce)
        XCTAssertNil(previous.thumbnail(for: oldNode))
        let ready = expectation(description: "新しい一覧の画像")
        let refresh = current.didProduce, small = try node("small.png", in: replacement)
        current.didProduce = { node in
            refresh?(node)
            XCTAssertTrue(node === small)
            ready.fulfill()
        }
        XCTAssertNil(current.thumbnail(for: small))
        await fulfillment(of: [ready], timeout: 5)
        await previous.cancelAll().value
        XCTAssertNotNil(current.thumbnail(for: small))
        XCTAssertTrue(fixture.files().isEmpty)
    }

    @MainActor func testDisplayLockedClearsPathBarAndCancelsThumbnails() async throws {
        let fixture = try Fixture(), ui = try await interface(fixture)
        let provider = try XCTUnwrap(ui.controller.thumbnailProvider), small = try node("small.png", in: ui.root)
        ui.controller.outlineView.selectRowIndexes(IndexSet(integer: ui.controller.outlineView.row(forItem: small)), byExtendingSelection: false)
        XCTAssertEqual(ui.controller.pathControl.pathItems.map(\.title), ["thumbnails.zip", "small.png"])
        XCTAssertNil(provider.thumbnail(for: small))
        ui.controller.displayLocked()
        XCTAssertNil(ui.controller.thumbnailProvider)
        XCTAssertNil(provider.didProduce)
        XCTAssertTrue(ui.controller.pathControl.pathItems.isEmpty)
        XCTAssertEqual(ui.controller.outlineView.numberOfRows, 0)
        await provider.cancelAll().value
        XCTAssertTrue(fixture.files().isEmpty)
        XCTAssertNil(ui.controller.window?.attachedSheet)
    }

    @MainActor func testWindowCloseCancelsPendingThumbnailProduction() async throws {
        let fixture = try Fixture(), ui = try await interface(fixture)
        let provider = try XCTUnwrap(ui.controller.thumbnailProvider), small = try node("small.png", in: ui.root)
        XCTAssertNotNil(provider.didProduce)
        XCTAssertNil(provider.thumbnail(for: small))
        ui.controller.window?.close()
        XCTAssertNil(provider.didProduce)
        await provider.cancelAll().value
        XCTAssertTrue(provider.isIdle)
        XCTAssertTrue(fixture.files().isEmpty)
    }

    @MainActor func testMaterializationCloseWaitsForThumbnailCleanupBeforeRemovingDocumentDirectory() async throws {
        let fixture = try Fixture(), gate = GenerationGate()
        defer { gate.cancelPending() }
        let session = try ArchiveSession(url: fixture.archive), snapshot = await session.snapshot()
        let materialization = ArchiveMaterializationController(session: session, temporaryDirectory: fixture.temporary)
        let worker = try XCTUnwrap(materialization.entryMaterializer)
        let provider = ArchiveThumbnailProvider(materializer: worker, session: session, generation: snapshot.generation,
                                                generate: gate.generate)
        materialization.cancelBackgroundWorkOnClose { [weak provider] in provider?.cancelAll() }
        addTeardownBlock { @MainActor in
            await materialization.close().value
            await session.close()
            withExtendedLifetime(fixture) {}
        }
        provider.didProduce = { _ in XCTFail("文書の終了後は通知しない") }
        let small = try node("small.png", in: EntryNode.tree(from: snapshot.entries))
        XCTAssertNil(provider.thumbnail(for: small))
        try await waitUntil { gate.urls.count == 1 }
        let url = try XCTUnwrap(gate.urls.first), documentDirectory = url.deletingLastPathComponent().deletingLastPathComponent()
        let cleanup = materialization.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try gate.succeed("small.png")
        await cleanup.value
        XCTAssertNil(provider.didProduce)
        XCTAssertTrue(provider.isIdle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: documentDirectory.path))
    }
}
