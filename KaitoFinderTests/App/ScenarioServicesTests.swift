import AppKit
import Foundation
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioServicesTests: XCTestCase {
    @MainActor func testCompressEmptyPasteboardReturnsSelectionError() throws {
        let board = NSPasteboard.withUniqueName(), delegate = AppDelegate()
        defer { board.releaseGlobally() }
        board.clearContents()
        var error: NSString = ""
        delegate.compressFiles(board, userData: "", error: &error)
        XCTAssertEqual(error as String, String(localized: "アーカイブにする項目を選んでください"))
        XCTAssertNil(delegate.archiveCreationTask)
        XCTAssertNil(delegate.creationOpenPanel)
    }

    @MainActor private func extractInvalidInput(folder: Bool) async throws {
        let fixture = try ScenarioFixture(), board = NSPasteboard.withUniqueName(), delegate = AppDelegate()
        defer { board.releaseGlobally() }
        let invalid = try folder ? fixture.folder("not-an-archive") : fixture.file("ordinary.txt")
        let out = try fixture.folder("out")
        guard board.writeObjects([invalid as NSURL, fixture.archive as NSURL]) else { throw XCTSkip("ペーストボードを利用できない") }
        var report: ArchiveBatchExtractor.Report?, received: [URL] = []
        // Servicesの入口を通し、パネルの代わりに同じ実バッチエンジンで結果を受け取る。
        delegate.batchExtractionHandler = { archives in
            received = archives
            let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always), passwordPrompt: { _, _ in
                XCTFail("通常ファイルやフォルダに認証を要求しました"); throw CancellationError()
            })
            report = await engine.run(archives: archives, base: out, progress: Progress())
        }
        var error: NSString = ""
        delegate.extractArchives(board, userData: "", error: &error)
        XCTAssertEqual(error, "")
        await delegate.batchExtractionTask?.value
        let result = try XCTUnwrap(report)
        XCTAssertEqual(received, [invalid, fixture.archive])
        XCTAssertEqual(result.failures.map(\.archive), [invalid])
        XCTAssertEqual(result.failures.first?.reason, String(localized: "対応していないフォーマットです。"))
        XCTAssertEqual(result.extracted, [fixture.archive])
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("archive/original.txt")), Data("original".utf8))
        XCTAssertEqual(try ScenarioFixture.files(under: out).count, 1)
    }

    @MainActor func testExtractServiceReportsNonArchivePerItemAndContinues() async throws {
        try await extractInvalidInput(folder: false)
    }

    @MainActor func testExtractServiceReportsFolderPerItemAndContinues() async throws {
        try await extractInvalidInput(folder: true)
    }
}
