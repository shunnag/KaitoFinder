import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveSingleCopyEditTests: XCTestCase {
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)
    private enum Injected: Error { case stop }

    private static func archive(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("original.zip")
        try ReleaseReviewFixtures.zip([("keep", Data([1])), ("remove", Data([2])), ("other", Data([3]))]).write(to: url)
        return url
    }

    private static func assertNoWork(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".KaitoFinder-add-") || $0.hasPrefix(".gyoshuku-") }, names.description, file: file, line: line)
    }

    private static func checkWork(_ work: URL, archive: URL, original: Data, identity: ArchiveFileIdentity) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.deletingLastPathComponent().path)
            .filter { !$0.hasPrefix("._") }, ["archive.zip"])
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(try ArchiveFileIdentity.capture(url: archive), identity)
    }

    private func immediateAndDeferred(in root: URL) async throws {
        for operation in 0..<6 {
            let url = try Self.archive(in: root), original = try Data(contentsOf: url)
            let identity = try ArchiveFileIdentity.capture(url: url), commits = Mutex(0)
            let strategies = Mutex<[ArchiveUpdater.CommitStrategy?]>([])
            let session = try ArchiveSession(url: url)
            let entries = await session.entries()
            let target = ArchiveEditSelection(path: entries[1].name, isDirectory: false, entries: [entries[1]])
            let source = root.appendingPathComponent(operation == 4 ? "keep" : "added")
            try Data("new bytes".utf8).write(to: source)
            try await ArchiveImportTransaction.didCommitUpdaterForTesting.withValue({ updater in
                strategies.withLock { $0.append(updater.lastCommitStrategy) }
            }) {
                try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                    try Self.checkWork(work, archive: url, original: original, identity: identity)
                    commits.withLock { $0 += 1 }
                }) {
                    switch operation {
                    case 0:
                        let result = try await session.remove([target], progress: Progress()); XCTAssertNil(result.reloadFailure)
                    case 1:
                        let result = try await session.rename(target, to: "renamed", progress: Progress()); XCTAssertNil(result.reloadFailure)
                    case 2, 4:
                        let result = try await session.append(urls: [source], to: "", progress: Progress(), resolveConflict: { _ in .init(choice: .replace) })
                        XCTAssertNil(result.reloadFailure); XCTAssertEqual(result.addedPaths, [source.lastPathComponent])
                    case 3:
                        let result = try await session.createFolder(in: "", baseName: "new", progress: Progress()); XCTAssertNil(result.reloadFailure)
                    default:
                        let snapshot = try await session.deferredSnapshot(), stamp = try ArchiveImportSourceStamp(source)
                        var pending = ArchivePendingChanges()
                        pending.removals = [.init(index: 1, expectedName: "remove", baseGeneration: snapshot.generation)]
                        pending.additions = [.init(id: UUID(), path: "added", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)]
                        let publication = ArchiveSavePublication(); defer { publication.finish() }
                        let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
                        XCTAssertNil(result.reloadFailure)
                    }
                }
            }
            XCTAssertEqual(commits.withLock { $0 }, 1)
            if operation == 4 || operation == 5 { XCTAssertEqual(strategies.withLock { $0 }, [.rebuildThenAppend]) }
            let current = await session.entries(), fresh = try ArchiveReader.open(url: url, options: .kaitoFinder()).entries
            XCTAssertEqual(current, fresh)
            await session.close()
            try Self.assertNoWork(in: root)
        }
    }

    func testEveryImmediateOperationAndMixedSaveUseOneWorkFile() async throws {
        let directory = try ArchiveTestDirectory()
        try await immediateAndDeferred(in: directory.url)
    }

    @MainActor func testDeferredDocumentMixedSaveUsesRebuildThenAppend() async throws {
        let fixture = try DeferredSaveFixture(files: [("keep", "A"), ("remove", "B")])
        defer { fixture.document.close() }
        _ = try await fixture.document.remove([fixture.node("remove")], progress: Progress())
        _ = try await fixture.document.append(urls: [fixture.file("added")], to: "", progress: Progress())
        let strategy = Mutex<ArchiveUpdater.CommitStrategy?>(nil)
        try await ArchiveImportTransaction.didCommitUpdaterForTesting.withValue({ updater in strategy.withLock { $0 = updater.lastCommitStrategy } }) {
            try await fixture.save()
        }
        await fixture.document.waitForDeferredPreparationForTesting()
        XCTAssertEqual(strategy.withLock { $0 }, .rebuildThenAppend)
        XCTAssertEqual(try DeferredSaveFixture.contents(fixture.archive), ["keep": Data("A".utf8), "added": Data("new".utf8)])
        XCTAssertFalse(fixture.document.isDocumentEdited)
    }

    private func compare(_ kind: SingleCopyZIPFixtures.Kind) throws {
        let directory = try ArchiveTestDirectory(), source = try SingleCopyZIPFixtures.make(kind, in: directory)
        let encrypted = kind == .zipCrypto || kind == .aes
        let entries = try ArchiveReader.open(url: source, options: .kaitoFinder()).entries
        if kind == .ditto { XCTAssertTrue(entries.contains { $0.name.contains("__MACOSX/") && $0.name.contains("._") }) }
        let files = entries.filter { $0.kind == .file }
        XCTAssertGreaterThanOrEqual(files.count, 3)
        let addition = directory.url.appendingPathComponent("new-file")
        try Data("fixed addition".utf8).write(to: addition)
        try FileManager.default.setAttributes([.modificationDate: Self.date], ofItemAtPath: addition.path)
        for operation in 0..<(encrypted ? 2 : 4) {
            let app = directory.url.appendingPathComponent("app-\(operation).zip")
            let conventional = directory.url.appendingPathComponent("conventional-\(operation).zip")
            try FileManager.default.copyItem(at: source, to: app)
            try FileManager.default.copyItem(at: source, to: conventional)
            let original = try Data(contentsOf: app), identity = try ArchiveFileIdentity.capture(url: app)
            var pending = ArchivePendingChanges()
            if operation == 0 || operation == 3 {
                pending.removals = [.init(index: files[0].index, expectedName: files[0].name, baseGeneration: 0)]
            }
            if operation == 1 || operation == 3 {
                let entry = files[1]
                pending.renames[.init(index: entry.index, expectedName: entry.name, baseGeneration: 0)] = "longer-renamed"
            }
            if operation >= 2 {
                let stamp = try ArchiveImportSourceStamp(addition)
                pending.additions = [.init(id: UUID(), path: "added", stagedURL: addition, sourceStamp: stamp, stagedStamp: stamp)]
            }
            if operation == 3 {
                pending.removals.insert(.init(index: files[2].index, expectedName: files[2].name, baseGeneration: 0))
                pending.createdFolders = [.init(id: UUID(), path: "new-folder/", date: Self.date)]
            }
            let plan = try ArchiveSaveReplayPlan(base: entries, generation: 0, pending: pending)
            let old = try ArchiveUpdater.open(url: conventional)
            try plan.replay(on: old, progress: Progress()); try old.commit()
            try ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                try Self.checkWork(work, archive: app, original: original, identity: identity)
            }) {
                _ = try ArchiveImportTransaction.publish(archive: app, mode: .inPlace, options: .init(), progress: Progress(),
                    willPublish: {
                        XCTAssertEqual(try ArchiveFileIdentity.capture(url: app), identity)
                        XCTAssertEqual(try Data(contentsOf: app), original)
                    }, deferredPlan: plan, expectedOutput: .init(plan: plan, mode: .inPlace)) {
                        try plan.replay(on: $0, progress: Progress())
                    }
            }
            XCTAssertEqual(try Data(contentsOf: app), try Data(contentsOf: conventional), "\(kind) operation=\(operation)")
            try Self.assertNoWork(in: directory.url)
        }
    }

    func testZIP64MatchesConventionalUpdaterBytes() throws { try compare(.zip64) }
    func testDittoAppleDoubleMatchesConventionalUpdaterBytes() throws { try compare(.ditto) }
    func testUnsignedDescriptorMatchesConventionalUpdaterBytes() throws { try compare(.unsignedDescriptor) }
    func testZipCryptoBit3MatchesConventionalUpdaterBytes() throws { try compare(.zipCrypto) }
    func testAESMatchesConventionalUpdaterBytes() throws { try compare(.aes) }
    func testCentralOrderAndGapsMatchConventionalUpdaterBytes() throws { try compare(.reordered); try compare(.gaps) }
    func testUnicodePathExtraMatchesConventionalUpdaterBytes() throws { try compare(.unicodePath) }

    func testCommitCancellationLeavesOriginalAndCleansWork() async throws {
        let directory = try ArchiveTestDirectory(), url = try Self.archive(in: directory.url)
        let original = try Data(contentsOf: url), identity = try ArchiveFileIdentity.capture(url: url)
        let entered = Mutex(false)
        let task = Task {
            try ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, .commit) = event {
                    entered.withLock { $0 = true }
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }) {
                let entries = try ArchiveReader.open(url: url).entries
                return try ArchiveEditTransaction.run(plan: .init(removals: [.init(entries[0])], renames: [], existing: entries),
                    archive: url, mode: .inPlace, progress: Progress())
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled commit published") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(entered.withLock { $0 })
        XCTAssertEqual(try Data(contentsOf: url), original); XCTAssertEqual(try ArchiveFileIdentity.capture(url: url), identity)
        try Self.assertNoWork(in: directory.url)
    }

    private func injectedFailure(in root: URL) throws {
        let url = try Self.archive(in: root), original = try Data(contentsOf: url), identity = try ArchiveFileIdentity.capture(url: url)
        let entries = try ArchiveReader.open(url: url).entries
        XCTAssertThrowsError(try ArchiveImportTransaction.didCommitForTesting.withValue({ work in
            try Self.checkWork(work, archive: url, original: original, identity: identity)
            throw Injected.stop
        }) {
            try ArchiveEditTransaction.run(plan: .init(removals: [.init(entries[0])], renames: [], existing: entries),
                archive: url, mode: .inPlace, progress: Progress())
        }) { XCTAssertTrue($0 is Injected) }
        XCTAssertEqual(try Data(contentsOf: url), original); XCTAssertEqual(try ArchiveFileIdentity.capture(url: url), identity)
        try Self.assertNoWork(in: root)
    }

    func testCommitHookFailureCleansWork() throws {
        let directory = try ArchiveTestDirectory(); try injectedFailure(in: directory.url)
    }
    func testHFSPlusSingleCopyEditsSavesAndCleanup() async throws {
        let disk = try VolumePublishTestDisk("HFS+")
        try await immediateAndDeferred(in: disk.mount); try injectedFailure(in: disk.mount)
    }
    func testExFATSingleCopyEditsSavesAndCleanup() async throws {
        let disk = try VolumePublishTestDisk("ExFAT")
        try await immediateAndDeferred(in: disk.mount); try injectedFailure(in: disk.mount)
    }

    func testGatekeeperRefusalsMatchConventionalOpenAndCleanWork() throws {
        for damage in ["prefix", "tail", "local"] {
            let directory = try ArchiveTestDirectory(), url = try Self.archive(in: directory.url)
            let entries = try ArchiveReader.open(url: url).entries
            var bytes = try Data(contentsOf: url)
            switch damage {
            case "prefix": bytes = Data("SFX!".utf8) + bytes
            case "tail": bytes.append(0)
            default: bytes[0] = 0
            }
            try bytes.write(to: url)
            var expected: UpdaterError?
            do { _ = try ArchiveUpdater.open(url: url); XCTFail("Conventional open accepted \(damage)") }
            catch { expected = try XCTUnwrap(error as? UpdaterError) }
            XCTAssertThrowsError(try ArchiveEditTransaction.run(plan: .init(removals: [.init(entries[0])], renames: [], existing: entries),
                archive: url, mode: .inPlace, progress: Progress())) { XCTAssertEqual($0 as? UpdaterError, expected) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            try Self.assertNoWork(in: directory.url)
        }
    }
}
