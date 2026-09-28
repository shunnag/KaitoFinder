import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSplitSaveTests: XCTestCase {
    @MainActor func testZIPPasswordMixedSavesUseUpdaterAndOnlyNonRelocatableFallsBack() async throws {
        for fallback in [false, true] {
            try await ArchiveReencryptionTestSupport.splitPasswordLifecycle(behavior: .onSave, fallback: fallback)
        }
    }

    @MainActor func testSplitReencryptionFailureKeepsOriginalCapabilityAndPendingChanges() async throws {
        for behavior: ArchivePreferences.SaveBehavior in [.onSave, .immediate] {
            let fixture = try DeferredSplitSaveFixture(format: .zip, behavior: behavior), document = fixture.document
            defer { document.close() }
            document.splitSaveHooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
            document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
            let session = try XCTUnwrap(document.session), prompts = Mutex(0), stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
            session.setPasswordPrompt { _ in prompts.withLock { $0 += 1 }; throw CancellationError() }
            do {
                try await ArchiveStageDiagnostics.observer.withValue({ event in
                    if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
                }) {
                    try await ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
                        throw UpdaterError.reencryptionFailed(index: 0, name: "file0.txt", reason: "verification")
                    }) {
                        _ = try await document.updatePassword(.set, settings: .init(password: "new"))
                        if behavior == .onSave { try await fixture.save() }
                    }
                }
                XCTFail("Re-encryption failure must not publish")
            } catch { }
            XCTAssertEqual(document.splitSaveFailure?.kind, .failed)
            XCTAssertTrue(session.capabilities.canEdit)
            XCTAssertFalse(session.requiresSplitRecovery)
            XCTAssertFalse(stages.withLock { $0.contains(.rewriterOpen) })
            XCTAssertEqual(prompts.withLock { $0 }, 0)
            XCTAssertEqual(try fixture.parts(), fixture.original)
            XCTAssertEqual(document.pendingChanges.outputEncryption != nil, behavior == .onSave)
        }
    }

    @MainActor func testSplitPasswordVerificationRejectsOnePlainFile() async throws {
        let fixture = try DeferredSplitSaveFixture(format: .zip), document = fixture.document
        defer { document.close() }
        document.splitSaveHooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
        let mixed = fixture.directory.url.appendingPathComponent("mixed.zip")
        let writer = try ArchiveWriter.create(url: mixed, options: .init(password: "new"))
        for name in fixture.contents.keys.sorted() where name != "file1.txt" { try writer.add(data: fixture.contents[name]!, as: name) }
        try writer.finish()
        let updater = try ArchiveUpdater.open(url: mixed)
        try updater.add(data: fixture.contents["file1.txt"]!, as: "file1.txt", modificationDate: nil, permissions: nil)
        try updater.commit()
        let incorrect = try Data(contentsOf: mixed)
        document.splitSaveHooks.didProduceWork = { try incorrect.write(to: $0) }
        _ = try await document.updatePassword(.set, settings: .init(password: "new"))
        do { try await fixture.save(); XCTFail("Mixed encryption must not publish") } catch { }
        XCTAssertEqual(try fixture.parts(), fixture.original)
        XCTAssertTrue(try XCTUnwrap(document.session).capabilities.canEdit)
        XCTAssertNotNil(document.pendingChanges.outputEncryption)
    }

    @MainActor func testZIPPasswordWorkProducerProgressFallbackAndRealFailures() async throws {
        for encryption in [false, true] {
            for failure: UpdaterError? in [nil, .nonRelocatableEntry(index: 0, name: "file", reason: "offset"),
                                           .reencryptionFailed(index: 0, name: "file", reason: "verification")] {
                let fixture = try DeferredSplitSaveFixture(format: .zip), session = try XCTUnwrap(fixture.document.session)
                defer { fixture.document.close() }
                let snapshot = try await session.deferredSnapshot(), layout = try XCTUnwrap(session.volumeLayout)
                let source = try ArchiveVolumeInput(layout: layout, expected: await session.sourceIdentity)
                let work = fixture.directory.url.appendingPathComponent("work.zip"), progress = Progress(totalUnitCount: 2)
                var pending = ArchivePendingChanges()
                pending.renames[.init(index: 0, expectedName: "file0.txt", baseGeneration: snapshot.generation)] = "renamed.txt"
                if encryption { pending.outputEncryption = .init(password: "new") }
                let options = (pending.outputEncryption ?? .init()).applying(to: .init(), format: .zip)
                let plan = try ArchiveSaveReplayPlan(base: snapshot.entries, generation: snapshot.generation, pending: pending, format: .zip)
                let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
                do {
                    let result = try ArchiveStageDiagnostics.observer.withValue({ event in
                        if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
                    }) {
                        try ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
                            if let failure { progress.completedUnitCount += 300; throw failure }
                        }) {
                            try ArchiveSplitWorkProducer.produce(source: source, workURL: work, mode: .inPlace, password: nil,
                                options: options, plan: plan, progress: progress, verifyAssembledInput: { try source.verify($0) })
                        }
                    }
                    let fallback: Bool
                    if case .nonRelocatableEntry = failure { fallback = true } else { fallback = false }
                    XCTAssertTrue(failure == nil || encryption && fallback)
                    XCTAssertEqual(result.recompressedZIP, fallback)
                    XCTAssertEqual(result.mode, fallback ? .rewrite(.zip) : .inPlace)
                    XCTAssertEqual(progress.totalUnitCount, fallback ? 6 : encryption ? 1002 : 2)
                    XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount - 1)
                    try ArchiveSplitWorkProducer.validate(ArchiveReader.open(url: work, options: .kaitoFinder(password: options.password)),
                        plan: plan, mode: result.mode, zipEncryption: encryption ? .init(options) : nil)
                } catch {
                    XCTAssertEqual(error as? UpdaterError, failure)
                    XCTAssertFalse(stages.withLock { $0.contains(.rewriterOpen) })
                    if case UpdaterError.reencryptionFailed = error { XCTAssertNil(ArchivePasswordChallenge(error)) }
                }
                XCTAssertEqual(try fixture.parts(), fixture.original)
            }
        }
    }

    @MainActor func testEveryWritableNumberedFormatReplaysOnceAndSecondSaveDoesNothing() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.sevenZip, .tar, .tarGzip, .tarBzip2, .tarXZ, .lha, .zip] {
            let fixture = try DeferredSplitSaveFixture(format: format), document = fixture.document
            defer { document.close() }
            XCTAssertTrue(document.session!.capabilities.splitSave)
            XCTAssertTrue(document.session!.usesPendingReading)
            let count = Mutex(0)
            let presenterID = ObjectIdentifier(document)
            document.splitSaveHooks.willBegin = { target in
                XCTAssertEqual(target.filePresenter.map(ObjectIdentifier.init), presenterID)
                count.withLock { $0 += 1 }
            }
            _ = try await document.append(urls: [fixture.file()], to: "", progress: Progress())
            _ = try await document.remove([fixture.node("file0.txt")], progress: Progress())
            _ = try await document.rename(fixture.node("file1.txt"), to: "renamed.txt", progress: Progress())
            let staging = try XCTUnwrap(document.pendingEditor?.staging?.directory)
            XCTAssertEqual(try fixture.parts(), fixture.original)
            XCTAssertTrue(document.isDocumentEdited)
            var expected = fixture.contents
            expected.removeValue(forKey: "file0.txt")
            expected["renamed.txt"] = expected.removeValue(forKey: "file1.txt")
            expected["added.txt"] = DeferredSplitSaveFixture.bytes(6000)
            try await fixture.save()
            try fixture.assertSaved(expected: expected)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
            XCTAssertFalse(document.undoManager!.canUndo)
            let before = try fixture.parts(), identity = await document.session!.sourceIdentity
            try await fixture.save()
            XCTAssertEqual(try fixture.parts(), before)
            let after = await document.session!.sourceIdentity
            XCTAssertEqual(after, identity)
            XCTAssertEqual(count.withLock { $0 }, 1)
            // Fetch a node from the new generation before making another reservation.
            _ = try await document.rename(fixture.node("renamed.txt"), to: "again.txt", progress: Progress())
            try await fixture.save()
            expected["again.txt"] = expected.removeValue(forKey: "renamed.txt")
            XCTAssertEqual(try DeferredSaveFixture.contents(fixture.gate), expected)
            XCTAssertEqual(count.withLock { $0 }, 2)
        }
    }

    @MainActor func testGrowAndShrinkUseWrittenLengthWithoutStaleTails() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.sevenZip, .tar, .tarGzip, .tarBzip2, .tarXZ, .lha, .zip] {
            let grow = try DeferredSplitSaveFixture(format: format, count: 3)
            defer { grow.document.close() }
            _ = try await grow.document.append(urls: [grow.file(count: 18_000)], to: "", progress: Progress())
            try await grow.save()
            var expected = grow.contents; expected["added.txt"] = DeferredSplitSaveFixture.bytes(18_000)
            try grow.assertSaved(expected: expected)
            let grownLength = try XCTUnwrap(grow.work.bytes).count
            let grownCount = (grownLength + grow.size - 1) / grow.size
            XCTAssertGreaterThan(grownCount, grow.original.count, "\(format)")
            XCTAssertEqual(try grow.parts().count, grownCount, "\(format)")
            let shrink = try DeferredSplitSaveFixture(format: format, fullLastZIP: format == .zip)
            defer { shrink.document.close() }
            if format == .zip { XCTAssertEqual(shrink.original.last?.count, shrink.size) }
            for name in ["file1.txt", "file2.txt", "file3.txt"] {
                _ = try await shrink.document.remove([shrink.node(name)], progress: Progress())
            }
            try await shrink.save()
            try shrink.assertSaved(expected: ["file0.txt": shrink.contents["file0.txt"]!])
            let shrunkLength = try XCTUnwrap(shrink.work.bytes).count
            let shrunkCount = (shrunkLength + shrink.size - 1) / shrink.size
            XCTAssertLessThan(shrunkCount, shrink.original.count, "\(format)")
            XCTAssertEqual(try shrink.parts().count, shrunkCount, "\(format)")
            for index in shrink.original.indices.dropFirst(shrunkCount) {
                XCTAssertFalse(FileManager.default.fileExists(atPath: shrink.gate.deletingPathExtension().appendingPathExtension(String(format: "%03d", index + 1)).path))
            }
        }
    }

    @MainActor func testOneVolumeReopenRestoresScheduleAndSplitsAgain() async throws {
        let fixture = try DeferredSplitSaveFixture(count: 3)
        defer { fixture.document.close() }
        for name in ["file1.txt", "file2.txt", "file3.txt"] { _ = try await fixture.document.remove([fixture.node(name)], progress: Progress()) }
        try await fixture.save()
        XCTAssertEqual(try fixture.parts().count, 1)
        let layout = try ArchiveVolumeMetadata.read(ArchiveVolumeMetadata.Layout.self, key: ArchiveVolumeMetadata.layoutKey, at: fixture.gate)
        XCTAssertEqual(layout?.schedule, .uniform(size: UInt64(fixture.size)))
        try await fixture.reopen()
        XCTAssertEqual(fixture.document.session?.volumeLayout?.savedSchedule, .uniform(size: UInt64(fixture.size)))
        _ = try await fixture.document.append(urls: [fixture.file(count: 40_000)], to: "", progress: Progress())
        try await fixture.save()
        XCTAssertGreaterThan(try fixture.parts().count, 1)
        XCTAssertTrue(try fixture.parts().dropLast().allSatisfy { $0.count == fixture.size })
    }

    @MainActor func testUnevenChooserAllOptionsAreRememberedAndCancelKeepsPending() async throws {
        for choice: ArchiveSplitScheduleChoice in [.original, .mostCommon, .single, .size(65536)] {
            let fixture = try DeferredSplitSaveFixture(uneven: true), document = fixture.document
            defer { document.close() }
            let layout = try XCTUnwrap(document.session?.volumeLayout)
            var calls = 0
            document.splitScheduleChooser = { _, tooMany in XCTAssertFalse(tooMany); calls += 1; return choice }
            _ = try await document.append(urls: [fixture.file(count: 50_000)], to: "", progress: Progress())
            try await fixture.save()
            var expected = fixture.contents; expected["added.txt"] = DeferredSplitSaveFixture.bytes(50_000)
            try fixture.assertSaved(expected: expected, schedule: choice.schedule(for: layout))
            _ = try await document.createFolder(in: "", baseName: "next", progress: Progress())
            try await fixture.save()
            XCTAssertEqual(calls, 1)
        }
        let fixture = try DeferredSplitSaveFixture(uneven: true)
        defer { fixture.document.close() }
        fixture.document.splitScheduleChooser = { _, _ in throw CancellationError() }
        fixture.document.splitSaveHooks.willBegin = { _ in XCTFail("Choice must precede begin") }
        _ = try await fixture.document.createFolder(in: "", progress: Progress())
        do { try await fixture.save(); XCTFail("Cancelled") }
        catch { XCTAssertEqual((error as NSError).code, NSUserCancelledError) }
        XCTAssertTrue(fixture.document.isDocumentEdited)
        XCTAssertEqual(try fixture.parts(), fixture.original)
    }

    @MainActor func testHazardConsentBeforeOneBeginAndOncePerDocument() async throws {
        let fixture = try DeferredSplitSaveFixture(), document = fixture.document
        defer { document.close() }
        document.splitSaveHooks.operations.volumeInfo = { directory in
            let value = try VolumePublishFS.volumeInfo(directory)
            return .init(uuid: value.uuid, cacheIdentity: value.cacheIdentity, fileSystem: value.fileSystem,
                         available: value.available, hazard: "file-provider")
        }
        var allow = false, prompts = 0
        document.splitHazardConsent = { _ in prompts += 1; return allow }
        let begins = Mutex(0)
        document.splitSaveHooks.willBegin = { _ in begins.withLock { $0 += 1 } }
        _ = try await document.createFolder(in: "", progress: Progress())
        do { try await fixture.save(); XCTFail("Consent is required") } catch { }
        XCTAssertEqual(begins.withLock { $0 }, 0)
        XCTAssertEqual(try fixture.parts(), fixture.original)
        XCTAssertTrue(document.isDocumentEdited)
        allow = true
        try await fixture.save()
        _ = try await document.createFolder(in: "", progress: Progress())
        try await fixture.save()
        XCTAssertEqual(prompts, 2); XCTAssertEqual(begins.withLock { $0 }, 2)
        XCTAssertEqual(ArchiveSplitSaveSheet.hazardAlert().buttons[0].keyEquivalent, "\r")
    }

    @MainActor func testCoordinationTimeoutUsesDocumentPresenterAndNeverEntersS5() async throws {
        let fixture = try DeferredSplitSaveFixture(), document = fixture.document
        defer { document.close() }
        document.splitSaveHooks.coordinationTimeout = 0.02
        document.splitSaveHooks.operations.coordinate = { _, _, _, _ in } // deliberately never completes
        let presenterID = ObjectIdentifier(document)
        document.splitSaveHooks.willBegin = { target in XCTAssertEqual(target.filePresenter.map(ObjectIdentifier.init), presenterID) }
        document.splitSaveHooks.fault = { step in if step == .s5 { XCTFail("Must fail closed before S5") } }
        _ = try await document.createFolder(in: "", progress: Progress())
        do { try await fixture.save(); XCTFail("Timeout") } catch { }
        XCTAssertEqual(document.splitSaveFailure?.kind, .coordination)
        XCTAssertTrue(document.isDocumentEdited); XCTAssertFalse(document.pendingChanges.isEmpty)
        XCTAssertEqual(try fixture.parts(), fixture.original)
        XCTAssertTrue(document.session!.capabilities.canEdit)
        XCTAssertTrue(try fixture.index.entries().isEmpty)
    }

    @MainActor func testExternalThirdVolumeChangeAfterReservationRefusesSave() async throws {
        let fixture = try DeferredSplitSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.createFolder(in: "", progress: Progress())
        try SplitArchiveFixture.changeByte(fixture.gate.deletingPathExtension().appendingPathExtension("003"))
        let before = try fixture.parts()
        document.splitSaveHooks.willBegin = { _ in XCTFail("Must verify before begin") }
        do { try await fixture.save(); XCTFail("Changed input") } catch { }
        XCTAssertEqual(try fixture.parts(), before)
        XCTAssertTrue(document.isDocumentEdited); XCTAssertFalse(document.pendingChanges.isEmpty)
    }

    @MainActor func testProvenRollbackKeepsPendingAndCanRetryWithoutReopening() async throws {
        let fixture = try DeferredSplitSaveFixture(), document = fixture.document
        defer { fixture.document.close() }
        _ = try await document.createFolder(in: "", progress: Progress())
        document.splitSaveHooks.fault = { if $0 == .s7 { throw VolumePublishError.validationFailed } }
        do { try await fixture.save(); XCTFail("Rolled back") } catch { }
        XCTAssertEqual(document.splitSaveFailure?.kind, .rolledBack)
        XCTAssertEqual(try fixture.parts(), fixture.original)
        XCTAssertTrue(document.isDocumentEdited); XCTAssertFalse(document.pendingChanges.isEmpty)
        XCTAssertTrue(document.session!.capabilities.canEdit)
        XCTAssertFalse(document.session!.requiresSplitRecovery)
        XCTAssertTrue(document.validateUserInterfaceItem(NSMenuItem(title: "Save", action: #selector(ArchiveDocument.saveArchiveDocument(_:)), keyEquivalent: "")))
        try await document.session!.verifyDeferredIdentity()
        document.splitSaveHooks.fault = { _ in }
        try await fixture.save()
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertTrue(document.pendingChanges.isEmpty)
    }

    @MainActor func testEncryptedSplitRequiresPasswordBeforeReservations() async throws {
        let fixture = try DeferredSplitSaveFixture(format: .zip, writerOptions: WriterOptions(password: "secret"))
        defer { fixture.document.close() }
        XCTAssertEqual(fixture.document.session!.capabilities.refusal, .encrypted)
        do { _ = try await fixture.document.createFolder(in: "", progress: Progress()); XCTFail("Password is required") } catch { }
        let unlocked = try ArchiveSession(url: fixture.gate, password: "secret", allowsSplitSave: true,
                                         volumeMetadataStore: fixture.metadata)
        XCTAssertTrue(unlocked.capabilities.splitSave)
        await unlocked.close()
        XCTAssertEqual(try fixture.parts(), fixture.original)
    }

    @MainActor func testCommittedCleanupWarningIsSuccessAndHeldVerificationKeepsPending() async throws {
        let committed = try DeferredSplitSaveFixture(), document = committed.document
        defer { document.close() }
        _ = try await document.createFolder(in: "", progress: Progress())
        document.splitSaveHooks.fault = { if $0 == .committed { throw VolumePublishError.system(EIO) } }
        try await committed.save()
        XCTAssertFalse(document.isDocumentEdited); XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertNotNil(document.splitSaveNotice)
        let held = try DeferredSplitSaveFixture(), other = held.document, gate = held.gate
        defer { other.close() }
        _ = try await other.createFolder(in: "", progress: Progress())
        other.splitSaveHooks.operations.openReader = { url, options in
            if url == gate { throw VolumePublishError.validationFailed }
            return try ArchiveReader.open(url: url, options: options)
        }
        do { try await held.save(); XCTFail("Held") } catch { }
        XCTAssertEqual(other.splitSaveFailure?.kind, .held)
        XCTAssertTrue(other.isDocumentEdited); XCTAssertFalse(other.pendingChanges.isEmpty)
        XCTAssertFalse(other.session!.capabilities.canEdit)
        XCTAssertNotNil(other.splitSaveFailure?.staging)
        XCTAssertTrue(other.splitSaveFailure!.recoveryOptions.contains(String(localized: "Finderで表示")))
        do { try await other.revertPending(); XCTFail("Read-only until reopened") } catch { }
    }

    @MainActor func testCrashS7MemberOpenOffersRecoveryBeforeMissingGateNormalization() async throws {
        let fixture = try DeferredSplitSaveFixture(), document = fixture.document
        defer { fixture.document.close() }
        _ = try await document.createFolder(in: "", progress: Progress())
        document.splitSaveHooks.fault = { if $0 == .s7 { throw SimulatedCrash() } }
        do { try await fixture.save(); XCTFail("Crash") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.gate.path))
        let member = fixture.gate.deletingPathExtension().appendingPathExtension("003")
        let controller = ArchiveDocumentController()
        controller.volumeRecoveryIndex = fixture.index; controller.volumeMetadataStore = fixture.metadata
        let error: (any Error)? = await withCheckedContinuation { continuation in
            controller.openDocument(withContentsOf: member, display: false) { opened, _, error in
                XCTAssertNil(opened); continuation.resume(returning: error)
            }
        }
        let presented = try XCTUnwrap(error as NSError?)
        let offer = try XCTUnwrap(presented.userInfo[NSRecoveryAttempterErrorKey] as? ArchiveVolumeRecoveryAttempter).offer
        XCTAssertEqual(offer.recovery.gate.resolvingSymlinksInPath(), fixture.gate.resolvingSymlinksInPath())
        XCTAssertEqual(offer.recoverySuggestion, String(localized: "中断した保存を完了して開く"))
        document.close(); await document.sessionCleanup?.value
        let results = await offer.recovery.recover()
        for result in results { guard case .recovered = result else { XCTFail("\(result)"); return } }
        let restored = try fixture.parts().reduce(into: Data()) { $0.append($1) }
        XCTAssertTrue(restored == fixture.original.reduce(into: Data()) { $0.append($1) } || restored == fixture.work.bytes)
        XCTAssertTrue(try fixture.index.entries().isEmpty)
        try await fixture.reopen()
        XCTAssertTrue(fixture.document.session!.capabilities.splitSave)
    }

    @MainActor func testMixedNativeXattrsRefuseEditingButRemainReadable() async throws {
        let fixture = try DeferredSplitSaveFixture()
        defer { fixture.document.close() }
        _ = try await fixture.document.createFolder(in: "", progress: Progress())
        try await fixture.save()
        let part = fixture.gate.deletingPathExtension().appendingPathExtension("003")
        let marker = try XCTUnwrap(ArchiveVolumeMetadata.read(ArchiveVolumeMetadata.Marker.self, key: ArchiveVolumeMetadata.setKey, at: part))
        let bad = ArchiveVolumeMetadata.Marker(setUUID: UUID(), generation: marker.generation + 1, index: 0,
                                               count: marker.count, totalSHA256: marker.totalSHA256)
        let data = try JSONEncoder().encode(bad)
        XCTAssertEqual(data.withUnsafeBytes { setxattr(part.path, ArchiveVolumeMetadata.setKey, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 0)
        try await fixture.reopen()
        XCTAssertEqual(fixture.document.session?.capabilities.refusal, .mixedVolumes)
        XCTAssertEqual(try DeferredSaveFixture.contents(fixture.gate), fixture.contents)
        do { _ = try await fixture.document.createFolder(in: "", progress: Progress()); XCTFail("Mixed") } catch { }
    }

    @MainActor func testPendingExtractionUsesAssembledSetAndStagedAddition() async throws {
        let fixture = try DeferredSplitSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.rename(fixture.node("file2.txt"), to: "renamed.txt", progress: Progress())
        _ = try await document.append(urls: [fixture.file()], to: "", progress: Progress())
        let session = try XCTUnwrap(document.session), destination = fixture.directory.url.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let nodes = try await [fixture.node("renamed.txt"), fixture.node("added.txt")]
        let payloads = nodes.map { ArchiveEntryPayload(node: $0, session: session, generation: session.generation) }
        let result = try await ExtractionService.extract(payloads, from: session, to: destination, progress: Progress())
        try ArchiveCopyOut.check(result)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("renamed.txt")), fixture.contents["file2.txt"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("added.txt")), DeferredSplitSaveFixture.bytes(6000))
    }

    @MainActor func testZIPGatekeeperFallsBackToRewriterAndReportsNotice() async throws {
        let fixture = try DeferredSplitSaveFixture(format: .zip, trailingZIP: true)
        defer { fixture.document.close() }
        _ = try await fixture.document.createFolder(in: "", progress: Progress())
        try await fixture.save()
        XCTAssertEqual(try DeferredSaveFixture.contents(fixture.gate), fixture.contents)
        XCTAssertEqual(fixture.document.splitSaveNotice, String(localized: "このZIPはそのまま更新できないため、アーカイブ全体を再圧縮しました。"))
    }

    @MainActor func testFAT32ConsentLeavesNoAppleDoubleAndOneVolumeReopensWithSchedule() async throws {
        let disk = try VolumePublishTestDisk("MS-DOS FAT32")
        addTeardownBlock { try disk.detach() }
        let fixture = try DeferredSplitSaveFixture(count: 3, parent: disk.mount)
        defer { fixture.document.close() }
        var prompts = 0, accepted = false
        fixture.document.splitHazardConsent = { _ in prompts += 1; return accepted }
        for name in ["file1.txt", "file2.txt", "file3.txt"] { _ = try await fixture.document.remove([fixture.node(name)], progress: Progress()) }
        do { try await fixture.save(); XCTFail("Default refusal") } catch { }
        XCTAssertEqual(try fixture.parts(), fixture.original)
        accepted = true
        try await fixture.save()
        XCTAssertEqual(prompts, 2); XCTAssertEqual(try fixture.parts().count, 1)
        XCTAssertTrue(try VolumePublishFS.usesAppleDouble(VolumePublishDirectory(fixture.root)))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix("._") })
        XCTAssertNil(try ArchiveVolumeMetadata.read(ArchiveVolumeMetadata.Layout.self, key: ArchiveVolumeMetadata.layoutKey, at: fixture.gate))
        XCTAssertEqual(try fixture.metadata.entry(for: fixture.gate)?.publication.layout.schedule, .uniform(size: UInt64(fixture.size)))
        try await fixture.reopen()
        XCTAssertEqual(fixture.document.session?.volumeLayout?.savedSchedule, .uniform(size: UInt64(fixture.size)))
        fixture.document.splitHazardConsent = { _ in true }
        _ = try await fixture.document.createFolder(in: "", progress: Progress())
        fixture.document.splitSaveHooks.fault = { if $0 == .s7 { throw VolumePublishError.validationFailed } }
        do { try await fixture.save(); XCTFail("Rollback") } catch { }
        XCTAssertEqual(fixture.document.splitSaveFailure?.kind, .rolledBack)
        try await fixture.reopen()
        XCTAssertEqual(fixture.document.session?.volumeLayout?.savedSchedule, .uniform(size: UInt64(fixture.size)))
        XCTAssertTrue(fixture.document.session!.capabilities.splitSave)
        fixture.document.splitHazardConsent = { _ in true }
        _ = try await fixture.document.append(urls: [fixture.file(count: 40_000)], to: "", progress: Progress())
        try await fixture.save()
        XCTAssertGreaterThan(try fixture.parts().count, 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix("._") })
    }
}
