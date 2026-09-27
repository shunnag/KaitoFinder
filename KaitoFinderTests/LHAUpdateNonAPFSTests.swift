import Foundation
@_spi(Testing) import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class LHAUpdateNonAPFSTests: XCTestCase {
    private func edits(_ root: URL) async throws -> ([String], [EntryKind], [UInt64?], [String: Data]) {
        let archive = try LHAUpdateFixture.make(root), session = try ArchiveSession(url: archive)
        let source = root.appendingPathComponent("added"); try Data("new".utf8).write(to: source)
        let entries = await session.entries()
        let removed = try await session.remove([LHAUpdateFixture.selection(entries[1])], progress: Progress())
        XCTAssertNil(removed.reloadFailure)
        let added = try await session.append(urls: [source], to: "", progress: Progress())
        XCTAssertNil(added.reloadFailure)
        let current = await session.entries()
        let renamed = try await session.rename(LHAUpdateFixture.selection(current[0]), to: "kept", progress: Progress())
        XCTAssertNil(renamed.reloadFailure)
        let snapshot = try await session.deferredSnapshot()
        var pending = ArchivePendingChanges()
        pending.createdFolders = [.init(id: UUID(), path: "saved/", date: LHAUpdateFixture.date)]
        let publication = ArchiveSavePublication(); defer { publication.finish() }
        let saved = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
        XCTAssertNil(saved.reloadFailure)
        let reader = try ArchiveReader.open(url: archive)
        let result = (reader.entries.map(\.name), reader.entries.map(\.kind), reader.entries.map(\.uncompressedSize), try LHAUpdateFixture.contents(reader))
        await session.close()
        return result
    }

    private func checkVolume(_ fileSystem: String) async throws {
        let disk = try VolumePublishTestDisk(fileSystem), directory = try ArchiveTestDirectory()
        let baseline = try await edits(directory.url), trace = LHAUpdateTrace()
        let actual = try await trace.observing { try await edits(disk.mount) }
        XCTAssertEqual(actual.0, baseline.0); XCTAssertEqual(actual.1, baseline.1)
        XCTAssertEqual(actual.2, baseline.2); XCTAssertEqual(actual.3, baseline.3)
        XCTAssertEqual(trace.strategies.withLock { $0 }, Array(repeating: .sequential, count: 4))
    }
    func testHFSPlusEditsMatchAPFS() async throws { try await checkVolume("HFS+") }
    func testExFATEditsMatchAPFS() async throws { try await checkVolume("ExFAT") }

    func testSequentialEditsWithoutCloneMatchAPFS() async throws {
        let a = try ArchiveTestDirectory(), b = try ArchiveTestDirectory()
        let baseline = try await edits(a.url), trace = LHAUpdateTrace()
        let actual = try await LHAUpdater.$testingDisablesClone.withValue(true) {
            try await trace.observing { try await edits(b.url) }
        }
        XCTAssertEqual(trace.strategies.withLock { $0 }, Array(repeating: .sequential, count: 4))
        XCTAssertEqual(actual.0, baseline.0); XCTAssertEqual(actual.1, baseline.1)
        XCTAssertEqual(actual.2, baseline.2); XCTAssertEqual(actual.3, baseline.3)
    }
}
