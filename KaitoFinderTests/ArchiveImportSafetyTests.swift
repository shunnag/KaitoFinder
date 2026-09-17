import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveImportSafetyTests: XCTestCase {
    private let quarantine = Data("0081;12345678;ImportSafetyTests;".utf8)

    func testAppendPropagatesQuarantineFromNestedFilesAndDirectories() async throws {
        for format in [GyoshukuKit.ArchiveFormat.zip, .tar] {
            for markDirectory in [false, true] {
                let directory = try ArchiveTestDirectory()
                let archive = directory.url.appendingPathComponent("archive." + ArchiveCreationPlan.filenameExtension(for: format))
                let writer = try ArchiveWriter.create(url: archive, format: format)
                try writer.add(data: Data("original".utf8), as: "original.txt")
                try writer.finish()
                let source = directory.url.appendingPathComponent("input", isDirectory: true)
                let nested = source.appendingPathComponent("nested", isDirectory: true)
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                let file = nested.appendingPathComponent("new.txt")
                try Data("new".utf8).write(to: file)
                try ExtractionQuarantine.apply(quarantine, to: markDirectory ? nested : file)
                XCTAssertNil(try ExtractionQuarantine.read(from: archive))
                XCTAssertNil(try ExtractionQuarantine.read(from: source))

                let session = try ArchiveSession(url: archive)
                let result = try await session.append(urls: [source], to: "", progress: Progress())
                XCTAssertTrue(result.failures.isEmpty)
                XCTAssertNil(result.reloadFailure)
                XCTAssertEqual(try ExtractionQuarantine.read(from: archive), quarantine, "\(format), directory=\(markDirectory)")
                let output = directory.url.appendingPathComponent("output", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                let extracted = try await ExtractionService.extract(ExtractionSelection(entries: await session.entries()),
                                                                     from: session, to: output)
                XCTAssertTrue(extracted.failures.isEmpty)
                XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("input/nested/new.txt")), Data("new".utf8))
                XCTAssertEqual(try ExtractionQuarantine.read(from: output.appendingPathComponent("input/nested/new.txt")), quarantine)
                await session.close()
            }
        }
    }

    func testAppendPreservesOriginalQuarantineAndCancellationDoesNotPublishNewQuarantine() async throws {
        let fixture = try ScenarioFixture()
        let file = try fixture.file("new.txt")
        try ExtractionQuarantine.apply(quarantine, to: file)
        let original = Data("0081;87654321;OriginalArchive;".utf8)
        try ExtractionQuarantine.apply(original, to: fixture.archive)
        let session = try ArchiveSession(url: fixture.archive)
        let before = try ScenarioFixture.digest(fixture.archive)
        let progress = Progress()
        do {
            _ = try await session.append(urls: [file], to: "", progress: progress, willPublish: { progress.cancel() })
            XCTFail("Cancellation must prevent publication")
        } catch is CancellationError {}
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        XCTAssertEqual(try ExtractionQuarantine.read(from: fixture.archive), original)
        _ = try await session.append(urls: [file], to: "", progress: Progress())
        XCTAssertEqual(try ExtractionQuarantine.read(from: fixture.archive), original)
        await session.close()
    }

    func testCreationPropagatesQuarantineFromNestedEmptyDirectory() throws {
        let fixture = try ScenarioFixture()
        let source = try fixture.folder("input"), nested = try fixture.folder("input/empty")
        try ExtractionQuarantine.apply(quarantine, to: nested)
        XCTAssertNil(try ExtractionQuarantine.read(from: source))
        let output = fixture.root.appendingPathComponent("created.zip")
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: [source], destination: output, format: .zip), progress: Progress())
        XCTAssertEqual(try ExtractionQuarantine.read(from: output), quarantine)
        XCTAssertEqual(Set(try ArchiveReader.open(url: output).entries.map(\.name)), ["input/", "input/empty/"])
    }

    func testCreationCannotReplaceAnImportedDescendantOrItsHardLink() throws {
        for hardLink in [false, true] {
            let fixture = try ScenarioFixture()
            let source = try fixture.folder("input")
            let original = try fixture.file("input/existing.zip", bytes: Data("irreplaceable source".utf8))
            let output: URL
            if hardLink {
                output = fixture.root.appendingPathComponent("alias.zip")
                try FileManager.default.linkItem(at: original, to: output)
            } else { output = original }
            let before = try Data(contentsOf: original)
            XCTAssertThrowsError(try ArchiveCreationTransaction.run(
                plan: .init(sources: [source], destination: output, format: .zip), progress: Progress())) {
                guard case ExtractionFailure.refused(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
                XCTAssertEqual(reason, String(localized: "作成元の項目とは別の保存先を選んでください。"))
            }
            XCTAssertEqual(try Data(contentsOf: original), before)
            XCTAssertEqual(try Data(contentsOf: output), before)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".KaitoFinder-new-") })
        }
    }

    func testCreationCanSaveANewArchiveInsideItsSourceDirectory() throws {
        let fixture = try ScenarioFixture(), source = try fixture.folder("input")
        _ = try fixture.file("input/keep.txt", bytes: Data("keep".utf8))
        let output = source.appendingPathComponent("new.zip")
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: [source], destination: output, format: .zip), progress: Progress())
        XCTAssertEqual(try ScenarioFixture.contents(output), ["input/keep.txt": Data("keep".utf8)])
    }
}
