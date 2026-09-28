import AppKit
import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredPostSaveTests: XCTestCase {
    @MainActor private func controller(_ fixture: DeferredSaveFixture) async throws -> ArchiveWindowController {
        fixture.document.makeWindowControllers()
        await fixture.document.waitForDeferredPreparationForTesting()
        return try XCTUnwrap(fixture.document.windowControllers.first as? ArchiveWindowController)
    }
    @MainActor private func visible(_ controller: ArchiveWindowController) -> [EntryNode] {
        (0..<controller.outlineView.numberOfRows).compactMap { controller.outlineView.item(atRow: $0) as? EntryNode }
    }

    @MainActor func testSaveCompletesAndDisplaysBeforePreparationWhileReservationsWait() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
        let controller = try await controller(fixture), session = try XCTUnwrap(document.session)
        defer { gate.release(); document.close() }
        let node = try await fixture.node("a.txt")
        _ = try await document.rename(node, to: "renamed.txt", progress: Progress())
        controller.setFilterQuery(".txt")
        let filters = ArchiveTestCounter(), stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
        var completed = false
        let save = Task {
            try await ArchiveTestCounters.mainThreadFilters.withValue(filters) {
                try await ArchiveStageDiagnostics.observer.withValue({ event in
                    if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
                }) {
                    try await ArchiveReservationDiagnostics.observer.withValue({ event, _ in
                        // install は索引を共有するだけ。背景での projection 準備を止める。
                        if event == .projection { gate.pauseOnce() }
                    }) { try await fixture.save(); completed = true }
                }
            }
        }
        try await scenarioWait { gate.isEntered && completed }
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertTrue(visible(controller).contains { $0.path == "renamed.txt" })
        XCTAssertFalse(visible(controller).contains { $0.path == "a.txt" })
        let token = try XCTUnwrap(controller.listLoadingTokenForTesting)
        XCTAssertTrue(controller.isCurrentListLoading(token))
        let reading = try XCTUnwrap(session.pendingReadSnapshot)
        let entries = await session.entries(), entry = try XCTUnwrap(entries.first { $0.name == "renamed.txt" })
        XCTAssertEqual(reading.origin(for: entry), .base(index: entry.index, expectedName: entry.name, baseGeneration: session.generation))
        let reader = try await session.extractionReader()
        XCTAssertEqual(try reader.read(entry), Data("A".utf8))
        let currentNode = try XCTUnwrap(visible(controller).first { $0.path == "renamed.txt" })
        var started = false, finished = false
        let reservation = Task {
            started = true
            defer { finished = true }
            return try await document.rename(currentNode, to: "again.txt", progress: Progress())
        }
        try await scenarioWait { started }
        XCTAssertFalse(finished)
        XCTAssertEqual(filters.value, 0)
        XCTAssertTrue(stages.withLock { $0.contains(.display) })
        gate.release()
        try await save.value
        let result = try await reservation.value
        XCTAssertNil(result.reloadFailure)
        await document.waitForDeferredPreparationForTesting()
        XCTAssertFalse(controller.isCurrentListLoading(token))
    }

    @MainActor func testSplitSaveInstallsReloadedBaseAndQueuedEditWaitsForPreparation() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tarGzip] {
            let fixture = try DeferredSplitSaveFixture(format: format), document = fixture.document, gate = ScenarioGate()
            defer { gate.release(); document.close() }
            // 表示と準備の順序を調べる。file coordination 自体は publisher の試験に委ねる。
            document.splitSaveHooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
            document.makeWindowControllers()
            await document.waitForDeferredPreparationForTesting()
            let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
            let session = try XCTUnwrap(document.session)
            _ = try await document.createFolder(in: "", baseName: "saved", progress: Progress())
            var completed = false
            let save = Task {
                try await ArchiveReservationDiagnostics.observer.withValue({ event, _ in
                    if event == .projection { gate.pauseOnce() }
                }) {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                        document.save(to: fixture.gate, ofType: ArchiveDocumentController.splitVolumeType, for: .saveOperation) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                    completed = true
                }
            }
            try await scenarioWait { gate.isEntered && completed }
            XCTAssertNil(document.deferredReloadFailure)
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertTrue(visible(controller).contains { $0.path == "saved" })
            let snapshot = await session.snapshot(), token = try XCTUnwrap(controller.listLoadingTokenForTesting)
            XCTAssertNotNil(session.volumeLayout)
            XCTAssertEqual(document.pendingEditor?.baseGeneration, snapshot.generation)
            XCTAssertEqual(document.pendingEditor?.base, snapshot.entries)
            XCTAssertNil(document.pendingEditor?.prepared)
            var started = false, finished = false
            let edit = Task {
                started = true
                defer { finished = true }
                return try await document.createFolder(in: "", baseName: "queued", progress: Progress())
            }
            try await scenarioWait { started }
            XCTAssertFalse(finished)
            XCTAssertTrue(document.pendingChanges.isEmpty)
            XCTAssertTrue(controller.isCurrentListLoading(token))
            gate.release()
            try await save.value
            let result = try await edit.value
            XCTAssertNil(result.reloadFailure)
            await document.waitForDeferredPreparationForTesting()
            XCTAssertEqual(document.pendingEditor?.baseGeneration, snapshot.generation)
            XCTAssertEqual(document.pendingEditor?.base, snapshot.entries)
            XCTAssertEqual(document.pendingChanges.createdFolders.map(\.path), ["queued/"])
            XCTAssertNil(controller.listLoadingTokenForTesting)
            XCTAssertFalse(controller.isListLoadingVisible)
            try await fixture.save()
            let saved = await session.entries()
            XCTAssertTrue(saved.contains { $0.name == "saved/" })
            XCTAssertTrue(saved.contains { $0.name == "queued/" })
        }
    }

    @MainActor func testPublishedDisplayFinishesLoadingTokenInBothModesAndReloadPaths() async throws {
        for mode: ArchivePreferences.SaveBehavior in [.immediate, .onSave] {
            for fallback in [false, true] {
                let fixture = try DeferredSaveFixture(behavior: mode), document = fixture.document, gate = ScenarioGate()
                let controller = try await controller(fixture)
                defer { gate.release(); document.close() }
                if mode == .onSave { _ = try await document.createFolder(in: "", baseName: "saved", progress: Progress()) }
                let adoptions = Mutex<[ArchiveReaderAdoption]>([])
                let edit = Task {
                    try await ArchiveSession.readerAdoptionObserverForTesting.withValue({ event in adoptions.withLock { $0.append(event) } }) {
                        try await ArchiveSession.willAdoptReaderForTesting.withValue({ output in
                            if fallback { output.verificationPassword = "different" }
                        }) {
                            try await ArchiveReservationDiagnostics.observer.withValue({ event, main in
                                if event == .tree && !main { gate.pauseOnce() }
                            }) {
                                if mode == .onSave { try await fixture.save() }
                                else { _ = try await document.createFolder(in: "", baseName: "saved", progress: Progress()) }
                            }
                        }
                    }
                }
                try await scenarioWait { gate.isEntered && controller.isListLoadingVisible }
                let token = try XCTUnwrap(controller.listLoadingTokenForTesting)
                XCTAssertEqual(adoptions.withLock { $0 }, [fallback ? .fallback(.password) : .adopted])
                gate.release()
                try await edit.value
                await document.waitForDeferredPreparationForTesting()
                XCTAssertTrue(visible(controller).contains { $0.path == "saved" })
                XCTAssertFalse(controller.isCurrentListLoading(token))
                XCTAssertNil(controller.listLoadingTokenForTesting)
                XCTAssertFalse(controller.isListLoadingVisible)
            }
        }
    }

    @MainActor func testSplitSaveHelperWaitsForPreparationWithoutWindow() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha] {
            let fixture = try DeferredSplitSaveFixture(format: format), document = fixture.document
            defer { document.close() }
            document.splitSaveHooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
            let session = try XCTUnwrap(document.session)
            _ = try await document.createFolder(in: "", baseName: "saved", progress: Progress())
            for _ in 0..<2 {
                try await fixture.save()
                let snapshot = await session.snapshot()
                XCTAssertTrue(document.windowControllers.isEmpty)
                XCTAssertEqual(document.pendingEditor?.baseGeneration, snapshot.generation)
                XCTAssertEqual(document.pendingEditor?.base, snapshot.entries)
                XCTAssertTrue(snapshot.entries.contains { $0.name == "saved/" })
            }
        }
    }

    func testTrustedZIPSkipsPreparationAndNextPublishStillOpensUpdater() async throws {
        let directory = try ArchiveTestDirectory(), url = directory.url.appendingPathComponent("original.zip")
        let writer = try ArchiveWriter.create(url: url)
        try writer.add(data: Data([1]), as: "a"); try writer.finish()
        let session = try ArchiveSession(url: url)
        _ = try await session.deferredSnapshot()
        let events = Mutex<[ArchiveReservationDiagnostics.Event]>([]), stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
        try await ArchiveReservationDiagnostics.observer.withValue({ event, _ in events.withLock { $0.append(event) } }) {
            try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
            }) {
                for index in 0..<2 {
                    let snapshot = try await session.deferredSnapshot()
                    var pending = ArchivePendingChanges()
                    pending.renames[.init(index: 0, expectedName: snapshot.entries[0].name, baseGeneration: snapshot.generation)] = "rename\(index)"
                    let publication = ArchiveSavePublication(); defer { publication.finish() }
                    let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
                    XCTAssertNil(result.reloadFailure)
                    await session.prepareDeferredEditing()
                    _ = try await session.deferredSnapshot()
                }
            }
        }
        XCTAssertFalse(events.withLock { $0.contains(.updaterPreparation) || $0.contains(.deferredUpdaterOpen) })
        XCTAssertFalse(stages.withLock { $0.contains(.updaterPreparation) })
        XCTAssertEqual(stages.withLock { $0.filter { $0 == .updaterOpen }.count }, 2)
        await session.close()
    }

    func testFallbackAndExternalReloadRequireZIPPreparationAgain() async throws {
        for fallback in [false, true] {
            let directory = try ArchiveTestDirectory(), url = directory.url.appendingPathComponent("original.zip")
            let writer = try ArchiveWriter.create(url: url)
            try writer.add(data: Data([1]), as: "a"); try writer.finish()
            let session = try ArchiveSession(url: url), events = Mutex<[ArchiveReservationDiagnostics.Event]>([])
            try await ArchiveSession.willAdoptReaderForTesting.withValue({ output in
                if fallback { output.verificationPassword = "different" }
            }) { _ = try await session.createFolder(in: "", progress: Progress()) }
            if !fallback { try await session.reloadAfterMutation() }
            await ArchiveReservationDiagnostics.observer.withValue({ event, _ in events.withLock { $0.append(event) } }) {
                await session.prepareDeferredEditing()
            }
            XCTAssertEqual(events.withLock { $0.filter { $0 == .updaterPreparation }.count }, 1)
            await session.close()
        }
    }

    func testTrustedGenerationDefersOnlyG4SpecificDefectToNextSave() async throws {
        let directory = try ArchiveTestDirectory(), url = directory.url.appendingPathComponent("original.zip")
        let input = directory.url.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        try Data(repeating: 42, count: 1024).write(to: input.appendingPathComponent("a"))
        try directory.run(ExternalTool.ditto, ["-c", "-k", "--keepParent", input.path, url.path])
        let session = try ArchiveSession(url: url), events = Mutex<[ArchiveReaderAdoption]>([])
        _ = try await session.deferredSnapshot()
        var pending = ArchivePendingChanges(); pending.createdFolders = [.init(id: UUID(), path: "new/")]
        let publication = ArchiveSavePublication(); defer { publication.finish() }
        let result = try await ArchiveSession.readerAdoptionObserverForTesting.withValue({ event in events.withLock { $0.append(event) } }) {
            try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                var data = try Data(contentsOf: work)
                func u16(_ offset: Int) -> Int { data.withUnsafeBytes { Int(UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self))) } }
                func u32(_ offset: Int) -> Int { data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) } }
                let end = data.count - 22
                var central = u32(end + 16), descriptor: Int?
                for _ in 0..<u16(end + 10) {
                    if u16(central + 8) & 8 != 0, u32(central + 24) > 0 {
                        let local = u32(central + 42)
                        let start = local + 30 + u16(local + 26) + u16(local + 28) + u32(central + 20)
                        descriptor = start + (u32(start) == 0x08074b50 ? 4 : 0)
                        break
                    }
                    central += 46 + u16(central + 28) + u16(central + 30) + u16(central + 32)
                }
                let crc = try XCTUnwrap(descriptor, "ditto fixture must have a data descriptor")
                data[crc] ^= 1
                try data.write(to: work)
                // 第二候補: descriptor の CRC だけを変え、G4 固有の検査を固定する。
                XCTAssertNoThrow(try ArchiveReader.open(url: work, options: .kaitoFinderVerification()))
                XCTAssertNoThrow(try ArchiveUpdater.probe(url: work))
                XCTAssertThrowsError(try ArchiveUpdater.open(url: work)) { XCTAssertTrue($0 is UpdaterError) }
            }) { try await session.savePending(pending, baseGeneration: 0, progress: Progress(), publication: publication) }
        }
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(events.withLock { $0 }, [.adopted])
        await session.prepareDeferredEditing()
        let next = try await session.deferredSnapshot()
        XCTAssertTrue(session.capabilities.canEdit)
        let original = try Data(contentsOf: url)
        var later = ArchivePendingChanges(); later.createdFolders = [.init(id: UUID(), path: "later/")]
        let nextPublication = ArchiveSavePublication(); defer { nextPublication.finish() }
        do {
            _ = try await session.savePending(later, baseGeneration: next.generation, progress: Progress(), publication: nextPublication)
            XCTFail("G4 must run at the next publication")
        } catch UpdaterError.invalidArchive { }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(session.capabilities.canEdit)
        await session.close()
    }

    @MainActor func testPreparationFailureKeepsPublishedListAndEndsToken() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        let controller = try await controller(fixture)
        defer { document.close() }
        _ = try await document.createFolder(in: "", baseName: "saved", progress: Progress())
        var errors = 0
        document.presentedErrorObserverForTesting = { _ in errors += 1 }
        try await ArchiveDocument.preparationFailureForTesting.withValue(CocoaError(.fileReadUnknown)) { try await fixture.save() }
        await document.waitForDeferredPreparationForTesting()
        XCTAssertEqual(errors, 1)
        XCTAssertTrue(visible(controller).contains { $0.path == "saved" })
        XCTAssertNil(controller.listLoadingTokenForTesting)
        XCTAssertFalse(document.isDocumentEdited)
    }

    @MainActor func testRevertDisplaysBeforePreparation() async throws { try await assertTransition("revert") }
    @MainActor func testExternalReloadDisplaysBeforePreparation() async throws { try await assertTransition("reload") }
    @MainActor func testSaveAsDisplaysBeforePreparationWithoutStaleErrors() async throws { try await assertTransition("saveAs") }

    @MainActor private func assertTransition(_ action: String) async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
        let controller = try await controller(fixture)
        defer { gate.release(); document.close() }
        _ = try await document.createFolder(in: "", baseName: "pending", progress: Progress())
        var errors = 0, completed = false
        document.presentedErrorObserverForTesting = { _ in errors += 1 }
        if action != "saveAs" {
            let other = fixture.directory.url.appendingPathComponent("replacement.zip")
            let writer = try ArchiveWriter.create(url: other)
            try writer.add(data: Data("changed".utf8), as: "changed"); try writer.finish()
            XCTAssertEqual(Darwin.rename(other.path, fixture.archive.path), 0)
            // 外部再読込は空の予約で呼ぶ。変更ありの Revert は古い予約を捨てる。
            if action == "reload" { try await document.revertPending(); await document.waitForDeferredPreparationForTesting() }
        }
        let creator = ArchiveCreationController(store: fixture.store)
        creator.destinationHandler = { _, _ in fixture.directory.url.appendingPathComponent("saved.zip") }
        let events = Mutex<[ArchiveReservationDiagnostics.Event]>([])
        let task = Task {
            try await ArchiveReservationDiagnostics.observer.withValue({ event, _ in
                events.withLock { $0.append(event) }
                if event == .baseValidation { gate.pauseOnce() }
            }) {
                switch action {
                case "revert": try await document.revertPending()
                case "reload": try await document.reloadAfterMutation()
                default: try await document.savePendingAs(using: creator, on: nil, progress: Progress())
                }
                completed = true
            }
        }
        try await scenarioWait { gate.isEntered }
        XCTAssertFalse(visible(controller).isEmpty)
        let token = try XCTUnwrap(controller.listLoadingTokenForTesting)
        XCTAssertTrue(controller.isCurrentListLoading(token))
        if action != "saveAs" { try await scenarioWait { completed } }
        XCTAssertEqual(errors, 0)
        gate.release()
        try await task.value
        await document.waitForDeferredPreparationForTesting()
        XCTAssertEqual(errors, 0)
        XCTAssertFalse(controller.isCurrentListLoading(token))
        XCTAssertTrue(events.withLock { $0.contains(.updaterPreparation) })
    }


    @MainActor func testNonZIPPreparesAfterDisplay() async throws {
        let fixture = try DeferredSaveFixture(format: .tarGzip), document = fixture.document, gate = ScenarioGate()
        let controller = try await controller(fixture)
        defer { gate.release(); document.close() }
        _ = try await document.createFolder(in: "", baseName: "saved", progress: Progress())
        var completed = false
        let task = Task {
            try await ArchiveReservationDiagnostics.observer.withValue({ event, _ in
                if event == .projection { gate.pauseOnce() }
            }) { try await fixture.save(); completed = true }
        }
        try await scenarioWait { gate.isEntered && completed }
        XCTAssertTrue(visible(controller).contains { $0.path == "saved" })
        XCTAssertNotNil(controller.listLoadingTokenForTesting)
        gate.release()
        try await task.value
        await document.waitForDeferredPreparationForTesting()
    }
}
