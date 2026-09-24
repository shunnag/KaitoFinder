import AppKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class M6bSearchTests: XCTestCase {
    @MainActor func testSearchTypingCostAt100kEntries() async throws {
        preserveArchiveWindowFrame()
        let defaults = try ArchivePreferencesTestDefaults()
        let controller = ArchiveWindowController(preferencesStore: ArchivePreferencesStore(defaults: defaults.defaults))
        defer { controller.close() }
        let entries = (0..<100_000).map { index in
            archiveColumnEntry("d\(index / 100)/file\(index).txt", index: index, size: 1)
        }
        let root = EntryNode.tree(from: entries)
        controller.display(root)
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(window.makeFirstResponder(controller.searchField))
        let editor = try XCTUnwrap(controller.searchField.currentEditor() as? NSTextView)
        let mode = controller.searchField.sendsSearchStringImmediately ? "before" : "after"
        XCTAssertFalse(controller.searchField.sendsSearchStringImmediately)
        XCTAssertFalse(controller.searchField.sendsWholeSearchString)
        for character in ["f", "i", "l", "e"] {
            let start = ContinuousClock.now
            editor.insertText(character, replacementRange: editor.selectedRange())
            // insertText は AppKit のキーイベント配送を行わないため、即時モードの action を再現する。
            if controller.searchField.sendsSearchStringImmediately {
                XCTAssertTrue(controller.searchField.sendAction(controller.searchField.action, to: controller.searchField.target))
            }
            print("M6b SEARCH \(mode) entries=100000 key=\(character) ms=\(milliseconds(start.duration(to: .now))) query=\(controller.filterQuery)")
        }
        let start = ContinuousClock.now
        controller.filterEntries(controller.searchField)
        print("M6b SEARCH \(mode) entries=100000 final-filter ms=\(milliseconds(start.duration(to: .now)))")
        XCTAssertEqual(controller.filterQuery, "file")
        XCTAssertEqual(controller.outlineView.numberOfRows, 101_000)
        controller.setFilterQuery("file99999")
        XCTAssertEqual(controller.outlineView.numberOfRows, 2)
        controller.setFilterQuery("")
        XCTAssertEqual(controller.outlineView.numberOfRows, 1_000)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
