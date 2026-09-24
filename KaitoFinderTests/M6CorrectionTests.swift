import AppKit
import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class M6CorrectionTests: XCTestCase {
    @MainActor private func window(_ fixture: DeferredSplitSaveFixture) -> ArchiveWindowController {
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        fixture.document.addWindowController(controller)
        _ = controller.window
        return controller
    }

    @MainActor private func saveAs(_ fixture: DeferredSplitSaveFixture, to destination: URL) async throws {
        let creator = ArchiveCreationController(store: fixture.store)
        creator.destinationHandler = { save, _ in
            save.formatPopup.selectItem(at: try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: .sevenZip)))
            save.changeFormat(save.formatPopup)
            return destination
        }
        if fixture.document.saveBehavior == .onSave {
            try await fixture.document.savePendingAs(using: creator, on: nil, progress: Progress())
        } else {
            let controller = window(fixture)
            let session = try XCTUnwrap(fixture.document.session), snapshot = await session.snapshot()
            controller.display(EntryNode.tree(from: snapshot.entries), session: session,
                               materializationController: fixture.document.materializationController())
            try await controller.saveArchiveAs(using: creator)
        }
    }

    // B1: a failed Save As cannot grant consent to the original destination; switching resets both prompts.
    @MainActor func testHazardConsentIsScopedToDestinationAndSaveAsResetsSuppression() async throws {
        let fixture = try DeferredSplitSaveFixture(behavior: .immediate), document = fixture.document
        defer { document.close() }
        var prompts = 0, confirmations = 0
        document.splitMutationConfirmation = { alert in
            confirmations += 1; alert.suppressionButton?.state = .on
            return .alertFirstButtonReturn
        }
        document.splitHazardConsent = { _ in prompts += 1; return true }
        document.splitSaveHooks.operations.volumeInfo = { directory in
            let info = try VolumePublishFS.volumeInfo(directory)
            return .init(uuid: info.uuid, cacheIdentity: info.cacheIdentity, fileSystem: info.fileSystem,
                         available: info.available, hazard: "file-provider")
        }
        let destination = fixture.directory.url.appendingPathComponent("other.7z")
        document.splitSaveHooks.willBegin = { _ in throw VolumePublishError.ownerAlive }
        do { try await saveAs(fixture, to: destination); XCTFail("Injected failure") } catch { }
        XCTAssertEqual(prompts, 1)
        document.splitSaveHooks.willBegin = { _ in }
        for name in ["one", "two"] { _ = try await document.createFolder(in: "", baseName: name, progress: Progress()) }
        XCTAssertEqual(prompts, 2, "Consent to the failed Save As destination must not authorize the original")
        XCTAssertEqual(confirmations, 1)
        try await saveAs(fixture, to: destination)
        _ = try await document.createFolder(in: "", baseName: "three", progress: Progress())
        XCTAssertEqual(confirmations, 2, "This archive suppression must not follow Save As")
        XCTAssertEqual(prompts, 3, "A successful backing-file switch clears the consent scope")
    }

    @MainActor func testHazardKindAndVolumeIdentityArePartOfConsent() async throws {
        let fixture = try DeferredSplitSaveFixture(behavior: .immediate), document = fixture.document
        defer { document.close() }
        var prompts = 0
        document.splitHazardConsent = { _ in prompts += 1; return true }
        for (volume, hazard) in [("A", "msdos"), ("A", "msdos"), ("B", "msdos"), ("B", "non-local")] {
            let info = VolumePublishFS.VolumeInfo(uuid: volume, cacheIdentity: volume, fileSystem: "exfat", available: .max, hazard: hazard)
            let location = try XCTUnwrap(ArchiveSplitHazardLocation(parent: fixture.root, info: info))
            let accepted = try await document.consentToSplitHazard(location)
            XCTAssertTrue(accepted)
        }
        XCTAssertEqual(prompts, 3)
    }

    // B2: the old path showed confirmation, then a pending-only reload sheet and CancellationError.
    @MainActor func testImmediateExternalChangeRefusesBeforeConfirmationWithAWindow() async throws {
        let fixture = try DeferredSplitSaveFixture(behavior: .immediate), document = fixture.document
        defer { document.close() }
        let controller = window(fixture)
        let originalURL = document.fileURL
        try SplitArchiveFixture.touch(fixture.gate.deletingPathExtension().appendingPathExtension("002"))
        var confirmations = 0
        document.splitMutationConfirmation = { _ in confirmations += 1; return .alertFirstButtonReturn }
        document.splitSaveHooks.willBegin = { _ in XCTFail("Changed source") }
        var completed = false
        let task = Task { @MainActor () -> (any Error)? in
            defer { completed = true }
            do { _ = try await document.createFolder(in: "", progress: Progress()); return nil } catch { return error }
        }
        for _ in 0..<250 {
            if completed || controller.window?.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let erroneousSheet = controller.window?.attachedSheet
        XCTAssertNil(erroneousSheet)
        // Release the pre-fix path so the regression fails without leaving a modal sheet running.
        if let erroneousSheet { controller.window?.endSheet(erroneousSheet, returnCode: .alertFirstButtonReturn) }
        let error = await task.value
        XCTAssertEqual(error as? ArchiveEditError, .archiveChanged)
        XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(document.fileURL, originalURL)
        XCTAssertEqual(try fixture.parts(), fixture.original)
    }

    // B3: check the actual footer, including cleanup-only success and ZIP rewrite fallback.
    @MainActor func testImmediateZIPAndCleanupNoticesAreVisible() async throws {
        for outcome in ["ZIP", "cleanup", "kept"] {
            let fixture = try DeferredSplitSaveFixture(format: .zip, trailingZIP: outcome == "ZIP", behavior: .immediate)
            let document = fixture.document, controller = window(fixture)
            defer { document.close() }
            document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
            if outcome == "cleanup" { document.splitSaveHooks.fault = { if $0 == .oldDisposed { throw VolumePublishError.system(EIO) } } }
            if outcome == "kept" {
                document.splitSaveHooks.operations.trash = { _ in throw VolumePublishError.system(EACCES) }
                document.splitSaveHooks.operations.willRemove = { _ in throw VolumePublishError.system(EBUSY) }
            }
            _ = try await document.createFolder(in: "", progress: Progress())
            let notice = try XCTUnwrap(document.splitSaveNotice)
            XCTAssertFalse(notice.isEmpty)
            controller.refreshCapabilityNotice(session: document.session)
            XCTAssertTrue(controller.capabilityNotice.stringValue.contains(notice))
            XCTAssertFalse(controller.capabilityNotice.isHidden)
            XCTAssertFalse(document.session!.requiresSplitRecovery)
        }
    }

    @MainActor func testSplitSaveAsCleanupNoticeIsVisibleInBothModes() async throws {
        for behavior: ArchivePreferences.SaveBehavior in [.onSave, .immediate] {
            let fixture = try DeferredSplitSaveFixture(behavior: behavior), document = fixture.document
            defer { document.close() }
            let controller = window(fixture)
            document.splitSaveHooks.fault = { if $0 == .oldDisposed { throw VolumePublishError.system(EIO) } }
            try await saveAs(fixture, to: fixture.directory.url.appendingPathComponent("notice.7z"))
            let notice = try XCTUnwrap(document.splitSaveNotice)
            controller.refreshCapabilityNotice(session: document.session)
            XCTAssertTrue(controller.capabilityNotice.stringValue.contains(notice))
            XCTAssertEqual(try fixture.parts(), fixture.original)
        }
    }

    // B4: a new-set hold does not put the source document into recovery or discard pending edits.
    @MainActor func testSaveAsRollbackAndHoldDescribeNewSetAndKeepSourceEditable() async throws {
        for behavior: ArchivePreferences.SaveBehavior in [.onSave, .immediate] {
            for held in [false, true] {
                let fixture = try DeferredSplitSaveFixture(behavior: behavior), document = fixture.document
                defer { document.close() }
                if behavior == .onSave { _ = try await document.createFolder(in: "", progress: Progress()) }
                let originalURL = document.fileURL, pending = document.pendingChanges
                document.splitSaveHooks.fault = { step in
                    if step == .s7 {
                        if held { throw SimulatedCrash() }
                        throw VolumePublishError.validationFailed
                    }
                }
                do { try await saveAs(fixture, to: fixture.directory.url.appendingPathComponent("failed.7z")); XCTFail("Injected failure") }
                catch let failure as ArchiveSplitSaveFailure {
                    XCTAssertEqual(failure.kind, held ? .held : .rolledBack)
                    XCTAssertEqual(failure.context, .newSet)
                    XCTAssertFalse(failure.requiresReopen)
                    XCTAssertEqual(failure.localizedDescription, held
                        ? String(localized: "新しい分割アーカイブの作成を完了できませんでした。元のアーカイブは変更されていません。保存先の作業フォルダをFinderで確認してください。")
                        : String(localized: "新しい分割アーカイブを作成できませんでした。元のアーカイブは変更されていません。もう一度保存してください。"))
                    if held { XCTAssertNotNil(failure.staging) }
                }
                XCTAssertEqual(document.fileURL, originalURL)
                XCTAssertEqual(document.pendingChanges, pending)
                XCTAssertTrue(document.session!.capabilities.canEdit)
                XCTAssertFalse(document.session!.requiresSplitRecovery)
                XCTAssertEqual(try fixture.parts(), fixture.original)
            }
        }
    }

    func testImmediateRetryCoordinationAndVolumeLimitUseEditActions() {
        let cases: [(VolumePublishError, String)] = [
            (.ownerAlive, String(localized: "別の保存または回復処理中です。しばらくしてからもう一度変更してください。")),
            (.coordinationTimedOut, String(localized: "変更のためのファイル調整が時間切れになりました。原本は変更されていません。もう一度変更してください。")),
            (.tooManyVolumes(required: 129), String(localized: "分割数が上限（128）を超えるため変更できません。「別名で保存」で巻サイズを大きくしてください。"))]
        for (error, text) in cases {
            XCTAssertEqual(ArchiveSplitSaveFailure.map(error, staging: nil, context: .immediateReplacement).localizedDescription, text)
        }
    }

    // B5/B10: the exact NSError shown by NSSavePanel, its output name and its occupied-name checks.
    @MainActor func testSavePanelValidatesCustomSizeVolumeLimitAndNumberedNamespace() throws {
        let directory = try ArchiveTestDirectory(), suite = try ArchivePreferencesTestDefaults()
        let destination = directory.url.appendingPathComponent("output.zip")
        let save = ArchiveSavePanel(sources: [], existingURL: directory.url.appendingPathComponent("source.zip"),
                                   store: ArchivePreferencesStore(defaults: suite.defaults))
        let controls = try XCTUnwrap(save.splitControls)
        controls.choices.selectItem(at: 1); controls.units.selectItem(at: 0); controls.changeChoice(nil)
        for invalid in ["63", "0", "abc"] {
            controls.number.stringValue = invalid
            XCTAssertThrowsError(try save.panel(save.panel, validate: destination)) {
                XCTAssertEqual(($0 as NSError).localizedDescription, String(localized: "64 KB以上のサイズを指定してください。"))
            }
        }
        controls.number.stringValue = "64"
        save.estimatedSplitLength = 129 * 65536
        XCTAssertThrowsError(try save.panel(save.panel, validate: destination)) {
            XCTAssertEqual(($0 as NSError).localizedDescription, String(localized: "分割数が上限（128）を超えるため保存できません。巻サイズを大きくしてください。"))
        }
        save.estimatedSplitLength = 65537 // two outputs plus the .003 next name
        try Data("unrelated bare name".utf8).write(to: destination)
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "output.zip", confirmed: true), "output.zip.001")
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "output.zip.001", confirmed: true), "output.zip.001")
        XCTAssertEqual(save.baseDestination(destination.appendingPathExtension("001")), destination)
        XCTAssertTrue(save.panel.allowedContentTypes.isEmpty)
        XCTAssertNoThrow(try save.panel(save.panel, validate: destination.appendingPathExtension("001")))
        for suffix in ["001", "002", "003"] {
            let occupied = destination.appendingPathExtension(suffix)
            try Data("occupied".utf8).write(to: occupied)
            XCTAssertThrowsError(try save.panel(save.panel, validate: destination)) {
                XCTAssertEqual(($0 as NSError).localizedDescription, String(localized: "同じ名前の分割ファイルが既にあります。"))
            }
            try FileManager.default.removeItem(at: occupied)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "unrelated bare name")
        controls.choices.selectItem(at: 0); controls.changeChoice(nil)
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "output.zip", confirmed: true), "output.zip")
        XCTAssertFalse(save.panel.allowedContentTypes.isEmpty)
    }

    // B6: metadata must win over a lone short member's inferred size, in editing and Save As.
    @MainActor func testSavedSingleExplicitAndUniformSchedulesSurviveImmediateEditsAndSaveAs() async throws {
        for choice: ArchiveSplitScheduleChoice in [.single, .original, .size(65536)] {
            // Seed metadata through the already-working M5 chooser, so the pre-fix failure
            // occurs when immediate mode interprets it, not during new Save As setup.
            let fixture = try DeferredSplitSaveFixture(uneven: true)
            defer { fixture.document.close() }
            let schedule = try choice.schedule(for: XCTUnwrap(fixture.document.session?.volumeLayout))
            fixture.document.splitScheduleChooser = { _, _ in choice }
            for name in fixture.contents.keys.sorted() {
                _ = try await fixture.document.remove([fixture.node(name)], progress: Progress())
            }
            _ = try await fixture.document.createFolder(in: "", baseName: "kept", progress: Progress())
            try await fixture.save()
            fixture.store.preferences.saveBehavior = .immediate
            try await fixture.reopen()
            let document = fixture.document
            XCTAssertEqual(document.session?.volumeLayout?.volumes.count, 1)
            XCTAssertTrue(document.session!.capabilities.splitIrreversible)
            let before = try XCTUnwrap(document.session?.volumeLayout)
            XCTAssertEqual(try ArchiveSaveSplitControls(layout: before).schedule(), schedule)
            if case .uniform = schedule { XCTAssertEqual(before.uniformSize, 65536) } else { XCTAssertNil(before.uniformSize) }
            document.splitMutationConfirmation = { alert in
                if schedule == .single { XCTAssertEqual(alert.informativeText, String(localized: "保存すると1つのファイルにします。")) }
                if case .explicit = schedule { XCTAssertEqual(alert.informativeText, String(localized: "保存すると元の巻サイズを再現します。")) }
                return .alertFirstButtonReturn
            }
            _ = try await document.append(urls: [fixture.file(count: 100_000)], to: "", progress: Progress())
            let edited = try XCTUnwrap(document.session?.volumeLayout)
            XCTAssertEqual(edited.savedSchedule, schedule)
            let expected = try VolumePlan(totalLength: edited.volumes.reduce(0) { $0 + $1.length }, schedule: schedule, scheme: edited.scheme)
            XCTAssertEqual(edited.volumes.map(\.length), expected.volumes.map(\.length))
            let original = try fixture.parts()
            try await saveAs(fixture, to: fixture.root.appendingPathComponent("again.7z"))
            XCTAssertEqual(document.session?.volumeLayout?.savedSchedule, schedule)
            if schedule == .single { XCTAssertEqual(document.session?.volumeLayout?.volumes.count, 1) }
            XCTAssertEqual(try fixture.parts(), original)
        }
    }

    // B7: suggest another mode only when that mode can actually edit the set.
    @MainActor func testUnevenEncryptedAndUnwritableSetsKeepTheirActualRefusal() async throws {
        for encrypted in [true, false] {
            let fixture = try DeferredSplitSaveFixture(uneven: true,
                writerOptions: WriterOptions(compressionMethod: .stored, password: encrypted ? "secret" : nil, encryptsSevenZipHeaders: false),
                behavior: .immediate)
            defer { fixture.document.close() }
            if !encrypted {
                let member = fixture.gate.deletingPathExtension().appendingPathExtension("003")
                XCTAssertEqual(chmod(member.path, 0o444), 0)
                addTeardownBlock { _ = chmod(member.path, 0o600) }
                try await fixture.reopen()
            }
            let deferred = try ArchiveSession(url: fixture.gate, allowsSplitSave: true)
            XCTAssertFalse(deferred.capabilities.canEdit)
            XCTAssertEqual(fixture.document.session?.capabilities.refusal, deferred.capabilities.refusal)
            XCTAssertNotEqual(deferred.capabilities.refusal, .unevenSplitArchive)
            await deferred.close()
        }
    }

    // B8: prove S10 precedes disposal; immediate edits and their recovery never enqueue old sets in Trash.
    @MainActor func testImmediateRemovesOldVolumesAndDeferredStillUsesTrash() async throws {
        for behavior: ArchivePreferences.SaveBehavior in [.immediate, .onSave] {
            let fixture = try DeferredSplitSaveFixture(behavior: behavior), document = fixture.document
            defer { document.close() }
            let trashed = Mutex(0), verified = Mutex(false), removed = Mutex(false)
            document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
            document.splitSaveHooks.fault = { if $0 == .s10 { verified.withLock { $0 = true } } }
            document.splitSaveHooks.operations.trash = { _ in
                XCTAssertTrue(verified.withLock { $0 }); trashed.withLock { $0 += 1 }
                throw VolumePublishError.system(EACCES)
            }
            document.splitSaveHooks.operations.willRemove = { url in
                if url.lastPathComponent == "old" { XCTAssertTrue(verified.withLock { $0 }); removed.withLock { $0 = true } }
            }
            _ = try await document.createFolder(in: "", progress: Progress())
            if behavior == .onSave { try await fixture.save() }
            XCTAssertEqual(trashed.withLock { $0 }, behavior == .immediate ? 0 : 1)
            XCTAssertTrue(removed.withLock { $0 })
            XCTAssertEqual(document.splitSaveResult?.oldVolumesDisposal, .removed)
        }
    }

    func testImmediateDisposalPolicySurvivesJournalAndRecovery() throws {
        let fixture = try VolumePublishFixture()
        var target = fixture.target(); target.oldVolumeDisposal = .remove
        var operations = VolumePublishOperations()
        operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
        operations.trash = { _ in XCTFail("Immediate policy must survive recovery"); throw VolumePublishError.system(EACCES) }
        let staging: URL = try {
            let publication = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(fixture.newBytes.count), index: fixture.index, operations: operations,
                fault: { if $0 == .committed { throw SimulatedCrash() } })
            try fixture.newBytes.write(to: publication.workURL)
            XCTAssertThrowsError(try publication.publish(progress: Progress())) { XCTAssertTrue($0 is SimulatedCrash) }
            return publication.stagingURL
        }() // release the live publication's ownership locks before crash recovery
        let result = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: staging)
        guard case .recovered(_, _, .removed) = result
        else { return XCTFail("Must remove proved superseded volumes: \(result)") }
        try fixture.assertNew()
    }

    // B9: one streamed snapshot on actual AppleDouble volumes; cancellation interrupts it before S5.
    @MainActor func testSaveAsStreamsEachSourceByteOnceAndCancelsBeforePublication() async throws {
        for fileSystem in ["MS-DOS FAT32", "ExFAT"] {
            let disk = try VolumePublishTestDisk(fileSystem)
            addTeardownBlock { try disk.detach() }
            let fixture = try DeferredSplitSaveFixture(parent: disk.mount), document = fixture.document
            defer { document.close() }
            let existing = try await ArchiveCreationController.existingArchive(from: XCTUnwrap(document.session), progress: Progress())
            for splitting in [false, true] {
                for cancel in [false, true] {
                    let name = "copy-\(splitting)-\(cancel).7z"
                    var plan = ArchiveCreationPlan(sources: [], destination: fixture.directory.url.appendingPathComponent(name), format: .sevenZip, existing: existing)
                    if splitting { plan.splitSchedule = .uniform(size: 65536) }
                    let progress = Progress(), bytes = Mutex(0), boundary = Mutex(false)
                    var hooks = ArchiveSplitSaveHooks()
                    hooks.didReadInputBytes = { count in bytes.withLock { $0 += count }; if cancel { progress.cancel() } }
                    hooks.fault = { if $0 == .s5 { boundary.withLock { $0 = true } } }
                    if cancel {
                        XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: plan, progress: progress,
                            volumeIndex: fixture.index, metadataStore: fixture.metadata, splitHooks: hooks)) { XCTAssertTrue($0 is CancellationError) }
                        XCTAssertFalse(boundary.withLock { $0 })
                        XCTAssertLessThan(bytes.withLock { $0 }, fixture.original.reduce(0) { $0 + $1.count })
                    } else {
                        let output = try ArchiveCreationTransaction.run(plan: plan, progress: progress,
                            volumeIndex: fixture.index, metadataStore: fixture.metadata, splitHooks: hooks)
                        XCTAssertEqual(try DeferredSaveFixture.contents(output), fixture.contents)
                        XCTAssertEqual(bytes.withLock { $0 }, fixture.original.reduce(0) { $0 + $1.count })
                    }
                    XCTAssertEqual(try fixture.parts(), fixture.original)
                }
            }
        }
    }
}
