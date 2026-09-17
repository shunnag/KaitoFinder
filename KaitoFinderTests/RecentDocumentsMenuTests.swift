import AppKit
import GyoshukuKit
import XCTest
@testable import KaitoFinder

nonisolated final class RecentDocumentsMenuTests: XCTestCase {
    @MainActor func testOpenedArchiveAppearsInRecentMenuAndCanBeReopened() async throws {
        preserveArchiveWindowFrame()
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent("recent-\(UUID().uuidString).zip")
        let writer = try ArchiveWriter.create(url: archive, format: .zip)
        try writer.add(data: Data("recent document".utf8), as: "note.txt")
        try writer.finish()
        let controller = NSDocumentController.shared
        let (document, _) = try await controller.openDocument(withContentsOf: archive, display: false)
        document.close()
        if let document = document as? ArchiveDocument { await document.sessionCleanup?.value }
        addTeardownBlock { @MainActor in
            for document in controller.documents where document.fileURL == archive {
                document.close()
                if let document = document as? ArchiveDocument {
                    await document.sessionCleanup?.value
                    await document.materializationCleanup?.value
                    await document.undoCleanup?.value
                }
            }
            withExtendedLifetime(directory) {}
        }
        XCTAssertTrue(controller.recentDocumentURLs.contains { $0.lastPathComponent == archive.lastPathComponent })
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let recentMenu = try XCTUnwrap(mainMenu.items.compactMap(\.submenu)
            .flatMap(\.items).compactMap(\.submenu).first { menu in
                menu.items.contains { $0.action == #selector(NSDocumentController.clearRecentDocuments(_:)) }
            })
        await showMenu(recentMenu) { recentMenu.items.contains { $0.title.contains(archive.lastPathComponent) } }
        let item = try XCTUnwrap(recentMenu.items.first { $0.title.contains(archive.lastPathComponent) },
                                "The recent menu must show the history recorded by NSDocumentController")
        try performMenuItem(item)
        try await scenarioWait { controller.document(for: archive)?.windowControllers.first?.window != nil }
        let reopened = try XCTUnwrap(controller.document(for: archive) as? ArchiveDocument)
        XCTAssertNotNil(reopened.session)
        XCTAssertFalse(reopened === document)
    }
}
