import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class LHAUpdateVerificationFailureTests: XCTestCase {
    func testMemberOrderAndUpdaterSelfVerificationFailuresKeepOriginalEditable() async throws {
        for selfVerification in [false, true] {
            let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.make(directory.url)
            let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
            let session = try ArchiveSession(url: archive), trace = LHAUpdateTrace()
            do {
                try await trace.observing {
                    try await ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
                        if selfVerification { throw UpdaterRouteError.outputVerificationFailed(reason: "injected") }
                    }) {
                        try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                            let bytes = try Data(contentsOf: work), reader = try ArchiveReader.open(url: work)
                            let first = try LHAUpdateFixture.group(reader.entries[0], in: bytes)
                            let second = try LHAUpdateFixture.group(reader.entries[1], in: bytes)
                            try (second + first + bytes.dropFirst(first.count + second.count)).write(to: work)
                        }) { _ = try await session.createFolder(in: "", baseName: "new", progress: Progress()) }
                    }
                }
                XCTFail("Corrupt output must not publish")
            } catch {
                XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed)
                if let failure = (error as? ArchivePublicationError)?.reason {
                    switch failure {
                    case .updaterVerification: XCTAssertTrue(selfVerification)
                    case .projection: XCTAssertFalse(selfVerification)
                    default: XCTFail("Unexpected verification failure: \(failure)")
                    }
                } else { XCTFail("Missing verification diagnostic") }
            }
            XCTAssertTrue(trace.fallbacks.withLock { $0.isEmpty })
            XCTAssertEqual(try Data(contentsOf: archive), original)
            XCTAssertEqual(try ArchiveFileIdentity.capture(url: archive), identity)
            XCTAssertEqual(session.capabilities.mode, .update(.lha))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).contains { $0.hasPrefix(".KaitoFinder-add-") })
            await session.close()
        }
    }

    func testRequiresRewriteAfterOpenNeverRepeatsMutation() throws {
        let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.make(directory.url)
        let original = try Data(contentsOf: archive), entries = try ArchiveReader.open(url: archive).entries
        let mutations = ArchiveTestCounter(), fallbacks = ArchiveTestCounter()
        for duringCommit in [false, true] {
            XCTAssertThrowsError(try ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallbacks.increment() }) {
                try ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({ throw UpdaterRouteError.requiresRewrite(reason: "commit") }) {
                    try ArchiveImportTransaction.publish(archive: archive, mode: .update(.lha), options: .init(), progress: Progress(),
                        willPublish: nil, expectedOutput: .init(existing: entries, mode: .update(.lha))) { _ in
                            mutations.increment()
                            if !duringCommit { throw UpdaterRouteError.requiresRewrite(reason: "mutate") }
                        }
                }
            }) { XCTAssertTrue($0 is UpdaterRouteError) }
            XCTAssertEqual(try Data(contentsOf: archive), original)
        }
        XCTAssertEqual(mutations.value, 2); XCTAssertEqual(fallbacks.value, 0)
    }

    func testZeroByteCommitProgressAndCancellation() throws {
        let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.make(directory.url)
        let entries = try ArchiveReader.open(url: archive).entries, progress = Progress(totalUnitCount: 1)
        try ArchiveImportTransaction.publish(archive: archive, mode: .update(.lha), options: .init(), progress: progress,
            willPublish: nil, expectedOutput: .init(existing: entries, mode: .update(.lha))) { _ in }
        XCTAssertEqual(progress.totalUnitCount, 1001); XCTAssertEqual(progress.completedUnitCount, 1001)
        let original = try Data(contentsOf: archive)
        XCTAssertThrowsError(try ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({ progress.cancel() }) {
            try ArchiveImportTransaction.publish(archive: archive, mode: .update(.lha), options: .init(), progress: progress,
                willPublish: nil, expectedOutput: .init(existing: entries, mode: .update(.lha))) { _ in }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    func testProjectionKeepsRootDirectorySizeAndRejectsWrongOrderKindAndSize() throws {
        let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.make(directory.url)
        let entries = try ArchiveReader.open(url: archive).entries
        let source = entries[2]
        func resized(_ entry: ArchiveEntry, size: UInt64, name: String? = nil) -> ArchiveEntry {
            ArchiveEntry(index: entry.index, rawName: entry.rawName, name: name ?? entry.name, pathComponents: entry.pathComponents,
                kind: entry.kind, uncompressedSize: size, compressedSize: entry.compressedSize, modificationDate: entry.modificationDate,
                posixPermissions: entry.posixPermissions, isEncrypted: false, solidGroup: -1, crc32: nil,
                methodDescription: entry.methodDescription, formatSpecific: entry.formatSpecific)
        }
        let directoryEntry = resized(source, size: 7, name: "./")
        let unusual = [directoryEntry] + entries.filter { $0.index != 2 }
        let projection = ArchiveOutputProjection(existing: unusual, mode: .update(.lha))
        XCTAssertEqual(projection.entries.map(\.name), unusual.map(\.name))
        XCTAssertEqual(projection.entries.map(\.size), unusual.map(\.uncompressedSize))
        try projection.validate(entries: unusual)
        XCTAssertThrowsError(try projection.validate(entries: Array(unusual.reversed())))
        XCTAssertThrowsError(try projection.validate(entries: Array(unusual.dropLast())))
        var wrong = unusual
        wrong[0] = unusual[1].pendingCopy(name: "./")
        XCTAssertThrowsError(try projection.validate(entries: wrong))
        wrong = unusual
        wrong[0] = resized(directoryEntry, size: 8)
        XCTAssertThrowsError(try projection.validate(entries: wrong))
        XCTAssertFalse(projection.resolving(.rewrite(.lha)).entries.contains { $0.name == "./" })
    }
}
