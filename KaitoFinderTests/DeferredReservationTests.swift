import AppKit
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredReservationTests: XCTestCase {
    private func entry(_ index: Int, _ path: String, kind: EntryKind = .file,
                       metadata: [String: String] = [:]) -> ArchiveEntry {
        ArchiveEntry(index: index, rawName: .init(bytes: Array(path.utf8)), name: path,
            pathComponents: ArchivePath.components(path), kind: kind, uncompressedSize: 1, compressedSize: nil,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000), posixPermissions: nil,
            isEncrypted: false, solidGroup: -1, crc32: nil, methodDescription: "stored", formatSpecific: metadata)
    }

    @MainActor func testRandomizedEditsMatchFullValidationAndUndo() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("incoming.txt")
        try Data([1]).write(to: source)
        let stamp = try ArchiveImportSourceStamp(source)
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tar, .lha] {
            let base = (0..<240).map { entry($0, "d\($0 / 20)/f\($0).txt") }
            let validation = ArchiveReservationValidation(base: base, format: format)
            XCTAssertNotNil(validation.context(for: .init()))
            var random: UInt64 = 0x92_24_2026
            func pick(_ count: Int) -> Int {
                random = random &* 6_364_136_223_846_793_005 &+ 1
                return Int((random >> 32) % UInt64(max(1, count)))
            }
            var pending = ArchivePendingChanges(), history: [ArchivePendingChanges] = []
            var accepted = 0, rejected = 0, undone = 0
            for step in 0..<180 {
                let operation = pick(8)
                if operation == 7, let previous = history.popLast() { pending = previous; undone += 1; continue }
                let projection = try ArchivePendingProjection(pending.projection(base: base, generation: 0))
                let root = EntryNode.tree(from: projection.entries)
                var nodes: [EntryNode] = [], remaining = root.children
                while let node = remaining.popLast() { nodes.append(node); remaining += node.children }
                guard !nodes.isEmpty else { break }
                let files = nodes.filter { !$0.isDirectory }, folders = nodes.filter(\.isDirectory)
                let pool = operation == 1 ? folders : (operation == 0 ? files : nodes)
                guard !pool.isEmpty else { continue }
                let node = pool[pick(pool.count)], selection = try projection.selection(ArchiveEditSelection(node))
                let target = pick(3) == 0 || folders.isEmpty ? "" : folders[pick(folders.count)].path
                let names = ["changed\(step)", "f1.txt", "bad/name", "..", "café", "cafe\u{301}", "d1"]
                let name = names[pick(names.count)], id = UUID()
                func apply(fast: Bool) throws -> ArchivePendingChanges {
                    let context = fast ? validation.context(for: pending) : nil
                    var next = pending
                    switch operation {
                    case 0, 1:
                        let plan = try ArchiveEditPlan.build(removing: [], renaming: [.init(selection: selection, name: name)],
                            existing: projection.planningEntries, occupancy: context)
                        next = ArchivePendingEditor.applying(plan, projection: projection, changes: pending, base: base, generation: 0)
                    case 2:
                        let plan = try ArchiveEditPlan.build(removing: [], renaming: [], moving: [.init(selection: selection, folder: target)],
                            existing: projection.planningEntries, occupancy: context)
                        next = ArchivePendingEditor.applying(plan, projection: projection, changes: pending, base: base, generation: 0)
                    case 3:
                        let plan = try ArchiveEditPlan.build(removing: [selection], renaming: [], existing: projection.planningEntries, occupancy: context)
                        next = ArchivePendingEditor.applying(plan, projection: projection, changes: pending, base: base, generation: 0)
                    case 4, 7:
                        let plan = try ArchiveNewFolderPlan.build(in: target, baseName: name, existing: projection.planningEntries, occupancy: context)
                        next.createdFolders.append(.init(id: id, path: plan.path, date: stamp.date))
                    default:
                        let plan = try ArchiveImportPlan.build(urls: [source], folder: target, existing: projection.planningEntries,
                                                              progress: Progress(), occupancy: context)
                        if let failure = plan.failures.first { throw ExtractionFailure.refused(failure.reason) }
                        for item in plan.items {
                            next.additions.append(.init(id: id, path: item.path, stagedURL: source, sourceStamp: stamp, stagedStamp: stamp,
                                                        reservedAt: stamp.date))
                        }
                    }
                    let result = try ArchivePendingProjection(next.projection(base: base, generation: 0))
                    if fast { try validation.validate(next, projection: result) }
                    else { try ArchiveReservationValidation.validateFull(result.entries, format: format) }
                    next.revision += 1
                    return next
                }
                let fast = Result { try apply(fast: true) }, full = Result { try apply(fast: false) }
                switch (fast, full) {
                case (.success(let next), .success(let expected)):
                    XCTAssertEqual(next, expected, "\(format), step \(step)")
                    history.append(pending); pending = next; accepted += 1
                case (.failure(let actual), .failure(let expected)):
                    XCTAssertEqual(String(reflecting: type(of: actual)), String(reflecting: type(of: expected)))
                    XCTAssertEqual(ArchiveErrorText.describe(actual), ArchiveErrorText.describe(expected), "\(format), step \(step)")
                    rejected += 1
                default: XCTFail("Validation disagreed at \(format), step \(step): \(fast), \(full)")
                }
            }
            XCTAssertGreaterThan(accepted, 30)
            XCTAssertGreaterThan(rejected, 10)
            XCTAssertGreaterThan(undone, 5)
        }
    }

    func testUnusualBaseFallsBackAndPreservesExactFailureOrRepair() throws {
        let archives = [
            [entry(0, "a"), entry(1, "a")],
            [entry(0, "cafe\u{301}"), entry(1, "other")],
            [entry(0, "./a"), entry(1, "bad/../path")],
            [entry(0, "a"), entry(1, "hard", kind: .hardlink, metadata: ["hardLinkTargetIndex": "0"])],
            [entry(0, "other", kind: .other), entry(1, "file")]
        ]
        for base in archives {
            for format: GyoshukuKit.ArchiveFormat in [.zip, .lha, .tar] {
                let validation = ArchiveReservationValidation(base: base, format: format)
                XCTAssertNil(validation.context(for: .init()))
                for index in [-1, 0, 1] {
                    var pending = ArchivePendingChanges()
                    if index >= 0 { pending.removals.insert(.init(index: index, expectedName: base[index].name, baseGeneration: 0)) }
                    let projection = try ArchivePendingProjection(pending.projection(base: base, generation: 0))
                    let fast = Result { try validation.validate(pending, projection: projection) }
                    let full = Result { try ArchiveReservationValidation.validateFull(projection.entries, format: format) }
                    switch (fast, full) {
                    case (.success, .success): break
                    case (.failure(let a), .failure(let b)): XCTAssertEqual(ArchiveErrorText.describe(a), ArchiveErrorText.describe(b))
                    default: XCTFail("Fallback disagreed")
                    }
                }
            }
        }
    }

    @MainActor func testBaseCacheIsScopedToSessionAsWellAsGeneration() async throws {
        let editor = ArchivePendingEditor(), first = NSObject(), second = NSObject()
        try await editor.install(base: [entry(0, "first")], generation: 0, sessionID: ObjectIdentifier(first))
        let before = try await editor.prepare(generation: 0)
        XCTAssertEqual(before.projection.entries.map(\.name), ["first"])
        try await editor.install(base: [entry(0, "second")], generation: 0, sessionID: ObjectIdentifier(second))
        let after = try await editor.prepare(generation: 0)
        XCTAssertEqual(after.projection.entries.map(\.name), ["second"])
        XCTAssertEqual(editor.baseSession, ObjectIdentifier(second))
    }

    func testUnchangedCopiesSharePathComponentsAndContiguousProjection() {
        let original = entry(0, "directory/subdirectory/filename.txt")
        let copied = original.pendingCopy(index: 10, kind: .hardlink, formatSpecific: ["hardLinkTargetIndex": "0"])
        let address = original.pathComponents.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        XCTAssertEqual(copied.pathComponents.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }, address)
        let renamed = original.pendingCopy(name: "different/path.txt")
        XCTAssertEqual(renamed.pathComponents, ["different", "path.txt"])
        let entries = [original], projection = ArchivePendingProjection(entries)
        XCTAssertEqual(entries.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) },
                       projection.planningEntries.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) })
        withExtendedLifetime((original, copied, entries)) {}
    }

    func testPendingSnapshotResolvesManyFoldersUsingOneSubtreeIndex() throws {
        let entries = (0..<10_000).map { entry($0, "folder\($0 / 2)/file\($0)") }
        let snapshot = try ArchivePendingReadSnapshot(base: entries, generation: 0, changes: .init(), staging: nil, nameSyntax: .portable)
        let start = ContinuousClock.now
        for folder in 0..<5_000 {
            let anchor = entries[folder * 2]
            let payload = ArchiveEntryPayload(archiveURL: URL(fileURLWithPath: "/unused.zip"), generation: 0,
                entryIndex: nil, path: "folder\(folder)", isDirectory: true, revision: 0,
                origin: .base(index: anchor.index, expectedName: anchor.name, baseGeneration: 0))
            XCTAssertEqual(try snapshot.resolve(payload).map(\.index), [folder * 2, folder * 2 + 1])
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
    }

    func testThirtyThousandPendingAdditionsRenameAndRemoveInLinearPasses() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("source")
        try Data([1]).write(to: source)
        let stamp = try ArchiveImportSourceStamp(source)
        var pending = ArchivePendingChanges()
        pending.additions = (0..<30_000).map { .init(id: UUID(), path: "folder/f\($0)", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp) }
        let projection = try ArchivePendingProjection(pending.projection(base: [], generation: 0))
        let plan = ArchiveEditPlan(removals: projection.planningEntries.prefix(15_000).map(ArchiveEditPlan.Entry.init),
            renames: projection.planningEntries.suffix(15_000).map { .init(entry: .init($0), path: "renamed/f\($0.index)") },
            existing: projection.planningEntries)
        let start = ContinuousClock.now
        let next = ArchivePendingEditor.applying(plan, projection: projection, changes: pending, base: [], generation: 0)
        let elapsed = start.duration(to: .now)
        XCTAssertEqual(next.additions.map(\.id), Array(pending.additions.suffix(15_000).map(\.id)))
        XCTAssertEqual(next.additions.map(\.path), (15_000..<30_000).map { "renamed/f\($0)" })
        XCTAssertLessThan(elapsed, .seconds(2))
        print("Pending additions, 30,000 mixed removals and renames: \(elapsed)")
    }

    func testManyRenameCyclesAreBrokenTogetherAndReplayOrderIsValid() throws {
        let count = 2_000
        let base = (0..<(count * 2)).map { entry($0, "\($0 < count ? "a" : "b")/f\($0 % count)") }
        var pending = ArchivePendingChanges()
        for value in base {
            pending.renames[.init(index: value.index, expectedName: value.name, baseGeneration: 0)] =
                "\(value.index < count ? "b" : "a")/f\(value.index % count)"
        }
        let start = ContinuousClock.now
        let plan = try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending)
        XCTAssertEqual(plan.edits.renames.count, count * 3)
        XCTAssertLessThanOrEqual(plan.renamePasses, 3)
        XCTAssertNoThrow(try plan.edits.validate(entries: base, allowsRepeatedRenames: true))
        XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        let progress = Progress(); progress.cancel()
        XCTAssertThrowsError(try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending, progress: progress)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    @MainActor func testRenameCommitMemoizesExactNamesButNotStaleGuards() async throws {
        preserveArchiveWindowFrame()
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        document.addWindowController(controller)
        controller.display(EntryNode.tree(from: try await document.projectedEntries()), session: document.session)
        let view = controller.outlineView
        let row = try XCTUnwrap((0..<view.numberOfRows).first { (view.item(atRow: $0) as? EntryNode)?.name == "a.txt" })
        view.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        controller.renameEntry(nil)
        let validation = try XCTUnwrap(controller.renameValidation), field = try XCTUnwrap(view.renameField)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = "renamed.txt"
        XCTAssertTrue(view.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        await controller.extractionTask?.value
        XCTAssertEqual(validation.validationCount, 1)
        XCTAssertEqual(document.pendingChanges.renames.values.sorted(), ["renamed.txt"])
        let session = ArchiveRenameValidation(selection: ArchiveEditSelection(try await fixture.node("b.txt")),
            entries: try await document.projectedEntries(), state: document.pendingEditor?.prepared)
        _ = try session.plan(for: "café")
        _ = try session.plan(for: "cafe\u{301}")
        _ = try session.plan(for: "café")
        XCTAssertEqual(session.validationCount, 2)
        let currentRow = try XCTUnwrap((0..<view.numberOfRows).first { (view.item(atRow: $0) as? EntryNode)?.name == "b.txt" })
        view.selectRowIndexes(IndexSet(integer: currentRow), byExtendingSelection: false)
        controller.renameEntry(nil)
        let staleValidation = try XCTUnwrap(controller.renameValidation), nextField = try XCTUnwrap(view.renameField)
        let nextEditor = try XCTUnwrap(nextField.currentEditor() as? NSTextView)
        nextEditor.string = "next.txt"
        XCTAssertTrue(view.control(nextField, textShouldEndEditing: nextEditor))
        document.pendingEditor?.replace(document.pendingChanges)
        XCTAssertFalse(view.control(nextField, textShouldEndEditing: nextEditor))
        XCTAssertEqual(staleValidation.validationCount, 1)
        view.cancelRenaming()
    }

    @MainActor func testImportPlanningStampsTreesAndStagingDeletionStayOffMainAndCardsAreLazy() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.projectedEntries()
        let source = try fixture.file("incoming.txt")
        let observations = Mutex<[(ArchiveReservationDiagnostics.Event, Bool)]>([])
        try await ArchiveReservationDiagnostics.observer.withValue({ event, main in observations.withLock { $0.append((event, main)) } }) {
            _ = try await document.append(urls: [source], to: "", progress: Progress(), resolveConflict: { _ in
                XCTFail("No conflict expected"); return .init(choice: .skip)
            })
            try await document.revertPending()
        }
        let events = observations.withLock { $0 }
        for event: ArchiveReservationDiagnostics.Event in [.importPlanning, .sourceVerification, .projection, .tree, .stagingDeletion] {
            XCTAssertTrue(events.contains { $0.0 == event }, "Missing event: \(event)")
            XCTAssertFalse(events.contains { $0.0 == event && $0.1 }, "Main actor event: \(event)")
        }
        XCTAssertFalse(events.contains { $0.0 == .conflictItem })
    }

    @MainActor func testSaveEmptinessDoesNotBuildReplayPlan() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.projectedEntries()
        var pending = ArchivePendingChanges()
        pending.renames[.init(index: 0, expectedName: "a.txt", baseGeneration: 0)] = "./a.txt"
        XCTAssertFalse(pending.hasEffectiveChanges)
        let plans = Mutex(0)
        try await ArchiveReservationDiagnostics.observer.withValue({ event, _ in
            if event == .replayPlan { plans.withLock { $0 += 1 } }
        }) { try await fixture.save() }
        XCTAssertEqual(plans.withLock { $0 }, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testStagingRetirementWaitsForReaderAndDeletesOffMain() async throws {
        let directory = try ArchiveTestDirectory(), registry = StagingRegistry(root: directory.url.appendingPathComponent("Staging"))
        let lease = try registry.create(id: UUID())
        try Data([1]).write(to: lease.directory.appendingPathComponent("only-copy"))
        var reader: StagingRegistry.ReadLease? = try lease.acquireRead()
        let deleted = Mutex<[Bool]>([])
        let task = Task {
            await ArchiveReservationDiagnostics.observer.withValue({ event, main in
                if event == .stagingDeletion { deleted.withLock { $0.append(main) } }
            }) { await lease.removeWhenUnused() }
        }
        await Task.yield()
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.directory.path))
        withExtendedLifetime(reader) {}; reader = nil
        await task.value
        XCTAssertEqual(deleted.withLock { $0 }, [false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.directory.path))
        XCTAssertTrue(try registry.sweep().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: registry.root.path).isEmpty)
    }
    @MainActor func testReservationRechecksRevisionAndCancellationAfterWorkerReturns() async throws {
        for cancellation in [false, true] {
            let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
            defer { gate.release(); document.close() }
            let node = try await fixture.node("a.txt"), progress = Progress()
            let task = Task {
                try await ArchiveReservationDiagnostics.observer.withValue({ event, _ in
                    if event == .planning { gate.pauseOnce() }
                }) { try await document.rename(node, to: "changed.txt", progress: progress) }
            }
            try await scenarioWait { gate.isEntered }
            do {
                _ = try await document.createFolder(in: "", progress: Progress())
                XCTFail("Reservations overlapped")
            } catch { XCTAssertTrue(error is ExtractionFailure) }
            if cancellation { progress.cancel() }
            else { document.pendingEditor?.replace(document.pendingChanges) }
            gate.release()
            do { _ = try await task.value; XCTFail("Stale/cancelled reservation was published") }
            catch {
                if cancellation { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? ArchiveEditError, .staleSelection) }
            }
            XCTAssertTrue(document.pendingChanges.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        }
    }

    func testSweepRecoversDeletionInterruptedAfterTombstoneRename() throws {
        let directory = try ArchiveTestDirectory(), registry = StagingRegistry(root: directory.url.appendingPathComponent("Staging"))
        var owner: StagingRegistry.Lease? = try registry.create(id: UUID())
        let original = try XCTUnwrap(owner?.directory)
        try Data([1]).write(to: original.appendingPathComponent("discarded"))
        let ledger = registry.root.deletingLastPathComponent().appendingPathComponent("staging.json")
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as? [[String: Any]])
        var record = try XCTUnwrap(entries.first)
        let tombstone = registry.root.appendingPathComponent(".KaitoFinder-deleted-" + UUID().uuidString)
        record["path"] = tombstone.path
        record["discardable"] = true
        entries.append(record)
        try JSONSerialization.data(withJSONObject: entries).write(to: ledger)
        try FileManager.default.moveItem(at: original, to: tombstone)
        XCTAssertTrue(try registry.sweep(trash: { _ in XCTFail("Active owner must be retained"); return original }).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.path))
        withExtendedLifetime(owner) {}; owner = nil
        XCTAssertTrue(try registry.sweep(trash: { _ in XCTFail("Discarded copies must not be recovered as user input"); return original }).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
        XCTAssertTrue(try registry.sweep().isEmpty)
    }

}
