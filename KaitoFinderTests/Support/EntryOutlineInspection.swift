import AppKit
import XCTest
@testable import KaitoFinder

/// ArchiveWindowController の表示行から項目・選択行・パス集合を調べる共通ヘルパー。
@MainActor extension ArchiveWindowController {
    func displayedNode(_ path: String) throws -> EntryNode {
        let view = outlineView
        return try XCTUnwrap((0..<view.numberOfRows).compactMap { view.item(atRow: $0) as? EntryNode }.first { $0.path == path })
    }

    func select(paths: [String]) throws {
        let rows = try paths.map { outlineView.row(forItem: try displayedNode($0)) }
        outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    var displayedPaths: Set<String> {
        let view = outlineView
        return Set((0..<view.numberOfRows).compactMap { (view.item(atRow: $0) as? EntryNode)?.path })
    }
}
