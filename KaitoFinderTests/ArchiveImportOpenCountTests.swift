import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveImportOpenCountTests: XCTestCase {
    // 旧名: ArchiveImportCorrectionTests
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
}
