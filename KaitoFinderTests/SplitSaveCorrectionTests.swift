import AppKit
import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

@MainActor private final class SplitRecoveryReply: NSObject {
    let completion: XCTestExpectation
    init(_ completion: XCTestExpectation) { self.completion = completion }
    @objc func didRecover(_ recovered: Bool, contextInfo: UnsafeMutableRawPointer?) {
        XCTAssertTrue(recovered)
        completion.fulfill()
    }
}

nonisolated final class SplitSaveCorrectionTests: XCTestCase {
    private func disk(_ kind: String = "MS-DOS FAT32") throws -> VolumePublishTestDisk {
        let disk = try VolumePublishTestDisk(kind)
        addTeardownBlock { try disk.detach() }
        return disk
    }
    private func crash(_ fixture: VolumePublishFixture, at step: VolumePublishStep = .s7) throws -> URL {
        // This fixture tests recovery/presentation, not Foundation coordination availability.
        var operations = VolumePublishOperations()
        operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
        let publication = try fixture.begin(operations: operations) { if $0 == step { throw SimulatedCrash() } }
        XCTAssertThrowsError(try publication.publish(progress: Progress())) { XCTAssertTrue($0 is SimulatedCrash) }
        return publication.stagingURL
    }
    private func xattr(_ url: URL, _ key: String, _ data: Data) throws {
        guard data.withUnsafeBytes({ setxattr(url.path, key, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }) == 0 else {
            throw VolumePublishError.system(errno)
        }
    }

    // 1: exact Foundation equality, including nanoseconds that differ under the epoch-first formula.
    func testPublishedDateExactlyMatchesFoundationAcrossNanoseconds() throws {
        let fixture = try VolumePublishFixture(), layout = try XCTUnwrap(fixture.layout)
        for nanos in stride(from: 269_568_531, to: 269_568_660, by: 1) {
            var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 0), timespec(tv_sec: 1_700_000_000, tv_nsec: nanos)]
            XCTAssertEqual(utimensat(AT_FDCWD, fixture.gate.path, &times, 0), 0)
            let result = ArchiveSplitSaveResult(published: .init(gateURL: fixture.gate, layout: layout,
                identity: try ArchiveSetIdentity.capture(layout: layout), oldVolumesDisposal: .none,
                usedExclusiveRenameFallback: false), reloadFailure: nil, recompressedZIP: false)
            XCTAssertEqual(result.modificationDate,
                           try FileManager.default.attributesOfItem(atPath: fixture.gate.path)[.modificationDate] as? Date)
        }
    }

    // 2: these are NSObject's real AppKit recovery entry points, not recovery.recover().
    @MainActor func testAppKitSynchronousAndDelegateRecoveryEntriesRecoverThenReopen() async throws {
        for useDelegate in [false, true] {
            let fixture = try VolumePublishFixture()
            _ = try crash(fixture)
            let recovery = try XCTUnwrap(ArchiveVolumeOpenRecovery.discover(fixture.gate, index: fixture.index))
            let opened = XCTestExpectation(description: "reopened after proof"), replied = XCTestExpectation(description: "delegate replied")
            if !useDelegate { replied.fulfill() }
            let offer = ArchiveVolumeOpenError(recovery: recovery, openRecovered: { gate in
                XCTAssertEqual(gate.resolvingSymlinksInPath(), fixture.gate.resolvingSymlinksInPath())
                do { try fixture.assertNew() } catch { XCTFail("\(error)") }
                opened.fulfill()
                return true
            }, showAlert: { alert in XCTFail("Unexpected recovery alert: \(alert.messageText)"); return .alertFirstButtonReturn })
            let controller = ArchiveDocumentController()
            controller.volumeRecoveryIndex = fixture.index
            controller.volumeRecoveryError = { _ in offer.presentedError }
            let delivered: NSError = try await withCheckedThrowingContinuation { continuation in
                controller.openDocument(withContentsOf: fixture.gate.deletingPathExtension().appendingPathExtension("003"), display: false) { document, _, error in
                    XCTAssertNil(document)
                    if let error { continuation.resume(returning: error as NSError) }
                    else { continuation.resume(throwing: VolumePublishError.invalidPlan) }
                }
            }
            XCTAssertNotNil(delivered.userInfo[NSRecoveryAttempterErrorKey])
            // AppKit/Foundation may recreate an NSError with the same userInfo.
            let error = NSError(domain: delivered.domain, code: delivered.code, userInfo: delivered.userInfo)
            let attempter = try XCTUnwrap(error.userInfo[NSRecoveryAttempterErrorKey] as? NSObject)
            let reply = SplitRecoveryReply(replied)
            if useDelegate {
                attempter.attemptRecovery(fromError: error, optionIndex: 0, delegate: reply,
                    didRecoverSelector: #selector(SplitRecoveryReply.didRecover(_:contextInfo:)), contextInfo: nil)
            } else {
                XCTAssertFalse(attempter.attemptRecovery(fromError: error, optionIndex: 0), "Must not claim success before the worker finishes")
            }
            await fulfillment(of: [opened, replied], timeout: 10)
            withExtendedLifetime(reply) {}
            XCTAssertTrue(try fixture.index.entries().isEmpty)
        }
    }

    // 3: a failed publication must not strand the pending plan; Save As uses the same readable base.
    @MainActor func testProvenRollbackRetainsGenerationAndAllowsSaveAsOnFAT() async throws {
        let disk = try disk(), fixture = try DeferredSplitSaveFixture(parent: disk.mount), document = fixture.document
        defer { document.close() }
        document.splitHazardConsent = { _ in true }
        _ = try await document.rename(fixture.node("file0.txt"), to: "kept.txt", progress: Progress())
        let generation = document.generation, stage = Mutex<URL?>(nil), gateName = fixture.gate.lastPathComponent
        document.splitSaveHooks.didProduceWork = { url in stage.withLock { $0 = url.deletingLastPathComponent().deletingLastPathComponent() } }
        document.splitSaveHooks.fault = { step in
            if step == .s7 {
                // Hash-proved FAT rollback may return a changed synthetic inode/mtime.
                let old = try XCTUnwrap(stage.withLock { $0 }).appendingPathComponent("old").appendingPathComponent(gateName)
                try SplitArchiveFixture.touch(old)
                throw VolumePublishError.validationFailed
            }
        }
        do { try await fixture.save(); XCTFail("rollback") } catch { }
        XCTAssertEqual(document.fileModificationDate, try FileManager.default.attributesOfItem(atPath: fixture.gate.path)[.modificationDate] as? Date)
        XCTAssertEqual(document.generation, generation)
        XCTAssertFalse(document.session!.requiresSplitRecovery)
        XCTAssertTrue(document.validateUserInterfaceItem(NSMenuItem(title: "Save", action: #selector(ArchiveDocument.saveArchiveDocument(_:)), keyEquivalent: "")))
        try await document.session!.verifyDeferredIdentity()
        document.splitSaveHooks.fault = { _ in }
        let creator = ArchiveCreationController(store: fixture.store)
        let destination = fixture.directory.url.appendingPathComponent("rescued.7z")
        creator.destinationHandler = { save, _ in
            save.formatPopup.selectItem(at: try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: .sevenZip)))
            save.changeFormat(save.formatPopup)
            save.splitControls?.choices.selectItem(at: 0)
            return destination
        }
        try await document.savePendingAs(using: creator, on: nil, progress: Progress())
        var expected = fixture.contents; expected["kept.txt"] = expected.removeValue(forKey: "file0.txt")
        XCTAssertEqual(try DeferredSaveFixture.contents(destination), expected)
        XCTAssertEqual(try fixture.parts(), fixture.original)
    }

    @MainActor func testHeldWindowKeyCheckDoesNotPresentExternalChangeOrAllowSaveAs() async throws {
        let fixture = try DeferredSplitSaveFixture(), document = fixture.document
        defer { document.close() }
        document.makeWindowControllers()
        let window = try XCTUnwrap(document.windowControllers.first?.window)
        _ = try await document.createFolder(in: "", progress: Progress())
        document.splitSaveHooks.fault = { if $0 == .s7 { throw SimulatedCrash() } }
        do { try await fixture.save(); XCTFail("held") } catch { }
        XCTAssertTrue(document.session!.requiresSplitRecovery)
        document.checkDeferredIdentityWhenKey()
        // Let the actor task that used to present the bogus external-change sheet run.
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(window.attachedSheet)
        let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        let item = NSMenuItem(title: "Save As", action: #selector(ArchiveWindowController.saveArchiveAs(_:)), keyEquivalent: "")
        XCTAssertFalse(controller.validateMenuItem(item))
    }

    // 4: exhaust every publisher error (including preflight errors outside the split pipeline).
    func testAllPublisherErrorsHaveActionableLocalizedDescriptions() throws {
        let url = URL(fileURLWithPath: "/tmp/staging")
        let errors: [VolumePublishError] = [.invalidPlan, .unsupportedScheme, .tooManyVolumes(required: 129),
            .hazardousVolume("msdos"), .insufficientSpace(required: .max, available: 0), .nameOccupied("x.004"),
            .unresolvedPublication(url), .setChanged, .unsafePath("bad"), .system(ENOSPC), .journalUnreadable,
            .journalTooLarge, .ownerAlive, .coordinationTimedOut, .validationFailed, .rollbackIncomplete(url),
            .alreadyUsed, .fat32WorkFileTooLarge(length: UInt64(UInt32.max)), .contentMismatch("x.001"),
            .publishedReaderFailed(staging: url, diagnostic: "private diagnostic"), .stagedReaderFailed("private diagnostic"),
            .publishedVerificationPending(staging: url, diagnostic: "private diagnostic"),
            .rolledBack(underlying: "private diagnostic", cleanupFailed: nil, disposal: .none)]
        for language in LocalizationAcceptance.languages {
            let bundle = try LocalizationAcceptance.bundle(language)
            for error in errors {
                let message = ArchiveErrorText.describe(error, bundle: bundle)
                XCTAssertFalse(message.isEmpty)
                XCTAssertFalse(message.contains("VolumePublishError"), "\(language): \(message)")
                XCTAssertFalse(message.contains("18446744073709551615"))
                XCTAssertFalse(message.contains("private diagnostic"))
                if language == "en" { XCTAssertFalse(message.range(of: "[一-龯ぁ-んァ-ヶ]", options: .regularExpression) != nil) }
            }
        }
    }

    func testFATWorkLimitRefusesBeforeWritingWithSpecificMessage() throws {
        let fixture = try VolumePublishFixture()
        var operations = VolumePublishOperations()
        operations.volumeInfo = { directory in
            let info = try VolumePublishFS.volumeInfo(directory)
            return .init(uuid: info.uuid, cacheIdentity: info.cacheIdentity, fileSystem: "msdos", available: .max, hazard: nil)
        }
        let target = VolumeSetTarget(parent: fixture.root, newSetScheme: .numbered(stem: "large.tar", width: 3),
                                     schedule: .uniform(size: 1024 * 1024 * 1024), allowHazardousVolume: true)
        for length in [UInt64(UInt32.max), UInt64(UInt32.max) + 1] {
            XCTAssertThrowsError(try VolumeSetPublication.begin(target, estimatedOutputLength: length, index: fixture.index, operations: operations)) {
                XCTAssertEqual(ArchiveErrorText.describe($0), String(localized: "このアーカイブの作業ファイルはFAT32の上限を超えます。APFSまたはexFATのディスクに保存してください。"))
            }
            XCTAssertTrue(try fixture.index.entries().isEmpty)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".KaitoFinder-vol-") })
        }
    }

    // 5: marker avoidance must never strip security or the old members' unrelated xattrs.
    @MainActor func testAppleDoubleQuarantineSurvivesDeferredImmediateAndSplitSaveAs() async throws {
        for kind in ["MS-DOS FAT32", "ExFAT"] {
            let disk = try disk(kind)
            for behavior: ArchivePreferences.SaveBehavior in [.onSave, .immediate] {
                let fixture = try DeferredSplitSaveFixture(parent: disk.mount, behavior: behavior), document = fixture.document
                defer { document.close() }
                let quarantine = Data("0083;12345678;KaitoFinder;".utf8)
                for volume in document.session!.volumeLayout!.volumes {
                    try xattr(volume.url, "com.apple.quarantine", quarantine)
                    try xattr(volume.url, "com.shunnag.test.extra", Data([1, 2, 3]))
                }
                document.splitHazardConsent = { _ in true }
                document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
                _ = try await document.createFolder(in: "", progress: Progress())
                if behavior == .onSave { try await fixture.save() }
                for volume in document.session!.volumeLayout!.volumes {
                    let values = try VolumeSplitter.Attributes(directory: VolumePublishDirectory(fixture.root), name: volume.url.lastPathComponent).xattrs
                    XCTAssertEqual(values["com.apple.quarantine"], quarantine)
                    XCTAssertEqual(values["com.shunnag.test.extra"], Data([1, 2, 3]))
                    XCTAssertNil(values[ArchiveVolumeMetadata.layoutKey]); XCTAssertNil(values[ArchiveVolumeMetadata.setKey])
                }
                let existing = try await ArchiveCreationController.existingArchive(from: document.session!, progress: Progress())
                var plan = ArchiveCreationPlan(sources: [], destination: fixture.root.appendingPathComponent("copy.7z"), format: .sevenZip, existing: existing)
                plan.splitSchedule = .uniform(size: UInt64(fixture.size)); plan.allowHazardousVolume = true
                let gate = try ArchiveCreationTransaction.run(plan: plan, progress: Progress(), volumeIndex: fixture.index, metadataStore: fixture.metadata)
                let reader = try ArchiveReader.open(url: gate)
                for volume in try XCTUnwrap(reader.volumeSet).volumes {
                    XCTAssertEqual(try ExtractionQuarantine.firstValue(from: [volume.url]) {}, quarantine)
                }
            }
        }
    }

    func testAppleDoubleOnlyCopiesAttributesToMatchingOldMembers() throws {
        let disk = try disk(), fixture = try VolumePublishFixture(parent: disk.mount, oldCount: 3, newCount: 3)
        try xattr(fixture.gate, "com.shunnag.test.extra", Data([7]))
        var target = fixture.target(consent: true); target.writesVolumeMetadata = true
        let publication = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(fixture.newBytes.count), index: fixture.index)
        try fixture.newBytes.write(to: publication.workURL)
        let output = try publication.publish(progress: Progress())
        let parent = try VolumePublishDirectory(fixture.root)
        XCTAssertEqual(try VolumeSplitter.Attributes(directory: parent, name: output.layout.volumes[0].url.lastPathComponent).xattrs["com.shunnag.test.extra"], Data([7]))
        for volume in output.layout.volumes.dropFirst() {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("._" + volume.url.lastPathComponent).path))
        }
    }

    // 6: paths are not a component of per-volume set membership.
    @MainActor func testRenamedAndDuplicatedNativeSetsRemainEditableIncludingSingletons() async throws {
        for singleton in [false, true] {
            let fixture = try DeferredSplitSaveFixture(volumeSize: singleton ? 100_000 : nil), document = fixture.document
            defer { document.close() }
            // A singleton starts as an ordinary archive; create the initial marked set through Save As.
            let existing = try await ArchiveCreationController.existingArchive(from: document.session!, progress: Progress())
            var plan = ArchiveCreationPlan(sources: [], destination: fixture.root.appendingPathComponent("saved.7z"), format: .sevenZip, existing: existing)
            plan.splitSchedule = .uniform(size: singleton ? 100_000 : UInt64(fixture.size))
            let gate = try ArchiveCreationTransaction.run(plan: plan, progress: Progress(), volumeIndex: fixture.index, metadataStore: fixture.metadata)
            let saved = try ArchiveSession(url: gate, allowsSplitSave: true, volumeMetadataStore: fixture.metadata)
            let layout = try XCTUnwrap(saved.volumeLayout)
            await saved.close()
            for volume in layout.volumes {
                let suffix = volume.url.pathExtension
                try FileManager.default.moveItem(at: volume.url, to: fixture.root.appendingPathComponent("renamed.7z." + suffix))
                try FileManager.default.copyItem(at: fixture.root.appendingPathComponent("renamed.7z." + suffix),
                                                to: fixture.root.appendingPathComponent("duplicate.7z." + suffix))
            }
            for stem in ["renamed", "duplicate"] {
                for immediate in [false, true] {
                    let opened = try ArchiveSession(url: fixture.root.appendingPathComponent(stem + ".7z.001"),
                        allowsSplitSave: !immediate, allowsImmediateSplitSave: immediate, volumeMetadataStore: fixture.metadata)
                    XCTAssertTrue(opened.capabilities.canEdit, "\(stem): \(String(describing: opened.capabilities.readOnlyReason))")
                    XCTAssertNotEqual(opened.capabilities.refusal, .mixedVolumes)
                    await opened.close()
                }
            }
        }
    }

    // 7: preserve the old inode, size AND coarse mtime: only the content key can reject this stale entry.
    func testMetadataCacheRejectsReusedInodeAndSameSizeDifferentGateBytes() throws {
        let disk = try disk(), fixture = try VolumePublishFixture(parent: disk.mount)
        let store = ArchiveVolumeMetadataStore(fileURL: try volumePublishTestURL(fixture.directory.url).appendingPathComponent("cache/metadata.json"))
        let layout = try XCTUnwrap(fixture.layout)
        let publication = ArchiveVolumeMetadata.Publication(layout: .init(stem: "archive.tar", width: 3, schedule: .uniform(size: 99999)),
            setUUID: UUID(), generation: 1, count: layout.volumes.count, totalSHA256: String(repeating: "a", count: 64))
        try store.save(publication, layout: layout)
        XCTAssertNotNil(try store.entry(for: fixture.gate))
        let before = try ArchiveSetIdentity.capture(layout: layout)
        // Overwrite through the same inode, modelling FAT's reuse of a freed cluster at this path.
        let handle = try FileHandle(forWritingTo: fixture.gate)
        try handle.seek(toOffset: 1024); try handle.write(contentsOf: Data([0x79])); try handle.close()
        let stamp = before.volumes[0]
        var times = [timespec(tv_sec: Int(stamp.modificationSeconds), tv_nsec: Int(stamp.modificationNanoseconds)),
                     timespec(tv_sec: Int(stamp.modificationSeconds), tv_nsec: Int(stamp.modificationNanoseconds))]
        XCTAssertEqual(utimensat(AT_FDCWD, fixture.gate.path, &times, 0), 0)
        XCTAssertEqual(try ArchiveSetIdentity.capture(layout: layout), before)
        XCTAssertNil(try store.entry(for: fixture.gate), "Stale cache must be ignored, not interpreted as mixed")
        let opened = try ArchiveSession(url: fixture.gate, allowsSplitSave: true, volumeMetadataStore: store)
        XCTAssertNil(opened.volumeLayout?.savedSchedule)
        XCTAssertTrue(opened.capabilities.canEdit)
    }

    // 8: cache writes fail AFTER proof. Neither normal publish, forward recovery nor rollback may HOLD.
    func testMetadataWriteFailureCannotHoldCommitRecoveryOrRollback() throws {
        let disk = try disk()
        for direction in ["commit", "forward", "backward"] {
            let fixture = try VolumePublishFixture(parent: disk.mount)
            let store = ArchiveVolumeMetadataStore(fileURL: try volumePublishTestURL(fixture.directory.url).appendingPathComponent("cache/metadata.json"))
            let layout = try XCTUnwrap(fixture.layout)
            let old = ArchiveVolumeMetadata.Publication(layout: .init(stem: "archive.tar", width: 3, schedule: .uniform(size: 9000)),
                setUUID: UUID(), generation: 1, count: layout.volumes.count, totalSHA256: String(repeating: "b", count: 64))
            try store.save(old, layout: layout)
            var target = fixture.target(consent: true); target.writesVolumeMetadata = true
            let publication = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(fixture.newBytes.count),
                index: fixture.index, metadataStore: store, fault: { step in
                    if step == .s7 {
                        try FileManager.default.removeItem(at: store.fileURL)
                        // rename(temp, directory) always fails, even with root privileges.
                        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
                        if direction == "forward" { throw SimulatedCrash() }
                        if direction == "backward" { throw VolumePublishError.validationFailed }
                    }
                })
            try fixture.newBytes.write(to: publication.workURL)
            if direction == "commit" {
                let result = try publication.publish(progress: Progress())
                guard case .committed(let warning) = result.outcome else { return XCTFail("committed") }
                XCTAssertNotNil(warning)
                try fixture.assertNew()
            } else {
                XCTAssertThrowsError(try publication.publish(progress: Progress())) { error in
                    if direction == "backward" {
                        guard case VolumePublishError.rolledBack = error else { return XCTFail("Cache error must not change a proved rollback: \(error)") }
                    }
                }
                if direction == "forward" {
                    let result = VolumePublishRecovery(index: fixture.index, metadataStore: store).recover(staging: publication.stagingURL)
                    guard case .recovered = result else { return XCTFail("\(result)") }
                    try fixture.assertNew()
                } else { try fixture.assertOld() }
            }
            XCTAssertNil(try ArchiveVolumeOpenRecovery.discover(fixture.gate, index: fixture.index, metadataStore: store))
        }
    }

    @MainActor func testSplitSaveAsMetadataFailureSucceedsAndReportsWarningInBothModes() async throws {
        let disk = try disk()
        for behavior: ArchivePreferences.SaveBehavior in [.onSave, .immediate] {
            let fixture = try DeferredSplitSaveFixture(behavior: behavior), document = fixture.document
            defer { document.close() }
            let destination = disk.mount.appendingPathComponent(UUID().uuidString + ".7z")
            let creator = ArchiveCreationController(store: fixture.store), storeURL = fixture.metadata.fileURL
            document.splitSaveHooks.fault = { step in
                if step == .s7 {
                    try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
                }
            }
            document.splitHazardConsent = { _ in true }
            creator.destinationHandler = { save, _ in
                save.formatPopup.selectItem(at: try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: .sevenZip)))
                save.changeFormat(save.formatPopup)
                XCTAssertNotNil(save.splitControls)
                return destination
            }
            if behavior == .onSave { try await document.savePendingAs(using: creator, on: nil, progress: Progress()) }
            else {
                let controller = ArchiveWindowController(preferencesStore: fixture.store)
                document.addWindowController(controller)
                let session = try XCTUnwrap(document.session), snapshot = await session.snapshot()
                controller.display(EntryNode.tree(from: snapshot.entries), session: session,
                                   materializationController: document.materializationController())
                try await controller.saveArchiveAs(using: creator)
            }
            XCTAssertEqual(document.splitSaveNotice, String(localized: "巻サイズの設定を記録できませんでした。次回開くときに巻サイズを確認してください。"))
            XCTAssertFalse(document.session!.requiresSplitRecovery)
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertEqual(try DeferredSaveFixture.contents(try XCTUnwrap(document.fileURL)), fixture.contents)
            XCTAssertEqual(try fixture.parts(), fixture.original)
        }
    }

    // 9: local/CD flag disagreement is readable by KaitoKit but rejected by ArchiveUpdater.open.
    @MainActor func testZIPStructuralRefusalUsesValidatedRewriteInBothModes() async throws {
        for behavior: ArchivePreferences.SaveBehavior in [.onSave, .immediate] {
            let fixture = try DeferredSplitSaveFixture(format: .zip, behavior: behavior, external: { url, _ in
                var bytes = try Data(contentsOf: url)
                bytes[6] ^= 0x08 // local header's descriptor flag differs from the CD, payload remains valid
                try bytes.write(to: url)
                XCTAssertThrowsError(try ArchiveUpdater.open(url: url)) {
                    guard case UpdaterError.invalidArchive = $0 else { return XCTFail("\($0)") }
                }
            })
            defer { fixture.document.close() }
            fixture.document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
            _ = try await fixture.document.createFolder(in: "", progress: Progress())
            if behavior == .onSave { try await fixture.save() }
            XCTAssertEqual(try DeferredSaveFixture.contents(fixture.gate), fixture.contents)
            XCTAssertEqual(fixture.document.splitSaveNotice, String(localized: "このZIPはそのまま更新できないため、アーカイブ全体を再圧縮しました。"))
        }
    }

    // 10: follow NSDocument's location, reusing the pending plan and preserving its generation.
    @MainActor func testContainingFolderMoveAllowsSaveRevertAndSaveAs() async throws {
        for action in ["save", "revert", "saveAs", "immediate"] {
            let fixture = try DeferredSplitSaveFixture(behavior: action == "immediate" ? .immediate : .onSave), document = fixture.document
            defer { document.close() }
            if action != "immediate" { _ = try await document.rename(fixture.node("file0.txt"), to: "pending.txt", progress: Progress()) }
            let moved = fixture.root.appendingPathExtension("moved")
            try FileManager.default.moveItem(at: fixture.root, to: moved)
            let gate = moved.appendingPathComponent(fixture.gate.lastPathComponent)
            document.fileURL = gate // The URL delivered by NSDocument's file presenter, with its spelling intact.
            if action == "save" {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    document.save(to: gate, ofType: ArchiveDocumentController.splitVolumeType, for: .saveOperation) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            if action == "revert" { try await document.revertPending() }
            if action == "saveAs" {
                let creator = ArchiveCreationController(store: fixture.store)
                creator.destinationHandler = { save, _ in
                    save.formatPopup.selectItem(at: try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: .sevenZip)))
                    save.changeFormat(save.formatPopup)
                    save.splitControls?.choices.selectItem(at: 0)
                    return moved.appendingPathComponent("export.7z")
                }
                try await document.savePendingAs(using: creator, on: nil, progress: Progress())
            }
            if action == "immediate" {
                document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
                _ = try await document.createFolder(in: "", progress: Progress())
            }
            if action != "saveAs" { XCTAssertEqual(document.fileURL, gate) }
            XCTAssertFalse(document.session!.requiresSplitRecovery)
            try await document.session!.verifyDeferredIdentity()
            let names = Set(try DeferredSaveFixture.contents(try XCTUnwrap(document.fileURL)).keys)
            XCTAssertTrue(names.contains(action == "save" || action == "saveAs" ? "pending.txt" : "file0.txt"))
        }
    }

    // 11: open lookup precedes discovery, including a missing gate during publication.
    @MainActor func testAlreadyOpenSavingAndHeldSetsReuseDocumentBeforeDiscovery() async throws {
        for held in [false, true] {
            let fixture = try DeferredSplitSaveFixture(), document = fixture.document
            let controller = ArchiveDocumentController()
            controller.volumeRecoveryIndex = fixture.index; controller.volumeMetadataStore = fixture.metadata
            controller.addDocument(document)
            defer { controller.removeDocument(document); document.close() }
            let session = try XCTUnwrap(document.session), layout = try XCTUnwrap(session.volumeLayout).publicationLayout()
            let target = VolumeSetTarget(parent: fixture.root, layout: layout, expected: await session.sourceIdentity,
                schedule: .uniform(size: UInt64(fixture.size)), filePresenter: document)
            let publication = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(fixture.original.joined().count),
                index: fixture.index, fault: { if $0 == .s7 { throw SimulatedCrash() } })
            defer { publication.cancel() }
            if held {
                try fixture.original.reduce(into: Data()) { $0.append($1) }.write(to: publication.workURL)
                XCTAssertThrowsError(try publication.publish(progress: Progress()))
            } else {
                XCTAssertNil(try ArchiveVolumeOpenRecovery.discover(fixture.gate, index: fixture.index), "Live publisher is not interrupted")
            }
            let member = fixture.gate.deletingPathExtension().appendingPathExtension("003")
            let result: (NSDocument?, Bool, (any Error)?) = await withCheckedContinuation { continuation in
                controller.openDocument(withContentsOf: member, display: false) { continuation.resume(returning: ($0, $1, $2)) }
            }
            XCTAssertTrue(result.0 === document); XCTAssertTrue(result.1); XCTAssertNil(result.2)
        }
    }

    // 12: proven live sets stay openable when Trash/removal is temporarily unavailable.
    func testCleanupOnlyForwardAndBackwardRecoveryDoesNotBlockOpening() throws {
        for forward in [true, false] {
            let fixture = try VolumePublishFixture()
            var operations = VolumePublishOperations()
            operations.trash = { _ in throw VolumePublishError.system(EACCES) }
            operations.willRemove = { _ in throw VolumePublishError.system(EBUSY) }
            let publication = try fixture.begin(operations: operations) {
                if $0 == .s7, !forward { throw VolumePublishError.validationFailed }
                if $0 == .committed, forward { throw SimulatedCrash() }
            }
            XCTAssertThrowsError(try publication.publish(progress: Progress()))
            let recovery = VolumePublishRecovery(index: fixture.index, operations: operations)
            let result = recovery.recover(staging: publication.stagingURL)
            guard case .recovered(_, _, .kept) = result else { return XCTFail("Cleanup must not HOLD a proven set: \(result)") }
            if forward { try fixture.assertNew() } else { try fixture.assertOld() }
            XCTAssertNil(try ArchiveVolumeOpenRecovery.discover(fixture.gate, index: fixture.index))
            // A later recovery with functioning cleanup can finish normally.
            guard case .recovered = VolumePublishRecovery(index: fixture.index).recover(staging: publication.stagingURL)
            else { return XCTFail("cleanup retry") }
        }
    }

    // 13: an attributable journal rejected by validation still offers recovery/Finder.
    func testInconsistentSameStemJournalOffersRecoveryInsteadOfRawError() throws {
        let fixture = try VolumePublishFixture(), stage = try crash(fixture)
        let renamed = fixture.root.appendingPathComponent(VolumePublishFS.stagingPrefix + UUID().uuidString)
        try FileManager.default.moveItem(at: stage, to: renamed)
        let offer = try XCTUnwrap(ArchiveVolumeOpenRecovery.discover(fixture.gate, index: fixture.index))
        XCTAssertEqual(try offer.stagings.map(volumePublishTestURL), [try volumePublishTestURL(renamed)])
        XCTAssertEqual(ArchiveVolumeOpenError(recovery: offer).recoveryOptions.first, String(localized: "中断した保存を完了して開く"))
        guard case .held = VolumePublishRecovery(index: fixture.index).recover(staging: renamed)
        else { return XCTFail("Unproved old/new data must stay for Finder inspection") }
    }
}
