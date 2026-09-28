import CryptoKit
import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class BatchImportTests: XCTestCase {
    private static let updateFormats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .sevenZip, .lha]
    private static let allFormats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha]

    private func archive(in root: URL, format: GyoshukuKit.ArchiveFormat) throws -> URL {
        let url = root.appendingPathComponent("original." + ArchiveCreationPlan.filenameExtension(for: format))
        let writer = try ArchiveWriter.create(url: url, format: format)
        try writer.add(data: Data("original".utf8), as: "original.txt")
        try writer.addDirectory("target")
        try writer.finish()
        return url
    }

    private func sources(in root: URL, count: Int = 5) throws -> [URL] {
        try (0..<count).map { index in
            let url = root.appendingPathComponent(String(format: "file-%04d.txt", index))
            try Data("payload \(index)".utf8).write(to: url)
            return url
        }
    }

    private func assertNoWork(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains {
            $0.hasPrefix(".KaitoFinder-add-") || $0.hasPrefix(".KaitoFinder-new-") || $0.hasPrefix(".gyoshuku-")
        }, names.description, file: file, line: line)
    }

    /// Records the batch boundary even if GyoshukuKit later makes an empty batch a no-op.
    private final class RenameOnlyEditor: ArchiveEditing {
        let base: any ArchiveEditing
        var batchCalls = 0
        init(_ base: any ArchiveEditing) { self.base = base }
        var entryNames: [String] { base.entryNames }
        func add(_ additions: [ArchiveAddition], events: ((ArchiveAdditionEvent) throws -> Void)?) throws {
            batchCalls += 1
            try base.add(additions, events: events)
        }
        func add(contentsOf url: URL, as path: String) throws { XCTFail("Unexpected file addition") }
        func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?) throws { XCTFail("Unexpected data addition") }
        func addDirectory(_ path: String) throws { XCTFail("Unexpected folder addition") }
        func remove(entriesAt indices: [Int]) throws { XCTFail("Unexpected removal") }
        func rename(entryAt index: Int, to path: String) throws { try base.rename(entryAt: index, to: path) }
        func commit() throws { try base.commit() }
    }

    func testRenameOnlyDeferredSaveDoesNotCallBatchInAnyUpdater() throws {
        for format in Self.updateFormats {
            for usesLedger in [false, true] {
                let directory = try ArchiveTestDirectory(), url = try archive(in: directory.url, format: format)
                let entries = try ArchiveReader.open(url: url).entries
                let entry = try XCTUnwrap(entries.first { $0.name == "original.txt" })
                var pending = ArchivePendingChanges()
                pending.renames[.init(index: entry.index, expectedName: entry.name, baseGeneration: 0)] = "renamed.txt"
                let plan = try ArchiveSaveReplayPlan(base: entries, generation: 0, pending: pending, format: format)
                let progress = Progress(totalUnitCount: 2)
                let ledger = usesLedger ? ArchiveWriteProgress(progress: progress, plan: .init(counted: 1,
                    additions: [], itemCount: 1, carriedBytes: ArchiveWriteProgress.carriedBytes(plan.projected),
                    changesExisting: true)) : nil
                let mode: ArchiveCapabilities.Mode = format == .zip ? .inPlace : .update(format)
                try ArchiveImportTransaction.publish(archive: url, mode: mode, options: .init(), progress: progress,
                    ledger: ledger, willPublish: nil,
                    sessionReader: try ArchiveReader.open(url: url, options: .kaitoFinder()),
                    deferredPlan: plan, expectedOutput: .init(plan: plan, mode: mode)) { updater in
                    XCTAssertFalse(updater is ArchiveRewriter, "\(format)")
                    let observed = RenameOnlyEditor(updater)
                    try plan.replay(on: observed, progress: progress, ledger: ledger)
                    XCTAssertEqual(observed.batchCalls, 0, "\(format), ledger: \(usesLedger)")
                    XCTAssertEqual(progress.completedUnitCount, 1, "Only the rename should be counted")
                    if usesLedger { XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 1) }
                }
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount, "\(format)")
                if usesLedger {
                    XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 1)
                    XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 1)
                }
                XCTAssertEqual(try ArchiveReader.open(url: url).entries.map(\.name), plan.projected.map(\.name))
                XCTAssertEqual(try DeferredSaveFixture.contents(url)["renamed.txt"], Data("original".utf8))
                try assertNoWork(in: directory.url)
            }
        }
    }

    func testCreationWithoutImportedItemsKeepsProgressAndContents() throws {
        for format in Self.allFormats {
            let directory = try ArchiveTestDirectory(), original = try archive(in: directory.url, format: .zip)
            let entries = try ArchiveReader.open(url: original).entries
            let output = directory.url.appendingPathComponent("converted." + ArchiveCreationPlan.filenameExtension(for: format))
            let progress = Progress()
            _ = try ArchiveCreationTransaction.run(plan: .init(sources: [], destination: output, format: format,
                existing: .init(url: original, password: nil, entries: entries)), progress: progress)
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount, "\(format)")
            XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, entries.count)
            XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, entries.count)
            XCTAssertEqual(try DeferredSaveFixture.contents(output), try DeferredSaveFixture.contents(original))
            try assertNoWork(in: directory.url)
        }
        let directory = try ArchiveTestDirectory(), progress = Progress()
        let empty = directory.url.appendingPathComponent("empty.zip")
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: [], destination: empty, format: .zip), progress: progress)
        XCTAssertTrue(try ArchiveReader.open(url: empty).entries.isEmpty)
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 0)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 0)
        try assertNoWork(in: directory.url)
    }

    func testEmptyImportLeavesArchiveAndProgressUntouched() throws {
        for format in Self.updateFormats {
            let directory = try ArchiveTestDirectory(), url = try archive(in: directory.url, format: format)
            let before = try ArchiveOracle.digest(url), entries = try ArchiveReader.open(url: url).entries
            let plan = try ArchiveImportPlan.build(urls: [], folder: "", existing: entries, progress: Progress(), format: format)
            let progress = Progress(totalUnitCount: 7)
            progress.completedUnitCount = 3
            let result = try ArchiveImportTransaction.run(plan: plan, archive: url,
                mode: format == .zip ? .inPlace : .update(format), progress: progress)
            XCTAssertTrue(result.addedPaths.isEmpty)
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertNil(result.publishedIdentity)
            XCTAssertEqual(progress.totalUnitCount, 7)
            XCTAssertEqual(progress.completedUnitCount, 3)
            XCTAssertEqual(try ArchiveOracle.digest(url), before)
            try assertNoWork(in: directory.url)
        }
    }

    func testThirdUnreadableImportUsesItsArchivePathAndPreservesOriginal() async throws {
        for format in Self.updateFormats {
            let directory = try ArchiveTestDirectory(), urls = try sources(in: directory.url)
            let url = try archive(in: directory.url, format: format), before = try ArchiveOracle.digest(url)
            let session = try ArchiveSession(url: url, writerOptions: { _ in .init(compressionThreads: 8) })
            let progress = Progress(), started = Mutex<[URL]>([]), finished = Mutex<[Int]>([])
            defer { XCTAssertEqual(chmod(urls[2].path, 0o600), 0) }
            do {
                _ = try await ArchiveImportTransaction.willAddFileForTesting.withValue({ source in
                    started.withLock { $0.append(source) }
                    // Run after planning/verification, but before this item's first lstat/open.
                    if source == urls[2] { XCTAssertEqual(chmod(source.path, 0), 0) }
                }) {
                    try await session.append(urls: urls, to: "target", progress: progress,
                                             didProcess: { index in finished.withLock { $0.append(index) } })
                }
                XCTFail("Unreadable third item was published: \(format)")
            } catch {
                XCTAssertTrue(error is ExtractionFailure, "\(error)")
                XCTAssertEqual(ArchiveErrorText.describe(error),
                    "target/\(urls[2].lastPathComponent): " + ArchiveErrorText.describe(WriterError.io(operation: "open", code: EACCES)))
            }
            XCTAssertTrue(started.withLock { $0.contains(urls[2]) })
            XCTAssertEqual(finished.withLock { $0 }, [0, 1])
            XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 2)
            XCTAssertEqual(try ArchiveOracle.digest(url), before)
            XCTAssertEqual(session.generation, 0)
            try assertNoWork(in: directory.url)
            await session.close()
        }
    }

    func testThirdUnreadableCreationUsesItsPathAndPreservesDestination() throws {
        for format in Self.allFormats {
            let directory = try ArchiveTestDirectory(), urls = try sources(in: directory.url)
            let destination = try archive(in: directory.url, format: format), before = try ArchiveOracle.digest(destination)
            let progress = Progress(), started = Mutex<[URL]>([])
            defer { XCTAssertEqual(chmod(urls[2].path, 0o600), 0) }
            XCTAssertThrowsError(try ArchiveImportTransaction.willAddFileForTesting.withValue({ source in
                started.withLock { $0.append(source) }
                if source == urls[2] { XCTAssertEqual(chmod(source.path, 0), 0) }
            }) {
                try ArchiveCreationTransaction.run(plan: .init(sources: urls, destination: destination, format: format,
                                                               options: .init(compressionThreads: 8)), progress: progress)
            }) { error in
                XCTAssertTrue(error is ExtractionFailure, "\(error)")
                XCTAssertEqual(ArchiveErrorText.describe(error),
                    "\(urls[2].lastPathComponent): " + ArchiveErrorText.describe(WriterError.io(operation: "open", code: EACCES)))
            }
            XCTAssertTrue(started.withLock { $0.contains(urls[2]) })
            XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 2)
            XCTAssertEqual(try ArchiveOracle.digest(destination), before)
            try assertNoWork(in: directory.url)
        }
    }

    func testReplacedStagingCopyKeepsReplayErrorUnwrapped() throws {
        let directory = try ArchiveTestDirectory(), urls = try sources(in: directory.url)
        let url = try archive(in: directory.url, format: .zip), before = try ArchiveOracle.digest(url)
        let base = try ArchiveReader.open(url: url).entries
        let stamp = try ArchiveImportSourceStamp(urls[2])
        var pending = ArchivePendingChanges()
        pending.additions = [.init(id: UUID(), path: "staged.txt", stagedURL: urls[2], sourceStamp: stamp, stagedStamp: stamp)]
        let plan = try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending)
        try Data("replacement".utf8).write(to: urls[2], options: .atomic)
        let expected: String
        do { try stamp.verify(); return XCTFail("Replacement did not change the stamp") }
        catch { expected = ArchiveErrorText.describe(error) }
        let editor = try ArchiveUpdater.open(url: url)
        XCTAssertThrowsError(try plan.replay(on: editor, progress: Progress())) { error in
            XCTAssertTrue(error is ExtractionFailure)
            XCTAssertFalse(error is ArchiveAdditionError)
            XCTAssertEqual(ArchiveErrorText.describe(error), expected)
        }
        XCTAssertEqual(try ArchiveOracle.digest(url), before)
        try assertNoWork(in: directory.url)
    }

    private final class Marker: Error, @unchecked Sendable {}

    /// Deliberately uses ArchiveEditing's default batch implementation, like existing replay doubles.
    private final class ReplayEditor: ArchiveEditing {
        var entryNames: [String] { [] }
        var paths: [String] = []
        var onFile: (() throws -> Void)?
        func add(contentsOf url: URL, as path: String) throws { paths.append(path); try onFile?() }
        func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws { paths.append(path) }
        func addDirectory(_ path: String) throws { XCTFail("Reserved directory date was lost") }
        func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?) throws { XCTFail("Unexpected data") }
        func remove(entriesAt indices: [Int]) throws { XCTFail("Unexpected removal") }
        func rename(entryAt index: Int, to path: String) throws { XCTFail("Unexpected rename") }
        func commit() throws {}
    }

    private func replayPlan(_ urls: [URL]) throws -> ArchiveSaveReplayPlan {
        var pending = ArchivePendingChanges()
        pending.additions = try urls.map { url in
            let stamp = try ArchiveImportSourceStamp(url)
            return .init(id: UUID(), path: url.lastPathComponent, stagedURL: url, sourceStamp: stamp, stagedStamp: stamp)
        }
        pending.createdFolders = [.init(id: UUID(), path: "created/", date: Date(timeIntervalSince1970: 1_700_000_000))]
        return try ArchiveSaveReplayPlan(base: [], generation: 0, pending: pending)
    }

    func testReplayUnwrapsBatchFailureAndKeepsLedgerFreeItemCounts() throws {
        let directory = try ArchiveTestDirectory(), urls = try sources(in: directory.url)
        let plan = try replayPlan(urls), marker = Marker()
        let failing = ReplayEditor(), failedProgress = Progress(totalUnitCount: 6)
        failing.onFile = { if failing.paths.count == 3 { throw marker } }
        defer { failing.onFile = nil }
        XCTAssertThrowsError(try plan.replay(on: failing, progress: failedProgress)) { error in
            XCTAssertTrue((error as? Marker) === marker)
        }
        XCTAssertEqual(failing.paths, urls.prefix(3).map(\.lastPathComponent))
        XCTAssertEqual(failedProgress.completedUnitCount, 2)
        let successful = ReplayEditor(), progress = Progress(totalUnitCount: 6)
        try plan.replay(on: successful, progress: progress)
        XCTAssertEqual(successful.paths, urls.map(\.lastPathComponent) + ["created/"])
        XCTAssertEqual(progress.completedUnitCount, 6)
        XCTAssertEqual(progress.totalUnitCount, 6)
    }

    func testProgressOnlyCancellationStopsAtNextReplayWillStart() throws {
        let directory = try ArchiveTestDirectory(), urls = try sources(in: directory.url)
        let plan = try replayPlan(urls), editor = ReplayEditor(), progress = Progress(totalUnitCount: 6)
        editor.onFile = { progress.cancel(); XCTAssertFalse(Task.isCancelled) }
        XCTAssertThrowsError(try plan.replay(on: editor, progress: progress)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(Task.isCancelled)
        XCTAssertEqual(editor.paths, [urls[0].lastPathComponent])
        XCTAssertEqual(progress.completedUnitCount, 1)
    }

    func testProgressOnlyCancellationPreventsNextImportAndCreationHook() async throws {
        for creation in [false, true] {
            let directory = try ArchiveTestDirectory(), urls = try sources(in: directory.url)
            let url = try archive(in: directory.url, format: .zip), before = try ArchiveOracle.digest(url)
            let progress = Progress(), started = Mutex<[URL]>([])
            let session = try ArchiveSession(url: url, writerOptions: { _ in .init(compressionThreads: 8) })
            do {
                try await ArchiveImportTransaction.willAddFileForTesting.withValue({ source in
                    started.withLock { $0.append(source) }
                    progress.cancel()
                    XCTAssertFalse(Task.isCancelled)
                }) {
                    if creation {
                        _ = try ArchiveCreationTransaction.run(plan: .init(sources: urls, destination: url, format: .zip,
                            options: .init(compressionThreads: 8)), progress: progress)
                    } else { _ = try await session.append(urls: urls, to: "", progress: progress) }
                }
                XCTFail("Progress-only cancellation succeeded")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertFalse(Task.isCancelled)
            XCTAssertEqual(started.withLock { $0 }, [urls[0]])
            XCTAssertEqual(progress.completedUnitCount, 0)
            XCTAssertEqual(try ArchiveOracle.digest(url), before)
            try assertNoWork(in: directory.url)
            await session.close()
        }
    }

    private func openFiles(under root: URL) throws -> Set<String> {
        let prefix = root.resolvingSymlinksInPath().path + "/"
        return Set(try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap { name in
            guard let descriptor = Int32(name) else { return nil }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard path.withUnsafeMutableBytes({ fcntl(descriptor, F_GETPATH, $0.baseAddress!) }) == 0 else { return nil }
            let raw = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            let value = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
            return value.hasPrefix(prefix) ? "\(descriptor):\(value)" : nil
        })
    }

    func testThousandthCompletionCancellationJoinsReadersAndPreservesOriginal() async throws {
        for format in Self.updateFormats {
            let directory = try ArchiveTestDirectory(), urls = try sources(in: directory.url, count: 1_300)
            let url = try archive(in: directory.url, format: format), before = try ArchiveOracle.digest(url)
            let session = try ArchiveSession(url: url, writerOptions: { _ in .init(compressionThreads: 8) })
            // Readers may mmap and close their descriptors. Check the inventory against a known
            // open source first, so an empty inventory after cancellation cannot pass vacuously.
            let probe = open(urls[0].path, O_RDONLY | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(probe, 0)
            guard probe >= 0 else { throw ExtractionFailure.system(errno) }
            do {
                let visible = try openFiles(under: directory.url)
                XCTAssertTrue(visible.contains { $0.hasPrefix("\(probe):") }, "Missing descriptor \(probe) in \(visible)")
            }
            catch { close(probe); throw error }
            XCTAssertEqual(close(probe), 0)
            let descriptors = try openFiles(under: directory.url), completed = Mutex<[Int]>([]), progress = Progress()
            let task = Task.detached {
                try await session.append(urls: urls, to: "", progress: progress, didProcess: { index in
                    completed.withLock { $0.append(index) }
                    if index == 999 { withUnsafeCurrentTask { $0?.cancel() } }
                })
            }
            do { _ = try await task.value; XCTFail("Cancelled batch was published: \(format)") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertEqual(completed.withLock { $0 }, Array(0..<1_000))
            XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 1_000)
            XCTAssertEqual(try ArchiveOracle.digest(url), before)
            XCTAssertEqual(session.generation, 0)
            XCTAssertEqual(try openFiles(under: directory.url), descriptors)
            try assertNoWork(in: directory.url)
            await session.close()
            XCTAssertTrue(try openFiles(under: directory.url).isEmpty)
        }
    }

    func testDidProcessErrorRetainsIdentityAndPreventsPublication() async throws {
        let directory = try ArchiveTestDirectory(), urls = try sources(in: directory.url)
        let url = try archive(in: directory.url, format: .zip), before = try ArchiveOracle.digest(url), marker = Marker()
        let session = try ArchiveSession(url: url)
        do {
            _ = try await session.append(urls: urls, to: "", progress: Progress(), didProcess: { _ in throw marker })
            XCTFail("Callback failure was published")
        } catch { XCTAssertTrue((error as? Marker) === marker) }
        XCTAssertEqual(try ArchiveOracle.digest(url), before)
        try assertNoWork(in: directory.url)
        await session.close()
    }

    func testDidProcessBatchErrorIsNotAttributedToTheCurrentImport() async throws {
        let directory = try ArchiveTestDirectory(), urls = try sources(in: directory.url)
        let writer = try ArchiveWriter.create(url: directory.url.appendingPathComponent("failed.zip"), format: .zip)
        let failure: ArchiveAdditionError
        do {
            try writer.add([.init(path: "other-operation/missing", source: .contents(of: directory.url.appendingPathComponent("missing")))], events: nil)
            return XCTFail("Missing file was accepted")
        } catch { failure = try XCTUnwrap(error as? ArchiveAdditionError) }
        let url = try archive(in: directory.url, format: .zip), before = try ArchiveOracle.digest(url)
        let session = try ArchiveSession(url: url)
        do {
            _ = try await session.append(urls: urls, to: "", progress: Progress(), didProcess: { _ in throw failure })
            XCTFail("Callback batch error was published")
        } catch {
            let actual = try XCTUnwrap(error as? ArchiveAdditionError)
            XCTAssertEqual(actual.index, failure.index)
            XCTAssertEqual(actual.path, failure.path)
            XCTAssertEqual(actual.sourceURL, failure.sourceURL)
            XCTAssertEqual(ArchiveErrorText.describe(actual.underlying), ArchiveErrorText.describe(failure.underlying))
        }
        XCTAssertEqual(try ArchiveOracle.digest(url), before)
        try assertNoWork(in: directory.url)
        await session.close()
    }

    func testErrorTextFallbackUsesBatchPathAndRequestedLocalization() throws {
        let directory = try ArchiveTestDirectory(), missing = directory.url.appendingPathComponent("missing")
        let writer = try ArchiveWriter.create(url: directory.url.appendingPathComponent("output.zip"), format: .zip)
        XCTAssertThrowsError(try writer.add([.init(path: "inside/missing", source: .contents(of: missing))], events: nil)) { error in
            guard let failure = error as? ArchiveAdditionError else { return XCTFail("\(error)") }
            for language in ["en", "ja"] {
                let bundle = Bundle(path: Bundle(for: ArchiveDocument.self).path(forResource: language, ofType: "lproj")!)!
                XCTAssertEqual(ArchiveErrorText.describe(failure, bundle: bundle),
                               "inside/missing: " + ArchiveErrorText.describe(failure.underlying, bundle: bundle))
            }
        }
    }
}
