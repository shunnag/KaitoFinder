import AppKit
import QuickLookUI
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveDocumentOpeningTests: XCTestCase {
    private func fixtureDirectory() throws -> ArchiveTestDirectory {
        let directory = try ArchiveTestDirectory()
        try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("nested/deeper"),
                                                withIntermediateDirectories: true)
        for name in ["nested/deeper/one.txt", "nested/deeper/two.txt", "note.txt"] {
            try Data(name.utf8).write(to: directory.url.appendingPathComponent(name))
        }
        return directory
    }

    @MainActor func testZIPOpensThroughDocumentController() async throws {
        let directory = try fixtureDirectory(), archive = directory.url.appendingPathComponent("opening.zip")
        try directory.run("/usr/bin/zip", ["-q", "-D", archive.path,
                                           "nested/deeper/one.txt", "nested/deeper/two.txt", "note.txt"])
        try await assertOpensThroughDocumentController(archive, in: directory)
    }

    @MainActor func testTGZOpensThroughDocumentController() async throws {
        let directory = try fixtureDirectory(), archive = directory.url.appendingPathComponent("opening.tgz")
        try directory.run("/usr/bin/bsdtar", ["--no-mac-metadata", "--no-xattrs", "-czf", archive.path,
                                              "nested", "note.txt"])
        try await assertOpensThroughDocumentController(archive, in: directory)
    }

    @MainActor func testQuickLookForSelectedZIPRowSurvivesForegroundAsyncLoading() async throws {
        let directory = try fixtureDirectory(), archive = directory.url.appendingPathComponent("preview.zip")
        // 行 0 が仮想フォルダではなく、プレビュー可能なファイルになる ZIP を開く。
        try directory.run("/usr/bin/zip", ["-q", "-D", archive.path, "note.txt"])
        NSApp.activate()
        let controller = try await assertOpensThroughDocumentController(archive, in: directory,
            expectedTopLevelPaths: ["note.txt"])
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.outlineView)
        let activationDeadline = ContinuousClock.now + .seconds(5)
        while !NSApp.isActive, ContinuousClock.now < activationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard NSApp.isActive else {
            throw XCTSkip("テスト host が前面になれない環境では QuickLookUI の非同期読み込みを起こせない")
        }
        controller.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(controller.outlineView.selectedRow, 0)
        controller.togglePreviewPanel(nil)

        // 前面時の QuickLookUI の非同期読み込みと、main actor での URL 公開を両方進める。
        let previewDeadline = Date().addingTimeInterval(1.5)
        while Date() < previewDeadline {
            runMainRunLoop(until: min(previewDeadline, Date().addingTimeInterval(0.01)))
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true)
        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        XCTAssertTrue(panel.currentController as AnyObject? === controller)
        XCTAssertNotNil(controller.previewPanel(panel, previewItemAt: 0)?.previewItemURL)
        controller.togglePreviewPanel(nil)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testDocumentCreationDisablesConcurrentReading() {
        // Concurrent reading makes AppKit invoke the @MainActor initializer on its
        // "NSDocumentController Opening" queue, causing the measured EXC_BREAKPOINT/SIGTRAP.
        XCTAssertFalse(ArchiveDocument.canConcurrentlyReadDocuments(ofType: "public.zip-archive"))
    }

    @MainActor private func runMainRunLoop(until date: Date) {
        RunLoop.main.run(until: date)
    }

    @MainActor @discardableResult private func assertOpensThroughDocumentController(
        _ url: URL, in directory: ArchiveTestDirectory, expectedTopLevelPaths: [String] = ["nested", "note.txt"]
    ) async throws -> ArchiveWindowController {
        let (openedDocument, error) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(NSDocument?, (any Error)?), Never>) in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                continuation.resume(returning: (document, error))
            }
        }
        XCTAssertNil(error)
        let document = try XCTUnwrap(openedDocument as? ArchiveDocument)
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === document })
            withExtendedLifetime(directory) {}
        }
        XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === document })
        XCTAssertEqual(document.fileURL, url)
        XCTAssertNotNil(document.windowControllers.first?.window)
        let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        let outlineView = controller.outlineView
        func topLevelPaths() -> [String] {
            (0..<outlineView.numberOfRows).compactMap { row in
                guard outlineView.level(forRow: row) == 0 else { return nil }
                return (outlineView.item(atRow: row) as? EntryNode)?.path
            }.sorted()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while topLevelPaths() != expectedTopLevelPaths, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(topLevelPaths(), expectedTopLevelPaths)
        return controller
    }
}
