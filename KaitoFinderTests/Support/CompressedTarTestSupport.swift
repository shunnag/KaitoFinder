import CryptoKit
import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
@_spi(TarEditLayout) import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated enum CompressedTarFixture {
    typealias Format = GyoshukuKit.ArchiveFormat
    static let formats: [Format] = [.tarGzip, .tarBzip2, .tarXZ]
    static func suffix(_ format: Format) -> String { ArchiveCreationPlan.filenameExtension(for: format) }
    static func open(_ url: URL) throws -> sending ArchiveReader {
        var options = ReaderOptions(appleDoublePolicy: .expose)
        options.recordsTarEditLayout = true
        return try ArchiveReader.open(url: url, options: options)
    }
    static func make(_ root: URL, format: Format, large: Bool = false) throws -> URL {
        let url = root.appendingPathComponent("original." + suffix(format))
        let writer = try ArchiveWriter.create(url: url, format: format)
        let size = large ? (format == .tarGzip ? 1_048_576 : format == .tarBzip2 ? 4_500_000 : 16_777_216) + 129 : 2_097_152
        for name in ["first", "second"] {
            var bytes = Data(repeating: name == "first" ? 37 : 38, count: size)
            var seed: UInt64 = 17
            for index in 0..<65536 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; bytes[index] = UInt8(truncatingIfNeeded: seed) }
            try writer.add(data: bytes, as: name)
        }
        try writer.addDirectory("folder")
        try writer.add(data: Data([1]), as: "folder/tiny")
        try writer.add(data: Data([2]), as: "last")
        try writer.finish()
        return url
    }
    static func legacy(_ root: URL, format: Format) throws -> URL {
        let name = format == .tarGzip ? "gz.tgz.b64" : format == .tarBzip2 ? "bz.tbz.b64" : "xz.txz.b64"
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/TarEdit")
        let bytes = try XCTUnwrap(Data(base64Encoded: Data(contentsOf: fixtures.appendingPathComponent(name)), options: .ignoreUnknownCharacters))
        let url = root.appendingPathComponent("original." + suffix(format)); try bytes.write(to: url); return url
    }
    static func compress(_ bytes: Data, in directory: ArchiveTestDirectory, format: Format,
                         arguments: [String] = [], name: String = "external") throws -> URL {
        let raw = directory.url.appendingPathComponent(name + ".tar")
        try bytes.write(to: raw)
        let tool = format == .tarGzip ? "/usr/bin/gzip" : format == .tarBzip2 ? "/usr/bin/bzip2" : "/opt/homebrew/bin/xz"
        try directory.run(tool, ["-k", "-f"] + arguments + [raw.path])
        return raw.appendingPathExtension(format == .tarGzip ? "gz" : format == .tarBzip2 ? "bz2" : "xz")
    }
    static var externalBytes: Data {
        TarUpdateFixture.pax("LIBARCHIVE.xattr.user.kaito", "a2VwdA") + TarUpdateFixture.member("keep", body: Data(repeating: 37, count: 5_000_000))
            + TarUpdateFixture.member("._keep", body: Data([42])) + TarUpdateFixture.member("last", body: Data([2])) + Data(count: 1024)
    }
    static func bytes(_ source: any ByteSource, range: Range<UInt64>? = nil) throws -> Data {
        let range = range ?? 0..<source.length
        var result = Data(count: Int(range.count)), offset = 0
        while offset < result.count {
            let count = try result.withUnsafeMutableBytes { raw in
                try source.read(into: UnsafeMutableRawBufferPointer(rebasing: raw[offset...]), at: range.lowerBound + UInt64(offset))
            }
            guard count > 0 else { throw KaitoError.io(EIO) }
            offset += count
        }
        return result
    }
    static func hashes(_ reader: ArchiveReader) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: reader.entries.map { entry in
            (entry.name, entry.kind == .directory ? Data() : Data(SHA256.hash(data: try reader.read(entry))))
        })
    }
    static func groups(_ reader: ArchiveReader) throws -> [String: Data] {
        let snapshot = try XCTUnwrap(reader.tarEditingSnapshot()), layout = try XCTUnwrap(snapshot.layout)
        return try Dictionary(uniqueKeysWithValues: reader.entries.map { entry in
            let member = try layout.member(at: entry.index)
            return (entry.name, try bytes(snapshot.image, range: member.groupRange.lowerBound..<member.headerRange.upperBound))
        })
    }
    static func assertNoWork(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".KaitoFinder-add-") || $0.hasPrefix(".gyoshuku-") }, file: file, line: line)
    }
    static func interop(_ url: URL, format: Format, directory: ArchiveTestDirectory) throws {
        let tool = format == .tarGzip ? "/usr/bin/gzip" : format == .tarBzip2 ? "/usr/bin/bzip2" : "/opt/homebrew/bin/xz"
        try directory.run(tool, ["-t", url.path])
        try directory.run("/usr/bin/bsdtar", ["-tvf", url.path])
        try directory.run("/opt/homebrew/bin/7zz", ["t", url.path])
        try directory.run("/usr/bin/python3", ["-c", "import tarfile,sys\nwith tarfile.open(sys.argv[1]) as t:\n for m in t:\n  if m.isfile(): t.extractfile(m).read()", url.path])
    }
}

nonisolated final class CompressedTarTrace: Sendable {
    let strategies = Mutex<[CompressedTarStrategy]>([])
    let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
    let adoptions = Mutex<[ArchiveReaderAdoption]>([])
    let fullVerifications = ArchiveTestCounter()
    let rewrites = ArchiveTestCounter()
    let snapshots = ArchiveTestCounter()

    func observing<T>(_ body: () async throws -> T) async rethrows -> T {
        try await ArchiveImportTransaction.didCommitCompressedTarUpdaterForTesting.withValue({ updater in
            let statistics = try XCTUnwrap(updater.lastCommitStatistics)
            self.strategies.withLock { $0.append(statistics.strategy) }
        }) {
            try await ArchiveImportTransaction.didFallBackToFullVerificationForTesting.withValue({ reason in
                XCTAssertEqual(reason, "baseNotSpliceable"); self.fullVerifications.increment()
            }) {
                try await ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in self.rewrites.increment() }) {
                    try await ArchiveStageDiagnostics.observer.withValue({ event in
                        if case .began(_, let stage) = event { self.stages.withLock { $0.append(stage) } }
                    }) {
                        try await ArchiveSession.readerAdoptionObserverForTesting.withValue({ event in self.adoptions.withLock { $0.append(event) } }) {
                            try await ArchiveSession.willAdoptReaderForTesting.withValue({ output in
                                // Runs after rename. Reopening must retain the descriptor-backed K5 snapshot.
                                let reopened = try? output.reader?.reopen()
                                XCTAssertEqual(reopened?.tarEditingSnapshot()?.archiveIsUnchanged(), true)
                                self.snapshots.increment()
                            }) { try await body() }
                        }
                    }
                }
            }
        }
    }
    func assertAdopted(_ count: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(adoptions.withLock { $0 }, Array(repeating: .adopted, count: count), file: file, line: line)
        XCTAssertEqual(snapshots.value, count, file: file, line: line)
        XCTAssertEqual(stages.withLock { $0.filter { $0 == .readerAdoption }.count }, count, file: file, line: line)
        XCTAssertFalse(stages.withLock { $0.contains(.reloadOpen) }, file: file, line: line)
    }
}
