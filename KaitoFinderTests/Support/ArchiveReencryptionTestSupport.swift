import Foundation
import AppKit
import GyoshukuKit
@_spi(ZipRawLayout) import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated enum ArchiveReencryptionTestSupport {
    struct Snapshot: Equatable {
        let payloads: [String: Data]
        let metadata: [Data]
        let comment: Data
    }

    static func fixture() throws -> ScenarioFixture {
        try ScenarioFixture(script: #"""
        with zipfile.ZipFile(p, 'w') as z:
            z.comment = b'archive comment'
            for name, method, mode, body in [
                ('cafe\u0301.txt', zipfile.ZIP_DEFLATED, stat.S_IFREG | 0o751, b'preserve deflate\n' * 200),
                ('bzip2.txt', zipfile.ZIP_BZIP2, stat.S_IFREG | 0o640, b'preserve bzip2\n' * 200),
                ('empty', zipfile.ZIP_STORED, stat.S_IFREG | 0o600, b''),
                ('./', zipfile.ZIP_STORED, stat.S_IFDIR | 0o755, b'root'),
                ('directory/', zipfile.ZIP_STORED, stat.S_IFDIR | 0o750, b'directory payload'),
                ('link', zipfile.ZIP_STORED, stat.S_IFLNK | 0o777, b'cafe.txt')]:
                m = zipfile.ZipInfo(name, (2024, 2, 3, 4, 5, 6))
                m.compress_type = method; m.create_system = 3; m.external_attr = mode << 16
                m.internal_attr = 1; m.comment = b'entry comment'
                m.extra = struct.pack('<HHBII', 0x5455, 9, 3, 1706933106, 1706933107)
                m.extra += struct.pack('<HH', 0x7875, 7) + bytes([1, 2, 245, 1, 2, 20, 0])
                m.extra += struct.pack('<HH', 0xcafe, 3) + b'xyz'
                z.writestr(m, body)
        """#)
    }

    static func snapshot(_ url: URL, password: String? = nil) throws -> Snapshot {
        let reader = try ArchiveReader.open(url: url, options: .kaitoFinder(password: password))
        let bytes = try Data(contentsOf: url)
        let end = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards)?.lowerBound)
        var central = Int(u32(bytes, end + 16)), payloads: [String: Data] = [:], metadata: [Data] = []
        for entry in reader.entries {
            let raw = try XCTUnwrap(reader.zipRawRecordLayout(at: entry.index))
            var payload = Data()
            try ExtractionService.consume(reader.zipStoredPayloadStream(at: entry.index), checkCancellation: {}) {
                payload.append(contentsOf: $0)
            }
            payloads[entry.name] = payload
            let local = Int(raw.recordRange.lowerBound), ln = Int(u16(bytes, local + 26)), lx = Int(u16(bytes, local + 28))
            let cn = Int(u16(bytes, central + 28)), cx = Int(u16(bytes, central + 30)), cc = Int(u16(bytes, central + 32))
            metadata += [Data(bytes[local + 10..<local + 14]), Data(bytes[local + 30..<local + 30 + ln]),
                extras(Data(bytes[local + 30 + ln..<local + 30 + ln + lx])),
                Data(bytes[central + 4..<central + 6]), Data(bytes[central + 12..<central + 16]),
                Data(bytes[central + 36..<central + 42]), Data(bytes[central + 46..<central + 46 + cn]),
                extras(Data(bytes[central + 46 + cn..<central + 46 + cn + cx])),
                Data(bytes[central + 46 + cn + cx..<central + 46 + cn + cx + cc]),
                Data([UInt8(truncatingIfNeeded: raw.compressionMethod), UInt8(raw.compressionMethod >> 8)])]
            central += 46 + cn + cx + cc
        }
        return Snapshot(payloads: payloads, metadata: metadata, comment: Data(bytes[end + 22..<bytes.count]))
    }

    private static func u16(_ data: Data, _ index: Int) -> UInt16 { UInt16(data[index]) | UInt16(data[index + 1]) << 8 }
    private static func u32(_ data: Data, _ index: Int) -> UInt32 { UInt32(u16(data, index)) | UInt32(u16(data, index + 2)) << 16 }
    private static func extras(_ data: Data) -> Data {
        var index = 0, result = Data()
        while index + 4 <= data.count {
            let tag = u16(data, index), end = index + 4 + Int(u16(data, index + 2))
            guard end <= data.count else { break }
            if tag != 1 && tag != 0x9901 { result.append(data[index..<end]) }
            index = end
        }
        return result
    }

    static func assertEncryption(_ url: URL, settings: ArchiveEncryptionSettings,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let reader = try ArchiveReader.open(url: url, options: .kaitoFinder(password: settings.password))
        let encryption = ArchiveOutputProjection.ExpectedZipEncryption(settings.applying(to: .init(), format: .zip))
        try ArchiveOutputProjection(projected: reader.entries, mode: .inPlace, zipEncryption: encryption).validate(reader)
        for entry in reader.entries {
            XCTAssertEqual(entry.isEncrypted, entry.kind == .file && settings.password != nil, file: file, line: line)
            _ = try reader.read(entry)
        }
    }

    static func assertNoWork(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains {
            $0.hasPrefix(".KaitoFinder-add-") || $0.hasPrefix(".gyoshuku-")
        }, file: file, line: line)
    }

    @MainActor static func splitPasswordLifecycle(behavior: ArchivePreferences.SaveBehavior, fallback: Bool) async throws {
        let fixture = try DeferredSplitSaveFixture(format: .zip, behavior: behavior), document = fixture.document
        defer { document.close() }
        // ここでは暗号化と公開を検査し、Foundation の調整は既存の publisher 試験に委ねる。
        document.splitSaveHooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
        document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
        var expected = fixture.contents
        if behavior == .onSave {
            _ = try await document.rename(fixture.node("file0.txt"), to: "renamed.txt", progress: Progress())
            _ = try await document.remove([fixture.node("file1.txt")], progress: Progress())
            _ = try await document.append(urls: [fixture.file()], to: "", progress: Progress())
            _ = try await document.createFolder(in: "", baseName: "new", progress: Progress())
            expected["renamed.txt"] = expected.removeValue(forKey: "file0.txt")
            expected.removeValue(forKey: "file1.txt"); expected["added.txt"] = DeferredSplitSaveFixture.bytes(6000)
        }
        for action: ArchivePasswordAction in [.set, .change, .remove] {
            let settings = ArchiveEncryptionSettings(password: action == .remove ? nil : action == .set ? "first" : "second",
                                                      zipEncryption: action == .set ? .aes256 : .zipCrypto)
            let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([]), attempts = Mutex(0), progress = Progress()
            try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
            }) {
                try await ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
                    attempts.withLock { $0 += 1 }
                    if fallback { throw UpdaterError.nonRelocatableEntry(index: 0, name: "file", reason: "offset") }
                }) {
                    _ = try await document.updatePassword(action, settings: settings, progress: progress)
                    if behavior == .onSave { try await fixture.save() }
                }
            }
            XCTAssertEqual(attempts.withLock { $0 }, 1)
            XCTAssertTrue(stages.withLock { $0.contains(.updaterOpen) })
            XCTAssertEqual(stages.withLock { $0.contains(.rewriterOpen) }, fallback)
            let recompressed = String(localized: "このZIPはそのまま更新できないため、アーカイブ全体を再圧縮しました。")
            XCTAssertEqual(document.splitSaveNotice?.contains(recompressed) == true, fallback)
            XCTAssertEqual(try DeferredSaveFixture.contents(fixture.gate, password: settings.password), expected)
            let reader = try ArchiveReader.open(url: fixture.gate, options: .kaitoFinder(password: settings.password))
            try ArchiveOutputProjection(projected: reader.entries, mode: .inPlace,
                zipEncryption: .init(settings.applying(to: .init(), format: .zip))).validate(reader)
            if behavior == .immediate {
                XCTAssertEqual(progress.totalUnitCount, fallback ? 5 : 1001)
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
            }
            XCTAssertTrue(document.pendingChanges.isEmpty)
            XCTAssertTrue(try XCTUnwrap(document.session).capabilities.canEdit)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        }
    }
}
