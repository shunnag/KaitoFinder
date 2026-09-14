import AppKit
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

    @MainActor func testDocumentCreationDisablesConcurrentReading() {
        // Concurrent reading makes AppKit invoke the @MainActor initializer on its
        // "NSDocumentController Opening" queue, causing the measured EXC_BREAKPOINT/SIGTRAP.
        XCTAssertFalse(ArchiveDocument.canConcurrentlyReadDocuments(ofType: "public.zip-archive"))
    }

    @MainActor private func assertOpensThroughDocumentController(_ url: URL, in directory: ArchiveTestDirectory) async throws {
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
        let expected = ["nested", "note.txt"]
        let deadline = ContinuousClock.now + .seconds(5)
        while topLevelPaths() != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(topLevelPaths(), expected)
    }
}
