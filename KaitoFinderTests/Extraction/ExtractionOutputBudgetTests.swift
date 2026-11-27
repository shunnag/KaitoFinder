import Darwin
import Foundation
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ExtractionOutputBudgetTests: XCTestCase {
    func testConcurrentWritesShareVolumeHeadroomAndUseCurrentFreeSpace() throws {
        let dir = try ArchiveTestDirectory()
        let fd = open(dir.url.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd); withExtendedLifetime(dir) {} }
        let free = Mutex<UInt64>(100)
        let budget = ExtractionOutputBudget(archiveLimit: 500, available: { _ in free.withLock { $0 } }, maximum: { _ in nil })
        XCTAssertEqual(try budget.usableCapacity(on: fd), 95)
        var first = try budget.begin(on: fd, declared: 95, isStaged: false)
        var second = try budget.begin(on: fd, declared: 0, isStaged: false)
        XCTAssertThrowsError(try budget.begin(on: fd, declared: 96, isStaged: false))
        try budget.writing(80, on: fd, file: &first) {
            XCTAssertThrowsError(try budget.writing(16, on: fd, file: &second) {})
            try budget.writing(15, on: fd, file: &second) {}
        }
        free.withLock { $0 = 5 }
        XCTAssertThrowsError(try budget.writing(1, on: fd, file: &first) {})
    }

    func testEmptyDestinationRejectsCombinedSizeAndFailedWriteRemovesFile() throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('first', b'abc')
            z.writestr('second', b'def')
        """, suffix: "zip")
        let reader = try ArchiveReader.open(url: fixture.archive)
        let root = fixture.root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let free = Mutex<UInt64>(5)
        let budget = ExtractionOutputBudget(archiveLimit: 100, available: { _ in free.withLock { $0 } }, maximum: { _ in 100 })
        let output = try ExtractionDestination(url: root, quarantine: nil, budget: budget)
        XCTAssertThrowsError(try output.preflight(reader.entries, mapping: .init(scope: .archive, syntax: .portable)) {})
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let existing = root.appendingPathComponent("second")
        try Data([9]).write(to: existing)
        try output.preflight(reader.entries, mapping: .init(scope: .archive, syntax: .portable)) {}
        var buffer = [UInt8](repeating: 0, count: 1)
        var checks = 0
        let first = reader.entries[0]
        XCTAssertThrowsError(try output.file(["first"], entry: first, stream: reader.stream(first), buffer: &buffer) {
            checks += 1
            if checks == 3 { free.withLock { $0 = 0 } }
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["second"])
        XCTAssertEqual(try Data(contentsOf: existing), Data([9]))
    }

    func testUnknownSizesEnforceFileAndOperationLimitsIncludingStagedFiles() throws {
        let dir = try ArchiveTestDirectory()
        let fd = open(dir.url.path, O_RDONLY | O_DIRECTORY)
        defer { close(fd); withExtendedLifetime(dir) {} }
        let budget = ExtractionOutputBudget(archiveLimit: 6, totalLimit: 9, available: { _ in 100 }, maximum: { _ in 4 })
        XCTAssertThrowsError(try budget.begin(on: fd, declared: 5, isStaged: false))
        var a = try budget.begin(on: fd, declared: 0, isStaged: false)
        var b = try budget.begin(on: fd, declared: 0, isStaged: false)
        try budget.writing(4, on: fd, file: &a) {}
        XCTAssertThrowsError(try budget.writing(1, on: fd, file: &a) {})
        XCTAssertThrowsError(try budget.writing(3, on: fd, file: &b) {})
        try budget.writing(2, on: fd, file: &b) {}
        var staged = try budget.begin(on: fd, declared: 3, isStaged: true)
        try budget.writing(3, on: fd, file: &staged) {}
        XCTAssertThrowsError(try budget.writing(1, on: fd, file: &staged) {})
    }
}
