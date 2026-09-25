import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class CompressedTarNonAPFSTests: XCTestCase {
    private func edits(_ root: URL, format: GyoshukuKit.ArchiveFormat) async throws -> ([String], [String: Data]) {
        let archive = try CompressedTarFixture.make(root, format: format), session = try ArchiveSession(url: archive)
        let input = root.appendingPathComponent("added"); try Data([99]).write(to: input)
        let trace = CompressedTarTrace()
        try await trace.observing {
            let entries = await session.entries()
            let removed = try await session.remove([TarUpdateFixture.selection(entries[1])], progress: Progress())
            XCTAssertNil(removed.reloadFailure)
            let added = try await session.append(urls: [input], to: "", progress: Progress())
            XCTAssertNil(added.reloadFailure)
            let renamed = try await session.rename(TarUpdateFixture.selection(entries[0]), to: "other", progress: Progress())
            XCTAssertNil(renamed.reloadFailure)
            let snapshot = try await session.deferredSnapshot()
            var pending = ArchivePendingChanges(); pending.createdFolders = [.init(id: UUID(), path: "saved/")]
            let publication = ArchiveSavePublication(); defer { publication.finish() }
            let saved = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
            XCTAssertNil(saved.reloadFailure)
        }
        trace.assertAdopted(4); XCTAssertEqual(trace.fullVerifications.value, 0)
        let reader = try ArchiveReader.open(url: archive), result = (reader.entries.map(\.name), try CompressedTarFixture.hashes(reader))
        try CompressedTarFixture.assertNoWork(root)
        await session.close()
        return result
    }
    private func check(_ fileSystem: String) async throws {
        let disk = try VolumePublishTestDisk(fileSystem)
        for format: GyoshukuKit.ArchiveFormat in [.tarGzip, .tarXZ] {
            let directory = try ArchiveTestDirectory()
            let actual = try await edits(disk.mount, format: format), expected = try await edits(directory.url, format: format)
            XCTAssertEqual(actual.0, expected.0); XCTAssertEqual(actual.1, expected.1)
        }
    }
    func testHFSPlusMatchesAPFS() async throws { try await check("HFS+") }
    func testExFATMatchesAPFS() async throws { try await check("ExFAT") }
    func testFAT32MatchesAPFS() async throws { try await check("MS-DOS FAT32") }
}
