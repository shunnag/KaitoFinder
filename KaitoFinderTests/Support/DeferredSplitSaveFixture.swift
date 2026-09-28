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
         behavior: ArchivePreferences.SaveBehavior = .onSave, undoStack: ArchiveUndoStack = ArchiveUndoStack(),
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
            // 正当な EOCD の comment を足し、totalLength を選んだ巻数でちょうど割り切れる長さにする。
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
        store.preferences.saveBehavior = behavior
        let index = RecoverableWorkIndex(fileURL: local.appendingPathComponent("support/index.json"))
        let metadata = ArchiveVolumeMetadataStore(fileURL: local.appendingPathComponent("support/metadata.json"))
        let document = ArchiveDocument(undoStack: undoStack, preferencesStore: store,
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
        // 保存の completion は一覧まで。基底の検査は背景の準備が終わってから照合する。
        await document.waitForDeferredPreparationForTesting()
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
        XCTAssertEqual(document.fileModificationDate, try FileManager.default.attributesOfItem(atPath: gate.path)[.modificationDate] as? Date, file: file, line: line)
        let publishedGate = try XCTUnwrap(document.splitSaveResult?.identity.volumes.first, file: file, line: line)
        XCTAssertEqual(publishedGate.modificationSeconds, Int64(gateInfo.st_mtimespec.tv_sec), file: file, line: line)
        XCTAssertEqual(publishedGate.modificationNanoseconds, Int64(gateInfo.st_mtimespec.tv_nsec), file: file, line: line)
        if case .trashed(let url) = document.splitSaveResult?.oldVolumesDisposal {
            let old = try original.indices.map { try Data(contentsOf: url.appendingPathComponent(gate.deletingPathExtension().lastPathComponent + String(format: ".%03d", $0 + 1))) }
            XCTAssertEqual(old, original, file: file, line: line)
        }
    }
}
