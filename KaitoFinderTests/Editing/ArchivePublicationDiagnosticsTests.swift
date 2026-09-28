import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePublicationDiagnosticsTests: XCTestCase {
    private func fixture() throws -> (ArchiveTestDirectory, URL, ArchiveEditPlan) {
        let directory = try ArchiveTestDirectory()
        let url = directory.url.appendingPathComponent("original.zip")
        try ReleaseReviewFixtures.zip([("private/keep", Data([1])), ("remove", Data([2]))]).write(to: url)
        let entries = try ArchiveReader.open(url: url, options: .kaitoFinder()).entries
        return (directory, url, .init(removals: [.init(entries[1])], renames: [], existing: entries))
    }

    func testIdentityDiagnosticsDistinguishPhasesAndDescriptorFromPath() throws {
        for phase: ArchiveVerificationFailure.Phase in [.beforeVerification, .beforePublication] {
            for replace in [false, true] {
                let (directory, url, plan) = try fixture(), original = try Data(contentsOf: url)
                let observed = Mutex<[ArchiveVerificationFailure]>([])
                let damage: @Sendable (URL) throws -> Void = { work in
                    if replace { try Data(contentsOf: work).write(to: work, options: .atomic) }
                    else {
                        let file = try FileHandle(forWritingTo: work)
                        defer { try? file.close() }
                        try file.seekToEnd(); try file.write(contentsOf: Data([0]))
                    }
                }
                XCTAssertThrowsError(try ArchiveVerificationFailure.observer.withValue({ reason in observed.withLock { $0.append(reason) } }) {
                    try ArchiveImportTransaction.didOpenVerificationSourceForTesting.withValue(phase == .beforeVerification ? damage : nil) {
                        try ArchiveImportTransaction.didVerifyForTesting.withValue(phase == .beforePublication ? damage : nil) {
                            try ArchiveEditTransaction.run(plan: plan, archive: url, mode: .inPlace, progress: Progress())
                        }
                    }
                }) { error in
                    let reason = (error as? ArchivePublicationError)?.reason
                    guard case .identity(let actualPhase, let anchor, let expected, let actual, let underlying) = reason else {
                        return XCTFail("Missing identity diagnosis: \(error)")
                    }
                    XCTAssertEqual(actualPhase, phase)
                    XCTAssertEqual(anchor, replace ? .path : .descriptor)
                    XCTAssertNotEqual(expected, actual); XCTAssertNil(underlying)
                    XCTAssertEqual(observed.withLock { $0 }, [reason!])
                    XCTAssertEqual(ArchiveErrorText.describe(error), ArchivePublicationError.verificationFailed.message())
                    XCTAssertFalse(reason!.description.contains(directory.url.path))
                }
                XCTAssertEqual(try Data(contentsOf: url), original)
            }
        }
    }

    func testMissingWorkReaderFormatAndProjectionDiagnostics() throws {
        for damage in ["source", "reader", "format", "missing", "size", "extra", "kind", "probe"] {
            let (directory, url, plan) = try fixture(), original = try Data(contentsOf: url)
            let mode: ArchiveCapabilities.Mode = damage == "format" ? .rewrite(.tar) : .inPlace
            XCTAssertThrowsError(try ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                switch damage {
                case "source": try FileManager.default.removeItem(at: work)
                case "reader": try Data([1, 2, 3]).write(to: work)
                case "format": try ReleaseReviewFixtures.zip([("private/keep", Data([1]))]).write(to: work)
                case "missing": try ReleaseReviewFixtures.zip([]).write(to: work)
                case "size": try ReleaseReviewFixtures.zip([("private/keep", Data([1, 2]))]).write(to: work)
                case "extra": try ReleaseReviewFixtures.zip([("private/keep", Data([1])), ("secret/extra", Data([2]))]).write(to: work)
                case "kind": try ReleaseReviewFixtures.zip([("private/keep/", Data())]).write(to: work)
                default:
                    var data = try Data(contentsOf: work); data.append(0); try data.write(to: work)
                }
            }) {
                try ArchiveEditTransaction.run(plan: plan, archive: url, mode: mode, progress: Progress())
            }) { error in
                guard let reason = (error as? ArchivePublicationError)?.reason else { return XCTFail("Missing \(damage) diagnosis") }
                switch (damage, reason) {
                case ("source", .sourceOpen), ("reader", .readerOpen), ("format", .format), ("probe", .outputProbe): break
                case ("missing", .projection(let expected, let actual)):
                    XCTAssertEqual(expected?.fileName, "keep"); XCTAssertNil(actual)
                case ("size", .projection(let expected, let actual)):
                    XCTAssertEqual(expected?.fileName, "keep"); XCTAssertEqual(expected?.size, 1)
                    XCTAssertEqual(actual?.fileName, "keep"); XCTAssertEqual(actual?.size, 2)
                case ("extra", .projection(let expected, let actual)):
                    XCTAssertNil(expected); XCTAssertEqual(actual?.fileName, "extra"); XCTAssertEqual(actual?.index, 1)
                case ("kind", .projection(let expected, let actual)):
                    XCTAssertEqual(expected?.kind, "file"); XCTAssertEqual(actual?.kind, "directory")
                default: XCTFail("\(damage): \(reason)")
                }
                XCTAssertFalse(reason.description.contains("private/")); XCTAssertFalse(reason.description.contains("secret/"))
                XCTAssertFalse(reason.description.contains(directory.url.path))
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testDiagnosticsNeverDescribeUnderlyingErrorsOrExposeThemInNSError() {
        let secret = "/private/password=never-log-this"
        let underlying = NSError(domain: secret, code: 123, userInfo: [NSLocalizedDescriptionKey: secret])
        let reason = ArchiveVerificationFailure.readerOpen(.init(underlying))
        XCTAssertFalse(reason.description.contains(secret)); XCTAssertTrue(reason.description.contains("123"))
        let error = ArchivePublicationError(reason: reason) as NSError
        XCTAssertNil(error.userInfo[NSUnderlyingErrorKey]); XCTAssertFalse(error.description.contains(secret))
    }

    func testIdentityBypassesCachedURLMetadataAndIgnoresXattrChanges() throws {
        let (directory, url, _) = try fixture()
        _ = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        let original = try ArchiveFileIdentity.capture(url: url)
        try Data([1]).write(to: url, options: .atomic)
        XCTAssertNotEqual(try ArchiveFileIdentity.capture(url: url), original)
        let current = try ArchiveFileIdentity.capture(url: url)
        XCTAssertEqual(setxattr(url.path, "org.kaitofinder.verification-test", "x", 1, 0, 0), 0)
        XCTAssertEqual(try ArchiveFileIdentity.capture(url: url), current)
        XCTAssertFalse(current.description.contains(directory.url.path))
    }

    func testMetadataObserversBetweenVerificationAndPublishDoNotInvalidateContent() throws {
        let (directory, url, plan) = try fixture()
        defer { withExtendedLifetime(directory) {} }
        try ArchiveImportTransaction.didVerifyForTesting.withValue({ work in
            _ = try work.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            XCTAssertEqual(setxattr(work.path, "org.kaitofinder.verification-test", "x", 1, 0, 0), 0)
        }) {
            _ = try ArchiveEditTransaction.run(plan: plan, archive: url, mode: .inPlace, progress: Progress())
        }
        XCTAssertEqual(try ArchiveReader.open(url: url).entries.map(\.name), ["private/keep"])
    }
}
