import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveSplitVolumeTests: XCTestCase {
    private struct Fixture {
        let directory: ArchiveTestDirectory
        let archive: URL

        init(_ format: GyoshukuKit.ArchiveFormat, name: String? = nil, options: WriterOptions = WriterOptions()) throws {
            directory = try ArchiveTestDirectory()
            archive = directory.url.appendingPathComponent(name ?? "archive." + ArchiveCreationPlan.filenameExtension(for: format))
            let writer = try ArchiveWriter.create(url: archive, format: format, options: options)
            var seed: UInt64 = 0x12345678
            for index in 0..<4 {
                let data = Data((0..<9728).map { _ in
                    seed = seed &* 6364136223846793005 &+ 1
                    return UInt8(truncatingIfNeeded: seed >> 32)
                })
                // tar の各項目は header を含めて 10240 byte。最後の親は移動先の仮想フォルダにも使う。
                try writer.add(data: data, as: index == 3 ? "folder/file3.txt" : "file\(index).txt")
            }
            try writer.finish()
        }

        func split(chunkSize: Int = 8192) throws -> [URL] {
            let bytes = try Data(contentsOf: archive)
            var volumes: [URL] = []
            for offset in stride(from: 0, to: bytes.count, by: chunkSize) {
                let volume = archive.appendingPathExtension(String(format: "%03d", volumes.count + 1))
                try bytes.subdata(in: offset..<min(offset + chunkSize, bytes.count)).write(to: volume)
                volumes.append(volume)
            }
            try FileManager.default.removeItem(at: archive)
            return volumes
        }

        func source() throws -> URL {
            let url = directory.url.appendingPathComponent("added.txt")
            try Data("added contents".utf8).write(to: url)
            return url
        }
    }

    private func assertSplit(_ capabilities: ArchiveCapabilities, refusal: ArchiveCapabilities.Refusal = .splitArchive,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(capabilities.refusal, refusal, file: file, line: line)
        XCTAssertFalse(capabilities.canEdit, file: file, line: line)
        XCTAssertNil(capabilities.mode, file: file, line: line)
        XCTAssertNil(capabilities.rewriteNotice, file: file, line: line)
        let reason = refusal == .nativeSplitArchive
            ? String(localized: "ZIP本来の分割アーカイブは変更できません。")
            : String(localized: "分割アーカイブは、設定で「保存時にまとめて書き込む」を選ぶと編集できます。")
        XCTAssertEqual(capabilities.readOnlyReason, reason, file: file, line: line)
    }

    private func assertRefused(_ error: any Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case ExtractionFailure.refused(let reason) = error else {
            return XCTFail("Expected split refusal, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(reason, String(localized: "分割アーカイブは、設定で「保存時にまとめて書き込む」を選ぶと編集できます。"), file: file, line: line)
    }

    private func assertUnchanged(_ volumes: [URL], bytes: [Data], in directory: URL,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(volumes.count, bytes.count, file: file, line: line)
        for (volume, original) in zip(volumes, bytes) {
            XCTAssertEqual(try Data(contentsOf: volume), original, volume.lastPathComponent, file: file, line: line)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".KaitoFinder-add-") }, names.description, file: file, line: line)
    }

    func testNumberedVolumeNames() throws {
        let directory = try ArchiveTestDirectory()
        let names = ["a.7z.001", "a.7z.002", "b.7z.001", "c.tar.001", "c.tar.005", "d.tar.005",
                     "e.zip.000", "e.zip.001", "f.7z.0001", "f.7z.0002", "g.7z.001", "g.7z.1000"]
        for name in names { try Data().write(to: directory.url.appendingPathComponent(name)) }
        let members = ["a.7z.001", "a.7z.002", "c.tar.005", "e.zip.000", "e.zip.001",
                       "f.7z.0001", "f.7z.0002", "g.7z.1000"]
        for name in names {
            XCTAssertEqual(ArchiveSplitVolume.isSplitVolumeMember(directory.url.appendingPathComponent(name)),
                           members.contains(name), name)
        }
    }

    func testNumberedNamesRequireASCIIDigitsAndHandleArbitraryWidths() throws {
        let directory = try ArchiveTestDirectory()
        for name in ["short.001", "short.002", "unicode.001", "unicode.002", "huge.001"] {
            try Data().write(to: directory.url.appendingPathComponent(name))
        }
        for name in ["short.01", "short.00", "unicode.００１", "unicode.٠٠١", "unicode.00a", "unicode.+01",
                     "short.001.extra", "no-extension"] {
            XCTAssertFalse(ArchiveSplitVolume.isSplitVolumeMember(directory.url.appendingPathComponent(name)), name)
        }
        for digits in [String(repeating: "9", count: 40), String(repeating: "0", count: 40)] {
            XCTAssertTrue(ArchiveSplitVolume.isSplitVolumeMember(directory.url.appendingPathComponent("huge." + digits)))
        }
        let padding = String(repeating: "0", count: 39)
        try Data().write(to: directory.url.appendingPathComponent("wide." + padding + "2"))
        XCTAssertTrue(ArchiveSplitVolume.isSplitVolumeMember(directory.url.appendingPathComponent("wide." + padding + "1")))
    }

    func testNativeZIPVolumeNamesAndFinalVolumes() throws {
        let directory = try ArchiveTestDirectory()
        for name in ["h.z01", "h.Z99", "h.z100", "h.zx01", "h.ZX100", "h.Zx01", "h.zX01"] {
            // 名前だけで拒否でき、対象自身の存在も必要ない。
            XCTAssertTrue(ArchiveSplitVolume.isSplitVolumeMember(directory.url.appendingPathComponent(name)), name)
        }
        for name in ["h.z1", "h.zx1", "h.z01x", "h.z０１", "h.zx٠١", "j.zip", "j.zipx"] {
            XCTAssertFalse(ArchiveSplitVolume.isSplitVolumeMember(directory.url.appendingPathComponent(name)), name)
        }
        for (index, suffix) in ["z01", "Z01", "zx01", "ZX01"].enumerated() {
            let stem = "native\(index)"
            try Data().write(to: directory.url.appendingPathComponent(stem + "." + suffix))
            for final in ["zip", "ZIP", "zipx", "ZiPx"] {
                XCTAssertTrue(ArchiveSplitVolume.isSplitVolumeMember(directory.url.appendingPathComponent(stem + "." + final)))
            }
        }
        for (final, first) in [("i.zip", "i.z01"), ("k.zipx", "k.zx01")] {
            try Data().write(to: directory.url.appendingPathComponent(first))
            XCTAssertTrue(ArchiveSplitVolume.isSplitVolumeMember(directory.url.appendingPathComponent(final)))
        }
    }

    func testSiblingExistenceUsesLstatForAnyFileTypeWithoutFollowingSymlinks() throws {
        let directory = try ArchiveTestDirectory()
        let first = directory.url.appendingPathComponent("link.tar.001")
        let sibling = directory.url.appendingPathComponent("link.tar.002")
        // 自己参照 symlink は stat では ELOOP になるが、lstat では存在する。
        try FileManager.default.createSymbolicLink(atPath: sibling.path, withDestinationPath: sibling.lastPathComponent)
        XCTAssertTrue(ArchiveSplitVolume.isSplitVolumeMember(first))
        try FileManager.default.removeItem(at: sibling)
        try FileManager.default.createSymbolicLink(atPath: sibling.path, withDestinationPath: "missing")
        XCTAssertTrue(ArchiveSplitVolume.isSplitVolumeMember(first))
        try FileManager.default.removeItem(at: sibling)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
        XCTAssertTrue(ArchiveSplitVolume.isSplitVolumeMember(first))
        let native = directory.url.appendingPathComponent("link.z01")
        try FileManager.default.createSymbolicLink(atPath: native.path, withDestinationPath: "missing")
        XCTAssertTrue(ArchiveSplitVolume.isSplitVolumeMember(directory.url.appendingPathComponent("link.zip")))
    }

    func testInspectRefusesByteSplitSevenZipTarTarGzipLHAAndZIP() throws {
        for format in [GyoshukuKit.ArchiveFormat.sevenZip, .tar, .tarGzip, .lha, .zip] {
            let fixture = try Fixture(format)
            let volumes = try fixture.split(), archive = try XCTUnwrap(volumes.first)
            XCTAssertGreaterThan(volumes.count, 1)
            let reader = try ArchiveReader.open(url: archive, options: .kaitoFinder())
            XCTAssertEqual(reader.entries.count, 4)
            let opens = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
            assertSplit(ArchiveCapabilities.inspect(url: archive, format: reader.format))
            assertSplit(ArchiveCapabilities.inspect(reader: reader, url: archive))
            XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 }, opens, "inspection must not open a reader")
        }
    }

    func testStandaloneTarSecondVolumeStartingAtAHeaderIsReadOnly() throws {
        let fixture = try Fixture(.tar)
        let volumes = try fixture.split(chunkSize: 30720)
        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(try Data(contentsOf: volumes[0]).count, 30720)
        let reader = try ArchiveReader.open(url: volumes[1], options: .kaitoFinder())
        XCTAssertEqual(reader.format, .tar)
        XCTAssertEqual(reader.entries.map(\.name), ["folder/file3.txt"])
        assertSplit(ArchiveCapabilities.inspect(url: volumes[1], format: .tar))
        assertSplit(ArchiveCapabilities.inspect(reader: reader, url: volumes[1]))
    }

    func testNativeZIPFinalVolumeIsSplitInsteadOfSFXAndKeepsItsFormatName() async throws {
        let fixture = try Fixture(.zip, name: "n.zip")
        try Data().write(to: fixture.directory.url.appendingPathComponent("n.z01"))
        let reader = try ArchiveReader.open(url: fixture.archive, options: .kaitoFinder())
        assertSplit(ArchiveCapabilities.inspect(url: fixture.archive, format: .zip), refusal: .nativeSplitArchive)
        assertSplit(ArchiveCapabilities.inspect(reader: reader, url: fixture.archive), refusal: .nativeSplitArchive)
        let session = try ArchiveSession(url: fixture.archive)
        assertSplit(session.capabilities, refusal: .nativeSplitArchive)
        XCTAssertEqual(ArchiveConversionNotice.formatName(for: session), session.format.displayName)
        do { _ = try await session.createFolder(in: "", progress: Progress()); XCTFail("Native split ZIP stays read-only") }
        catch ExtractionFailure.refused(let reason) {
            XCTAssertEqual(reason, String(localized: "ZIP本来の分割アーカイブは変更できません。"))
        }
        await session.close()
    }

    func testSplitRefusalPrecedesFormatPermissionAndInvalidContents() throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("invalid.001")
        try Data("not an archive".utf8).write(to: archive)
        try Data().write(to: directory.url.appendingPathComponent("invalid.002"))
        XCTAssertEqual(chmod(archive.path, 0o000), 0)
        defer { chmod(archive.path, 0o600) }
        let opens = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        for format in [KaitoKit.ArchiveFormat.rar, .zip, .tar, .sevenZip, .lha] {
            assertSplit(ArchiveCapabilities.inspect(url: archive, format: format))
        }
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 }, opens)
    }

    func testSplitRefusalPrecedesEncryptionAndZIPGatekeepers() throws {
        let options = ArchiveEncryptionSettings(password: "secret").applying(to: WriterOptions(), format: .zip)
        let fixture = try Fixture(.zip, name: "encrypted.zip.001", options: options)
        let reader = try ArchiveReader.open(url: fixture.archive, options: .kaitoFinder(password: "secret"))
        XCTAssertTrue(reader.entries.contains(where: \.isEncrypted))
        try Data().write(to: fixture.archive.deletingPathExtension().appendingPathExtension("002"))
        assertSplit(ArchiveCapabilities.inspect(url: fixture.archive, format: .zip))
        assertSplit(ArchiveCapabilities.inspect(reader: reader, url: fixture.archive))
    }

    func testTemporaryCopyRefusalStillWinsOverSplitArchive() throws {
        let fixture = try Fixture(.tar, name: "temporary.tar.001")
        let reader = try ArchiveReader.open(url: fixture.archive)
        try Data().write(to: fixture.archive.deletingPathExtension().appendingPathExtension("002"))
        let descriptor = open(fixture.archive.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ExtractionFailure.system(errno) }
        defer { close(descriptor) }
        try ArchiveTemporaryCopy.mark(descriptor: descriptor)
        XCTAssertEqual(ArchiveCapabilities.inspect(url: fixture.archive, format: .tar).refusal, .temporaryCopy)
        XCTAssertEqual(ArchiveCapabilities.inspect(reader: reader, url: fixture.archive).refusal, .temporaryCopy)
    }

    private enum Operation: CaseIterable { case append, remove, createFolder, rename, move, updatePassword }

    private func perform(_ operation: Operation, session: ArchiveSession, source: URL,
                         willPublish: (@Sendable () throws -> Void)? = nil) async throws {
        let entries = await session.entries()
        let entry = try XCTUnwrap(entries.first { $0.name == "file0.txt" })
        let selection = ArchiveEditSelection(path: entry.name, isDirectory: false, entries: [entry])
        switch operation {
        case .append:
            _ = try await session.append(urls: [source], to: "", progress: Progress(), willPublish: willPublish)
        case .remove:
            _ = try await session.edit(removing: [selection], progress: Progress(), willPublish: willPublish)
        case .createFolder:
            _ = try await session.createFolder(in: "", progress: Progress(), willPublish: willPublish)
        case .rename:
            _ = try await session.rename(selection, to: "renamed.txt", progress: Progress(), willPublish: willPublish)
        case .move:
            _ = try await session.move([selection], to: "folder", progress: Progress(), resolveConflict: nil, willPublish: willPublish)
        case .updatePassword:
            _ = try await session.updatePassword(.set, settings: ArchiveEncryptionSettings(password: "secret"),
                                                 progress: Progress(), willPublish: willPublish)
        }
    }

    func testSplitSevenZipSessionRefusesEveryEditWithoutChangingAnyVolume() async throws {
        let fixture = try Fixture(.sevenZip), source = try fixture.source()
        let volumes = try fixture.split(), before = try volumes.map { try Data(contentsOf: $0) }
        let session = try ArchiveSession(url: XCTUnwrap(volumes.first))
        assertSplit(session.capabilities)
        XCTAssertEqual(ArchiveConversionNotice.formatName(for: session), String(localized: "7z"))
        for operation in Operation.allCases {
            do {
                try await perform(operation, session: session, source: source)
                XCTFail("\(operation) must refuse a split archive")
            } catch { assertRefused(error) }
            try assertUnchanged(volumes, bytes: before, in: fixture.directory.url)
        }
        await session.close()
    }

    func testPublishStartRefusesSiblingAddedAfterOpenAndNotifiesObserver() async throws {
        let fixture = try Fixture(.tar, name: "x.tar.001")
        let session = try ArchiveSession(url: fixture.archive)
        XCTAssertEqual(session.capabilities.mode, .rewrite(.tar))
        let sibling = fixture.archive.deletingPathExtension().appendingPathExtension("002")
        try Data("new volume".utf8).write(to: sibling)
        let volumes = [fixture.archive, sibling], before = try volumes.map { try Data(contentsOf: $0) }
        let notified = expectation(description: "split refusal updates the UI")
        session.setCapabilitiesObserver { notified.fulfill() }
        do {
            _ = try await session.createFolder(in: "", progress: Progress(), willOpenUpdater: {
                XCTFail("split refusal must precede opening the updater")
            })
            XCTFail("a sibling appearing after open must prevent publication")
        } catch { assertRefused(error) }
        await fulfillment(of: [notified], timeout: 5)
        assertSplit(session.capabilities)
        try assertUnchanged(volumes, bytes: before, in: fixture.directory.url)
        await session.close()
    }

    func testPublishRechecksImmediatelyBeforeRenameOnEveryEditingPath() async throws {
        // その場更新と書き直しの両方で、作業後に現れた兄弟を原本の置換前に検出する。
        for format in [GyoshukuKit.ArchiveFormat.zip, .sevenZip] {
            for operation in Operation.allCases {
                let fixture = try Fixture(format, name: "late." + ArchiveCreationPlan.filenameExtension(for: format) + ".001")
                let source = try fixture.source(), session = try ArchiveSession(url: fixture.archive)
                XCTAssertTrue(session.capabilities.canEdit)
                let before = try Data(contentsOf: fixture.archive)
                let sibling = fixture.archive.deletingPathExtension().appendingPathExtension("002")
                let siblingBytes = Data("appeared immediately before publication".utf8)
                do {
                    try await perform(operation, session: session, source: source, willPublish: {
                        try siblingBytes.write(to: sibling)
                    })
                    XCTFail("\(operation) must recheck for split siblings")
                } catch { assertRefused(error) }
                assertSplit(session.capabilities)
                try assertUnchanged([fixture.archive, sibling], bytes: [before, siblingBytes], in: fixture.directory.url)
                await session.close()
            }
        }
    }

    func testLoneFirstSevenZipAndTarVolumesRemainEditable() async throws {
        for format in [GyoshukuKit.ArchiveFormat.sevenZip, .tar] {
            let fixture = try Fixture(format, name: "lone." + ArchiveCreationPlan.filenameExtension(for: format) + ".001")
            let source = try fixture.source(), reader = try ArchiveReader.open(url: fixture.archive)
            XCTAssertTrue(ArchiveCapabilities.inspect(url: fixture.archive, format: reader.format).canEdit)
            XCTAssertTrue(ArchiveCapabilities.inspect(reader: reader, url: fixture.archive).canEdit)
            let session = try ArchiveSession(url: fixture.archive)
            let result = try await session.append(urls: [source], to: "", progress: Progress())
            XCTAssertEqual(result.addedPaths, ["added.txt"])
            XCTAssertNil(result.reloadFailure)
            XCTAssertTrue(session.capabilities.canEdit)
            let entries = await session.entries()
            XCTAssertTrue(entries.contains { $0.name == "added.txt" })
            await session.close()
        }
    }

    func testUndoRefusesNewSplitSiblingWithoutSwappingOrConsumingTheSlot() async throws {
        let fixture = try Fixture(.tar, name: "undo.tar.001")
        let session = try ArchiveSession(url: fixture.archive), source = try fixture.source()
        let stack = ArchiveUndoStack(clone: { source, destination in
            do { try FileManager.default.copyItem(at: source, to: destination); return 0 }
            catch { return EIO }
        })
        addTeardownBlock { await stack.dispose(); await session.close() }
        let slot = try XCTUnwrap(stack.capture(fixture.archive))
        stack.recordMutation(slot)
        let original = try Data(contentsOf: slot.url)
        try await perform(.rename, session: session, source: source)
        let sibling = fixture.archive.deletingPathExtension().appendingPathExtension("002")
        try Data("later volume".utf8).write(to: sibling)
        let volumes = [fixture.archive, sibling], before = try volumes.map { try Data(contentsOf: $0) }
        let generation = session.generation
        do {
            try await session.restoreUndoSlot(slot.id, from: stack)
            XCTFail("undo must not replace just one volume")
        } catch { assertRefused(error) }
        assertSplit(session.capabilities)
        XCTAssertEqual(session.generation, generation)
        XCTAssertEqual(stack.slots.map(\.id), [slot.id])
        XCTAssertEqual(try Data(contentsOf: slot.url), original)
        try assertUnchanged(volumes, bytes: before, in: fixture.directory.url)
    }

    func testSplitReasonHasTwentySixTranslationsWithMatchingPunctuation() throws {
        let key = "分割アーカイブは、設定で「保存時にまとめて書き込む」を選ぶと編集できます。"
        let entry = try XCTUnwrap(LocalizationAcceptance.catalog().strings[key])
        XCTAssertEqual(Set(entry.localizations.keys), Set(LocalizationAcceptance.languages))
        XCTAssertEqual(entry.localizations["en"]?.stringUnit.value, "Split archives can be edited by choosing “Together When Saving” in Settings.")
        for language in LocalizationAcceptance.languages {
            let unit = try XCTUnwrap(entry.localizations[language]?.stringUnit)
            XCTAssertEqual(unit.state, "translated", language)
            XCTAssertFalse(unit.value.contains("%"), language)
            let bundle = try LocalizationAcceptance.bundle(language)
            XCTAssertEqual(ArchiveCapabilities(refusal: .splitArchive).readOnlyReason(bundle: bundle), unit.value, language)
            let ending = LocalizationAcceptance.sentenceEnding(language)
            if ending.isEmpty {
                XCTAssertFalse([".", "。", "।"].contains { unit.value.hasSuffix($0) }, language)
            } else {
                XCTAssertTrue(unit.value.hasSuffix(ending), language)
            }
        }
    }
}
