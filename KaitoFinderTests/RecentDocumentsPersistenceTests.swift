import AppKit
import XCTest
@testable import KaitoFinder

nonisolated final class RecentDocumentsPersistenceTests: XCTestCase {
    /// Tools/verify_ui_integration.py が同じ専用 bundle ID で各段階を別プロセスで起動する。
    /// 通常のテスト実行では、ユーザーの履歴を消去する経路へ入らない。
    @MainActor func testHistoryAcrossLaunches() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["KAITOFINDER_RECENTS_PHASE"] else {
            throw XCTSkip("再起動と履歴消去は Tools/verify_ui_integration.py の分離したプロセスで検証する")
        }
        let prefix = "com.shunnag.KaitoFinder.UIIntegrationVerification."
        let identifier = try XCTUnwrap(environment["KAITOFINDER_RECENTS_BUNDLE_ID"])
        guard Bundle.main.bundleIdentifier == identifier, identifier.hasPrefix(prefix),
              UUID(uuidString: String(identifier.dropFirst(prefix.count))) != nil else {
            XCTFail("専用のランダムなアプリ識別子以外では履歴を変更しない")
            return
        }
        let archive = URL(fileURLWithPath: try XCTUnwrap(environment["KAITOFINDER_RECENTS_ARCHIVE"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let controller = NSDocumentController.shared
        let clearAction = #selector(NSDocumentController.clearRecentDocuments(_:))
        let clear = try menuItem(clearAction,
                                 in: XCTUnwrap(NSApp.mainMenu))
        let menu = try XCTUnwrap(clear.menu)
        let recorded = { controller.recentDocumentURLs.contains { $0.lastPathComponent == archive.lastPathComponent } }
        let displayed = { menu.items.contains { $0.title.contains(archive.lastPathComponent) } }
        addTeardownBlock { @MainActor in
            for document in controller.documents where document.fileURL?.lastPathComponent == archive.lastPathComponent {
                document.close()
                if let document = document as? ArchiveDocument {
                    await document.sessionCleanup?.value
                    await document.materializationCleanup?.value
                    await document.undoCleanup?.value
                }
            }
        }
        switch phase {
        case "record":
            XCTAssertFalse(recorded())
            let (document, _) = try await controller.openDocument(withContentsOf: archive, display: false)
            document.close()
            if let document = document as? ArchiveDocument { await document.sessionCleanup?.value }
            XCTAssertTrue(recorded())
            await showMenu(menu, until: displayed)
        case "reopen":
            XCTAssertTrue(recorded(), "前の起動で開いた履歴が残ること")
            await showMenu(menu, until: displayed)
            let item = try XCTUnwrap(menu.items.first { $0.title.contains(archive.lastPathComponent) })
            try performMenuItem(item)
            try await scenarioWait { controller.document(for: archive)?.windowControllers.first?.window != nil }
            let document = try XCTUnwrap(controller.document(for: archive) as? ArchiveDocument)
            document.close()
            await document.sessionCleanup?.value
            await document.materializationCleanup?.value
            await document.undoCleanup?.value
        case "clear":
            // 再オープンの処理が残るプロセスから分離し、履歴消去の永続化を単独で検証する。
            XCTAssertTrue(recorded())
            await showMenu(menu, until: displayed)
            try performMenuItem(menuItem(#selector(NSDocumentController.clearRecentDocuments(_:)), in: menu))
            XCTAssertTrue(controller.recentDocumentURLs.isEmpty)
            await showMenu(menu) { !displayed() && !menu.items.contains { $0.action == clearAction && $0.isEnabled } }
            if !controller.recentDocumentURLs.isEmpty {
                XCTFail("履歴消去後に項目が復活した: \(controller.recentDocumentURLs.map(\.lastPathComponent))")
            }
        case "verify-cleared":
            XCTAssertTrue(controller.recentDocumentURLs.isEmpty, "消去後に再起動しても履歴が復活しないこと")
            await showMenu(menu) { !displayed() && !menu.items.contains { $0.action == clearAction && $0.isEnabled } }
        default:
            XCTFail("Unknown recent-history phase: \(phase)")
        }
    }
}
