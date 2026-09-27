import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class SevenZipUpdateNonAPFSTests: XCTestCase {
    private func edits(_ root: URL, sequential: Bool = false) async throws -> ([String], [EntryKind], [UInt64?], [String: Data]) {
        let archive = try SevenZipUpdateFixture.make(root)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .creationDate: SevenZipUpdateFixture.date], ofItemAtPath: archive.path)
        let tag = Data("tag".utf8)
        XCTAssertEqual(tag.withUnsafeBytes { setxattr(archive.path, "user.kaito", $0.baseAddress, $0.count, 0, 0) }, 0)
        var original = stat(); XCTAssertEqual(lstat(archive.path, &original), 0)
        let session = try ArchiveSession(url: archive)
        let source = root.appendingPathComponent("added"); try Data("new".utf8).write(to: source)
        let entries = await session.entries()
        let removed = try await session.remove([SevenZipUpdateFixture.selection(entries[1])], progress: Progress())
        XCTAssertNil(removed.reloadFailure)
        let added = try await session.append(urls: [source], to: "", progress: Progress())
        XCTAssertNil(added.reloadFailure)
        let current = await session.entries()
        let renamed = try await session.rename(SevenZipUpdateFixture.selection(current[0]), to: "kept", progress: Progress())
        XCTAssertNil(renamed.reloadFailure)
        let snapshot = try await session.deferredSnapshot()
        var pending = ArchivePendingChanges()
        pending.createdFolders = [.init(id: UUID(), path: "saved/", date: SevenZipUpdateFixture.date)]
        let publication = ArchiveSavePublication(); defer { publication.finish() }
        let saved = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
        XCTAssertNil(saved.reloadFailure)
        var actual = stat(); XCTAssertEqual(lstat(archive.path, &actual), 0)
        XCTAssertEqual(actual.st_mode, original.st_mode)
        XCTAssertEqual(actual.st_birthtimespec.tv_sec, original.st_birthtimespec.tv_sec)
        XCTAssertEqual(actual.st_birthtimespec.tv_nsec, original.st_birthtimespec.tv_nsec)
        if sequential {
            XCTAssertEqual(getxattr(archive.path, "user.kaito", nil, 0, 0, 0), -1)
            XCTAssertEqual(errno, ENOATTR)
        }
        let reader = try ArchiveReader.open(url: archive)
        let result = (reader.entries.map(\.name), reader.entries.map(\.kind), reader.entries.map(\.uncompressedSize), try SevenZipUpdateFixture.contents(reader))
        await session.close()
        return result
    }

    private func checkVolume(_ fileSystem: String) async throws {
        let disk = try VolumePublishTestDisk(fileSystem), directory = try ArchiveTestDirectory()
        let baseline = try await edits(directory.url), trace = SevenZipUpdateTrace()
        let actual = try await trace.observing { try await edits(disk.mount, sequential: true) }
        XCTAssertEqual(actual.0, baseline.0); XCTAssertEqual(actual.1, baseline.1)
        XCTAssertEqual(actual.2, baseline.2); XCTAssertEqual(actual.3, baseline.3)
        XCTAssertEqual(trace.strategies.withLock { $0 }, Array(repeating: .sequential, count: 4))
    }
    func testHFSPlusEditsMatchAPFS() async throws { try await checkVolume("HFS+") }
    func testFAT32EditsMatchAPFS() async throws { try await checkVolume("MS-DOS FAT32") }
    func testExFATEditsMatchAPFS() async throws { try await checkVolume("ExFAT") }

    func testSequentialEditsWithoutCloneMatchAPFS() async throws {
        let a = try ArchiveTestDirectory(), b = try ArchiveTestDirectory()
        let baseline = try await edits(a.url), trace = SevenZipUpdateTrace()
        let actual = try await SevenZipUpdater.$testingDisablesClone.withValue(true) {
            try await trace.observing { try await edits(b.url, sequential: true) }
        }
        XCTAssertEqual(trace.strategies.withLock { $0 }, Array(repeating: .sequential, count: 4))
        XCTAssertEqual(actual.0, baseline.0); XCTAssertEqual(actual.1, baseline.1)
        XCTAssertEqual(actual.2, baseline.2); XCTAssertEqual(actual.3, baseline.3)
    }
}
