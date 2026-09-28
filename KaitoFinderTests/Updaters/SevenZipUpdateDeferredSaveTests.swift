import AppKit
import Foundation
@_spi(Testing) @testable import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class SevenZipUpdateDeferredSaveTests: XCTestCase {
    @MainActor func testNumberedSevenZipStillRewritesInBothSaveModes() async throws {
        for behavior: ArchivePreferences.SaveBehavior in [.immediate, .onSave] {
            let fixture = try DeferredSplitSaveFixture(format: .sevenZip, behavior: behavior)
            defer { fixture.document.close() }
            fixture.document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
            // 公開と検証は実装を通し、sandbox にない Foundation の調停だけを置き換える。
            fixture.document.splitSaveHooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
            let session = try XCTUnwrap(fixture.document.session)
            XCTAssertEqual(session.capabilities.mode, .rewrite(.sevenZip)); XCTAssertTrue(session.capabilities.splitSave)
            let trace = SevenZipUpdateTrace()
            try await trace.observing {
                _ = try await fixture.document.rename(fixture.node("file0.txt"), to: "renamed.txt", progress: Progress())
                if behavior == .onSave { try await fixture.save() }
            }
            XCTAssertTrue(trace.strategies.withLock { $0.isEmpty })
            XCTAssertFalse(trace.stages.withLock { $0.contains(.updaterOpen) })
            XCTAssertEqual(trace.stages.withLock { $0.filter { $0 == .rewriterOpen }.count }, 1)
            var expected = fixture.contents
            expected["renamed.txt"] = expected.removeValue(forKey: "file0.txt")
            XCTAssertEqual(try DeferredSaveFixture.contents(fixture.gate), expected)
            XCTAssertEqual(session.capabilities.mode, .rewrite(.sevenZip))
        }
    }

    func testFiveChangesAndRenameOnlyPreserveReservedOrderAndFolderDate() async throws {
        for frozen in [false, true] {
            for renameOnly in [false, true] {
                let directory = try ArchiveTestDirectory(), archive = try (frozen ? SevenZipUpdateFixture.frozen("z_nonsolid", at: directory.url) : SevenZipUpdateFixture.make(directory.url))
                let session = try ArchiveSession(url: archive), snapshot = try await session.deferredSnapshot()
                let source = directory.url.appendingPathComponent("added"); try Data("new".utf8).write(to: source)
                let stamp = try ArchiveImportSourceStamp(source)
                var pending = ArchivePendingChanges()
                pending.renames[.init(index: 1, expectedName: snapshot.entries[1].name, baseGeneration: snapshot.generation)] = "rename"
                if !renameOnly {
                    pending.removals = Set([snapshot.entries[3], snapshot.entries.last!].map {
                        .init(index: $0.index, expectedName: $0.name, baseGeneration: snapshot.generation)
                    })
                    pending.additions = [.init(id: UUID(), path: "added", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)]
                    pending.createdFolders = [.init(id: UUID(), path: "new/", date: SevenZipUpdateFixture.date)]
                }
                let expected = try pending.projection(base: snapshot.entries, generation: snapshot.generation).map(\.name)
                let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
                let publication = ArchiveSavePublication(); defer { publication.finish() }
                let trace = SevenZipUpdateTrace(), progress = Progress()
                try await trace.observing {
                    try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                        try SevenZipUpdateFixture.assertWork(work, archive: archive, bytes: original, identity: identity)
                    }) {
                        let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: progress, publication: publication)
                        XCTAssertNil(result.reloadFailure)
                    }
                }
                trace.assertRoute([.updaterOpen])
                XCTAssertEqual(trace.stages.withLock { $0.filter { $0 == .mutate || $0 == .replay } }, [.replay])
                XCTAssertEqual(trace.adoptions.withLock { $0 }, [.adopted])
                XCTAssertEqual(trace.strategies.withLock { $0 }, [renameOnly ? .headerOnly : frozen ? .compacted : .appendOnly])
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                let reader = try ArchiveReader.open(url: archive)
                XCTAssertEqual(reader.entries.map { ArchiveEditPlan.key($0.name) }, expected.map(ArchiveEditPlan.key))
                XCTAssertEqual(reader.entries.map(\.index), Array(expected.indices))
                if !renameOnly { XCTAssertEqual(reader.entries.last?.modificationDate, SevenZipUpdateFixture.date) }
                await session.close()
            }
        }
    }
    func testEncryptionReservationPrecedesAdditionWithoutRelocationInBothModes() async throws {
        for sequential in [false, true] {
            let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.make(directory.url)
            let session = try ArchiveSession(url: archive), snapshot = try await session.deferredSnapshot()
            let source = directory.url.appendingPathComponent("added"); try Data("new".utf8).write(to: source)
            let stamp = try ArchiveImportSourceStamp(source)
            var pending = ArchivePendingChanges()
            pending.outputEncryption = .init(password: "new", encryptsSevenZipHeaders: true)
            pending.additions = [.init(id: UUID(), path: "added", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)]
            let trace = SevenZipUpdateTrace(), progress = Progress(), publication = ArchiveSavePublication()
            defer { publication.finish() }
            try await SevenZipUpdater.$testingDisablesClone.withValue(sequential) {
                try await trace.observing {
                    let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: progress, publication: publication)
                    XCTAssertNil(result.reloadFailure)
                }
            }
            trace.assertRoute([.updaterOpen])
            XCTAssertEqual(trace.strategies.withLock { $0 }, [sequential ? .sequential : .reencrypted])
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
            let reader = try SevenZipUpdateFixture.reader(archive, password: "new")
            XCTAssertEqual(reader.entries.last?.name, "added")
            try ArchiveOutputProjection(projected: reader.entries, mode: .update(.sevenZip), sevenZipEncryption: true).validate(reader)
            await session.close()
        }
    }

    func testZIPReplayBeforeAndAfterAdditionProducesIdenticalBytes() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("original.zip")
        let writer = try ArchiveWriter.create(url: source, format: .zip)
        try writer.add(data: Data("original".utf8), as: "keep", modificationDate: SevenZipUpdateFixture.date)
        try writer.finish()
        let entries = try ArchiveReader.open(url: source).entries
        let added = directory.url.appendingPathComponent("added"); try Data("added".utf8).write(to: added)
        let stamp = try ArchiveImportSourceStamp(added)
        var pending = ArchivePendingChanges()
        pending.outputEncryption = .init(password: "new")
        pending.additions = [.init(id: UUID(), path: "added", stagedURL: added, sourceStamp: stamp, stagedStamp: stamp)]
        pending.createdFolders = [.init(id: UUID(), path: "new/", date: SevenZipUpdateFixture.date)]
        let plan = try ArchiveSaveReplayPlan(base: entries, generation: 0, pending: pending, format: .zip)
        var outputs: [Data] = []
        for legacy in [false, true] {
            let output = directory.url.appendingPathComponent("output-\(legacy).zip")
            let updater = try ArchiveUpdater.open(url: source, output: output, options: .init(password: "new"))
            try EncryptionPrimitives.$testingRandomBytes.withValue({ count in Data(repeating: 7, count: count) }) {
                if legacy {
                    try updater.add(contentsOf: added, as: "added")
                    try updater.addDirectory("new/", modificationDate: SevenZipUpdateFixture.date, ownerIDs: nil)
                    try updater.reencryptExistingEntries(currentPassword: nil)
                } else { try plan.replay(on: updater, progress: Progress()) }
                try updater.commit()
            }
            outputs.append(try Data(contentsOf: output))
        }
        XCTAssertEqual(outputs[0], outputs[1])
    }

}
