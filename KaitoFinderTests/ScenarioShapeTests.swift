import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioShapeTests: XCTestCase {
    @MainActor func testEmptyZIPOpensExtractsNothingAndBatchCreatesNoFolder() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w'): pass")
        let (document, controller) = try await scenarioDocument(fixture)
        XCTAssertEqual(controller.outlineView.numberOfRows, 0)
        let session = try XCTUnwrap(document.session), entries = await session.entries()
        XCTAssertTrue(entries.isEmpty)
        let out = try fixture.folder("out"), result = try await fixture.extract(to: out, session: session)
        XCTAssertTrue(result.written.isEmpty && result.failures.isEmpty)
        XCTAssertFalse(result.cancelled)
        for policy in [ArchivePreferences.FolderPolicy.always, .whenMultipleTopLevelItems, .never] {
            let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: policy), passwordPrompt: { _, _ in
                XCTFail("空のZIPは認証を要求しない"); throw CancellationError()
            })
            let report = await engine.run(archives: [fixture.archive], base: out, progress: Progress())
            XCTAssertEqual(report.extracted, [fixture.archive])
            XCTAssertTrue(report.failures.isEmpty)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        }
    }

    func testDirectoriesOnlyArchiveCreatesEveryDirectoryWithoutFiles() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z:\n for name in ['one/', 'one/deep/', 'two/']: z.writestr(name, b'')")
        let out = try fixture.folder("out"), result = try await fixture.extract(to: out)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.written.compactMap(\.entryIndex), [0, 1, 2])
        XCTAssertTrue(try ScenarioFixture.files(under: out).isEmpty)
        for path in ["one", "one/deep", "two"] {
            XCTAssertEqual(try out.appendingPathComponent(path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory, true)
        }
    }

    @MainActor func testSingleFileArchiveExtractsUnderEveryFolderPolicy() async throws {
        let fixture = try ScenarioFixture()
        for (index, policy) in [ArchivePreferences.FolderPolicy.always, .whenMultipleTopLevelItems, .never].enumerated() {
            let out = try fixture.folder("out-\(index)")
            let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: policy), passwordPrompt: { _, _ in throw CancellationError() })
            let report = await engine.run(archives: [fixture.archive], base: out, progress: Progress())
            XCTAssertEqual(report.extracted, [fixture.archive])
            XCTAssertTrue(report.failures.isEmpty)
            let parent = policy == .always ? out.appendingPathComponent("archive") : out
            XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent("original.txt")), Data("original".utf8))
            XCTAssertEqual(try ScenarioFixture.files(under: out).count, 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [policy == .always ? "archive" : "original.txt"])
        }
    }

    func testTarHardLinkAndSymlinkSurviveRewriteAppend() async throws {
        let fixture = try ScenarioFixture(script: #"""
        with tarfile.open(p, 'w', format=tarfile.USTAR_FORMAT) as t:
            body = tarfile.TarInfo('body'); body.size = 7; body.mode = 0o640
            t.addfile(body, io.BytesIO(b'payload'))
            hard = tarfile.TarInfo('hard'); hard.type = tarfile.LNKTYPE; hard.linkname = 'body'; t.addfile(hard)
            soft = tarfile.TarInfo('soft'); soft.type = tarfile.SYMTYPE; soft.linkname = 'body'; t.addfile(soft)
        """#, suffix: "tar")
        let session = try ArchiveSession(url: fixture.archive), source = try fixture.file("new.txt")
        XCTAssertEqual(session.capabilities.mode, .rewrite(.tar))
        _ = try await session.append(urls: [source], to: "", progress: Progress())
        let entries = await session.entries()
        // rewriterは追加項目を先に書くため、名前と種類の対応で保存結果を検証する。
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.kind) }),
                       ["body": .file, "hard": .hardlink, "soft": .symlink, "new.txt": .file])
        let out = try fixture.folder("out"), result = try await fixture.extract(to: out, session: session)
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        for path in ["body", "hard", "soft"] { XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(path)), Data("payload".utf8)) }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: out.appendingPathComponent("soft").path), "body")
        var body = stat(), hard = stat()
        XCTAssertEqual(lstat(out.appendingPathComponent("body").path, &body), 0)
        XCTAssertEqual(lstat(out.appendingPathComponent("hard").path, &hard), 0)
        XCTAssertEqual(body.st_ino, hard.st_ino)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("new.txt")), Data("added".utf8))
        try fixture.directory.run("/usr/bin/bsdtar", ["-tf", fixture.archive.path])
    }

    func testSolidSevenZipRewriteAppendKeepsEveryEntryAndByte() async throws {
        let fixture = try ScenarioFixture(), archive = fixture.root.appendingPathComponent("solid.7z")
        var expected: [String: Data] = [:]
        for n in 0..<12 {
            let name = "part-\(n).txt", bytes = Data(repeating: UInt8(65 + n), count: 8192)
            expected[name] = bytes
            _ = try fixture.file(name, bytes: bytes)
        }
        try fixture.directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-ms=on", archive.path] + expected.keys.sorted())
        let session = try ArchiveSession(url: archive), before = await session.entries()
        XCTAssertEqual(Set(before.map(\.solidGroup)).count, 1)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(before.first).solidGroup, 0)
        XCTAssertEqual(session.capabilities.mode, .rewrite(.sevenZip))
        let source = try fixture.file("new.txt")
        _ = try await session.append(urls: [source], to: "", progress: Progress())
        expected["new.txt"] = Data("added".utf8)
        XCTAssertEqual(try ScenarioFixture.contents(archive), expected)
        XCTAssertEqual(try ArchiveReader.open(url: archive).entries.count, 13)
        try fixture.directory.run("/opt/homebrew/bin/7zz", ["t", "-bd", archive.path])
    }

    func testCP932LHANameAndContentsSurviveRewriteAppend() async throws {
        let fixture = try ScenarioFixture(), archive = fixture.root.appendingPathComponent("legacy.lzh")
        let writer = try ArchiveWriter.create(url: archive, format: .lha)
        try writer.add(data: Data("legacy".utf8), as: "日本語.txt")
        try writer.finish()
        let before = try XCTUnwrap(ArchiveReader.open(url: archive).entries.first)
        XCTAssertEqual(before.rawName.bytes, [0x93, 0xfa, 0x96, 0x7b, 0x8c, 0xea, 0x2e, 0x74, 0x78, 0x74])
        let session = try ArchiveSession(url: archive), source = try fixture.file("追加.txt")
        XCTAssertEqual(session.capabilities.mode, .rewrite(.lha))
        _ = try await session.append(urls: [source], to: "", progress: Progress())
        XCTAssertEqual(try ScenarioFixture.contents(archive), ["日本語.txt": Data("legacy".utf8), "追加.txt": Data("added".utf8)])
        XCTAssertEqual(try ArchiveReader.open(url: archive).entries.first(where: { $0.name == "日本語.txt" })?.rawName.bytes, before.rawName.bytes)
    }
}
