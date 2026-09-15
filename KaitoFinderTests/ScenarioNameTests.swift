import Darwin
import Foundation
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioNameTests: XCTestCase {
    @MainActor func testJapaneseNFCAndNFDShareOneFolderAndFirstOutputWins() async throws {
        let fixture = try ScenarioFixture(script: #"""
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('か\u3099/同名.txt', b'first')
            z.writestr('が/同名.txt', b'second')
            z.writestr('が/別名.txt', b'other')
        """#)
        let session = try ArchiveSession(url: fixture.archive)
        let tree = EntryNode.tree(from: await session.entries())
        XCTAssertEqual(tree.children.count, 1)
        XCTAssertEqual(tree.children.first?.name, "が")
        XCTAssertEqual(ExtractionSelection(nodes: tree.children).entries.count, 3)
        let out = try fixture.folder("out"), result = try await fixture.extract(to: out, session: session)
        XCTAssertEqual(result.failures.map(\.entryIndex), [1])
        XCTAssertEqual(result.failures.first?.reason, String(localized: "重複する出力名です（アーカイブ順で最初のentryを優先）。"))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("が/同名.txt")), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("か\u{3099}/同名.txt")), Data("first".utf8))
        XCTAssertEqual(try ScenarioFixture.files(under: out).count, 2)
    }

    func testCaseInsensitiveDiskRefusesSecondSpellingAndPreservesFirst() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('A.txt', b'first')\n z.writestr('a.txt', b'second')")
        let probe = try fixture.file("caseProbe")
        guard FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("CASEPROBE").path) else {
            throw XCTSkip("大文字小文字を区別するボリュームではAPFS既定の衝突を再現できない")
        }
        try FileManager.default.removeItem(at: probe)
        let out = try fixture.folder("out"), result = try await fixture.extract(to: out)
        XCTAssertEqual(result.failures.map(\.entryIndex), [1])
        XCTAssertEqual(result.failures.first?.reason, ExtractionFailure.system(EEXIST).description)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("A.txt")), Data("first".utf8))
        XCTAssertEqual(try ScenarioFixture.files(under: out).count, 1)
    }

    func testNameMaxBoundaryUnicodeSpacesReservedNamesAndTraversalAreIsolated() async throws {
        let fixture = try ScenarioFixture(script: #"""
        with zipfile.ZipFile(p, 'w') as z:
            for name in ['x' * 255, 'y' * 256, '😀.txt', 'مرحبا.txt', ' leading', 'trailing ', 'CON', 'aux', 'safe/../escape', 'last.txt']:
                z.writestr(name, name.encode())
        """#)
        let out = try fixture.folder("out"), result = try await fixture.extract(to: out)
        XCTAssertEqual(result.failures.map(\.entryIndex), [1, 8])
        XCTAssertEqual(result.failures.first?.reason, ExtractionFailure.system(ENAMETOOLONG).description)
        XCTAssertEqual(result.failures.last?.reason, String(localized: "パスに..成分があります。"))
        // NAME_MAX は上限を含む。255バイトは成功し、256バイトは項目単位で拒否する。
        for name in [String(repeating: "x", count: 255), "😀.txt", "مرحبا.txt", " leading", "trailing ", "CON", "aux", "last.txt"] {
            XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(name)), Data(name.utf8), name)
        }
        XCTAssertEqual(try ScenarioFixture.files(under: out).count, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escape").path))
    }
}
