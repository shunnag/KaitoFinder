import Foundation
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioScaleTests: XCTestCase {
    @MainActor func testTenThousandEntriesOpenFilterSelectAllAndExtractExactBytes() async throws {
        let fixture = try ScenarioFixture(script: #"""
        with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            for n in range(10000):
                z.writestr('folder%03d/file%05d.txt' % (n % 300, n), ('payload-%05d\n' % n).encode())
        """#)
        let start = ContinuousClock.now
        let session = try ArchiveSession(url: fixture.archive)
        let entries = await session.entries(), tree = EntryNode.tree(from: entries)
        let opened = start.duration(to: .now)
        XCTAssertEqual(entries.count, 10_000)
        XCTAssertEqual(tree.children.count, 300)
        XCTAssertEqual(tree.size, 140_000)
        let filterStart = ContinuousClock.now
        let filter = EntryTreeFilter(root: tree, query: "99")
        let filtered = filterStart.duration(to: .now)
        var visible: [String] = [], pending = filter.children(of: tree)
        while let node = pending.popLast() {
            if !node.isDirectory { visible.append(node.path) }
            pending.append(contentsOf: filter.children(of: node))
        }
        XCTAssertEqual(Set(visible), Set(entries.filter { $0.name.contains("99") }.map(\.name)))
        // CI では時間の主張だけを省き、件数・選択・ディスク上の内容は最後まで検証する。
        if ProcessInfo.processInfo.environment["CI"] == nil {
            XCTAssertLessThan(opened, .seconds(4))
            XCTAssertLessThan(filtered, .milliseconds(400))
        }
        let selection = ExtractionSelection(nodes: tree.children)
        XCTAssertEqual(selection.entries.map(\.index), Array(0..<10_000))
        let destination = try fixture.folder("out"), before = try ScenarioFixture.digest(fixture.archive)
        let result = try await ExtractionService.extract(selection, from: session, to: destination)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(result.written.compactMap(\.entryIndex).count, 10_000)
        XCTAssertEqual(try ScenarioFixture.files(under: destination).count, 10_000)
        var total = 0
        for n in 0..<10_000 {
            let path = String(format: "folder%03d/file%05d.txt", n % 300, n)
            let bytes = try Data(contentsOf: destination.appendingPathComponent(path))
            XCTAssertEqual(bytes, Data(String(format: "payload-%05d\n", n).utf8), path)
            total += bytes.count
        }
        XCTAssertEqual(total, 140_000)
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
    }

    func testStatusBarGroupsTotalFilteredAndSelectedCountsInEnglishJapaneseAndGerman() throws {
        for (language, locale, number) in [("en", "en_US", "10,000"), ("ja", "ja_JP", "10,000"), ("de", "de_DE", "10.000")] {
            let bundle = try LocalizationAcceptance.bundle(language), locale = Locale(identifier: locale)
            let total = ArchiveStatusBarText.text(totalCount: 10_000, totalSize: 140_000, bundle: bundle, locale: locale)
            let filtered = ArchiveStatusBarText.text(totalCount: 10_000, totalSize: 140_000, filteredCount: 1_999,
                                                    bundle: bundle, locale: locale)
            let selected = ArchiveStatusBarText.text(totalCount: 10_000, totalSize: 140_000, selectedCount: 10_000,
                                                    selectedSize: 140_000, bundle: bundle, locale: locale)
            for text in [total, filtered, selected] { XCTAssertTrue(text.contains(number), "\(language): \(text)") }
            XCTAssertTrue(filtered.contains(language == "de" ? "1.999" : "1,999"), filtered)
        }
    }
}
