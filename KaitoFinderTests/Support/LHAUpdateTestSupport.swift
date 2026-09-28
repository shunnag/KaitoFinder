import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated enum LHAUpdateFixture {
    static let fallbacks = ["sfx", "names-euc-jp", "names-utf8-undeclared", "names-utf8-declared", "tl-S5", "tl-S11",
                            "level3", "anonymous-middle", "empty-name-directory-tail", "data-directories", "lhark-lh7"]
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func frozen(_ name: String, at root: URL, filename: String = "original.lzh") throws -> URL {
        let fixtures = TestPaths.fixtures.appendingPathComponent("LHAUpdate")
        let data = try Data(contentsOf: fixtures.appendingPathComponent(name + ".lzh.b64"))
        let url = root.appendingPathComponent(filename)
        try XCTUnwrap(Data(base64Encoded: data, options: .ignoreUnknownCharacters)).write(to: url)
        return url
    }

    static func make(_ root: URL, mixed: Bool = false, filename: String = "original.lzh") throws -> URL {
        if mixed { return try frozen("tl-S3b", at: root, filename: filename) }
        let url = root.appendingPathComponent(filename)
        let writer = try ArchiveWriter.create(url: url, format: .lha)
        for name in ["keep", "remove"] { try writer.add(data: Data(name.utf8), as: name, modificationDate: date) }
        try writer.addDirectory("folder")
        try writer.add(data: Data("child".utf8), as: "folder/child", modificationDate: date)
        try writer.add(data: Data("last".utf8), as: "last", modificationDate: date)
        try writer.finish()
        return url
    }

    static func selection(_ entry: ArchiveEntry) -> ArchiveEditSelection {
        .init(path: entry.name, isDirectory: entry.kind == .directory, entries: [entry])
    }

    static func group(_ entry: ArchiveEntry, in bytes: Data, payloadOnly: Bool = false) throws -> Data {
        let start = try XCTUnwrap(entry.formatSpecific[payloadOnly ? "dataOffset" : "headerOffset"].flatMap(Int.init))
        let end = try XCTUnwrap(entry.formatSpecific["dataOffset"].flatMap(Int.init)) + Int(try XCTUnwrap(entry.compressedSize))
        return bytes.subdata(in: start..<end)
    }

    static func assertWork(_ work: URL, archive: URL, bytes: Data, identity: ArchiveFileIdentity) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.deletingLastPathComponent().path), ["archive.lzh"])
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertEqual(try ArchiveFileIdentity.capture(url: archive), identity)
    }

    static func contents(_ reader: ArchiveReader) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: reader.entries.filter { $0.kind != .directory }.map { ($0.name, try reader.read($0)) })
    }
}

nonisolated final class LHAUpdateTrace: Sendable {
    let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
    let strategies = Mutex<[LHAUpdater.CommitStrategy?]>([])
    let adoptions = Mutex<[ArchiveReaderAdoption]>([])
    let fallbacks = Mutex<[String]>([])

    func observing<T>(_ body: () async throws -> T) async rethrows -> T {
        try await ArchiveStageDiagnostics.observer.withValue({ event in
            if case .began(_, let stage) = event { self.stages.withLock { $0.append(stage) } }
        }) {
            try await ArchiveSession.readerAdoptionObserverForTesting.withValue({ event in self.adoptions.withLock { $0.append(event) } }) {
                try await ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ reason in self.fallbacks.withLock { $0.append(reason) } }) {
                    try await ArchiveImportTransaction.didCommitLHAUpdaterForTesting.withValue({ updater in
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
