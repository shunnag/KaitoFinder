import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioDiskTests: XCTestCase {
    /// 容量不足を起こせるよう 8 MiB の APFS を作る。hdiutil が使えない環境ではスキップする。
    private func volume() throws -> VolumePublishTestDisk {
        let volume = try VolumePublishTestDisk("APFS", size: "8m")
        addTeardownBlock { try volume.detach() }
        return volume
    }

    private func assertOutOfSpace(_ error: any Error, file: StaticString = #filePath, line: UInt = #line) {
        let cocoa = error as NSError, reason = ArchiveErrorText.describe(error)
        let descriptions = [
            ArchiveErrorText.describe(CocoaError(.fileWriteOutOfSpace)),
            ArchiveErrorText.describe(WriterError.io(operation: "write", code: ENOSPC)),
            ArchiveErrorText.describe(POSIXError(.ENOSPC)),
            ArchiveErrorText.describe(ExtractionFailure.system(ENOSPC))
        ]
        let typed = (cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.fileWriteOutOfSpace.rawValue)
            || (cocoa.domain == NSPOSIXErrorDomain && cocoa.code == Int(ENOSPC))
        // 項目名を付けた書き込みエラーも、同じ言語の ENOSPC 説明で照合する。
        XCTAssertTrue(typed || descriptions.contains { reason == $0 || reason.hasSuffix(": " + $0) },
                      reason, file: file, line: line)
    }

    func testFullDiskExtractionReportsNoSpaceAndRemovesPartialPayload() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as z: z.writestr('large.bin', b'x' * (32 * 1024 * 1024))")
        let volume = try volume(), original = try ScenarioFixture.digest(fixture.archive)
        let sentinel = volume.mount.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let result = try await fixture.extract(to: volume.mount)
        XCTAssertEqual(result.failures.map(\.name), ["large.bin"])
        XCTAssertEqual(result.failures.first?.reason, ExtractionFailure.system(ENOSPC).description)
        XCTAssertTrue(result.written.isEmpty)
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: volume.mount.appendingPathComponent("large.bin").path))
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), original)
    }

    @MainActor func testFullArchiveVolumeRefusesAppendWithoutPublishOrUndo() async throws {
        let fixture = try ScenarioFixture(), volume = try volume()
        let archive = volume.mount.appendingPathComponent("archive.zip")
        try FileManager.default.copyItem(at: fixture.archive, to: archive)
        let (document, _) = try await scenarioDocument(fixture, url: archive)
        let before = try ScenarioFixture.digest(archive), source = try fixture.file("new.bin", bytes: Data(repeating: 0x61, count: 1024 * 1024))
        let originalNames = Set(try FileManager.default.contentsOfDirectory(atPath: volume.mount.path))
        try volume.fill()
        do {
            _ = try await document.append(urls: [source], to: "", progress: Progress(), willPublish: { XCTFail("容量不足で公開境界に進みました") })
            XCTFail("容量のないボリュームへ追加を公開しました")
        } catch {
            assertOutOfSpace(error)
        }
        XCTAssertEqual(try ScenarioFixture.digest(archive), before)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertEqual(document.generation, 0)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: volume.mount.path)), originalNames.union(["filler"]))
        // マウント解除より前に文書が保持するreaderを閉じる。
        document.close()
        await document.sessionCleanup?.value
    }

    @MainActor func testReadOnlyVolumeRefusesEditingWithPermissionReasonAndBatchReportsEachArchive() async throws {
        let fixture = try ScenarioFixture(), volume = try volume()
        let archive = volume.mount.appendingPathComponent("archive.zip")
        try FileManager.default.copyItem(at: fixture.archive, to: archive)
        try volume.detach()
        try volume.attach(readOnly: true)
        let session = try ArchiveSession(url: archive)
        let permission = String(localized: "アーカイブまたは親フォルダへの書き込み権限がありません。")
        XCTAssertEqual(session.capabilities.refusal, .unavailable(permission))
        XCTAssertTrue(try XCTUnwrap(session.capabilities.readOnlyReason).contains(permission))
        do { _ = try await session.createFolder(in: "", progress: Progress()); XCTFail("読み取り専用ボリュームを変更しました") }
        catch { XCTAssertEqual(String(describing: error), session.capabilities.readOnlyReason) }
        let second = try fixture.pythonArchive("second.zip", script: "with zipfile.ZipFile(p, 'w') as z: z.writestr('second', b'2')")
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always), passwordPrompt: { _, _ in throw CancellationError() })
        let report = await engine.run(archives: [fixture.archive, second], base: volume.mount, progress: Progress())
        XCTAssertEqual(report.failures.map(\.archive), [fixture.archive, second])
        XCTAssertTrue(report.extracted.isEmpty)
        for failure in report.failures { XCTAssertEqual(failure.reason, ExtractionFailure.system(EROFS).description) }
        XCTAssertEqual(try ScenarioFixture.digest(archive), try ScenarioFixture.digest(fixture.archive))
        await session.close()
    }

    @MainActor func testLHALargeAppendOutOfSpaceKeepsOriginalAndRemovesSpool() async throws {
        let fixture = try ScenarioFixture(), volume = try volume()
        let archive = volume.mount.appendingPathComponent("archive.lzh")
        let writer = try GyoshukuKit.ArchiveWriter.create(url: archive, format: .lha)
        try writer.add(data: Data("original".utf8), as: "original.txt")
        try writer.finish()
        let (document, _) = try await scenarioDocument(fixture, url: archive)
        let before = try ScenarioFixture.digest(archive)
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: volume.mount.path))
        let source = try fixture.file("large.bin", bytes: Data(repeating: 0x41, count: 32 * 1024 * 1024))
        do {
            _ = try await document.append(urls: [source], to: "", progress: Progress(),
                                          willPublish: { XCTFail("容量不足で公開境界に進みました") })
            XCTFail("LHA streaming append exceeded the test volume")
        } catch {
            assertOutOfSpace(error)
        }
        XCTAssertEqual(try ScenarioFixture.digest(archive), before)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertEqual(document.generation, 0)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: volume.mount.path)), names)
        document.close()
        await document.sessionCleanup?.value
    }

    @MainActor func testCompressedTarAppendOutOfSpaceKeepsOriginalAndUndoHistory() async throws {
        var state: UInt64 = 0x7461_7220_2026
        let bytes = Data((0..<(16 * 1_024 * 1_024)).map { _ in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return UInt8(truncatingIfNeeded: state)
        })
        for (format, suffix) in [(GyoshukuKit.ArchiveFormat.tarBzip2, "tar.bz2"), (.tarXZ, "tar.xz")] {
            let fixture = try ScenarioFixture(), volume = try volume()
            let archive = volume.mount.appendingPathComponent("archive." + suffix)
            let writer = try GyoshukuKit.ArchiveWriter.create(url: archive, format: format)
            try writer.add(data: Data("original".utf8), as: "original.txt")
            try writer.finish()
            let (document, _) = try await scenarioDocument(fixture, url: archive)
            let before = try ScenarioFixture.digest(archive)
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: volume.mount.path))
            let source = try fixture.file("large.bin", bytes: bytes)
            do {
                _ = try await document.append(urls: [source], to: "", progress: Progress(),
                                              willPublish: { XCTFail("容量不足で公開境界に進みました") })
                XCTFail("compressed tar append exceeded the test volume")
            } catch {
                assertOutOfSpace(error)
            }
            XCTAssertEqual(try ScenarioFixture.digest(archive), before)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
            XCTAssertEqual(document.generation, 0)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: volume.mount.path)), names)
            document.close()
            await document.sessionCleanup?.value
            try volume.detach()
        }
    }

}


extension ScenarioDiskTests {
    func testFailedPublishKeepsUnremovableWorkRegistered() throws {
        let fixture = try ArchiveTestDirectory(), parent = fixture.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let archive = parent.appendingPathComponent("archive.zip")
        let original = ReleaseReviewFixtures.zip([("original.txt", Data("original".utf8))])
        try original.write(to: archive)
        let file = fixture.url.appendingPathComponent("pending.json"), registry = PendingWorkRegistry(fileURL: file)
        defer { chmod(parent.path, 0o700) }
        let entries = try ArchiveReader.open(url: archive).entries
        XCTAssertThrowsError(try ArchiveImportTransaction.publish(archive: archive, mode: .inPlace,
            options: WriterOptions(), progress: Progress(),
            ledger: .forTesting(plan: .init(counted: 0,
                additions: [UInt64("added".utf8.count)], itemCount: 1,
                carriedBytes: ArchiveWriteProgress.carriedBytes(entries), changesExisting: false)), willPublish: {
                guard chmod(parent.path, 0o555) == 0 else { throw ExtractionFailure.system(errno) }
            }, registry: registry, expectedOutput: .init(existing: entries,
                additions: [.init(adding: "added.txt", kind: .file)], mode: .inPlace),
            mutate: { try $0.add(data: Data("added".utf8), as: "added.txt", modificationDate: nil, permissions: nil) }))
        let work = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".KaitoFinder-add-") }
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(try PendingWorkRegistryTests.entries(in: file).compactMap { $0["path"] as? String }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path },
            work.map { $0.standardizedFileURL.resolvingSymlinksInPath().path },
                       "Failed cleanup must remain registered")
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    func testFailedCreationKeepsUnremovableWorkRegistered() throws {
        let fixture = try ArchiveTestDirectory(), parent = fixture.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let input = fixture.url.appendingPathComponent("input.txt")
        try Data("payload".utf8).write(to: input)
        let file = fixture.url.appendingPathComponent("pending.json"), registry = PendingWorkRegistry(fileURL: file)
        let destination = parent.appendingPathComponent("new.zip")
        let plan = ArchiveCreationPlan(sources: [input], destination: destination, format: .zip, options: WriterOptions())
        defer { chmod(parent.path, 0o700) }
        XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: plan, progress: Progress(), willPublish: {
            guard chmod(parent.path, 0o555) == 0 else { throw ExtractionFailure.system(errno) }
        }, registry: registry))
        let work = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".KaitoFinder-new-") }
        XCTAssertEqual(work.count, 1)
        XCTAssertEqual(try PendingWorkRegistryTests.entries(in: file).compactMap { $0["path"] as? String }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path },
            work.map { $0.standardizedFileURL.resolvingSymlinksInPath().path },
                       "Failed cleanup must remain registered")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}

private extension VolumePublishTestDisk {
    /// 空きを使い切り、書き込みが ENOSPC になることを確かめる。
    nonisolated func fill() throws {
        let descriptor = open(mount.appendingPathComponent("filler").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw ExtractionFailure.system(errno) }
        defer { close(descriptor) }
        let bytes = [UInt8](repeating: 0xa5, count: 4096)
        // 疎ファイルは容量不足を起こさない。小さいブロックで実際に空きを使い切る。
        for _ in 0..<8192 {
            let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            if count < 0 {
                XCTAssertEqual(errno, ENOSPC)
                guard errno == ENOSPC else { throw ExtractionFailure.system(errno) }
                return
            }
        }
        XCTFail("8 MiBのテストボリュームで32 MiBを書き込めました")
    }
}
