import Foundation
import KaitoKit
import GyoshukuKit
import XCTest
@testable import KaitoFinder

/// B1: 編集可否は session が開いた reader から導き、書庫を開き直さない。
nonisolated final class ArchiveCapabilityInspectionTests: XCTestCase {
    private func openCount() -> Int { ReaderOptions.kaitoFinderOpenCount.withLock { $0 } }

    func testSessionOpenParsesZIPOnceAndInspectsFromTheReader() async throws {
        let fixture = try ScenarioFixture()
        let before = openCount()
        let session = try ArchiveSession(url: fixture.archive)
        XCTAssertEqual(openCount() - before, 1, "document open must parse the archive once (session reader only)")
        XCTAssertEqual(session.capabilities.mode, .inPlace)
        XCTAssertTrue(session.capabilities.canEdit)
        await session.close()
    }

    func testMutationReloadOpensAtMostTwice() async throws {
        // 公開前の検証 open（作業コピー）と、公開後の再読込の 2 回。inspect は再読込の reader を使う。
        let fixture = try ScenarioFixture()
        let session = try ArchiveSession(url: fixture.archive)
        let before = openCount()
        _ = try await session.createFolder(in: "", progress: Progress())
        XCTAssertLessThanOrEqual(openCount() - before, 2, "a mutation must not re-open the archive for capabilities")
        XCTAssertEqual(session.capabilities.mode, .inPlace)
        await session.close()
    }

    func testReaderBasedInspectMatchesURLBasedInspectForEveryEditableFormat() throws {
        let directory = try ArchiveTestDirectory(), zipFixture = try ScenarioFixture()
        var archives: [URL] = [zipFixture.archive]
        for format in [GyoshukuKit.ArchiveFormat.tar, .tarGzip, .sevenZip, .lha] {
            let url = directory.url.appendingPathComponent("sample." + ArchiveCreationPlan.filenameExtension(for: format))
            let writer = try ArchiveWriter.create(url: url, format: format)
            try writer.add(data: Data("payload".utf8), as: "file.txt")
            try writer.finish()
            archives.append(url)
        }
        for archive in archives {
            let reader = try ArchiveReader.open(url: archive, options: .kaitoFinder())
            let fromReader = ArchiveCapabilities.inspect(reader: reader, url: archive)
            let fromURL = ArchiveCapabilities.inspect(url: archive, format: reader.format)
            XCTAssertEqual(fromReader.mode, fromURL.mode, archive.lastPathComponent)
            XCTAssertEqual(fromReader.refusal, fromURL.refusal, archive.lastPathComponent)
            XCTAssertTrue(fromReader.canEdit, archive.lastPathComponent)
        }
    }

    func testAssembledVolumeSetRefusesEditingEvenWhenNameCheckNoLongerFindsSiblings() throws {
        let fixture = try SplitArchiveFixture(.tar)
        let reader = try ArchiveReader.open(url: fixture.archive, options: .kaitoFinder())
        XCTAssertNotNil(reader.volumeSet)
        for volume in fixture.volumes.dropFirst() {
            try FileManager.default.moveItem(at: volume, to: volume.appendingPathExtension("held"))
        }
        XCTAssertFalse(ArchiveSplitVolume.isSplitVolumeMember(fixture.archive))
        let opens = openCount()
        XCTAssertEqual(ArchiveCapabilities.inspect(reader: reader, url: fixture.archive).refusal, .splitArchive)
        XCTAssertEqual(openCount(), opens)
    }

    func testReaderBasedInspectKeepsRefusals() throws {
        let directory = try ArchiveTestDirectory(), zipFixture = try ScenarioFixture()
        // 終端の後ろに追加データ: GyoshukuKit の門番（probe が同じ拒否を返す）。
        let trailing = directory.url.appendingPathComponent("trailing.zip")
        var bytes = try Data(contentsOf: zipFixture.archive)
        bytes.append(contentsOf: Array("trailing".utf8))
        try bytes.write(to: trailing)
        let reader = try ArchiveReader.open(url: trailing, options: .kaitoFinder())
        guard case .gatekeeper(.trailingData, _)? = ArchiveCapabilities.inspect(reader: reader, url: trailing).refusal else {
            return XCTFail("trailing data must be refused through the probe")
        }
        // 読み取り専用の親フォルダ: 権限の拒否は形式判定の後、表現可能性の前。
        let locked = directory.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        let inside = locked.appendingPathComponent("inside.zip")
        try Data(contentsOf: zipFixture.archive).write(to: inside)
        XCTAssertEqual(chmod(locked.path, 0o555), 0)
        defer { chmod(locked.path, 0o700) }
        let lockedReader = try ArchiveReader.open(url: inside, options: .kaitoFinder())
        guard case .unavailable? = ArchiveCapabilities.inspect(reader: lockedReader, url: inside).refusal else {
            return XCTFail("unwritable parent must be refused")
        }
    }

    // G4 の中央ディレクトリ照合は公開時に走る。終端の門番を通る細工 ZIP は開いた時点では編集可と判定され、
    // 最初の編集で invalidArchive として拒否される。その拒否は以後の編集可否に反映され、原本は変わらない。
    func testPublishTimeCentralDirectoryRefusalIsRememberedByTheSession() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('a.txt', b'first-payload')
            z.writestr('b.txt', b'second-payload')
        """)
        var data = try Data(contentsOf: fixture.archive)
        func u32(_ at: Int) -> UInt32 { data.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func set32(_ value: UInt32, at: Int) { withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(at..<(at + 4), with: $0) } }
        let central = Int(UInt32(littleEndian: u32(data.count - 22 + 16)))
        // 先頭 entry の local / central のサイズを CD の位置まで伸ばす（GyoshukuKit の integrity test と同じ細工）。
        for offset in [18, 22, central + 20, central + 24] { set32(UInt32(central), at: offset) }
        try data.write(to: fixture.archive)
        let session = try ArchiveSession(url: fixture.archive)
        XCTAssertEqual(session.capabilities.mode, .inPlace, "tail-only probe accepts the forged layout")
        do {
            _ = try await session.createFolder(in: "", progress: Progress())
            XCTFail("the publish-time central-directory walk must refuse the forged layout")
        } catch UpdaterError.invalidArchive {}
        XCTAssertFalse(session.capabilities.canEdit, "the publish-time refusal must stick")
        guard case .unavailable? = session.capabilities.refusal else { return XCTFail("expected unavailable") }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), data, "the original must not change")
        await session.close()
    }

    // パスワードの設定は書き直しで行うが、その場更新の門番を通らない ZIP は同じ理由で拒否する。
    func testPasswordEditOnZIPRunsTheInPlaceGatekeepersFirst() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('a.txt', b'first-payload')
            z.writestr('b.txt', b'second-payload')
        """)
        var data = try Data(contentsOf: fixture.archive)
        func u32(_ at: Int) -> UInt32 { data.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func set32(_ value: UInt32, at: Int) { withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(at..<(at + 4), with: $0) } }
        let central = Int(UInt32(littleEndian: u32(data.count - 22 + 16)))
        for offset in [18, 22, central + 20, central + 24] { set32(UInt32(central), at: offset) }
        try data.write(to: fixture.archive)
        let session = try ArchiveSession(url: fixture.archive)
        XCTAssertTrue(session.capabilities.canEdit)
        do {
            _ = try await session.updatePassword(.set, settings: ArchiveEncryptionSettings(password: "secret"), progress: Progress())
            XCTFail("a ZIP the in-place updater refuses must not be rewritten for a password change")
        } catch UpdaterError.invalidArchive {}
        XCTAssertFalse(session.capabilities.canEdit)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), data)
        await session.close()
    }

    func testHundredThousandEntryZIPSessionOpensInAboutOneParse() throws {
        guard ProcessInfo.processInfo.environment["KAITOFINDER_SCALE_TIMING"] == "1" else {
            throw XCTSkip("Set KAITOFINDER_SCALE_TIMING=1 to time a 100,000-entry ZIP session open")
        }
        let fixture = try ScenarioFixture()
        let archive = try fixture.pythonArchive("entries-100k.zip", script: """
        with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_STORED, allowZip64=True) as z:
            for i in range(100000):
                z.writestr('d%03d/s%d/t%d/f%07d.txt' % (i % 200, (i // 200) % 5, (i // 1000) % 7, i), b'x')
        """)
        let clock = ContinuousClock()
        var reader: Duration = .zero, session: Duration = .zero
        for _ in 0..<3 {
            let t0 = clock.now
            _ = try ArchiveReader.open(url: archive, options: .kaitoFinder())
            reader += clock.now - t0
            let t1 = clock.now
            let opened = try ArchiveSession(url: archive)
            session += clock.now - t1
            XCTAssertEqual(opened.capabilities.mode, .inPlace)
        }
        print("B1 TIMING 100k: reader open \(reader / 3), session init \(session / 3)")
        XCTAssertLessThan(session, reader * 3 / 2, "session init must cost about one parse, not three")
    }
}
