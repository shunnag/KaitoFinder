import AppKit
import XCTest
@testable import KaitoFinder

nonisolated final class AutosaveIsolationTests: XCTestCase {
    @MainActor func testResetRestoresDefaultSortForNextController() async throws {
        let fixture = try ScenarioFixture()
        let (_, first) = try await scenarioDocument(fixture)
        first.outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]
        XCTAssertNotNil(UserDefaults.standard.object(
            forKey: "NSTableView Sort Ordering v2 \(ArchiveWindowController.columnsAutosaveName)"))

        TestProcessSetup.resetAutosaveDefaults()
        for key in TestProcessSetup.autosaveKeys { XCTAssertNil(UserDefaults.standard.object(forKey: key), key) }

        let (_, second) = try await scenarioDocument(fixture)
        XCTAssertEqual(second.outlineView.sortDescriptors.first?.key, "name")
        XCTAssertEqual(second.outlineView.sortDescriptors.first?.ascending, true)
    }

    /// 期待値は本番の定数から作る。TestProcessSetup は nonisolated なので設定キーを文字列で持ち、
    /// ここでその文字列が `ArchivePreferencesStore.Key` の値の改名に追随しているかを確かめる。
    /// 定数は列挙できないため、本番に autosave 名や設定キーを足したときは、ここと `autosaveKeys` の両方へ足す。
    @MainActor func testAutosaveKeysCoverAllApplicationAutosaveNames() {
        typealias Key = ArchivePreferencesStore.Key
        XCTAssertEqual(TestProcessSetup.autosaveKeys.sorted(), [
            "NSTableView Sort Ordering v2 \(ArchiveWindowController.columnsAutosaveName)",
            "NSTableView Columns v3 \(ArchiveWindowController.columnsAutosaveName)",
            "NSTableView Supports v2 \(ArchiveWindowController.columnsAutosaveName)",
            "NSToolbar Configuration \(ArchiveWindowController.toolbarAutosaveName)",
            "NSWindow Frame \(ArchiveWindowController.frameAutosaveName)",
            "NSWindow Frame \(PreferencesWindowController.frameAutosaveName)",
            "NSWindow Frame \(ArchiveViewOptionsController.frameAutosaveName)",
            Key.saveBehavior, Key.compressionThreads, Key.folderOpening, Key.listIconSize, Key.listTextSize,
            Key.keepsFoldersOnTop, Key.additionPosition, Key.tarCarriedOwnerIDs
        ].sorted())
    }
}
