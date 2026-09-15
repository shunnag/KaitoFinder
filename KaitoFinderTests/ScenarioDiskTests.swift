import Darwin
import Foundation
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioDiskTests: XCTestCase {
    /// hdiutilだけは失敗をアサーションにせず、ディスク作成が許可されない環境をスキップする。
    private final class Volume: Sendable {
        let directory: ArchiveTestDirectory
        let image: URL
        let mount: URL
        private let attached = Mutex(false)

        init() throws {
            directory = try ArchiveTestDirectory()
            image = directory.url.appendingPathComponent("disk.dmg")
            mount = directory.url.appendingPathComponent("mount")
            try command(["create", "-size", "8m", "-fs", "APFS", "-volname", "KFTest", image.path])
            try attach(readOnly: false)
        }

        private func command(_ arguments: [String]) throws {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.currentDirectoryURL = directory.url
            process.standardOutput = output
            process.standardError = output
            do { try process.run() }
            catch { throw XCTSkip("hdiutilを起動できない: \(error)") }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw XCTSkip("hdiutil \(arguments.first ?? "")が利用できない (\(process.terminationStatus)): \(String(decoding: bytes, as: UTF8.self))")
            }
        }

        func attach(readOnly: Bool) throws {
            try attached.withLock { value in
                try command(["attach", "-nobrowse", "-mountpoint", mount.path] + (readOnly ? ["-readonly"] : []) + [image.path])
                value = true
            }
        }

        func detach() throws {
            try attached.withLock { value in
                guard value else { return }
                try command(["detach", "-force", mount.path])
                value = false
            }
        }

        deinit { try? detach() }

        func fill() throws {
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

    private func volume() throws -> Volume {
        let volume = try Volume()
        addTeardownBlock { try volume.detach() }
        return volume
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
            let cocoa = error as NSError
            let reason = String(describing: error)
            XCTAssertTrue(reason.contains("\(ENOSPC)") || reason.localizedCaseInsensitiveContains("space")
                          || (cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.fileWriteOutOfSpace.rawValue), reason)
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
}
