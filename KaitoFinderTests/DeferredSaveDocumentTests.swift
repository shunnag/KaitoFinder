import AppKit
@_spi(Testing) import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSaveDocumentTests: XCTestCase {
    @MainActor func testZIPMixedEncryptionSaveUsesStagedRebuildAndKeepsReaderAdoption() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.rename(fixture.node("a.txt"), to: "renamed.txt", progress: Progress())
        _ = try await document.remove([fixture.node("b.txt")], progress: Progress())
        _ = try await document.append(urls: [fixture.file("added.txt")], to: "", progress: Progress())
        _ = try await document.createFolder(in: "", baseName: "new", progress: Progress())
        _ = try await document.updatePassword(.set, settings: .init(password: "first"))
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        let strategies = Mutex<[ArchiveUpdater.CommitStrategy?]>([]), stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
        let adoptions = Mutex<[ArchiveReaderAdoption]>([])
        try await ArchiveImportTransaction.didCommitUpdaterForTesting.withValue({ updater in
            strategies.withLock { $0.append(updater.lastCommitStrategy) }
        }) {
            try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
            }) {
                try await ArchiveSession.readerAdoptionObserverForTesting.withValue({ event in adoptions.withLock { $0.append(event) } }) {
                    try await fixture.save()
                }
            }
        }
        await document.waitForDeferredPreparationForTesting()
        XCTAssertEqual(strategies.withLock { $0 }, [.stagedRebuild])
        XCTAssertTrue(stages.withLock { $0.contains(.updaterOpen) && $0.contains(.replay) })
        XCTAssertFalse(stages.withLock { $0.contains(.rewriterOpen) || $0.contains(.reloadOpen) })
        XCTAssertEqual(adoptions.withLock { $0 }, [.adopted])
        XCTAssertEqual(try DeferredSaveFixture.contents(fixture.archive, password: "first"),
                       ["renamed.txt": Data("A".utf8), "folder/child.txt": Data("child".utf8), "added.txt": Data("new".utf8)])
        XCTAssertEqual(try DeferredSaveFixture.inventory(fixture.archive)["new/"], .directory)
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertFalse(document.isDocumentEdited)
        try ArchiveReencryptionTestSupport.assertEncryption(fixture.archive, settings: .init(password: "first"))
        for action: ArchivePasswordAction in [.change, .remove] {
            let settings = ArchiveEncryptionSettings(password: action == .remove ? nil : "second", zipEncryption: .zipCrypto)
            _ = try await document.updatePassword(action, settings: settings)
            try await fixture.save()
            await document.waitForDeferredPreparationForTesting()
            try ArchiveReencryptionTestSupport.assertEncryption(fixture.archive, settings: settings)
        }
    }

    func testDeferredEncryptionFallbackResetsReplayAndCommitProgress() async throws {
        for fallback in [false, true] {
            let directory = try ArchiveTestDirectory(), url = directory.url.appendingPathComponent("original.zip")
            let writer = try ArchiveWriter.create(url: url, options: .init(password: "old"))
            try writer.add(data: Data("old contents".utf8), as: "old"); try writer.finish()
            let session = try ArchiveSession(url: url, password: "old"), snapshot = try await session.deferredSnapshot()
            var pending = ArchivePendingChanges()
            pending.renames[.init(index: 0, expectedName: "old", baseGeneration: snapshot.generation)] = "renamed"
            pending.outputEncryption = .init(password: "new", zipEncryption: .zipCrypto)
            let progress = Progress(), attempts = Mutex(0), stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
            let resets = Mutex((last: Int64(0), count: 0))
            let observation = progress.observe(\.completedUnitCount) { value, _ in
                resets.withLock {
                    if value.completedUnitCount == 0 && $0.last > 0 { $0.count += 1 }
                    $0.last = value.completedUnitCount
                }
            }
            defer { observation.invalidate() }
            let publication = ArchiveSavePublication(); defer { publication.finish() }
            try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
            }) {
                try await ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
                    attempts.withLock { $0 += 1 }
                    XCTAssertEqual(progress.completedUnitCount, 1)
                    if fallback {
                        progress.completedUnitCount += 300
                        throw UpdaterError.nonRelocatableEntry(index: 0, name: "old", reason: "offset")
                    }
                }) {
                    let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: progress, publication: publication)
                    XCTAssertNil(result.reloadFailure)
                }
            }
            XCTAssertEqual(attempts.withLock { $0 }, 1)
            XCTAssertEqual(resets.withLock { $0.count }, fallback ? 1 : 0)
            XCTAssertTrue(stages.withLock { $0.contains(.updaterOpen) })
            XCTAssertEqual(stages.withLock { $0.contains(.rewriterOpen) }, fallback)
            XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 1)
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
            XCTAssertEqual(try DeferredSaveFixture.contents(url, password: "new"), ["renamed": Data("old contents".utf8)])
            try ArchiveReencryptionTestSupport.assertEncryption(url, settings: pending.outputEncryption!)
            try ArchiveOracle.assertNoWorkFiles(in: directory.url)
            await session.close()
        }
    }

    @MainActor func testDeferredSaveAsCallerCancellationReachesUnstructuredTask() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.createFolder(in: "", baseName: "pending", progress: Progress())
        let creator = ArchiveCreationController(store: fixture.store), progress = Progress()
        var waiting = false
        creator.destinationHandler = { _, _ in
            waiting = true
            try await Task.sleep(for: .seconds(10))
            return nil
        }
        let saving = Task { try await document.savePendingAs(using: creator, on: nil, progress: progress) }
        try await scenarioWait { waiting }
        let worker = try XCTUnwrap(document.deferredSaveTask)
        saving.cancel()
        do { try await saving.value; XCTFail("Cancelled Save As succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(worker.isCancelled)
        XCTAssertTrue(progress.isCancelled)
        XCTAssertNil(creator.savePanel)
        XCTAssertFalse(document.isDeferredSaveRunning)
        XCTAssertEqual(document.pendingChanges.createdFolders.map(\.path), ["pending/"])
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testDeferredSaveAsSheetCancellationReachesWritingTask() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
        defer { gate.release(); document.close() }
        _ = try await document.createFolder(in: "", baseName: "pending", progress: Progress())
        let creator = ArchiveCreationController(store: fixture.store), progress = Progress(), cancelled = Mutex(false)
        let output = fixture.directory.url.appendingPathComponent("saved.zip")
        creator.destinationHandler = { _, _ in output }
        document.deferredWillPublish = {
            gate.pauseOnce()
            cancelled.withLock { $0 = Task.isCancelled }
            try Task.checkCancellation()
        }
        let saving = Task { try await document.savePendingAs(using: creator, on: nil, progress: progress) }
        try await scenarioWait { gate.isEntered }
        let task = try XCTUnwrap(document.deferredSaveTask)
        try XCTUnwrap(creator.progressSheet).cancelExtraction(nil)
        try await scenarioWait { task.isCancelled }
        gate.release()
        do { try await saving.value; XCTFail("Cancelled Save As succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(cancelled.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(document.fileURL, fixture.archive)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        XCTAssertTrue(document.isDocumentEdited)
    }

    @MainActor func testPreferenceIsImmediateByDefaultAndCapturedOnce() throws {
        let defaults = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: defaults.defaults)
        XCTAssertEqual(store.preferences.saveBehavior, .immediate)
        let first = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        store.preferences.saveBehavior = .onSave
        let second = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        store.preferences.saveBehavior = .immediate
        XCTAssertEqual(first.saveBehavior, .immediate)
        XCTAssertEqual(second.saveBehavior, .onSave)
        XCTAssertTrue(second.writableTypes(for: .saveOperation).isEmpty)
        first.close(); second.close()
    }

    @MainActor func testAllSingleFileFormatsReserveUndoRedoAndPublishOnce() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tarGzip, .lha] {
            let fixture = try DeferredSaveFixture(format: format), document = fixture.document
            defer { document.close() }
            let count = Mutex(0)
            document.deferredWillPublish = { count.withLock { $0 += 1 } }
            let source = try fixture.file("added.txt", contents: "snapshot")
            _ = try await document.append(urls: [source], to: "folder", progress: Progress())
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
            let stage = try XCTUnwrap(document.pendingEditor?.staging?.directory)
            let manager = try XCTUnwrap(document.undoManager)
            manager.undo()
            XCTAssertTrue(document.pendingChanges.isEmpty)
            XCTAssertFalse(document.isDocumentEdited)
            manager.redo()
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertEqual(document.pendingChanges.additions.count, 1)
            let folder = try await fixture.node("folder")
            _ = try await document.rename(folder, to: "renamed", progress: Progress())
            XCTAssertEqual(document.pendingChanges.additions.first?.path, "renamed/added.txt")
            _ = try await document.remove([fixture.node("b.txt")], progress: Progress())
            _ = try await document.createFolder(in: "", baseName: "destination", progress: Progress())
            _ = try await document.move([fixture.node("a.txt")], to: "destination", progress: Progress())
            XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
            try Data("changed after reservation".utf8).write(to: source)
            try await fixture.save()
            XCTAssertEqual(count.withLock { $0 }, 1)
            XCTAssertEqual(try DeferredSaveFixture.contents(fixture.archive), [
                "destination/a.txt": Data("A".utf8), "renamed/child.txt": Data("child".utf8),
                "renamed/added.txt": Data("snapshot".utf8)
            ])
            XCTAssertEqual(try DeferredSaveFixture.inventory(fixture.archive), [
                "destination/": .directory, "destination/a.txt": .file, "renamed/": .directory,
                "renamed/child.txt": .file, "renamed/added.txt": .file
            ])
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertFalse(manager.canUndo)
            XCTAssertTrue(document.pendingChanges.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
            let bytes = try Data(contentsOf: fixture.archive)
            try await fixture.save()
            XCTAssertEqual(count.withLock { $0 }, 1)
            XCTAssertEqual(try Data(contentsOf: fixture.archive), bytes)
        }
    }

    @MainActor func testTwoSavesSynchronizeModificationDateAndToken() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        for name in ["first", "second"] {
            _ = try await document.createFolder(in: "", baseName: name, progress: Progress())
            try await fixture.save()
            let date = try FileManager.default.attributesOfItem(atPath: fixture.archive.path)[.modificationDate] as? Date
            XCTAssertEqual(document.fileModificationDate, date)
            XCTAssertFalse(document.isDocumentEdited)
            try await XCTUnwrap(document.session).verifyDeferredIdentity()
        }
    }

    @MainActor func testSwapReservationsAreFoldedFromBaseIndices() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        for (source, destination) in [("a.txt", "temporary.txt"), ("b.txt", "a.txt"), ("temporary.txt", "b.txt")] {
            _ = try await document.rename(fixture.node(source), to: destination, progress: Progress())
        }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        try await fixture.save()
        let saved = try DeferredSaveFixture.contents(fixture.archive)
        XCTAssertEqual(saved["a.txt"], Data("B".utf8))
        XCTAssertEqual(saved["b.txt"], Data("A".utf8))
    }

    @MainActor func testAddThenDeleteSavesWithoutPublishingOrChangingMtime() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let before = document.fileModificationDate
        _ = try await document.append(urls: [fixture.file("added")], to: "", progress: Progress())
        _ = try await document.remove([fixture.node("added")], progress: Progress())
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertTrue(document.isDocumentEdited)
        document.deferredWillPublish = { XCTFail("An empty folded plan must not publish") }
        try await fixture.save()
        XCTAssertEqual(document.fileModificationDate, before)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertNil(document.pendingEditor?.staging)
    }

    @MainActor func testRevertDropsStagingAndUndoWithoutReopeningUnchangedReader() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.append(urls: [fixture.file("added")], to: "", progress: Progress())
        let stage = try XCTUnwrap(document.pendingEditor?.staging?.directory), generation = document.generation
        try await document.revertPending()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertEqual(document.generation, generation)
        XCTAssertFalse(document.undoManager!.canUndo)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testExternalChangeSaveFailsAndRevertReloads() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.createFolder(in: "", baseName: "pending", progress: Progress())
        let other = fixture.directory.url.appendingPathComponent("other.zip")
        let writer = try ArchiveWriter.create(url: other)
        try writer.add(data: Data("external".utf8), as: "external")
        try writer.finish()
        let changed = try Data(contentsOf: other)
        try changed.write(to: fixture.archive, options: .atomic)
        do { try await fixture.save(); XCTFail("External replacement must be refused") } catch { }
        XCTAssertEqual(document.pendingChanges.createdFolders.count, 1)
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), changed)
        try await document.revertPending()
        XCTAssertEqual(document.generation, 1)
        XCTAssertFalse(document.isDocumentEdited)
        let entries = try await document.projectedEntries()
        XCTAssertEqual(entries.map(\.name), ["external"])
    }

    @MainActor func testCloseWithoutSavingIsIdempotentAndCleanupOutlivesDocumentList() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        _ = try await document.append(urls: [fixture.file("added")], to: "", progress: Progress())
        let stage = try XCTUnwrap(document.pendingEditor?.staging?.directory)
        document.close()
        let cleanup = document.stagingCleanup
        document.close()
        XCTAssertTrue(DocumentCleanupRegistry.shared.hasPendingCleanup)
        await cleanup?.value
        await DocumentCleanupRegistry.shared.waitUntilEmpty()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testPendingReplacementUsesStagedConflictSourceAndParentRemovalDropsAddition() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let source = try fixture.file("added")
        _ = try await document.append(urls: [source], to: "folder", progress: Progress())
        let staged = try XCTUnwrap(document.pendingChanges.additions.first?.stagedURL)
        _ = try await document.append(urls: [source], to: "folder", progress: Progress(), resolveConflict: { conflict in
            guard case .file(let url) = conflict.existing.source else { XCTFail("Must compare the staged file"); return .init(choice: .skip) }
            XCTAssertEqual(url, staged)
            return .init(choice: .replace)
        })
        XCTAssertEqual(document.pendingChanges.additions.count, 1)
        _ = try await document.remove([fixture.node("folder")], progress: Progress())
        XCTAssertTrue(document.pendingChanges.additions.isEmpty)
        document.undoManager?.undo()
        XCTAssertEqual(document.pendingChanges.additions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "Undo history keeps every staged snapshot")
    }

    @MainActor func testPasswordAdoptsNewKeyOnlyAfterSave() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip] {
            let fixture = try DeferredSaveFixture(format: format), document = fixture.document
            defer { document.close() }
            _ = try await document.updatePassword(.set, settings: .init(password: "new-key"), progress: Progress())
            XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
            let before = await document.session?.password
            XCTAssertNil(before)
            XCTAssertTrue(document.isDocumentEdited)
            try await fixture.save()
            let after = await document.session?.password
            XCTAssertEqual(after, "new-key")
            XCTAssertEqual(try DeferredSaveFixture.contents(fixture.archive, password: "new-key")["a.txt"], Data("A".utf8))
            XCTAssertFalse(document.isDocumentEdited)
        }
    }
}

extension DeferredSaveDocumentTests {
    @MainActor func testLateEditWaitsForSaveAndRemainsPendingAndDirty() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document, gate = ScenarioGate()
        defer { gate.release(); document.close() }
        _ = try await document.createFolder(in: "", baseName: "first", progress: Progress())
        document.deferredWillPublish = { gate.pauseOnce() }
        let saving = Task { try await fixture.save() }
        try await scenarioWait { gate.isEntered }
        XCTAssertTrue(document.isDeferredSaveRunning)
        XCTAssertFalse(document.undoManager!.canUndo)
        let late = Task { try await document.createFolder(in: "", baseName: "late", progress: Progress()) }
        await Task.yield()
        XCTAssertFalse(document.pendingChanges.createdFolders.contains { $0.path == "late/" })
        // AppKit の後着した変更数も token によって保存済みとは扱われない。
        document.updateChangeCount(.changeDone)
        gate.release()
        try await saving.value
        _ = try await late.value
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertEqual(document.pendingChanges.createdFolders.map(\.path), ["late/"])
        XCTAssertTrue(try ArchiveReader.open(url: fixture.archive).entries.contains { $0.name == "first/" })
        XCTAssertFalse(try ArchiveReader.open(url: fixture.archive).entries.contains { $0.name == "late/" })
        try await fixture.save()
        XCTAssertFalse(document.isDocumentEdited)
    }

    @MainActor func testCancelledSaveKeepsReservationsAndStaging() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.append(urls: [fixture.file("added")], to: "", progress: Progress())
        let staged = try XCTUnwrap(document.pendingChanges.additions.first?.stagedURL)
        document.deferredWillPublish = { throw CancellationError() }
        do { try await fixture.save(); XCTFail("Injected cancellation must fail") } catch { }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertTrue(document.undoManager!.canUndo)
        document.deferredWillPublish = nil
        try await fixture.save()
        XCTAssertFalse(document.isDocumentEdited)
    }

    @MainActor func testSaveAsReplaysPendingPathsAndSwitchesWithoutChangingOriginal() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.append(urls: [fixture.file("added")], to: "folder", progress: Progress())
        _ = try await document.rename(fixture.node("folder"), to: "renamed", progress: Progress())
        _ = try await document.remove([fixture.node("b.txt")], progress: Progress())
        let stage = try XCTUnwrap(document.pendingEditor?.staging?.directory)
        let destination = fixture.directory.url.appendingPathComponent("saved.7z")
        let creator = ArchiveCreationController(store: fixture.store)
        creator.destinationHandler = { save, _ in
            save.formatPopup.selectItem(at: try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: .sevenZip)))
            save.changeFormat(save.formatPopup)
            return destination
        }
        try await document.savePendingAs(using: creator, on: nil, progress: Progress())
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        XCTAssertEqual(document.fileURL, destination)
        XCTAssertEqual(document.session?.sourceURL, destination)
        XCTAssertEqual(try DeferredSaveFixture.contents(destination), ["a.txt": Data("A".utf8),
            "renamed/child.txt": Data("child".utf8), "renamed/added": Data("new".utf8)])
        XCTAssertEqual(try DeferredSaveFixture.inventory(destination), ["a.txt": .file, "renamed/": .directory,
            "renamed/child.txt": .file, "renamed/added": .file])
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertFalse(document.undoManager!.canUndo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }

    @MainActor func testUnchangedBaseCopyUsesExistingExtractionThenStagesBeforeTemporaryInputDisappears() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let session = try XCTUnwrap(document.session), node = try await fixture.node("a.txt")
        let temporary = fixture.directory.url.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let payload = ArchiveEntryPayload(node: node, session: session, generation: document.generation)
        let result = try await ExtractionService.extract([payload], from: session, to: temporary, progress: Progress())
        try ArchiveCopyOut.check(result)
        let source = temporary.appendingPathComponent("a.txt")
        _ = try await document.append(urls: [source], to: "folder", progress: Progress())
        try FileManager.default.removeItem(at: temporary)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        try await fixture.save()
        XCTAssertEqual(try DeferredSaveFixture.contents(fixture.archive)["folder/a.txt"], Data("A".utf8))
    }

    @MainActor func testSplitReservationsLeaveEveryVolumeUnchangedUntilSave() async throws {
        let fixture = try SplitArchiveFixture(), defaults = try ArchivePreferencesTestDefaults()
        let store = ArchivePreferencesStore(defaults: defaults.defaults)
        store.preferences.saveBehavior = .onSave
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        defer { document.close() }
        try document.read(from: fixture.archive, ofType: "public.data")
        let before = try fixture.volumes.map { try Data(contentsOf: $0) }
        _ = try await document.createFolder(in: "", progress: Progress())
        XCTAssertFalse(document.pendingChanges.isEmpty)
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertEqual(try fixture.volumes.map { try Data(contentsOf: $0) }, before)
    }

    @MainActor func testDeferredFolderEnumerationExcludesApplicationWorkNames() async throws {
        let fixture = try DeferredSaveFixture(), document = fixture.document
        defer { document.close() }
        let source = fixture.directory.url.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data([1]).write(to: source.appendingPathComponent("keep"))
        try Data([2]).write(to: source.appendingPathComponent(".KaitoFinder-stage-hidden"))
        _ = try await document.append(urls: [source], to: "", progress: Progress())
        XCTAssertEqual(Set(document.pendingChanges.additions.map(\.path)), ["source", "source/keep"])
        try await document.revertPending()
    }
}
