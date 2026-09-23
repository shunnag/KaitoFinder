import AppKit
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ImmediateSplitInteropTests: XCTestCase {
    private static func require(_ executable: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Missing \(executable)") }
    }
    private static func run(_ executable: String, _ arguments: [String], at directory: URL) throws -> String {
        try require(executable)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = directory; process.standardOutput = output; process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text
    }

    @MainActor func testImmediateEditsAndSaveAsPassSevenZipAndInfoZIPInterop() async throws {
        try Self.require("/opt/homebrew/bin/7zz")
        try Self.require("/usr/bin/zip")
        for format: GyoshukuKit.ArchiveFormat in [.sevenZip, .tarGzip, .zip] {
            let fixture = try DeferredSplitSaveFixture(format: format, behavior: .immediate, external: { whole, directory in
                guard format == .zip else { return }
                let names = (0..<4).map { "file\($0).txt" }
                for (i, name) in names.enumerated() {
                    try DeferredSplitSaveFixture.bytes(9728, seed: UInt64(i + 1)).write(to: directory.appendingPathComponent(name))
                }
                let output = directory.appendingPathComponent("infozip.zip")
                _ = try Self.run("/usr/bin/zip", ["-0", output.path] + names, at: directory)
                try Data(contentsOf: output).write(to: whole)
            })
            defer { fixture.document.close() }
            fixture.document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
            _ = try await fixture.document.remove([fixture.node("file0.txt")], progress: Progress())
            _ = try await fixture.document.rename(fixture.node("file1.txt"), to: "renamed.txt", progress: Progress())
            _ = try await fixture.document.append(urls: [fixture.file(count: 80000)], to: "", progress: Progress())
            let text = try Self.run("/opt/homebrew/bin/7zz", ["t", fixture.gate.path], at: fixture.root)
            XCTAssertFalse(text.lowercased().contains("data after the end")); XCTAssertFalse(text.contains("Tail"))
            let session = try XCTUnwrap(fixture.document.session)
            let existing = try await ArchiveCreationController.existingArchive(from: session, progress: Progress())
            let output = fixture.root.appendingPathComponent("export.zip")
            var plan = ArchiveCreationPlan(sources: [], destination: output, format: .zip, existing: existing)
            plan.splitSchedule = .uniform(size: 65536)
            let gate = try ArchiveCreationTransaction.run(plan: plan, progress: Progress(), volumeIndex: fixture.index, metadataStore: fixture.metadata)
            _ = try Self.run("/opt/homebrew/bin/7zz", ["t", gate.path], at: fixture.root)
            let listing = try Self.run("/opt/homebrew/bin/7zz", ["l", gate.path], at: fixture.root)
            XCTAssertTrue(listing.contains("renamed.txt")); XCTAssertTrue(listing.contains("added.txt"))
            let layout = try XCTUnwrap(ArchiveReader.open(url: gate).volumeSet)
            XCTAssertTrue(listing.contains("Volumes: \(layout.volumes.count)"), listing)
        }
    }
}
