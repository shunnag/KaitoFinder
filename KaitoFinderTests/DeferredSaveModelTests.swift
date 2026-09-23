import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSaveModelTests: XCTestCase {
    private func entry(_ index: Int, _ name: String, directory: Bool = false) -> ArchiveEntry {
        ArchiveEntry(index: index, rawName: .init(bytes: Array(name.utf8)), name: name,
            pathComponents: ArchivePath.components(name), kind: directory ? .directory : .file,
            uncompressedSize: 1, compressedSize: nil, modificationDate: nil, posixPermissions: nil,
            isEncrypted: false, solidGroup: -1, crc32: nil, methodDescription: "stored", formatSpecific: [:])
    }

    func testProjectionAndSaveRefuseOldGenerationRatherThanRetargetIndex() throws {
        let base = [entry(0, "a")]
        var pending = ArchivePendingChanges()
        pending.renames[.init(index: 0, expectedName: "a", baseGeneration: 3)] = "b"
        XCTAssertThrowsError(try pending.projection(base: base, generation: 4))
        XCTAssertThrowsError(try ArchiveSaveReplayPlan(base: base, generation: 4, pending: pending))
        XCTAssertThrowsError(try pending.projection(base: [entry(0, "replacement")], generation: 3))
        XCTAssertEqual(try pending.projection(base: base, generation: 3).map(\.name), ["b"])
    }

    func testFolderRenameExpandsDescendantsAndSyntheticIndicesStartAfterBase() throws {
        let base = [entry(0, "folder/", directory: true), entry(1, "folder/a"), entry(2, "remove")]
        var pending = ArchivePendingChanges()
        pending.renames[.init(index: 0, expectedName: "folder/", baseGeneration: 0)] = "renamed/"
        pending.renames[.init(index: 1, expectedName: "folder/a", baseGeneration: 0)] = "renamed/a"
        pending.removals.insert(.init(index: 2, expectedName: "remove", baseGeneration: 0))
        let id = UUID()
        pending.createdFolders.append(.init(id: id, path: "new/"))
        let projection = try pending.projection(base: base, generation: 0)
        XCTAssertEqual(projection.map(\.name), ["renamed/", "renamed/a", "new/"])
        XCTAssertEqual(projection.map(\.index), [0, 1, 3])
        XCTAssertEqual(projection.last?.formatSpecific["kaitofinder.pending"], id.uuidString)
        let plan = try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending)
        XCTAssertEqual(Set(plan.edits.renames.map(\.entry.index)), [0, 1])
        XCTAssertEqual(plan.edits.existing.count, 3)
    }

    func testSwapBreaksCycleAndReplaysThroughBothEditors() throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tarGzip, .lha] {
            let directory = try ArchiveTestDirectory()
            let archive = directory.url.appendingPathComponent("test." + ArchiveCreationPlan.filenameExtension(for: format))
            let writer = try ArchiveWriter.create(url: archive, format: format)
            try writer.add(data: Data("A".utf8), as: "a")
            try writer.add(data: Data("B".utf8), as: "b")
            try writer.finish()
            let base = try ArchiveReader.open(url: archive).entries
            var pending = ArchivePendingChanges()
            pending.renames[.init(index: 0, expectedName: "a", baseGeneration: 0)] = "b"
            pending.renames[.init(index: 1, expectedName: "b", baseGeneration: 0)] = "a"
            let plan = try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending)
            XCTAssertEqual(plan.edits.renames.count, 3)
            XCTAssertTrue(plan.edits.renames[0].path.hasPrefix(".KaitoFinder-rename-"))
            try ArchiveImportTransaction.publish(archive: archive, mode: format == .zip ? .inPlace : .rewrite(format),
                options: .init(), progress: Progress(), willPublish: nil) { editor in
                try plan.replay(on: editor, progress: Progress())
            }
            XCTAssertEqual(try DeferredSaveFixture.contents(archive), ["a": Data("B".utf8), "b": Data("A".utf8)])
        }
    }

    func testReplayRejectsAdditionConflictsBeforeOpeningEditor() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("a")
        try Data([1]).write(to: source)
        let stamp = try ArchiveImportSourceStamp(source)
        var pending = ArchivePendingChanges()
        pending.additions = [.init(id: UUID(), path: "a", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)]
        XCTAssertThrowsError(try ArchiveSaveReplayPlan(base: [entry(0, "a")], generation: 0, pending: pending))
        pending.removals.insert(.init(index: 0, expectedName: "a", baseGeneration: 0))
        XCTAssertNoThrow(try ArchiveSaveReplayPlan(base: [entry(0, "a")], generation: 0, pending: pending))
        try Data([2]).write(to: source)
        XCTAssertThrowsError(try ArchiveSaveReplayPlan(base: [entry(0, "a")], generation: 0, pending: pending))
    }

    func testOrphanSweepUsesOwnerLockAndMovesToTrash() throws {
        let directory = try ArchiveTestDirectory()
        let registry = StagingRegistry(root: directory.url.appendingPathComponent("Staging"))
        let id = UUID()
        var owner: StagingRegistry.Lease? = try registry.create(id: id)
        let path = try XCTUnwrap(owner?.directory)
        let onlyCopy = path.appendingPathComponent("only-copy")
        try Data("keep me".utf8).write(to: onlyCopy)
        let recovered = directory.url.appendingPathComponent("Recovered")
        let trash: @Sendable (URL) throws -> URL = { source in
            try FileManager.default.moveItem(at: source, to: recovered)
            return recovered
        }
        XCTAssertTrue(try registry.sweep(trash: trash).isEmpty)
        withExtendedLifetime(owner) {}
        owner = nil
        XCTAssertEqual(try registry.sweep(trash: trash), [recovered])
        XCTAssertEqual(try Data(contentsOf: recovered.appendingPathComponent("only-copy")), Data("keep me".utf8))
        XCTAssertTrue(try registry.sweep(trash: trash).isEmpty)
    }

    func testStagingKeepsSymlinkModeModificationDateAndExtendedAttributes() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("source")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source.path)
        let mark = Data("0081;12345678;Browser;".utf8)
        try ExtractionQuarantine.apply(mark, to: source)
        let target = directory.url.appendingPathComponent("staged")
        try StagingRegistry.copySnapshot(from: source, to: target, isDirectory: false)
        XCTAssertEqual(try ExtractionQuarantine.read(from: target), mark)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(attributes[.modificationDate] as? Date, Date(timeIntervalSince1970: 1_700_000_000))
        let link = directory.url.appendingPathComponent("link"), stagedLink = directory.url.appendingPathComponent("staged-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "source")
        try StagingRegistry.copySnapshot(from: link, to: stagedLink, isDirectory: false)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stagedLink.path), "source")
    }
}
