import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class LargeArchiveTests: XCTestCase {
    func testSessionListsZIP64EntryLargerThanFourGiB() async throws {
        let directory = try ArchiveTestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let archive = try LargeArchiveFixtures.zip64(in: directory.url)
        var opened: ArchiveSession?
        XCTAssertNoThrow(opened = try ArchiveSession(url: archive), "ZIP64 entries above 4 GiB must open")
        guard let session = opened else { return }
        let entries = await session.entries()
        XCTAssertEqual(entries.map(\.name), ["big.bin"])
        XCTAssertEqual(entries.map(\.uncompressedSize), [LargeArchiveFixtures.zipEntrySize])
        await session.close()
    }

    func testSessionListsTarWithTotalLargerThanSixtyFourGiB() async throws {
        let directory = try ArchiveTestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let archive = try LargeArchiveFixtures.hugeTotalTar(in: directory.url)
        var opened: ArchiveSession?
        XCTAssertNoThrow(opened = try ArchiveSession(url: archive), "A tar total above 64 GiB must open")
        guard let session = opened else { return }
        let entries = await session.entries()
        XCTAssertEqual(entries.map(\.name), LargeArchiveFixtures.tarEntryNames)
        XCTAssertEqual(entries.map(\.uncompressedSize), Array(repeating: LargeArchiveFixtures.fourGiB, count: 17))
        XCTAssertEqual(entries.reduce(UInt64(0)) { $0 + ($1.uncompressedSize ?? 0) }, 68 * 1_024 * 1_024 * 1_024)
        await session.close()
    }

    func testSessionStreamsFirstMiBOfLargeZIP64Entry() async throws {
        let directory = try ArchiveTestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let archive = try LargeArchiveFixtures.zip64(in: directory.url)
        let session = try ArchiveSession(url: archive)
        let snapshot = try await session.extractionSnapshot()
        let entry = try XCTUnwrap(snapshot.reader.entries.first)
        let stream = try snapshot.reader.stream(entry)
        var buffer = [UInt8](repeating: 0xff, count: 1_024 * 1_024)
        var total = 0
        while total < buffer.count {
            let count = try buffer.withUnsafeMutableBytes {
                try stream.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[total...]))
            }
            guard count > 0 else { break }
            total += count
        }
        XCTAssertEqual(total, 1_024 * 1_024)
        XCTAssertTrue(buffer.allSatisfy { $0 == 0 })
        await session.close()
    }

    func testLargeZIP64RemainsEditableInPlace() throws {
        let directory = try ArchiveTestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let archive = try LargeArchiveFixtures.zip64(in: directory.url)
        let capabilities = ArchiveCapabilities.inspect(url: archive, format: .zip)
        XCTAssertEqual(capabilities.mode, .inPlace)
        XCTAssertNil(capabilities.refusal)
        XCTAssertTrue(capabilities.canEdit)
    }

    func testExtractsEntireLargeZIP64EntryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["KAITOFINDER_LARGE_ENTRY_TESTS"] == "1" else {
            throw XCTSkip("Set KAITOFINDER_LARGE_ENTRY_TESTS=1 to extract the full 4 GiB + 1 byte ZIP64 entry")
        }
        let directory = try ArchiveTestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let archive = try LargeArchiveFixtures.zip64(in: directory.url)
        let destination = directory.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let session = try ArchiveSession(url: archive)
        let result = try await ExtractionService.extract(ExtractionSelection(entries: await session.entries()),
                                                         from: session, to: destination)
        XCTAssertFalse(result.cancelled)
        XCTAssertTrue(result.failures.isEmpty, result.failures.map(\.reason).joined(separator: "; "))
        XCTAssertEqual(result.written.map(\.entryIndex), [0])
        let output = destination.appendingPathComponent("big.bin")
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.uint64Value, LargeArchiveFixtures.zipEntrySize)
        let file = try FileHandle(forReadingFrom: output)
        defer { try? file.close() }
        try file.seek(toOffset: LargeArchiveFixtures.zipEntrySize - 1)
        XCTAssertEqual(try file.read(upToCount: 1), Data([0]))
        await session.close()
    }
}
