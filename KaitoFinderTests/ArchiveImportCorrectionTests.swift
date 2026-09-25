import AppKit
import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveImportCorrectionTests: XCTestCase {
    func testDeferredTarPreservingOwnersUsesOneVerificationOpen() async throws {
        let directory = try ArchiveTestDirectory(), archive = try TarUpdateFixture.archive(directory.url)
        let session = try ArchiveSession(url: archive, writerOptions: { _ in .init(preserveOwnerIDs: true) })
        let snapshot = try await session.deferredSnapshot()
        var pending = ArchivePendingChanges(); pending.createdFolders = [.init(id: UUID(), path: "new/")]
        let publication = ArchiveSavePublication(); defer { publication.finish() }
        let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - before, 1)
        await session.close()
    }

    func testImportUsesSessionSnapshotWithoutAnExtraOpen() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .lha, .tar, .tarGzip, .tarBzip2, .tarXZ] {
            for replacing in [false, true] {
                let directory = try ArchiveTestDirectory()
                let archive = directory.url.appendingPathComponent("original." + ArchiveCreationPlan.filenameExtension(for: format))
                let writer = try ArchiveWriter.create(url: archive, format: format)
                try writer.add(data: Data("original".utf8), as: replacing ? "added" : "original")
                try writer.finish()
                let source = directory.url.appendingPathComponent("added")
                try Data("added".utf8).write(to: source)
                let session = try ArchiveSession(url: archive)
                let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
                let resolver: ArchiveImportConflict.Resolver = { _ in .init(choice: .replace) }
                let result = try await session.append(urls: [source], to: "", progress: Progress(),
                                                      resolveConflict: replacing ? resolver : nil)
                // 公開前の検証だけ開き、公開後はその解析を採用する。
                XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - before, 1,
                               "\(format), replacing=\(replacing)")
                XCTAssertEqual(result.addedPaths, ["added"])
                XCTAssertNil(result.reloadFailure)
                await session.close()
                let reader = try ArchiveReader.open(url: archive)
                XCTAssertEqual(reader.entries.count, replacing ? 1 : 2)
                XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first { $0.name == "added" })), Data("added".utf8))
            }
        }
    }

    func testImportWithoutSnapshotFailsBeforeOpeningOrChangingArchive() throws {
        let fixture = try ScenarioFixture(), source = try fixture.file("added")
        let original = try Data(contentsOf: fixture.archive)
        var plan = try ArchiveImportPlan.build(urls: [source], folder: "",
            existing: ArchiveReader.open(url: fixture.archive).entries, progress: Progress())
        XCTAssertNotNil(plan.expectedEntries)
        plan.expectedEntries = nil
        let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        XCTAssertThrowsError(try ArchiveImportTransaction.run(plan: plan, archive: fixture.archive, mode: .inPlace, progress: Progress())) {
            XCTAssertEqual($0 as? ArchiveEditError, .staleSelection)
        }
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 }, before)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), original)
    }

    func testTarImportAcceptsFilesystemHardLinks() async throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("original.tar.gz")
        let writer = try ArchiveWriter.create(url: archive, format: .tarGzip)
        try writer.add(data: Data([1]), as: "original")
        try writer.finish()
        let first = directory.url.appendingPathComponent("first"), second = directory.url.appendingPathComponent("second")
        try Data("payload".utf8).write(to: first)
        try FileManager.default.linkItem(at: first, to: second)
        let session = try ArchiveSession(url: archive)
        let result = try await session.append(urls: [first, second], to: "", progress: Progress())
        XCTAssertNil(result.reloadFailure)
        await session.close()
        let reader = try ArchiveReader.open(url: archive)
        let file = try XCTUnwrap(reader.entries.first { $0.name == "first" })
        XCTAssertEqual(file.kind, .file)
        XCTAssertEqual(try reader.read(file), Data("payload".utf8))
        let link = try XCTUnwrap(reader.entries.first { $0.name == "second" })
        XCTAssertEqual(link.kind, .hardlink)
        XCTAssertEqual(link.formatSpecific["linkPath"], "first")
        XCTAssertEqual(link.formatSpecific["hardLinkTargetIndex"], String(file.index))
    }

    private func lha(_ payload: Data, name: String = "member.bin", method: String = "-lh0-", os: UInt8 = 0x6d) -> Data {
        func little<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        var crc: UInt16 = 0
        for byte in payload {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc >> 1 ^ (crc & 1 == 0 ? 0 : 0xa001) }
        }
        let filename = Data(name.utf8)
        var header = Data(count: 2) + Data(method.utf8)
        header += little(UInt32(payload.count)) + little(UInt32(payload.count)) + little(UInt32(1_700_000_000))
        header += Data([0x20, 2]) + little(crc) + Data([os])
        header += little(UInt16(filename.count + 3)) + Data([1]) + filename + little(UInt16(0))
        header.replaceSubrange(0..<2, with: little(UInt16(header.count)))
        return header + payload + Data([0])
    }

    private func macBinary() -> Data {
        var bytes = Data(count: 128)
        bytes[1] = 10
        bytes.replaceSubrange(2..<12, with: "member.bin".utf8)
        bytes.replaceSubrange(65..<73, with: "BINATEST".utf8)
        for (offset, payload) in [(83, Data("data fork".utf8)), (87, Data("resource fork".utf8))] {
            withUnsafeBytes(of: UInt32(payload.count).bigEndian) { bytes.replaceSubrange(offset..<(offset + 4), with: $0) }
            bytes += payload + Data(count: 128 - payload.count)
        }
        return bytes
    }

    @MainActor func testMacBinaryAndUnsupportedLHAAreReadOnlyAndShowTheProbeReason() async throws {
        preserveArchiveWindowFrame()
        let directory = try ArchiveTestDirectory(), controller = ArchiveWindowController()
        defer { controller.close() }
        for (bytes, reason, entriesAccepted) in [
            (lha(macBinary()), "MacBinary の envelope・resource fork を保持できないため再圧縮できません", true),
            (lha(Data("payload".utf8), method: "-pm2-"), "未対応の LHA 圧縮方式は再圧縮できません: -pm2-", false)
        ] {
            let archive = directory.url.appendingPathComponent(UUID().uuidString + ".lzh")
            try bytes.write(to: archive)
            let reader = try ArchiveReader.open(url: archive, options: .kaitoFinder())
            if entriesAccepted { XCTAssertNoThrow(try ArchiveRewriter.probe(entries: reader.entries, format: .lha)) }
            let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
            let capability = ArchiveCapabilities.inspect(reader: reader, url: archive)
            XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 }, before)
            XCTAssertFalse(capability.canEdit)
            XCTAssertEqual(capability.refusal, .unrepresentable("member.bin: " + reason))
            XCTAssertEqual(ArchiveCapabilities.inspect(url: archive, format: .lha).refusal, capability.refusal)
            let session = try ArchiveSession(url: archive), snapshot = await session.snapshot()
            XCTAssertEqual(session.capabilities.refusal, capability.refusal)
            let message = try XCTUnwrap(capability.readOnlyReason)
            XCTAssertTrue(message.contains("member.bin: " + reason))
            controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
            XCTAssertEqual(controller.capabilityNotice.stringValue, message)
            XCTAssertFalse(controller.capabilityNotice.isHidden)
            XCTAssertEqual(try Data(contentsOf: archive), bytes)
            await session.close()
        }
    }

    func testPlainMacLHAAndEmptyLHADirectoryStillPublish() async throws {
        for directoryEntry in [false, true] {
            let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("original.lzh")
            let bytes = lha(directoryEntry ? Data() : Data("payload".utf8), name: directoryEntry ? "directory/" : "member.bin",
                            method: directoryEntry ? "-lhd-" : "-lh0-")
            try bytes.write(to: archive)
            XCTAssertEqual(try ArchiveReader.open(url: archive).entries.first?.uncompressedSize, directoryEntry ? 0 : 7)
            let session = try ArchiveSession(url: archive)
            XCTAssertTrue(session.capabilities.canEdit)
            let result = try await session.createFolder(in: "", baseName: "added", progress: Progress())
            XCTAssertNil(result.reloadFailure)
            await session.close()
            let reader = try ArchiveReader.open(url: archive)
            XCTAssertEqual(reader.entries.count, 2)
            let carried = try XCTUnwrap(reader.entries.first { $0.name != "added/" })
            XCTAssertEqual(carried.kind, directoryEntry ? .directory : .file)
            XCTAssertEqual(carried.uncompressedSize, directoryEntry ? 0 : 7)
            if !directoryEntry { XCTAssertEqual(try reader.read(carried), Data("payload".utf8)) }
        }
    }

    func testNonemptyLHADirectoryCannotReachTheEditPath() throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("original.lzh")
        try lha(Data("payload".utf8), name: "directory/", method: "-lhd-").write(to: archive)
        XCTAssertThrowsError(try ArchiveReader.open(url: archive)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("LHA directory member has data"))
        }
    }
}
