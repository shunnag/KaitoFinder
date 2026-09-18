import CryptoKit
import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class CompressionCapabilityTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("KaitoKit/Tests/Fixtures")
    }

    @MainActor private func assertPreview(_ fixture: String, method: String, digest: String,
                                         password: String? = nil, entryName: String? = nil, archiveName: String? = nil) async throws {
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent(archiveName ?? URL(fileURLWithPath: fixture).lastPathComponent)
        let encoded = try Data(contentsOf: fixtures.appendingPathComponent(fixture + ".b64"))
        try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)).write(to: archive)
        let session = try ArchiveSession(url: archive, password: password)
        let snapshot = await session.snapshot()
        let entry = try XCTUnwrap(snapshot.entries.first { entryName == nil || $0.name == entryName })
        XCTAssertTrue(entry.methodDescription.split(separator: "+").contains(Substring(method)),
                      "Expected \(method) in \(entry.methodDescription)")
        let capability = EntryReadCapability(entry: entry, isDirectory: false, format: session.format)
        XCTAssertTrue(capability.canPreview, capability.reason ?? fixture)
        XCTAssertTrue(capability.canOpen, capability.reason ?? fixture)
        let materializer = EntryMaterializer(session: session,
            temporaryDirectory: ExtractionTemporaryDirectory(root: directory.url.appendingPathComponent("preview")))
        let payload = ArchiveEntryPayload(archiveURL: archive, generation: snapshot.generation,
            entryIndex: entry.index, path: entry.name, isDirectory: false)
        do {
            let url = try await materializer.materialize(payload, progress: Progress(totalUnitCount: 1))
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), digest,
                           "参照ツールで確認済みの fixture の内容を、プレビューと同じ経路で取り出す")
            await materializer.close()
        } catch {
            await materializer.close()
            throw error
        }
        withExtendedLifetime(directory) {}
    }

    @MainActor func testZstandardZIPCanBePreviewedAndOpened() async throws {
        try await assertPreview("zstd/method93.zip", method: "zstd",
            digest: "0284b818713e7c725b754b952234b7b33bc6c77e782fee475778989fb80ae78d")
    }

    @MainActor func testXZZIPCanBePreviewedAndOpened() async throws {
        try await assertPreview("zip-modern/xz.zip", method: "xz",
            digest: "16f3e0211c947966c0e1e379ac87c947174a6b227df976fe95373940be9449b4")
    }

    @MainActor func testLegacyZstandardZIPCanBePreviewedAndOpened() async throws {
        try await assertPreview("zip-modern/zstd20.zip", method: "zstd",
            digest: "16f3e0211c947966c0e1e379ac87c947174a6b227df976fe95373940be9449b4")
    }

    @MainActor func testEncryptedXZAndLegacyZstandardZIPCanBePreviewedAfterUnlocking() async throws {
        for fixture in ["xz-aes.zip", "xz-zipcrypto.zip", "zstd-aes20.zip"] {
            try await assertPreview("zip-modern/" + fixture,
                method: fixture.hasPrefix("xz") ? "xz" : "zstd",
                digest: "16f3e0211c947966c0e1e379ac87c947174a6b227df976fe95373940be9449b4",
                password: "KaitoFixture")
        }
    }

    @MainActor func testModernZIPDocumentBatchEditsAndUndoPreserveArchiveBytes() async throws {
        for fixture in ["xz.zip", "xz-aes.zip", "xz-zipcrypto.zip", "zstd20.zip", "zstd-aes20.zip"] {
            let directory = try ArchiveTestDirectory()
            let archive = directory.url.appendingPathComponent(fixture)
            let encoded = try Data(contentsOf: fixtures.appendingPathComponent("zip-modern/" + fixture + ".b64"))
            try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)).write(to: archive)
            let document = ArchiveDocument(undoStack: ArchiveUndoStack())
            try document.read(from: archive, ofType: "archive")
            addTeardownBlock { @MainActor in
                document.close()
                await document.undoCleanup?.value
                await document.materializationCleanup?.value
                await document.sessionCleanup?.value
                withExtendedLifetime(directory) {}
            }
            let session = try XCTUnwrap(document.session)
            session.setPasswordPrompt { _ in "KaitoFixture" }
            _ = try await session.preparedPassword()
            XCTAssertEqual(session.capabilities.mode, .inPlace)
            var states = [try Data(contentsOf: archive)]
            let first = directory.url.appendingPathComponent("first.txt")
            let second = directory.url.appendingPathComponent("second.txt")
            try Data("first".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            let added = try await document.append(urls: [first, second], to: "", progress: Progress())
            XCTAssertEqual(Set(added.addedPaths), ["first.txt", "second.txt"])
            XCTAssertTrue(added.failures.isEmpty)
            XCTAssertNil(added.reloadFailure)
            states.append(try Data(contentsOf: archive))

            let root = EntryNode.tree(from: await session.entries())
            let original = try XCTUnwrap(root.children.first { $0.path == "payload.txt" })
            let renamed = try await document.rename(original, to: "改名.txt", progress: Progress())
            XCTAssertEqual(renamed.renamedPaths, ["改名.txt"])
            XCTAssertNil(renamed.reloadFailure)
            states.append(try Data(contentsOf: archive))

            let current = EntryNode.tree(from: await session.entries())
            let secondNode = try XCTUnwrap(current.children.first { $0.path == "second.txt" })
            let removed = try await document.remove([secondNode], progress: Progress())
            XCTAssertEqual(removed.removedPaths, ["second.txt"])
            XCTAssertNil(removed.reloadFailure)
            let edited = try Data(contentsOf: archive)
            let reader = try ArchiveReader.open(url: archive, options: ReaderOptions(password: "KaitoFixture"))
            XCTAssertEqual(Set(reader.entries.map(\.name)), ["改名.txt", "first.txt"])
            let entry = try XCTUnwrap(reader.entries.first { $0.name == "改名.txt" })
            XCTAssertEqual(entry.methodDescription, fixture.hasPrefix("xz") ? "xz" : "zstd")
            XCTAssertEqual(SHA256.hash(data: try reader.read(entry)).map { String(format: "%02x", $0) }.joined(),
                "16f3e0211c947966c0e1e379ac87c947174a6b227df976fe95373940be9449b4")

            let manager = try XCTUnwrap(document.undoManager)
            for bytes in states.reversed() {
                XCTAssertTrue(manager.canUndo)
                manager.undo()
                await document.undoTask?.value
                XCTAssertNil(document.undoFailure)
                XCTAssertEqual(try Data(contentsOf: archive), bytes, fixture)
            }
            XCTAssertFalse(manager.canUndo)
            for _ in states {
                XCTAssertTrue(manager.canRedo)
                manager.redo()
                await document.undoTask?.value
                XCTAssertNil(document.undoFailure)
            }
            XCTAssertEqual(try Data(contentsOf: archive), edited, fixture)
        }
    }

    @MainActor func testPPMdZIPCanBePreviewedAndOpened() async throws {
        try await assertPreview("zip-ppmd/text-o8-default.zip", method: "ppmd",
            digest: "2ff68d77335ddd5b329c258fd9d49904a79e473515f7b115b2103b395bc64fde")
    }

    @MainActor func testSwapFilteredSolidSevenZipCanBePreviewedAndOpened() async throws {
        for width in [2, 4] {
            for protection in ["plain", "aes"] {
                for (name, digest) in [
                    ("first.bin", "a078b4e0753e13ab07561237b0d9507f9446982a7ae013b8285a713d26bb29d9"),
                    ("second.bin", "318e252cf75fc244620e81039294bf77f79a5b5c24edcc51fa8dc9b9bed6a311")
                ] {
                    try await assertPreview("sevenzip-swap/swap\(width)-\(protection).7z", method: "Swap\(width)",
                                            digest: digest, password: "KaitoFixture", entryName: name)
                }
            }
        }
    }

    @MainActor func testSwapFilteredSevenZipBatchAppendAndUndoPreserveContentsAndEncryption() async throws {
        for width in [2, 4] {
            for protection in ["plain", "aes"] {
                let directory = try ArchiveTestDirectory()
                let fixture = "swap\(width)-\(protection).7z"
                let archive = directory.url.appendingPathComponent(fixture)
                let encoded = try Data(contentsOf: fixtures.appendingPathComponent("sevenzip-swap/" + fixture + ".b64"))
                let original = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
                try original.write(to: archive)
                let document = ArchiveDocument(undoStack: ArchiveUndoStack())
                try document.read(from: archive, ofType: "archive")
                addTeardownBlock { @MainActor in
                    document.close()
                    await document.undoCleanup?.value
                    await document.materializationCleanup?.value
                    await document.sessionCleanup?.value
                    withExtendedLifetime(directory) {}
                }
                XCTAssertEqual(document.isPasswordLocked, protection == "aes")
                if document.isPasswordLocked { try await document.unlock(password: "KaitoFixture") }
                let session = try XCTUnwrap(document.session)
                session.setPasswordPrompt { _ in "KaitoFixture" }
                _ = try await session.preparedPassword()
                XCTAssertEqual(session.capabilities.mode, .rewrite(.sevenZip))
                let additions = ["added-a.txt", "added-b.txt"].map { directory.url.appendingPathComponent($0) }
                for url in additions { try Data(url.lastPathComponent.utf8).write(to: url) }
                let result = try await document.append(urls: additions, to: "", progress: Progress())
                XCTAssertEqual(Set(result.addedPaths), Set(additions.map(\.lastPathComponent)))
                XCTAssertTrue(result.failures.isEmpty)
                XCTAssertNil(result.reloadFailure)
                let edited = try Data(contentsOf: archive)
                let reader = try ArchiveReader.open(url: archive, options: ReaderOptions(password: "KaitoFixture"))
                XCTAssertEqual(Set(reader.entries.map(\.name)), ["first.bin", "second.bin", "empty", "added-a.txt", "added-b.txt"])
                for (name, digest) in [
                    ("first.bin", "a078b4e0753e13ab07561237b0d9507f9446982a7ae013b8285a713d26bb29d9"),
                    ("second.bin", "318e252cf75fc244620e81039294bf77f79a5b5c24edcc51fa8dc9b9bed6a311")
                ] {
                    let entry = try XCTUnwrap(reader.entries.first { $0.name == name })
                    XCTAssertEqual(entry.isEncrypted, protection == "aes")
                    XCTAssertEqual(SHA256.hash(data: try reader.read(entry)).map { String(format: "%02x", $0) }.joined(), digest)
                }
                for url in additions {
                    let entry = try XCTUnwrap(reader.entries.first { $0.name == url.lastPathComponent })
                    XCTAssertEqual(entry.isEncrypted, protection == "aes")
                    XCTAssertEqual(try reader.read(entry), Data(url.lastPathComponent.utf8))
                }
                let manager = try XCTUnwrap(document.undoManager)
                XCTAssertTrue(manager.canUndo)
                manager.undo()
                await document.undoTask?.value
                XCTAssertNil(document.undoFailure)
                XCTAssertEqual(try Data(contentsOf: archive), original)
                XCTAssertFalse(manager.canUndo, "A multi-file drop creates one undo operation")
                manager.redo()
                await document.undoTask?.value
                XCTAssertNil(document.undoFailure)
                XCTAssertEqual(try Data(contentsOf: archive), edited)
                _ = try directory.run("/opt/homebrew/bin/7zz", ["t", "-bd", "-pKaitoFixture", archive.path])
            }
        }
    }

    @MainActor func testLZ4SingleFileAndCompressedTarCanBePreviewedAndOpened() async throws {
        try await assertPreview("lz4-frame/tiny.lz4", method: "LZ4",
            digest: "e28a99eda349e29dde69fe63be0ce3fa1c3d0d14591e289ea4d5fa18d7808108")
        let digest = SHA256.hash(data: Data("LZ4 frame fixture\n".utf8)).map { String(format: "%02x", $0) }.joined()
        try await assertPreview("lz4-frame/tar-linked.lz4", method: "tar (stored)", digest: digest,
            entryName: "note.txt", archiveName: "bundle.tar.lz4")
    }

    @MainActor func testLegacyLZ4SingleFileAndCompressedTarCanBePreviewedAndOpened() async throws {
        try await assertPreview("lz4-frame/legacy-tiny.lz4", method: "LZ4",
            digest: "e28a99eda349e29dde69fe63be0ce3fa1c3d0d14591e289ea4d5fa18d7808108")
        let digest = SHA256.hash(data: Data("LZ4 frame fixture\n".utf8)).map { String(format: "%02x", $0) }.joined()
        try await assertPreview("lz4-frame/legacy-tar.lz4", method: "tar (stored)", digest: digest,
            entryName: "note.txt", archiveName: "legacy.tar.lz4")
    }

    func testLZ4TarWithLeadingSkippableFrameRemainsReadOnlyAndConvertsItsWholeSuffix() throws {
        for fixture in ["tar-linked", "legacy-tar"] {
            try assertLZ4TarReadOnly(fixture)
        }
    }

    private func assertLZ4TarReadOnly(_ fixture: String) throws {
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent("archive.TAR.LZ4")
        let encoded = try Data(contentsOf: fixtures.appendingPathComponent("lz4-frame/" + fixture + ".lz4.b64"))
        let bytes = Data([0x50, 0x2a, 0x4d, 0x18, 0, 0, 0, 0])
            + (try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)))
        try bytes.write(to: archive)
        XCTAssertEqual(try ArchiveReader.open(url: archive).format, .tar)
        let capability = ArchiveCapabilities.inspect(url: archive, format: .tar)
        XCTAssertEqual(capability.refusal, .format("tar.lz4"))
        XCTAssertNil(capability.mode)
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertEqual(ArchiveCreationPlan.conversionName(for: archive, format: .zip), "archive.zip")
    }

    @MainActor func testLZXCabinetCanBePreviewedAndOpened() async throws {
        try await assertPreview("cab-lzx/repeated-offsets.cab", method: "cab (LZX)",
            digest: "d0dd5cef8544d91daf6d6c95eef8f291822e0b6c91050bedca706e72977d1023")
    }

    func testZstandardTarWithLeadingSkippableFrameCannotBeRewrittenAsPlainTar() throws {
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent("archive.tar.zst")
        let encoded = try Data(contentsOf: fixtures.appendingPathComponent("zstd/bundle.tar.zst.b64"))
        // RFC 8878: empty skippable frame followed by the ordinary frame.
        let bytes = Data([0x50, 0x2a, 0x4d, 0x18, 0, 0, 0, 0])
            + (try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)))
        try bytes.write(to: archive)
        XCTAssertEqual(try ArchiveReader.open(url: archive).format, .tar)
        let capability = ArchiveCapabilities.inspect(url: archive, format: .tar)
        XCTAssertEqual(capability.refusal, .format("tar.zst"))
        XCTAssertNil(capability.mode)
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
    }

    func testLZMATarWithNondefaultPropertiesCannotBeRewrittenAsPlainTar() throws {
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent("archive.tar.lzma")
        try directory.run("/usr/bin/python3", ["-c", """
        import io, lzma, sys, tarfile
        tar = io.BytesIO()
        with tarfile.open(fileobj=tar, mode='w') as writer:
            entry = tarfile.TarInfo('file.txt'); entry.size = 7
            writer.addfile(entry, io.BytesIO(b'payload'))
        filters = [{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 20, 'lc': 4, 'lp': 0, 'pb': 2}]
        open(sys.argv[1], 'wb').write(lzma.compress(tar.getvalue(), format=lzma.FORMAT_ALONE, filters=filters))
        """, archive.path])
        let bytes = try Data(contentsOf: archive)
        XCTAssertNotEqual(bytes.first, 0x5d)
        XCTAssertEqual(try ArchiveReader.open(url: archive).format, .tar)
        let capability = ArchiveCapabilities.inspect(url: archive, format: .tar)
        XCTAssertEqual(capability.refusal, .format("tar.lzma"))
        XCTAssertNil(capability.mode)
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
    }

    func testPlainTarMemberNameDoesNotMasqueradeAsBzip2Header() throws {
        let fixture = try ScenarioFixture(script: """
        with tarfile.open(p, 'w') as writer:
            entry = tarfile.TarInfo('BZh9-report.txt'); entry.size = 7
            writer.addfile(entry, io.BytesIO(b'payload'))
        """, suffix: "tar")
        XCTAssertEqual(try ArchiveReader.open(url: fixture.archive).format, .tar)
        XCTAssertEqual(ArchiveCapabilities.inspect(url: fixture.archive, format: .tar).mode, .rewrite(.tar))
    }
}
