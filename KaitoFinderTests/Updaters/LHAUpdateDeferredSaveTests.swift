import AppKit
import Foundation
@_spi(Testing) import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class LHAUpdateDeferredSaveTests: XCTestCase {
    @MainActor func testNumberedLHAStillRewritesInBothSaveModes() async throws {
        for behavior: ArchivePreferences.SaveBehavior in [.immediate, .onSave] {
            let fixture = try DeferredSplitSaveFixture(format: .lha, behavior: behavior)
            defer { fixture.document.close() }
            fixture.document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
            // 公開と検証は実装を通し、sandbox にない Foundation の調停だけを置き換える。
            fixture.document.splitSaveHooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
            let session = try XCTUnwrap(fixture.document.session)
            XCTAssertEqual(session.capabilities.mode, .rewrite(.lha)); XCTAssertTrue(session.capabilities.splitSave)
            let trace = LHAUpdateTrace()
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
            XCTAssertEqual(session.capabilities.mode, .rewrite(.lha))
        }
    }

    func testFiveChangesAndRenameOnlyPreserveReservedOrderAndFolderDate() async throws {
        for mixed in [false, true] {
            for renameOnly in [false, true] {
                let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.make(directory.url, mixed: mixed)
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
                    pending.createdFolders = [.init(id: UUID(), path: "new/", date: LHAUpdateFixture.date)]
                }
                let expected = try pending.projection(base: snapshot.entries, generation: snapshot.generation).map(\.name)
                let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
                let publication = ArchiveSavePublication(); defer { publication.finish() }
                let trace = LHAUpdateTrace(), progress = Progress()
                try await trace.observing {
                    try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                        try LHAUpdateFixture.assertWork(work, archive: archive, bytes: original, identity: identity)
                    }) {
                        let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: progress, publication: publication)
                        XCTAssertNil(result.reloadFailure)
                    }
                }
                trace.assertRoute([.updaterOpen])
                XCTAssertEqual(trace.stages.withLock { $0.filter { $0 == .mutate || $0 == .replay } }, [.replay])
                XCTAssertEqual(trace.adoptions.withLock { $0 }, [.adopted])
                XCTAssertEqual(trace.strategies.withLock { $0 }, [renameOnly && !mixed ? .inPlacePatch : .splice])
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                let reader = try ArchiveReader.open(url: archive)
                XCTAssertEqual(reader.entries.map(\.name), expected)
                XCTAssertEqual(reader.entries.map(\.index), Array(expected.indices))
                if !renameOnly { XCTAssertEqual(reader.entries.last?.modificationDate, LHAUpdateFixture.date) }
                await session.close()
            }
        }
    }
}
