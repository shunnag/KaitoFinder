import Darwin
import Foundation
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioPathTests: XCTestCase {
    func testTwoHundredLevelsExtractWithExactLeafContents() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z: z.writestr('d/' * 200 + 'leaf', b'deep')")
        let out = try fixture.folder("out"), result = try await fixture.extract(to: out)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.written.filter { $0.entryIndex == nil }.count, 200)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(String(repeating: "d/", count: 200) + "leaf")), Data("deep".utf8))
    }

    func testPathMaxAndOutsideSymlinkAreReportedPerEntryWithoutEscaping() async throws {
        let fixture = try ScenarioFixture(script: #"""
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr(('longsegment/' * 100) + 'leaf', b'too long')
            link = zipfile.ZipInfo('sub/outside')
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(link, '../../x')
            z.writestr('ok.txt', b'good')
        """#)
        let sentinel = try fixture.file("x", bytes: Data("untouched".utf8)), out = try fixture.folder("out")
        let result = try await fixture.extract(to: out)
        XCTAssertEqual(result.failures.map(\.entryIndex), [0, 1])
        XCTAssertEqual(result.failures.first?.reason, ExtractionFailure.system(ENAMETOOLONG).description)
        XCTAssertEqual(result.failures.last?.reason, String(localized: "シンボリックリンクのtargetが安全な出力先へ解決されません。"))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("ok.txt")), Data("good".utf8))
        var info = stat()
        XCTAssertEqual(lstat(out.appendingPathComponent("sub/outside").path, &info), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("longsegment").path))
    }
}
