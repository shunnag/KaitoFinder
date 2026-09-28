import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
@_spi(SevenZipEditLayout) import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated enum SevenZipUpdateFixture {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let fallbacks = ["archive_properties", "packpos16"]
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sevenzip-edit")

    static func frozen(_ name: String, at root: URL, filename: String = "original.7z") throws -> URL {
        let url = root.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name + ".7z"), to: url)
        return url
    }

    static func make(_ root: URL, password: String? = nil, headers: Bool = false, filename: String = "original.7z") throws -> URL {
        let url = root.appendingPathComponent(filename)
        let writer = try ArchiveWriter.create(url: url, format: .sevenZip,
            options: .init(password: password, encryptsSevenZipHeaders: headers))
        for name in ["keep", "remove"] { try writer.add(data: Data(name.utf8), as: name, modificationDate: date) }
        try writer.addDirectory("folder")
        try writer.add(data: Data("child".utf8), as: "folder/child", modificationDate: date)
        try writer.add(data: Data("last".utf8), as: "last", modificationDate: date)
        try writer.finish()
        return url
    }

    static func reader(_ url: URL, password: String? = "secret") throws -> ArchiveReader {
        try ArchiveReader.open(url: url, options: .kaitoFinder(password: password))
    }

    static func selection(_ entry: ArchiveEntry) -> ArchiveEditSelection {
        .init(path: ArchiveEditPlan.key(entry.name), isDirectory: entry.kind == .directory, entries: [entry])
    }

    static func contents(_ reader: ArchiveReader) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: reader.entries.filter { $0.kind != .directory }.map { ($0.name, try reader.read($0)) })
    }

    static func assertWork(_ work: URL, archive: URL, bytes: Data, identity: ArchiveFileIdentity) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.deletingLastPathComponent().path), ["archive.7z"])
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertEqual(try ArchiveFileIdentity.capture(url: archive), identity)
    }

    static func assertCarried(_ before: ArchiveReader, bytes: Data, after: ArchiveReader, output: Data,
                              removed: Set<Int>) throws {
        let old = try XCTUnwrap(before.sevenZipEditingSnapshot()), new = try XCTUnwrap(after.sevenZipEditingSnapshot())
        var outputFolder = 0
        for (index, folder) in old.folders.enumerated() {
            let files = old.files.indices.filter { file in
                old.files[file].substreamIndex.map { old.substreams[$0].folderIndex == index } ?? false
            }
            if files.allSatisfy({ removed.contains($0) }) { continue }
            defer { outputFolder += 1 }
            if files.contains(where: { removed.contains($0) }) { continue }
            let carried = try XCTUnwrap(new.folders.indices.contains(outputFolder) ? new.folders[outputFolder] : nil)
            XCTAssertEqual(carried.coders, folder.coders)
            XCTAssertEqual(carried.bindPairs, folder.bindPairs)
            XCTAssertEqual(carried.unpackSizes, folder.unpackSizes)
            for (a, b) in zip(folder.packIndices, carried.packIndices) {
                let x = old.packs[a].range, y = new.packs[b].range
                XCTAssertEqual(bytes.subdata(in: Int(old.baseOffset + x.lowerBound)..<Int(old.baseOffset + x.upperBound)),
                               output.subdata(in: Int(new.baseOffset + y.lowerBound)..<Int(new.baseOffset + y.upperBound)))
            }
        }
    }
}

nonisolated final class SevenZipUpdateTrace: Sendable {
    let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
    let strategies = Mutex<[SevenZipUpdater.CommitStrategy?]>([])
    let adoptions = Mutex<[ArchiveReaderAdoption]>([])
    let fallbacks = Mutex<[String]>([])

    func observing<T>(_ body: () async throws -> T) async rethrows -> T {
        try await ArchiveStageDiagnostics.observer.withValue({ event in
            if case .began(_, let stage) = event { self.stages.withLock { $0.append(stage) } }
        }) {
            try await ArchiveSession.readerAdoptionObserverForTesting.withValue({ event in self.adoptions.withLock { $0.append(event) } }) {
                try await ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ reason in self.fallbacks.withLock { $0.append(reason) } }) {
                    try await ArchiveImportTransaction.didCommitSevenZipUpdaterForTesting.withValue({ updater in
                        self.strategies.withLock { $0.append(updater.lastCommitStrategy) }
                    }, operation: body)
                }
            }
        }
    }

    func assertRoute(_ expected: [ArchiveStageDiagnostics.Stage], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(stages.withLock { $0.filter { $0 == .updaterOpen || $0 == .rewriterOpen || $0 == .workCopy || $0 == .reloadOpen } },
                       expected, file: file, line: line)
    }
}
