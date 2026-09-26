import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class TarUpdateProjectionTests: XCTestCase {
    func testAllTarUpdateModesKeepOrderKindsSizesAndRoot() throws {
        let directory = try ArchiveTestDirectory()
        let bytes = TarUpdateFixture.member("./", type: 53, body: Data())
            + TarUpdateFixture.member("directory/", type: 53, body: Data())
            + TarUpdateFixture.member("link", type: 50, body: Data(), link: "target") + Data(count: 1024)
        let archive = try TarUpdateFixture.archive(directory.url, bytes: bytes)
        let entries = try ArchiveReader.open(url: archive).entries.map { entry in
            ArchiveEntry(index: entry.index, rawName: entry.rawName, name: entry.name, pathComponents: entry.pathComponents,
                kind: entry.kind, uncompressedSize: UInt64(entry.index + 3), compressedSize: nil, modificationDate: nil, posixPermissions: nil,
                isEncrypted: false, solidGroup: -1, crc32: nil, methodDescription: "", formatSpecific: entry.formatSpecific)
        }
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip, .tarBzip2, .tarXZ] {
            let projection = ArchiveOutputProjection(existing: entries, mode: .update(format))
            XCTAssertEqual(projection.entries.map(\.name), entries.map(\.name))
            XCTAssertEqual(projection.entries.map(\.size), entries.map(\.uncompressedSize))
            try projection.validate(entries: entries)
            XCTAssertThrowsError(try projection.validate(entries: Array(entries.reversed())))
            XCTAssertThrowsError(try projection.validate(entries: Array(entries.dropLast())))
            let rewrite = projection.resolving(.rewrite(format))
            XCTAssertEqual(rewrite.entries.map(\.name), ["directory/", "link"])
            XCTAssertEqual(rewrite.entries.map(\.size), [0, 0])
        }
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip] {
            XCTAssertThrowsError(try ArchiveOutputProjection(existing: entries, mode: .update(format)).validate(entries: entries)) {
                XCTAssertEqual($0 as? ArchiveEditError, .staleSelection)
            }
        }
    }

    func testTarHardLinksRetargetMaterializeAndResolveFallbackFromOriginalInputs() throws {
        let directory = try ArchiveTestDirectory()
        let bytes = TarUpdateFixture.member("data") + TarUpdateFixture.member("first", type: 49, body: Data(), link: "data")
            + TarUpdateFixture.member("chain", type: 49, body: Data(), link: "first")
            + TarUpdateFixture.member("second", type: 49, body: Data(), link: "data") + Data(count: 1024)
        let archive = try TarUpdateFixture.archive(directory.url, bytes: bytes)
        let entries = try ArchiveReader.open(url: archive).entries
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip, .tarBzip2, .tarXZ] {
            for removed in [[0], [1], [0, 1]] {
                let renamed = [ArchiveEditPlan.Rename(entry: .init(entries[2]), path: "renamed-chain")]
                let update = ArchiveOutputProjection(existing: entries, removing: removed, renaming: renamed, mode: .update(format))
                let expectedKinds: [EntryKind] = removed == [0] ? [.file, .hardlink, .hardlink]
                    : removed == [1] ? [.file, .hardlink, .hardlink] : [.file, .hardlink]
                XCTAssertEqual(update.entries.map(\.kind), expectedKinds)
                XCTAssertEqual(update.entries.last?.hardLinkTarget, removed == [0] ? "first" : removed == [1] ? "data" : "renamed-chain")
                let direct = ArchiveOutputProjection(existing: entries, removing: removed, renaming: renamed, mode: .rewrite(format))
                let fallback = update.resolving(.rewrite(format))
                XCTAssertEqual(fallback.entries.map(\.kind), direct.entries.map(\.kind))
                XCTAssertEqual(fallback.entries.map(\.size), direct.entries.map(\.size))
                XCTAssertEqual(fallback.entries.map(\.name), direct.entries.map(\.name))
            }
            let projection = ArchiveOutputProjection(existing: entries, mode: .update(format))
            var wrong = entries, metadata = entries[3].formatSpecific
            metadata["hardLinkTargetIndex"] = "1"
            wrong[3] = wrong[3].pendingCopy(formatSpecific: metadata)
            // 同じ実体でも、直接の参照先が計画と違えば拒否する。
            XCTAssertThrowsError(try projection.validate(entries: wrong))
        }
    }

    func testAddedHardLinksAreAtTheEndAndNameTheirFirstAddition() throws {
        let directory = try ArchiveTestDirectory(), archive = try TarUpdateFixture.archive(directory.url)
        let entries = try ArchiveReader.open(url: archive).entries
        let source = directory.url.appendingPathComponent("a"), link = directory.url.appendingPathComponent("b")
        try Data("added".utf8).write(to: source); try FileManager.default.linkItem(at: source, to: link)
        let plan = try ArchiveImportPlan.build(urls: [source, link], folder: "", existing: entries, progress: Progress(), format: .tar)
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip, .tarBzip2, .tarXZ] {
            let output = try ArchiveOutputProjection(existing: entries, additions: plan.items.map { try .init(adding: $0) }, mode: .update(format))
            XCTAssertEqual(output.entries.map(\.name), entries.map(\.name) + ["a", "b"])
            XCTAssertEqual(output.entries.suffix(2).map(\.kind), [.file, .hardlink])
            XCTAssertEqual(output.entries.last?.hardLinkTarget, "a")
        }
    }
}
