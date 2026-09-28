import Foundation
@_spi(Testing) import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class TarUpdateNonAPFSTests: XCTestCase {
    private func volumeEdits(_ root: URL) async throws -> [ArchiveEntry] {
        let archive = try TarUpdateFixture.archive(root), session = try ArchiveSession(url: archive)
        let source = root.appendingPathComponent("added"); try Data("new".utf8).write(to: source)
        var entries = await session.entries()
        let removed = try await session.remove([TarUpdateFixture.selection(entries[1])], progress: Progress())
        XCTAssertNil(removed.reloadFailure)
        let added = try await session.append(urls: [source], to: "", progress: Progress())
        XCTAssertNil(added.reloadFailure)
        entries = await session.entries()
        let renamed = try await session.rename(TarUpdateFixture.selection(entries[0]), to: "kept", progress: Progress())
        XCTAssertNil(renamed.reloadFailure)
        let snapshot = try await session.deferredSnapshot()
        var pending = ArchivePendingChanges(); pending.createdFolders = [.init(id: UUID(), path: "saved/", date: Date(timeIntervalSince1970: 1_700_000_000))]
        let publication = ArchiveSavePublication(); defer { publication.finish() }
        let saved = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
        XCTAssertNil(saved.reloadFailure)
        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first { $0.name == "added" })), Data("new".utf8))
        let result = await session.entries(); await session.close()
        return result
    }

    private func checkVolume(_ fileSystem: String) async throws {
        let disk = try VolumePublishTestDisk(fileSystem), directory = try ArchiveTestDirectory()
        let baseline = try await volumeEdits(directory.url), actual = try await volumeEdits(disk.mount)
        XCTAssertEqual(actual.map(\.name), baseline.map(\.name)); XCTAssertEqual(actual.map(\.kind), baseline.map(\.kind))
        XCTAssertEqual(actual.map(\.uncompressedSize), baseline.map(\.uncompressedSize))
    }
    func testHFSPlusEditsMatchAPFS() async throws { try await checkVolume("HFS+") }
    func testExFATEditsMatchAPFS() async throws { try await checkVolume("ExFAT") }
    func testFAT32EditsMatchAPFS() async throws { try await checkVolume("MS-DOS FAT32") }
    func testSequentialEditsWithoutCloneMatchAPFS() async throws {
        let a = try ArchiveTestDirectory(), b = try ArchiveTestDirectory()
        let baseline = try await volumeEdits(a.url)
        let strategies = Mutex<[TarUpdater.CommitStrategy?]>([])
        let actual = try await TarUpdater.$testingDisablesClone.withValue(true) {
            try await ArchiveImportTransaction.didCommitTarUpdaterForTesting.withValue({ updater in strategies.withLock { $0.append(updater.lastCommitStrategy) } }) {
                try await volumeEdits(b.url)
            }
        }
        XCTAssertEqual(strategies.withLock { $0 }, Array(repeating: .sequential, count: 4))
        XCTAssertEqual(actual.map(\.name), baseline.map(\.name)); XCTAssertEqual(actual.map(\.kind), baseline.map(\.kind))
        XCTAssertEqual(actual.map(\.uncompressedSize), baseline.map(\.uncompressedSize))
    }
}
