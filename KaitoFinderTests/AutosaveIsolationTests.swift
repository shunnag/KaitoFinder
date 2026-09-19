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

    func testAutosaveKeysCoverAllApplicationAutosaveNames() {
        XCTAssertEqual(TestProcessSetup.autosaveKeys.sorted(), [
            "NSTableView Sort Ordering v2 \(ArchiveWindowController.columnsAutosaveName)",
            "NSTableView Columns v3 \(ArchiveWindowController.columnsAutosaveName)",
            "NSTableView Supports v2 \(ArchiveWindowController.columnsAutosaveName)",
            "NSToolbar Configuration \(ArchiveWindowController.toolbarAutosaveName)",
            "NSWindow Frame \(ArchiveWindowController.frameAutosaveName)",
            "NSWindow Frame \(PreferencesWindowController.frameAutosaveName)"
        ].sorted())
    }
}
