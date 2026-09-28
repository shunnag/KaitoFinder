import CryptoKit
import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

/// Export harness for comparing import results across builds; it runs only when KAITOFINDER_P7_EXPORT_DIRECTORY is set.
/// For each format it writes the archives this build creates and, where the format can be edited, appends files and then
/// a folder tree to, each with an `.entries.json` listing (name, kind, size, SHA-256). The same file is copied alone into
/// an older KaitoFinder tree to produce that build's export, so it uses only APIs that tree also has (hence the literal
/// /usr/bin/touch below instead of ExternalTool).
/// It lives in Probes/ with the other environment-gated harnesses: its output is data for a comparison made outside the
/// test run, and a normal test run skips it.
nonisolated final class BatchImportExportProbeTests: XCTestCase {
    // 旧名: BatchImportCompatibilityTests
    func testExportWhenEnabled() async throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOFINDER_P7_EXPORT_DIRECTORY"] else {
            throw XCTSkip("KAITOFINDER_P7_EXPORT_DIRECTORY is not configured")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true), fixture = try ArchiveTestDirectory()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixedDate = Date(timeIntervalSince1970: 1_672_627_445)
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha] {
            let suffix = ArchiveCreationPlan.filenameExtension(for: format)
            let root = fixture.url.appendingPathComponent(suffix, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let sources = try (0..<300).map { index in
                let url = root.appendingPathComponent(String(format: "item-%03d", index))
                if format != .lha && index % 20 == 19 {
                    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "item-000")
                } else {
                    try Data((0..<(202 + index * 13 % 3801)).map { UInt8(truncatingIfNeeded: $0 + index) }).write(to: url)
                }
                return url
            }
            // Set both atime and mtime, including the symlink itself.
            try fixture.run("/usr/bin/touch", ["-h", "-t", "202301020304.05"] + sources.map(\.path))
            let options = WriterOptions(compressionThreads: 8)
            let created = output.appendingPathComponent("create." + suffix)
            _ = try ArchiveCreationTransaction.run(plan: .init(sources: sources, destination: created, format: format,
                                                               options: options), progress: Progress())
            try exportEntries(created)
            if [.zip, .tar, .tarGzip, .sevenZip, .lha].contains(format) {
                let imported = output.appendingPathComponent("add." + suffix)
                let writer = try ArchiveWriter.create(url: imported, format: format, options: options)
                try writer.add(data: Data("base".utf8), as: "base.txt", modificationDate: fixedDate, permissions: 0o644)
                try writer.finish()
                let session = try ArchiveSession(url: imported, writerOptions: { _ in options })
                let result = try await session.append(urls: sources, to: "", progress: Progress())
                XCTAssertTrue(result.failures.isEmpty)
                XCTAssertNil(result.reloadFailure)
                await session.close()
                try exportEntries(imported)

                let folder = root.appendingPathComponent("tree", isDirectory: true)
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
                try Data("nested".utf8).write(to: folder.appendingPathComponent("nested.txt"))
                let withDirectories = output.appendingPathComponent("directories." + suffix)
                try FileManager.default.copyItem(at: imported, to: withDirectories)
                let directorySession = try ArchiveSession(url: withDirectories, writerOptions: { _ in options })
                let directoryResult = try await directorySession.append(urls: [folder], to: "", progress: Progress())
                XCTAssertTrue(directoryResult.failures.isEmpty)
                XCTAssertNil(directoryResult.reloadFailure)
                await directorySession.close()
                try exportEntries(withDirectories)
            }
        }
    }

    private func exportEntries(_ url: URL) throws {
        let reader = try ArchiveReader.open(url: url)
        let rows: [[String: Any]] = try reader.entries.map { entry in
            let bytes = entry.kind == .directory ? Data() : try reader.read(entry)
            return ["name": entry.name, "kind": String(describing: entry.kind), "size": entry.uncompressedSize,
                    "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
            .write(to: url.appendingPathExtension("entries.json"))
    }
}
