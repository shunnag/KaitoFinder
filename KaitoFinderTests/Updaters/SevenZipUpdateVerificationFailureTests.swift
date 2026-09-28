import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class SevenZipUpdateVerificationFailureTests: XCTestCase {
    func testWrongOrderPlainFolderAndSelfCheckFailuresPreserveSessionAndSource() async throws {
        for fault in ["order", "encryption", "self-check"] {
            let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("original.7z")
            let writer = try ArchiveWriter.create(url: archive, format: .sevenZip)
            try writer.add(data: Data("first".utf8), as: "first")
            try writer.add(data: Data("second".utf8), as: "second"); try writer.finish()
            let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
            let session = try ArchiveSession(url: archive), entries = await session.entries(), generation = session.generation
            let trace = SevenZipUpdateTrace()
            do {
                try await trace.observing {
                    try await ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
                        if fault == "self-check" { throw UpdaterRouteError.outputVerificationFailed(reason: "injected") }
                    }) {
                        try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                            let replacement = work.deletingLastPathComponent().appendingPathComponent("replacement.7z")
                            let reader = try SevenZipUpdateFixture.reader(work, password: fault == "encryption" ? "new" : nil)
                            let corrupted = try ArchiveWriter.create(url: replacement, format: .sevenZip)
                            if fault == "order" {
                                for entry in reader.entries.reversed() {
                                    if entry.kind == .directory { try corrupted.addDirectory(entry.name) }
                                    else { try corrupted.add(data: reader.read(entry), as: entry.name) }
                                }
                                try corrupted.finish()
                            } else {
                                try corrupted.add(data: reader.read(reader.entries[0]), as: reader.entries[0].name)
                                try corrupted.finish()
                                let mixed = work.deletingLastPathComponent().appendingPathComponent("mixed.7z")
                                let updater = try SevenZipUpdater.open(url: replacement, output: mixed, options: .init(password: "new"))
                                try updater.add(data: reader.read(reader.entries[1]), as: reader.entries[1].name)
                                try updater.commit()
                                try FileManager.default.removeItem(at: replacement)
                                try FileManager.default.moveItem(at: mixed, to: replacement)
                            }
                            try FileManager.default.removeItem(at: work)
                            try FileManager.default.moveItem(at: replacement, to: work)
                        }) {
                            if fault == "encryption" {
                                _ = try await session.updatePassword(.set, settings: .init(password: "new"), progress: Progress())
                            } else { _ = try await session.createFolder(in: "", baseName: "new", progress: Progress()) }
                        }
                    }
                }
                XCTFail("Corrupt output must not publish")
            } catch {
                XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed)
                switch (error as? ArchivePublicationError)?.reason {
                case .projection: XCTAssertEqual(fault, "order")
                case .encryption: XCTAssertEqual(fault, "encryption")
                case .updaterVerification: XCTAssertEqual(fault, "self-check")
                default: XCTFail("Unexpected verification failure: \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: archive), original)
            XCTAssertEqual(try ArchiveFileIdentity.capture(url: archive), identity)
            let unchanged = await session.entries()
            XCTAssertEqual(unchanged, entries); XCTAssertEqual(session.generation, generation)
            XCTAssertEqual(session.capabilities.mode, .update(.sevenZip))
            XCTAssertTrue(trace.adoptions.withLock { $0.isEmpty })
            XCTAssertTrue(trace.fallbacks.withLock { $0.isEmpty })
            XCTAssertFalse(trace.stages.withLock { $0.contains(.reloadOpen) || $0.contains(.publish) })
            try ArchiveOracle.assertNoWorkFiles(in: directory.url)
            // 同じ reader で次の編集もできる。
            _ = try await session.rename(SevenZipUpdateFixture.selection(entries[0]), to: "retry", progress: Progress())
            XCTAssertEqual(session.generation, generation + 1)
            await session.close()
        }
    }

    func testRequiresRewriteAfterOpenNeverRepeatsMutation() throws {
        let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.make(directory.url)
        let original = try Data(contentsOf: archive), entries = try SevenZipUpdateFixture.reader(archive).entries
        let mutations = ArchiveTestCounter(), fallbacks = ArchiveTestCounter()
        for duringCommit in [false, true] {
            XCTAssertThrowsError(try ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallbacks.increment() }) {
                try ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({ throw UpdaterRouteError.requiresRewrite(reason: "commit") }) {
                    try ArchiveImportTransaction.publish(archive: archive, mode: .update(.sevenZip), options: .init(), progress: Progress(),
                        willPublish: nil, expectedOutput: .init(existing: entries, mode: .update(.sevenZip))) { _ in
                            mutations.increment()
                            if !duringCommit { throw UpdaterRouteError.requiresRewrite(reason: "mutate") }
                        }
                }
            }) { XCTAssertTrue($0 is UpdaterRouteError) }
            XCTAssertEqual(try Data(contentsOf: archive), original)
        }
        XCTAssertEqual(mutations.value, 2); XCTAssertEqual(fallbacks.value, 0)
    }

    func testZeroWorkProgressIgnoresCallerMeterAndCancellationPreservesSource() throws {
        let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.make(directory.url)
        let entries = try SevenZipUpdateFixture.reader(archive).entries, progress = Progress(totalUnitCount: 1)
        try ArchiveImportTransaction.publish(archive: archive, mode: .update(.sevenZip), options: .init(), progress: progress,
            commitProgress: { _ in XCTFail("7z must use its own meter") },
            willPublish: nil, expectedOutput: .init(existing: entries, mode: .update(.sevenZip))) { _ in }
        XCTAssertEqual(progress.totalUnitCount, 1001); XCTAssertEqual(progress.completedUnitCount, 1001)
        let original = try Data(contentsOf: archive), cancelled = Progress(totalUnitCount: 1)
        XCTAssertThrowsError(try ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({ cancelled.cancel() }) {
            try ArchiveImportTransaction.publish(archive: archive, mode: .update(.sevenZip), options: .init(), progress: cancelled,
                willPublish: nil, expectedOutput: .init(existing: entries, mode: .update(.sevenZip))) { _ in }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    func testProjectionKeepsRootSizesAndChecksEncryptionInBothRoutes() throws {
        let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.frozen("lib", at: directory.url)
        let reader = try SevenZipUpdateFixture.reader(archive), entries = reader.entries
        let projection = ArchiveOutputProjection(existing: entries, mode: .update(.sevenZip), sevenZipEncryption: false)
        XCTAssertEqual(projection.entries.map(\.name), entries.map(\.name))
        XCTAssertEqual(projection.entries.map(\.size), entries.map(\.uncompressedSize))
        try projection.validate(reader)
        XCTAssertThrowsError(try projection.validate(entries: Array(entries.reversed())))
        XCTAssertThrowsError(try projection.validate(entries: Array(entries.dropLast())))
        for mode: ArchiveCapabilities.Mode in [.update(.sevenZip), .rewrite(.sevenZip)] {
            let expectation = ArchiveOutputProjection(projected: entries, mode: mode, sevenZipEncryption: true)
            if case .encryption = expectation.validationFailure(entries: entries) {} else { XCTFail("Missing encryption failure") }
        }
    }
}
