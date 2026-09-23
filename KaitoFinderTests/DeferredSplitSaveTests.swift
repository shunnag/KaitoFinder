import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSplitWorkCapture: Sendable {
    private let value = Mutex<Data?>(nil)
    var bytes: Data? {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }
}

@MainActor final class DeferredSplitSaveFixture {
    let directory: ArchiveTestDirectory
    let root: URL
    let gate: URL
    let defaults: ArchivePreferencesTestDefaults
    let store: ArchivePreferencesStore
    let index: RecoverableWorkIndex
    let metadata: ArchiveVolumeMetadataStore
    let original: [Data]
    let contents: [String: Data]
    let size: Int
    var document: ArchiveDocument
    let work = DeferredSplitWorkCapture()

    init(format: GyoshukuKit.ArchiveFormat = .sevenZip, count: Int = 5, parent: URL? = nil, volumeSize: Int? = nil,
         uneven: Bool = false, trailingZIP: Bool = false, fullLastZIP: Bool = false,
         writerOptions: WriterOptions = WriterOptions(compressionMethod: .stored),
         external: (URL, URL) throws -> Void = { _, _ in }) throws {
        let directory = try ArchiveTestDirectory(), local = try volumePublishTestURL(directory.url)
        let root = (try parent.map(volumePublishTestURL) ?? local).appendingPathComponent("set-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let stem = "archive." + ArchiveCreationPlan.filenameExtension(for: format)
        let whole = local.appendingPathComponent(stem)
        let writer = try ArchiveWriter.create(url: whole, format: format, options: writerOptions)
        var contents: [String: Data] = [:]
        for i in 0..<4 {
            let name = "file\(i).txt", bytes = Self.bytes(9728, seed: UInt64(i + 1))
            contents[name] = bytes
            try writer.add(data: bytes, as: name)
        }
        try writer.finish()
        try external(whole, local)
        var bytes = try Data(contentsOf: whole)
        if fullLastZIP {
            // A legitimate EOCD comment makes totalLength exactly divisible by the chosen count.
            let extra = (count - bytes.count % count) % count
            bytes[bytes.count - 2] = UInt8(extra); bytes[bytes.count - 1] = 0
            bytes.append(Data(repeating: 0x61, count: extra))
        }
        if trailingZIP { bytes.append(Data("trailing data".utf8)) }
        let size = volumeSize ?? (bytes.count + count - 1) / count
        let lengths = uneven ? [9000, 7000, 11000, bytes.count - 27000]
            : stride(from: 0, to: bytes.count, by: size).map { min(size, bytes.count - $0) }
        var parts: [Data] = [], offset = 0
        for (i, length) in lengths.enumerated() {
            let part = bytes.subdata(in: offset..<(offset + length))
            try part.write(to: root.appendingPathComponent(stem + String(format: ".%03d", i + 1)))
            parts.append(part); offset += length
        }
        let gate = root.appendingPathComponent(stem + ".001")
        let defaults = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: defaults.defaults)
        store.preferences.saveBehavior = .onSave
        let index = RecoverableWorkIndex(fileURL: local.appendingPathComponent("support/index.json"))
        let metadata = ArchiveVolumeMetadataStore(fileURL: local.appendingPathComponent("support/metadata.json"))
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store,
            volumeMetadataStore: metadata, volumeRecoveryIndex: index)
        try document.read(from: gate, ofType: ArchiveDocumentController.splitVolumeType)
        document.fileURL = gate; document.fileType = ArchiveDocumentController.splitVolumeType
        document.fileModificationDate = try FileManager.default.attributesOfItem(atPath: gate.path)[.modificationDate] as? Date
        self.directory = directory; self.root = root; self.gate = gate; self.defaults = defaults
        self.store = store; self.index = index; self.metadata = metadata; self.original = parts
        self.contents = contents; self.size = size; self.document = document
        installWorkObserver()
    }
    private func installWorkObserver() {
        let captured = work
        document.splitSaveHooks.didProduceWork = { url in
            let bytes = try Data(contentsOf: url)
            captured.bytes = bytes
        }
    }
    func reopen() async throws {
        document.close(); await document.sessionCleanup?.value
        document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store,
            volumeMetadataStore: metadata, volumeRecoveryIndex: index)
        try document.read(from: gate, ofType: ArchiveDocumentController.splitVolumeType)
        document.fileURL = gate; document.fileType = ArchiveDocumentController.splitVolumeType
        installWorkObserver()
    }
    nonisolated static func bytes(_ count: Int, seed: UInt64 = 42) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        })
    }
    func file(_ name: String = "added.txt", count: Int = 6000) throws -> URL {
        let url = directory.url.appendingPathComponent(name)
        try Self.bytes(count).write(to: url)
        return url
    }
    func node(_ name: String) async throws -> EntryNode {
        let entries = try await document.projectedEntries()
        return try XCTUnwrap(EntryNode.tree(from: entries).children.first { $0.path == name })
    }
    func save() async throws {
        let document = self.document, session = try XCTUnwrap(document.session)
        let originalURL = try XCTUnwrap(document.fileURL), originalSource = session.sourceURL
        let generation = session.generation, originalIdentity = await session.sourceIdentity
        let hadChanges = !document.pendingChanges.isEmpty
        defer {
            XCTAssertEqual(document.fileURL, originalURL, "Save must preserve the document's gate URL spelling")
            XCTAssertEqual(session.sourceURL, originalSource, "The session must reload through its original gate URL")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            document.save(to: originalURL, ofType: ArchiveDocumentController.splitVolumeType, for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        if hadChanges {
            XCTAssertNil(document.deferredReloadFailure)
            let published = try XCTUnwrap(document.splitSaveResult), layout = try XCTUnwrap(session.volumeLayout)
            let identity = await session.sourceIdentity, snapshot = await session.snapshot()
            XCTAssertNotEqual(identity, originalIdentity)
            XCTAssertEqual(identity, published.identity, "Reload must adopt the fully published set")
            XCTAssertEqual(identity, try ArchiveSetIdentity.capture(layout: layout))
            XCTAssertEqual(layout.volumes.map(\.length), published.layout.volumes.map(\.length))
            XCTAssertEqual(layout.nextVolumeName, published.layout.nextVolumeName)
            XCTAssertEqual(snapshot.generation, generation + 1)
            XCTAssertEqual(document.pendingEditor?.baseGeneration, snapshot.generation)
            XCTAssertEqual(document.pendingEditor?.base.map(\.name), snapshot.entries.map(\.name))
            try await session.verifyDeferredIdentity()
        }
    }
    func parts() throws -> [Data] {
        var result: [Data] = []
        for i in 1...128 {
            let url = gate.deletingPathExtension().appendingPathExtension(String(format: "%03d", i))
            if !FileManager.default.fileExists(atPath: url.path) { break }
            result.append(try Data(contentsOf: url))
        }
        return result
    }
    func assertSaved(expected: [String: Data], schedule: VolumePlan.Schedule? = nil,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try XCTUnwrap(work.bytes, file: file, line: line), parts = try parts()
        XCTAssertEqual(parts.reduce(into: Data()) { $0.append($1) }, bytes, file: file, line: line)
        let layout = try XCTUnwrap(document.session?.volumeLayout)
        let plan = try VolumePlan(totalLength: UInt64(bytes.count), schedule: schedule ?? .uniform(size: UInt64(size)), scheme: layout.scheme)
        XCTAssertEqual(parts.map { UInt64($0.count) }, plan.volumes.map(\.length), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.nextVolumeURL.path), file: file, line: line)
        XCTAssertEqual(try DeferredSaveFixture.contents(gate), expected, file: file, line: line)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let memberNames = names.filter { ArchiveVolumeSet.parse(fileName: $0)?.scheme == layout.scheme }
        XCTAssertEqual(Set(memberNames), Set(plan.volumes.map(\.name)), "No surplus or disconnected tail volumes", file: file, line: line)
        XCTAssertFalse(names.contains { $0.hasPrefix(".KaitoFinder-vol-") }, file: file, line: line)
        XCTAssertTrue(try index.entries().isEmpty, file: file, line: line)
        XCTAssertTrue(document.pendingChanges.isEmpty, file: file, line: line)
        XCTAssertFalse(document.isDocumentEdited, file: file, line: line)
        XCTAssertEqual(document.fileURL?.resolvingSymlinksInPath().standardizedFileURL,
                       gate.resolvingSymlinksInPath().standardizedFileURL, file: file, line: line)
        var gateInfo = stat()
        XCTAssertEqual(lstat(gate.path, &gateInfo), 0, file: file, line: line)
        let timestamp = Double(gateInfo.st_mtimespec.tv_sec) + Double(gateInfo.st_mtimespec.tv_nsec) / 1_000_000_000
        let modificationDate = try XCTUnwrap(document.fileModificationDate, file: file, line: line)
        XCTAssertEqual(modificationDate.timeIntervalSince1970, timestamp, accuracy: 0.000001, file: file, line: line)
        let publishedGate = try XCTUnwrap(document.splitSaveResult?.identity.volumes.first, file: file, line: line)
        XCTAssertEqual(publishedGate.modificationSeconds, Int64(gateInfo.st_mtimespec.tv_sec), file: file, line: line)
        XCTAssertEqual(publishedGate.modificationNanoseconds, Int64(gateInfo.st_mtimespec.tv_nsec), file: file, line: line)
        if case .trashed(let url) = document.splitSaveResult?.oldVolumesDisposal {
            let old = try original.indices.map { try Data(contentsOf: url.appendingPathComponent(gate.deletingPathExtension().lastPathComponent + String(format: ".%03d", $0 + 1))) }
            XCTAssertEqual(old, original, file: file, line: line)
        }
    }
}

nonisolated final class DeferredSplitSaveTests: XCTestCase {
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

    @MainActor func testProvenRollbackKeepsPendingAndRequiresReopen() async throws {
        let fixture = try DeferredSplitSaveFixture(), document = fixture.document
        defer { fixture.document.close() }
        _ = try await document.createFolder(in: "", progress: Progress())
        document.splitSaveHooks.fault = { if $0 == .s7 { throw VolumePublishError.validationFailed } }
        do { try await fixture.save(); XCTFail("Rolled back") } catch { }
        XCTAssertEqual(document.splitSaveFailure?.kind, .rolledBack)
        XCTAssertEqual(try fixture.parts(), fixture.original)
        XCTAssertTrue(document.isDocumentEdited); XCTAssertFalse(document.pendingChanges.isEmpty)
        XCTAssertFalse(document.session!.capabilities.canEdit)
        XCTAssertTrue(document.session!.requiresSplitRecovery)
        document.splitSaveHooks.fault = { _ in }
        do { try await fixture.save(); XCTFail("Reopen is required after S5") } catch { }
        XCTAssertTrue(document.isDocumentEdited)
        XCTAssertEqual(try fixture.parts(), fixture.original)
        try await fixture.reopen()
        XCTAssertTrue(fixture.document.session!.capabilities.canEdit)
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
        let offer = try XCTUnwrap(error as? ArchiveVolumeOpenError)
        XCTAssertEqual(offer.recovery.gate, fixture.gate)
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
