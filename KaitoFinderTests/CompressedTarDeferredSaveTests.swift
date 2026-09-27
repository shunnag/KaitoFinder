import Foundation
@_spi(Testing) import GyoshukuKit
@_spi(TarEditLayout) import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class CompressedTarDeferredSaveTests: XCTestCase {
    func testFiveChangesPreserveSourceOwnersAndCommitOnceThenSpliceAgain() async throws {
        for format in CompressedTarFixture.formats {
            let directory = try ArchiveTestDirectory(), archive = try CompressedTarFixture.make(directory.url, format: format)
            let session = try ArchiveSession(url: archive, writerOptions: { _ in WriterOptions(preserveOwnerIDs: true) })
            let snapshot = try await session.deferredSnapshot()
            let before = try CompressedTarFixture.groups(CompressedTarFixture.open(archive))
            let original = URL(fileURLWithPath: "/etc/hosts"), sourceStamp = try ArchiveImportSourceStamp(original)
            let staged = directory.url.appendingPathComponent("staged")
            try FileManager.default.copyItem(at: original, to: staged)
            let stagedStamp = try ArchiveImportSourceStamp(staged)
            var pending = ArchivePendingChanges()
            pending.removals = [.init(index: 0, expectedName: "first", baseGeneration: snapshot.generation),
                                .init(index: 4, expectedName: "last", baseGeneration: snapshot.generation)]
            pending.renames[.init(index: 3, expectedName: "folder/tiny", baseGeneration: snapshot.generation)] = "folder/renamed"
            pending.additions = ["added", "last"].map { .init(id: UUID(), path: $0, stagedURL: staged, sourceStamp: sourceStamp, stagedStamp: stagedStamp) }
            pending.createdFolders = [.init(id: UUID(), path: "new/", date: Date(timeIntervalSince1970: 1_700_000_000))]
            let expected = try pending.projection(base: snapshot.entries, generation: snapshot.generation).map(\.name)
            let trace = CompressedTarTrace(), progress = Progress()
            let publication = ArchiveSavePublication(); defer { publication.finish() }
            try await trace.observing {
                let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: progress, publication: publication)
                XCTAssertNil(result.reloadFailure)
            }
            trace.assertAdopted()
            XCTAssertEqual(trace.strategies.withLock { $0.count }, 1)
            XCTAssertEqual(trace.stages.withLock { $0.filter { [.updaterOpen, .rewriterOpen, .commit, .replay].contains($0) } }, [.updaterOpen, .replay, .commit])
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
            let saved = try CompressedTarFixture.open(archive), groups = try CompressedTarFixture.groups(saved)
            XCTAssertEqual(saved.entries.map(\.name), expected)
            for name in ["second", "folder/"] { XCTAssertEqual(groups[name], before[name]) }
            for entry in saved.entries where ["added", "last", "new/"].contains(entry.name) {
                XCTAssertEqual(entry.formatSpecific["uid"], entry.kind == .directory ? "0" : String(sourceStamp.userID))
                XCTAssertEqual(entry.formatSpecific["gid"], entry.kind == .directory ? "0" : String(sourceStamp.groupID))
                if entry.kind == .file { XCTAssertEqual(try saved.read(entry), try Data(contentsOf: original)) }
            }
            let next = try await session.deferredSnapshot(), nextTrace = CompressedTarTrace()
            var second = ArchivePendingChanges(); second.createdFolders = [.init(id: UUID(), path: "again/")]
            let nextPublication = ArchiveSavePublication(); defer { nextPublication.finish() }
            try await nextTrace.observing {
                _ = try await session.savePending(second, baseGeneration: next.generation, progress: Progress(), publication: nextPublication)
            }
            nextTrace.assertAdopted()
            guard case .splice = try XCTUnwrap(nextTrace.strategies.withLock({ $0.first })) else { return XCTFail("Second save must splice") }
            await session.close()
        }
    }

    func testGlobalOwnerFallbackOpensAndReplaysExactlyOnce() throws {
        let directory = try ArchiveTestDirectory()
        let bytes = TarUpdateFixture.pax("uid", "501", type: 103) + TarUpdateFixture.member("keep") + TarUpdateFixture.member("remove") + Data(count: 1024)
        let archive = try CompressedTarFixture.compress(bytes, in: directory, format: .tarGzip)
        let entries = try CompressedTarFixture.open(archive).entries
        for deferred in [false, true] {
            let target = directory.url.appendingPathComponent("edit-\(deferred).tar.gz")
            try FileManager.default.copyItem(at: archive, to: target)
            var pending = ArchivePendingChanges(); pending.removals = [.init(index: entries.count - 1, expectedName: "remove", baseGeneration: 0)]
            let plan = try ArchiveSaveReplayPlan(base: entries, generation: 0, pending: pending, format: .tarGzip)
            let openings = ArchiveTestCounter(), replays = ArchiveTestCounter(), fallbacks = ArchiveTestCounter()
            let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([]), progress = Progress(totalUnitCount: 2)
            try ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
            }) {
                try ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallbacks.increment() }) {
                    try ArchiveImportTransaction.publish(archive: target, mode: .update(.tarGzip), options: .init(), progress: progress,
                        willOpenUpdater: { openings.increment() }, willPublish: nil, sessionReader: CompressedTarFixture.open(target),
                        deferredPlan: deferred ? plan : nil, expectedOutput: .init(plan: plan, mode: .update(.tarGzip))) { editor in
                            replays.increment(); try plan.replay(on: editor, progress: progress)
                        }
                }
            }
            XCTAssertEqual(openings.value, 1); XCTAssertEqual(replays.value, 1); XCTAssertEqual(fallbacks.value, 1)
            XCTAssertEqual(stages.withLock { $0.filter { [.updaterOpen, .rewriterOpen, .mutate, .replay, .commit].contains($0) } }, [.updaterOpen, .rewriterOpen, deferred ? .replay : .mutate, .commit])
            let saved = try ArchiveReader.open(url: target)
            XCTAssertEqual(progress.completedUnitCount, Int64(saved.entries.count + 2))
            XCTAssertEqual(progress.totalUnitCount, Int64(entries.count + 2))
            XCTAssertEqual(saved.entries.map(\.name), ["keep"])
            try CompressedTarFixture.assertNoWork(directory.url)
        }
    }

    func testRequiresRewriteFromMutationOrCommitDoesNotReplay() throws {
        for format in CompressedTarFixture.formats {
            let directory = try ArchiveTestDirectory(), archive = try CompressedTarFixture.make(directory.url, format: format)
            let original = try Data(contentsOf: archive), entries = try ArchiveReader.open(url: archive).entries
            let calls = ArchiveTestCounter(), fallbacks = ArchiveTestCounter()
            for duringCommit in [false, true] {
                XCTAssertThrowsError(try ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallbacks.increment() }) {
                    try ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({ throw TarUpdaterError.requiresRewrite(reason: "commit") }) {
                        try ArchiveImportTransaction.publish(archive: archive, mode: .update(format), options: .init(), progress: Progress(),
                            willPublish: nil, sessionReader: CompressedTarFixture.open(archive), expectedOutput: .init(existing: entries, mode: .update(format))) { _ in
                                calls.increment()
                                if !duringCommit { throw TarUpdaterError.requiresRewrite(reason: "mutate") }
                            }
                    }
                }) { XCTAssertTrue($0 is TarUpdaterError) }
                XCTAssertEqual(try Data(contentsOf: archive), original)
                try CompressedTarFixture.assertNoWork(directory.url)
            }
            XCTAssertEqual(calls.value, 2); XCTAssertEqual(fallbacks.value, 0)
        }
    }
}
