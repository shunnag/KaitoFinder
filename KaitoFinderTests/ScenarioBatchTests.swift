import Foundation
import GyoshukuKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioBatchTests: XCTestCase {
    @MainActor func testThirtyMixedArchivesPreserveOrderIsolateFailuresAndTrashOnlySuccesses() async throws {
        let fixture = try ScenarioFixture(), out = try fixture.folder("out")
        var archives: [URL] = [], expected: [URL: Data] = [:]
        for n in 0..<30 {
            let bytes = Data("archive-\(n)\n日本語\0".utf8)
            let stem = String(format: "item-%02d", n)
            let url: URL
            if n == 7 {
                url = try fixture.file(stem + ".zip", bytes: Data("corrupt archive".utf8))
            } else if n == 13 || n == 21 {
                let source = try fixture.file("input-\(n)/payload.txt", bytes: bytes)
                url = fixture.root.appendingPathComponent(stem + (n == 13 ? ".zip" : ".7z"))
                if n == 13 {
                    try fixture.directory.run("/usr/bin/zip", ["-q", "-j", "-P", "secret", url.path, source.path])
                } else {
                    try fixture.directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-psecret", "-mhe=on", url.path, source.path])
                }
            } else {
                let source = try fixture.file("input-\(n)/payload.txt", bytes: bytes)
                // ZIP/tar/7zは独立したwriterで作り、LHAだけGyoshukuKitを使う。
                let input = "source = os.path.join(os.path.dirname(p), 'input-\(n)', 'payload.txt')\n"
                switch n % 4 {
                case 0:
                    url = try fixture.pythonArchive(stem + ".zip", script: input
                        + "with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as z: z.write(source, 'payload.txt')")
                case 1:
                    url = try fixture.pythonArchive(stem + ".tgz", script: input
                        + "with tarfile.open(p, 'w:gz') as t: t.add(source, arcname='payload.txt')")
                case 2:
                    url = fixture.root.appendingPathComponent(stem + ".7z")
                    try fixture.directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", url.path, source.path])
                default:
                    url = fixture.root.appendingPathComponent(stem + ".lzh")
                    let writer = try ArchiveWriter.create(url: url, format: .lha)
                    try writer.add(data: bytes, as: "payload.txt")
                    try writer.finish()
                }
            }
            archives.append(url)
            expected[url] = bytes
        }
        let originals = try archives.map(ScenarioFixture.digest)
        let trashed = Mutex<[URL]>([])
        var prompts: [URL] = [], visited: [URL?] = []
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always, trashesArchiveAfterExtraction: true),
            passwordPrompt: { url, challenge in
                prompts.append(url)
                XCTAssertEqual(challenge, .required)
                if url == archives[21] { throw CancellationError() }
                XCTAssertEqual(url, archives[13])
                return "secret"
            }, trash: { url in trashed.withLock { $0.append(url) } }, currentArchive: { visited.append($0) })
        let progress = Progress(), report = await engine.run(archives: archives, base: out, progress: progress)
        let successes = archives.enumerated().filter { ![7, 21].contains($0.offset) }.map(\.element)
        XCTAssertEqual(report.failures.map(\.archive), [archives[7], archives[21]])
        XCTAssertTrue(report.failures.allSatisfy { !$0.reason.isEmpty })
        XCTAssertEqual(report.failures.last?.reason, String(localized: "キャンセル"))
        XCTAssertEqual(report.extracted, successes)
        XCTAssertEqual(trashed.withLock { $0 }, successes)
        XCTAssertEqual(prompts, [archives[13], archives[21]])
        XCTAssertEqual(visited, archives.map(Optional.some) + [nil])
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(progress.completedUnitCount, 30)
        XCTAssertEqual(try ScenarioFixture.files(under: out).count, 28)
        for (index, archive) in archives.enumerated() {
            let folder = out.appendingPathComponent(ArchiveCreationPlan.archiveStem(for: archive))
            if [7, 21].contains(index) { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path)) }
            else { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("payload.txt")), expected[archive]) }
            XCTAssertEqual(try ScenarioFixture.digest(archive), originals[index])
        }
    }
}
