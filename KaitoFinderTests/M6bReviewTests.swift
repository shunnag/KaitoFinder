import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class M6bReviewTests: XCTestCase {
    @MainActor func testDeferredDotPrefixConflictUsesNormalizedGroupForImportAndMove() async throws {
        let fixture = try ScenarioFixture(), date = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            archiveColumnEntry("./cafe\u{301}.txt", index: 0, size: 5, date: date),
            archiveColumnEntry("./folder/", index: 1, kind: .directory, date: date),
            archiveColumnEntry("./folder/child.txt", index: 2),
            archiveColumnEntry("./source/café.txt", index: 3)
        ]
        let state = try await ArchiveReservationState.build(base: entries, generation: 0, changes: .init(),
            validation: .init(base: entries, format: .tar), staging: nil)
        let incoming = try fixture.file("café.txt"), folder = try fixture.folder("folder")
        _ = try fixture.file("folder/new.txt")
        var names: [String] = []
        let plan = try await ArchiveReservationComputation.importPlan(urls: [incoming, folder], folder: "", state: state,
            archive: fixture.archive, progress: Progress(), options: .init(), resolver: { conflict in
                names.append(conflict.existing.name)
                XCTAssertEqual(conflict.existing.modificationDate, date)
                XCTAssertEqual(conflict.existing.entryCount, 1)
                if conflict.path == "café.txt" {
                    XCTAssertEqual(conflict.existing.kind, .file)
                    XCTAssertEqual(conflict.existing.size, 5)
                    XCTAssertTrue(conflict.allowsBatchChoice)
                } else { XCTAssertEqual(conflict.existing.kind, .directory) }
                return .init(choice: .skip)
            })
        XCTAssertEqual(Set(names), ["café.txt", "folder"])
        XCTAssertTrue(plan.items.isEmpty)
        let source = try XCTUnwrap(state.tree.nodes(at: "source/café.txt").first)
        var movedConflict = false
        _ = try await ArchiveReservationComputation.move([ArchiveEditSelection(source)], folder: "", state: state,
            changes: .init(), base: entries, archive: fixture.archive, generation: 0, progress: Progress(), resolver: { conflict in
                movedConflict = true
                XCTAssertEqual(conflict.existing.name, "café.txt")
                XCTAssertEqual(conflict.existing.kind, .file)
                XCTAssertEqual(conflict.existing.modificationDate, date)
                XCTAssertTrue(conflict.allowsBatchChoice)
                return .init(choice: .skip)
            })
        XCTAssertTrue(movedConflict)
    }

    @MainActor func testOpenValidationStopsAtFirstRefusalInLargeSelection() async throws {
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document
        defer { document.close() }
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        document.addWindowController(controller)
        let entries = [archiveColumnEntry("000-directory/", kind: .directory)] + (1..<100_000).map {
            archiveColumnEntry("file\($0).txt", index: $0, method: "stored")
        }
        controller.display(EntryNode.tree(from: entries), session: try XCTUnwrap(document.session))
        controller.outlineView.selectAll(nil)
        XCTAssertEqual(controller.outlineView.numberOfSelectedRows, 100_000)
        let start = ContinuousClock.now
        let item = NSMenuItem(title: "", action: #selector(ArchiveWindowController.togglePreviewPanel(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item))
        let elapsed = start.duration(to: .now)
        print("M6b VALIDATION selected=100000 first-refusal duration=\(elapsed)")
        XCTAssertEqual(item.toolTip, EntryReadCapability.Refusal.directory.message())
        XCTAssertLessThan(elapsed, .milliseconds(200))
        XCTAssertNil(controller.selectionOpenRefusal(skippingDirectories: true))
        let open = NSMenuItem(title: "", action: #selector(ArchiveWindowController.openEntry(_:)), keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(open))
        let rename = NSMenuItem(title: "", action: #selector(ArchiveWindowController.renameEntry(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(rename))
    }

    @MainActor func testSplitSaveAsReservesJoinedInputBeforeReadingAnySourceBytes() async throws {
        let fixture = try DeferredSplitSaveFixture(format: .tar)
        defer { fixture.document.close() }
        let existing = try await ArchiveCreationController.existingArchive(from: XCTUnwrap(fixture.document.session), progress: Progress())
        let output = fixture.root.appendingPathComponent("copy.tar")
        var plan = ArchiveCreationPlan(sources: [], destination: output, format: .tar, existing: existing)
        plan.splitSchedule = .uniform(size: UInt64(fixture.size))
        let sourceBytes = fixture.original.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        let available = sourceBytes + UInt64(fixture.size) + VolumePublishFS.margin
        let reads = Mutex(0)
        var hooks = ArchiveSplitSaveHooks()
        hooks.operations.volumeInfo = { directory in
            let info = try VolumePublishFS.volumeInfo(directory)
            return .init(uuid: info.uuid, cacheIdentity: info.cacheIdentity, fileSystem: info.fileSystem,
                         available: available, hazard: nil)
        }
        hooks.didReadInputBytes = { bytes in reads.withLock { $0 += bytes } }
        XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: plan, progress: Progress(),
            volumeIndex: fixture.index, metadataStore: fixture.metadata, splitHooks: hooks)) { error in
                XCTAssertEqual((error as? ArchiveSplitSaveFailure)?.diagnostic,
                    VolumePublishError.insufficientSpace(required: available + sourceBytes, available: available).message())
            }
        XCTAssertEqual(reads.withLock { $0 }, 0)
        XCTAssertEqual(try fixture.parts(), fixture.original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathExtension("001").path))

        let target = VolumeSetTarget(parent: fixture.root, newSetScheme: .numbered(stem: "small.tar", width: 3),
                                    schedule: .uniform(size: 1024))
        hooks.operations.volumeInfo = { directory in
            let info = try VolumePublishFS.volumeInfo(directory)
            return .init(uuid: info.uuid, cacheIdentity: info.cacheIdentity, fileSystem: "msdos", available: .max, hazard: nil)
        }
        let publication = try VolumeSetPublication.begin(target, estimatedOutputLength: 1000,
            additionalWorkBytes: UInt64(UInt32.max) + 1, index: fixture.index, operations: hooks.operations)
        publication.cancel()
        XCTAssertTrue(try fixture.index.entries().isEmpty)
    }

    @MainActor func testImmediateSplitStagingUsesDestinationVolumeAndRemovesItsLedger() async throws {
        let fixture = try DeferredSplitSaveFixture(format: .tar, behavior: .immediate), document = fixture.document
        defer { document.close() }
        document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
        document.splitSaveHooks.operations.coordinate = { _, _, queue, access in queue.addOperation { access(nil) } }
        let root = fixture.root, staged = Mutex<[URL]>([])
        document.splitSaveHooks.didProduceWork = { _ in
            let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".KaitoFinder-staging-") }
            XCTAssertEqual(directories.count, 1)
            for directory in directories {
                XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("staging.json").path))
                let files = try ScenarioFixture.files(under: directory)
                XCTAssertTrue(files.contains { (try? Data(contentsOf: $0)) == Data("same volume".utf8) })
                var parentInfo = stat(), stagingInfo = stat()
                XCTAssertEqual(lstat(root.path, &parentInfo), 0)
                XCTAssertEqual(lstat(directory.path, &stagingInfo), 0)
                XCTAssertEqual(parentInfo.st_dev, stagingInfo.st_dev)
            }
            staged.withLock { $0 = directories }
        }
        let file = fixture.directory.url.appendingPathComponent("incoming.txt")
        try Data("same volume".utf8).write(to: file)
        _ = try await document.append(urls: [file], to: "", progress: Progress())
        XCTAssertEqual(staged.withLock { $0.count }, 1)
        for directory in staged.withLock({ $0 }) { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("staging.json").path))
        XCTAssertEqual(try DeferredSaveFixture.contents(fixture.gate)["incoming.txt"], Data("same volume".utf8))
    }

    @MainActor func testSplitProgressCountsRemovalsAndOnlyFinalCarryPass() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tar, .tarGzip] {
            for ownerIDs in (format == .tar || format == .tarGzip ? [false, true] : [false]) {
                let fixture = try DeferredSplitSaveFixture(format: format), session = try XCTUnwrap(fixture.document.session)
                defer { fixture.document.close() }
                let base = await session.entries()
                var pending = ArchivePendingChanges()
                pending.removals = Set(base.prefix(2).map { .init(index: $0.index, expectedName: $0.name, baseGeneration: 0) })
                let replay = try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending)
                let layout = try XCTUnwrap(session.volumeLayout)
                let input = try ArchiveVolumeInput(layout: layout, expected: ArchiveSetIdentity.capture(layout: layout))
                let progress = Progress(totalUnitCount: 3)
                let work = fixture.root.appendingPathComponent("work." + ArchiveCreationPlan.filenameExtension(for: format))
                var options = WriterOptions()
                options.preserveOwnerIDs = ownerIDs
                let produced = try ArchiveSplitWorkProducer.produce(source: input, workURL: work,
                    mode: format == .zip ? .inPlace : .rewrite(format), password: nil, options: options,
                    plan: replay, progress: progress, verifyAssembledInput: { try input.verify($0) })
                let carried = format == .zip ? 0 : Int64(replay.projected.count)
                XCTAssertEqual(progress.completedUnitCount, 2 + carried, "\(format), owners=\(ownerIDs)")
                let estimatedCarry = format == .zip ? 0 : (ownerIDs ? replay.projected.count : base.count)
                XCTAssertEqual(progress.totalUnitCount, 3 + Int64(estimatedCarry))
                try ArchiveSplitWorkProducer.validate(ArchiveReader.open(url: work), plan: replay, mode: produced.mode)
            }
        }
    }

    @MainActor func testBlankAreaNewFolderUsesRootWhileToolbarUsesSelectedFolder() async throws {
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        document.addWindowController(controller)
        let root = EntryNode.tree(from: try await document.projectedEntries())
        controller.display(root, session: try XCTUnwrap(document.session))
        let folder = try XCTUnwrap(root.nodes(at: "folder").first)
        controller.outlineView.selectRowIndexes(IndexSet(integer: controller.outlineView.row(forItem: folder)), byExtendingSelection: false)
        let menu = try XCTUnwrap(controller.outlineView.contextMenu(forRow: -1))
        let item = try XCTUnwrap(menu.items.first { $0.action == #selector(ArchiveWindowController.newFolder(_:)) })
        XCTAssertEqual(controller.outlineView.clickedRow, -1)
        controller.newFolder(item)
        await controller.extractionTask?.value
        XCTAssertEqual(document.pendingChanges.createdFolders.count, 1)
        XCTAssertEqual(ArchivePath.components(document.pendingChanges.createdFolders[0].path).count, 1)
        controller.outlineView.cancelRenaming()
        let row = try XCTUnwrap((0..<controller.outlineView.numberOfRows).first {
            (controller.outlineView.item(atRow: $0) as? EntryNode)?.path == "folder"
        })
        controller.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.newFolder(nil)
        await controller.extractionTask?.value
        XCTAssertTrue(document.pendingChanges.createdFolders.last?.path.hasPrefix("folder/") == true)
    }

    func testVisibleStatusSizeIgnoresHiddenUnknownSizesAndOverflow() {
        let root = EntryNode.tree(from: [archiveColumnEntry("visible.txt", size: 7),
            archiveColumnEntry("folder/file.txt", index: 1, size: 11),
            archiveColumnEntry("folder/.hidden", index: 2, size: .max),
            archiveColumnEntry(".secret/file", index: 3, size: nil)])
        for query in ["", "visible"] {
            let filtered = EntryTreeFilter(root: root, query: query)
            XCTAssertEqual(filtered.totalCount, 3)
            XCTAssertEqual(filtered.totalSize, 18)
            XCTAssertNil(EntryTreeFilter(root: root, query: query, showsHiddenFiles: true).totalSize)
        }
        let unknown = EntryNode.tree(from: [archiveColumnEntry("unknown", size: nil)])
        XCTAssertNil(EntryTreeFilter(root: unknown, query: "").totalSize)
        let overflow = EntryNode.tree(from: [archiveColumnEntry("a", size: .max), archiveColumnEntry("b", index: 1, size: 1)])
        XCTAssertNil(EntryTreeFilter(root: overflow, query: "").totalSize)
    }

    @MainActor func testUnsafeTopLevelSelectionsReportEachEntryAndStillExtractSafeFiles() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('..', b'bad file')
            z.writestr('../escape.txt', b'bad child')
            z.writestr('ok.txt', b'good')
        """)
        let session = try ArchiveSession(url: fixture.archive), base = await session.entries()
        defer { Task { await session.close() } }
        for deferred in [false, true] {
            if deferred {
                session.setPendingReadSnapshot(try .init(base: base, generation: session.generation, changes: .init(), staging: nil))
            }
            let tree = EntryNode.tree(from: base)
            let payloads = ArchiveEntryPayload.payloads(for: tree.children, session: session, generation: session.generation)
            let output = try fixture.folder(deferred ? "deferred" : "immediate")
            let result = try await ExtractionService.extract(payloads, from: session, to: output, progress: Progress())
            XCTAssertEqual(Set(result.failures.compactMap(\.entryIndex)), [0, 1])
            XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("ok.txt")), Data("good".utf8))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escape.txt").path))
            let copied = Mutex(0)
            do {
                _ = try await ArchiveCopyOut.prepare(payloads, from: session, progress: Progress(),
                    temporaryDirectory: .init(root: fixture.root.appendingPathComponent(deferred ? "copy-deferred" : "copy-immediate")),
                    didProcess: { _ in copied.withLock { $0 += 1 } })
                XCTFail("Unsafe entries must be reported")
            } catch { XCTAssertEqual(copied.withLock { $0 }, 3) }
        }
        var preferences = ArchivePreferences()
        preferences.folderPolicy = .never
        let batch = ArchiveBatchExtractor(preferences: preferences, passwordPrompt: { _, _ in throw CancellationError() }, reveal: { _ in })
        let processed = Mutex(0)
        let report = await batch.run(archives: [fixture.archive], base: try fixture.folder("batch"), progress: Progress(),
            didProcess: { _ in processed.withLock { $0 += 1 } })
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(processed.withLock { $0 }, 3)
    }

    @MainActor func testSplitDiscoveryFailureUsesOpenWordingAndPreservesErrno() throws {
        let fixture = try ArchiveTestDirectory(), parent = fixture.url.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let member = parent.appendingPathComponent("archive.tar.002")
        try Data([0]).write(to: member)
        XCTAssertEqual(chmod(parent.path, 0o111), 0)
        defer { _ = chmod(parent.path, 0o700) }
        let document = ArchiveDocument()
        defer { document.close() }
        for read in [false, true] {
            XCTAssertThrowsError(try { () -> Void in
                if read { try document.read(from: member, ofType: ArchiveDocumentController.splitVolumeType) }
                else { _ = try ArchiveVolumeOpenRecovery.discover(member) }
            }()) { error in
                let failure = error as NSError
                XCTAssertEqual(failure.localizedDescription, String(localized: "分割アーカイブの状態を確認できませんでした"))
                XCTAssertEqual(failure.code, Int(EACCES))
                XCTAssertEqual((failure.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain, NSPOSIXErrorDomain)
                XCTAssertTrue(failure.localizedFailureReason?.contains(String(EACCES)) == true)
            }
            XCTAssertNil(document.session)
        }
    }
}
