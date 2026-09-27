import AppKit
import CryptoKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ByteProgressIntegrationTests: XCTestCase {
    private final class Trace: Sendable {
        struct Sample: Sendable { let slot: ArchiveWriteProgress.Slot; let done: Int64; let total: Int64 }
        let values = Mutex<[Sample]>([])
        func record(_ slot: ArchiveWriteProgress.Slot, _ done: Int64, _ total: Int64) {
            values.withLock { $0.append(.init(slot: slot, done: done, total: total)) }
        }
        func samples(_ slot: ArchiveWriteProgress.Slot) -> [Sample] { values.withLock { $0.filter { $0.slot == slot } } }
        func assertComplete(_ progress: Progress, items: Int, file: StaticString = #filePath, line: UInt = #line) {
            let all = values.withLock { $0 }
            XCTAssertFalse(all.isEmpty, file: file, line: line)
            XCTAssertTrue(all.allSatisfy { $0.done <= $0.total }, file: file, line: line)
            XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { $0.done <= $1.done }, file: file, line: line)
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount, file: file, line: line)
            XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, items, file: file, line: line)
            XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, items, file: file, line: line)
        }
    }

    private func file(_ directory: URL, name: String = "input.bin", mib: Int, random: Bool = true) throws -> URL {
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var bytes = Data(repeating: 0x61, count: 1 << 20)
        for _ in 0..<mib {
            if random { bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) } }
            try output.write(contentsOf: bytes)
        }
        return url
    }

    private func archive(_ directory: URL, format: GyoshukuKit.ArchiveFormat, count: Int = 1, mib: Int = 0) throws -> URL {
        let url = directory.appendingPathComponent("original." + ArchiveCreationPlan.filenameExtension(for: format))
        let writer = try ArchiveWriter.create(url: url, format: format, options: .init(compressionMethod: .stored, compressionThreads: 8))
        let data = Data(repeating: 0x62, count: max(1, mib << 20))
        for index in 0..<count { try writer.add(data: data, as: "folder/f\(index).txt") }
        try writer.finish()
        return url
    }

    func testImportPlanCountsOnlyRegularFileContents() throws {
        let directory = try ArchiveTestDirectory()
        let regular = try file(directory.url, mib: 1), empty = try file(directory.url, name: "empty", mib: 0)
        let folder = directory.url.appendingPathComponent("dir"), link = directory.url.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let plan = try ArchiveImportPlan.build(urls: [regular, empty, folder, link], folder: "", existing: [], progress: Progress())
        XCTAssertTrue(plan.failures.isEmpty)
        XCTAssertEqual(plan.items.map(\.byteCount), [1 << 20, 0, 0, 0])
    }

    func testLargeImmediateAdditionInEveryRequiredUpdater() async throws {
        let directory = try ArchiveTestDirectory(), source = try file(directory.url, mib: 64)
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar, .tarGzip, .lha, .sevenZip] {
            let url = try archive(directory.url, format: format)
            let session = try ArchiveSession(url: url, writerOptions: { _ in .init(compressionThreads: 8) })
            XCTAssertEqual(session.capabilities.mode, format == .zip ? .inPlace : .update(format))
            let progress = Progress(), trace = Trace()
            let result = try await ArchiveWriteProgress.didCreditForTesting.withValue(trace.record) {
                try await session.append(urls: [source], to: "", progress: progress, willPublish: {
                    XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount - 1)
                })
            }
            XCTAssertNil(result.reloadFailure)
            let addition = trace.samples(.addition(0))
            XCTAssertGreaterThanOrEqual(addition.count, 12, "\(format)")
            XCTAssertEqual(addition.last?.done, 64 << 20)
            XCTAssertGreaterThan(Set(addition.map(\.done)).count, 10)
            XCTAssertGreaterThanOrEqual(trace.samples(.finishAdditions).first?.done ?? 0, addition.last!.done)
            trace.assertComplete(progress, items: 1)
            await session.close()
        }
    }

    func testRewriteBothPlacementsMapsCarryAndDeferredReads() async throws {
        let directory = try ArchiveTestDirectory(), source = try file(directory.url, mib: 16, random: false)
        for beginning in [false, true] {
            let url = try archive(directory.url, format: .tarGzip, mib: 32)
            let options = WriterOptions(compressionThreads: 8, additionPlacement: beginning ? .beginning : .end, carriedTarOwnerIDs: .reset)
            let session = try ArchiveSession(url: url, writerOptions: { _ in options })
            XCTAssertEqual(session.capabilities.mode?.resolved(with: options), .rewrite(.tarGzip))
            let progress = Progress(), trace = Trace()
            _ = try await ArchiveWriteProgress.didCreditForTesting.withValue(trace.record) {
                try await session.append(urls: [source], to: "", progress: progress)
            }
            let addition = trace.samples(.addition(0))
            if beginning {
                XCTAssertGreaterThan(Set(addition.map(\.done)).count, 2)
            } else {
                XCTAssertEqual(addition.count, 2)
                XCTAssertEqual(addition.map(\.done), [1, 1])
            }
            XCTAssertGreaterThanOrEqual(trace.samples(.commit).count, 6)
            trace.assertComplete(progress, items: 1)
            await session.close()
            try FileManager.default.removeItem(at: url)
        }
    }

    func testLargeDeleteAndFolderMoveHaveByteCommitProgress() throws {
        let directory = try ArchiveTestDirectory()
        for (format, moving): (GyoshukuKit.ArchiveFormat, Bool) in [(.zip, false), (.zip, true), (.tar, false)] {
            let url = try archive(directory.url, format: format, count: 200, mib: 1)
            let entries = try ArchiveReader.open(url: url).entries
            let plan = ArchiveEditPlan(removals: moving ? [] : [.init(entries[0])],
                renames: moving ? entries.map { .init(entry: .init($0), path: "moved-longer/" + $0.name) } : [], existing: entries, format: format)
            let progress = Progress(), trace = Trace()
            _ = try ArchiveWriteProgress.didCreditForTesting.withValue(trace.record) {
                try ArchiveEditTransaction.run(plan: plan, archive: url, mode: format == .zip ? .inPlace : .update(.tar), progress: progress)
            }
            XCTAssertGreaterThanOrEqual(trace.samples(.commit).count, 10)
            trace.assertComplete(progress, items: moving ? 200 : 1)
            try FileManager.default.removeItem(at: url)
        }
    }

    func testCreationAndUnchangedConversionCountOutputItems() throws {
        let directory = try ArchiveTestDirectory(), large = try file(directory.url, mib: 64)
        let folder = directory.url.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let small = try (0..<10).map { index in
            let url = directory.url.appendingPathComponent("small\(index)")
            try Data("small contents".utf8).write(to: url)
            return url
        }
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tarXZ] {
            let output = directory.url.appendingPathComponent("created." + ArchiveCreationPlan.filenameExtension(for: format))
            let progress = Progress(), trace = Trace()
            _ = try ArchiveWriteProgress.didCreditForTesting.withValue(trace.record) {
                try ArchiveCreationTransaction.run(plan: .init(sources: [large, folder] + small, destination: output, format: format,
                    options: .init(compressionThreads: 8)), progress: progress, willPublish: {
                        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount - 1)
                    })
            }
            XCTAssertGreaterThanOrEqual(trace.samples(.addition(0)).count, 12)
            XCTAssertFalse(trace.samples(.finishAdditions).isEmpty)
            trace.assertComplete(progress, items: 12)
        }
        let original = try archive(directory.url, format: .tar, count: 20)
        let entries = try ArchiveReader.open(url: original).entries
        let output = directory.url.appendingPathComponent("converted.zip"), progress = Progress(), trace = Trace()
        _ = try ArchiveWriteProgress.didCreditForTesting.withValue(trace.record) {
            try ArchiveCreationTransaction.run(plan: .init(sources: [], destination: output, format: .zip,
                existing: .init(url: original, password: nil, entries: entries)), progress: progress)
        }
        trace.assertComplete(progress, items: 20)
        XCTAssertEqual(try ArchiveReader.open(url: output).entries.count, 20)
    }

    func testDeferredSaveCountsTwoAdditionsRenameAndFolder() async throws {
        let directory = try ArchiveTestDirectory()
        let large = try file(directory.url, mib: 16), empty = try file(directory.url, name: "empty", mib: 0)
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar] {
            let url = try archive(directory.url, format: format), session = try ArchiveSession(url: url)
            let snapshot = try await session.deferredSnapshot()
            var pending = ArchivePendingChanges()
            pending.renames[.init(index: 0, expectedName: snapshot.entries[0].name, baseGeneration: snapshot.generation)] = "renamed"
            pending.createdFolders = [.init(id: UUID(), path: "new-folder")]
            pending.additions = try [large, empty].map { source in
                let stamp = try ArchiveImportSourceStamp(source)
                return .init(id: UUID(), path: source.lastPathComponent, stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)
            }
            let progress = Progress(), trace = Trace(), publication = ArchiveSavePublication()
            defer { publication.finish() }
            let result = try await ArchiveWriteProgress.didCreditForTesting.withValue(trace.record) {
                try await session.savePending(pending, baseGeneration: snapshot.generation, progress: progress, publication: publication)
            }
            XCTAssertNil(result.reloadFailure)
            XCTAssertGreaterThanOrEqual(trace.samples(.addition(0)).count, 5)
            trace.assertComplete(progress, items: 4)
            await session.close()
        }
    }

    func testConversionReplayOffsetsAdditionsAndOmitsRootFromItemCount() throws {
        let directory = try ArchiveTestDirectory(), original = try archive(directory.url, format: .tar, count: 3)
        let entries = try ArchiveReader.open(url: original).entries
        var pending = ArchivePendingChanges()
        pending.removals = [.init(index: 0, expectedName: entries[0].name, baseGeneration: 0)]
        pending.renames[.init(index: 1, expectedName: entries[1].name, baseGeneration: 0)] = "renamed"
        pending.createdFolders = [.init(id: UUID(), path: "created-folder")]
        pending.additions = try ["staged-a", "staged-b"].map { name in
            let url = directory.url.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            let stamp = try ArchiveImportSourceStamp(url)
            return .init(id: UUID(), path: name, stagedURL: url, sourceStamp: stamp, stagedStamp: stamp)
        }
        let replay = try ArchiveSaveReplayPlan(base: entries, generation: 0, pending: pending)
        let extra = try file(directory.url, name: "extra", mib: 1)
        let output = directory.url.appendingPathComponent("with-pending.zip"), progress = Progress(), trace = Trace()
        _ = try ArchiveWriteProgress.didCreditForTesting.withValue(trace.record) {
            try ArchiveCreationTransaction.run(plan: .init(sources: [extra], destination: output, format: .zip,
                existing: .init(url: original, password: nil, entries: entries, pending: replay)), progress: progress)
        }
        for index in 0..<3 { XCTAssertFalse(trace.samples(.addition(index)).isEmpty) }
        trace.assertComplete(progress, items: 6)
        XCTAssertEqual(try ArchiveReader.open(url: output).entries.count, 6)

        let rootArchive = try TarUpdateFixture.archive(directory.url,
            bytes: TarUpdateFixture.member("./", type: 53, body: Data()) + TarUpdateFixture.member("keep") + Data(count: 1024))
        let rootEntries = try ArchiveReader.open(url: rootArchive).entries
        XCTAssertEqual(rootEntries.count, 2)
        let rootProgress = Progress(), rootTrace = Trace(), rootOutput = directory.url.appendingPathComponent("without-root.zip")
        _ = try ArchiveWriteProgress.didCreditForTesting.withValue(rootTrace.record) {
            try ArchiveCreationTransaction.run(plan: .init(sources: [], destination: rootOutput, format: .zip,
                existing: .init(url: rootArchive, password: nil, entries: rootEntries)), progress: rootProgress)
        }
        rootTrace.assertComplete(rootProgress, items: 1)
        XCTAssertEqual(try ArchiveReader.open(url: rootOutput).entries.map(\.name), ["keep"])
    }

    @MainActor func testCancellationInEveryPhasePreservesOriginalAndUndo() async throws {
        for (format, slot, beginning): (GyoshukuKit.ArchiveFormat, ArchiveWriteProgress.Slot, Bool) in [
            (.zip, .addition(0), false), (.sevenZip, .finishAdditions, false), (.zip, .commit, false), (.tarGzip, .commit, true)
        ] {
            let fixture = try DeferredSaveFixture(format: format, behavior: .immediate)
            fixture.store.preferences.additionPosition = beginning ? .beginning : .end
            let document = fixture.document, original = try ArchiveSetIdentity.capture(url: fixture.archive)
            defer { document.close() }
            let digest = SHA256.hash(data: try Data(contentsOf: fixture.archive))
            let source = try file(fixture.directory.url, mib: 16), progress = Progress(), calls = Mutex(0)
            do {
                try await ArchiveWriteProgress.didCreditForTesting.withValue({ current, _, _ in
                    guard current == slot else { return }
                    let n = calls.withLock { $0 += 1; return $0 }
                    if n == (slot == .addition(0) ? 2 : 1) { progress.cancel() }
                }) {
                    _ = try await document.append(urls: [source], to: "", progress: progress)
                }
                XCTFail("Expected cancellation in \(slot)")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertGreaterThan(calls.withLock { $0 }, 0)
            XCTAssertEqual(try ArchiveSetIdentity.capture(url: fixture.archive), original)
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: fixture.archive)), digest)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
            XCTAssertFalse(document.undoManager?.canUndo ?? false)
            try assertNoWork(fixture.directory.url)
            await document.prepareForTermination()
        }
    }

    func testCreationCancellationRemovesTemporaryOutput() throws {
        let directory = try ArchiveTestDirectory(), source = try file(directory.url, mib: 16)
        let output = directory.url.appendingPathComponent("new.tar.xz"), progress = Progress()
        XCTAssertThrowsError(try ArchiveWriteProgress.didCreditForTesting.withValue({ slot, _, _ in
            if slot == .finishAdditions { progress.cancel() }
        }) {
            try ArchiveCreationTransaction.run(plan: .init(sources: [source], destination: output, format: .tarXZ), progress: progress)
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoWork(directory.url)
    }

    func testCancellationAfterRenameStillCompletesLedgerAndOperation() async throws {
        let directory = try ArchiveTestDirectory(), url = try archive(directory.url, format: .zip)
        let session = try ArchiveSession(url: url), progress = Progress()
        let operation = Task {
            try await ArchiveImportTransaction.didPublishForTesting.withValue({ _ in
                progress.cancel()
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try await session.createFolder(in: "", baseName: "published", progress: progress)
            }
        }
        let result = try await operation.value
        XCTAssertEqual(result.addedPaths, ["published/"])
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 1)
        XCTAssertTrue(progress.isCancelled)
        await session.close()
    }

    private func assertNoWork(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".KaitoFinder-add-") || $0.hasPrefix(".KaitoFinder-new-") }, file: file, line: line)
    }
}
