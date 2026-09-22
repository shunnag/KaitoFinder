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

    private func fixtureData(_ fixture: String) throws -> Data {
        let encoded = try Data(contentsOf: fixtures.appendingPathComponent(fixture + ".b64"))
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
        // 大きなイメージは KaitoKit 側の規約どおり gzip + base64 で収録されている。
        guard fixture.hasSuffix(".gz") else { return bytes }
        let gzip = try ArchiveReader.open(data: bytes, options: .kaitoFinder())
        XCTAssertEqual(gzip.format, .gzip)
        return try gzip.read(XCTUnwrap(gzip.entries.first))
    }

    @MainActor private func assertPreview(_ fixture: String, method: String, digest: String,
                                         password: String? = nil, entryName: String? = nil, archiveName: String? = nil,
                                         format: ArchiveFormat? = nil) async throws {
        let directory = try ArchiveTestDirectory()
        let fixtureURL = URL(fileURLWithPath: fixture)
        let name = fixture.hasSuffix(".gz") ? fixtureURL.deletingPathExtension().lastPathComponent : fixtureURL.lastPathComponent
        let archive = directory.url.appendingPathComponent(archiveName ?? name)
        try fixtureData(fixture).write(to: archive)
        let session = try ArchiveSession(url: archive, password: password)
        if let format { XCTAssertEqual(session.format, format, fixture) }
        let snapshot = await session.snapshot()
        let entry = try XCTUnwrap(snapshot.entries.first { entryName == nil || $0.name == entryName })
        XCTAssertTrue(entry.methodDescription == method || entry.methodDescription.split(separator: "+").contains(Substring(method)),
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

    // 新形式の期待 SHA-256 は各 fixture ディレクトリの manifest.json に記録された原文の値。
    @MainActor func testDMGCanBePreviewedAndOpened() async throws {
        try await assertPreview("dmg/hfs-zlib.dmg.gz", method: "HFS+ (stored)",
            digest: "c6ced9f772ab08b591a1d3a1057bf4fd267ab64b1536d170f61722afb16677de",
            entryName: "readme.txt", format: .dmg)
    }

    @MainActor func testUDFCanBePreviewedAndOpened() async throws {
        try await assertPreview("udf/pure150.iso.gz", method: "UDF (stored)",
            digest: "efe110a6cc29d1711091a93ff160466004e53f7a835209094e1131983276f25e",
            entryName: "readme.txt", format: .udf)
    }

    @MainActor func testWIMCanBePreviewedAndOpened() async throws {
        try await assertPreview("wim/xpress.wim", method: "WIM XPRESS",
            digest: "7c6166813b80b8a0c8aafd5e02490ce4629e5d54c145f55999fe75367b755b67",
            entryName: "text.txt", format: .wim)
    }

    @MainActor func testCompoundFileCanBePreviewedAndOpened() async throws {
        try await assertPreview("cfb/v3.cfb.gz", method: "stored",
            digest: "47c2c0b99b7e5fd62dbf785e2fb8355ef4e9f1c332dcdb02f410efe459ea5ff9",
            entryName: "small.txt", format: .compoundFile)
    }

    @MainActor func testCHMCanBePreviewedAndOpened() async throws {
        try await assertPreview("chm/basic.chm.gz", method: "LZX",
            digest: "c7cd97f68797d2214ddb7985a4c5d301f416084675db287770eed28548f21a06",
            entryName: "index.htm", format: .chm)
    }

    @MainActor func testARJCanBePreviewedAndOpened() async throws {
        try await assertPreview("arj/basic.arj", method: "compressed most",
            digest: "8d1126c536d13946d9fd277a295e1fe7ff3941edb04f94b99c2b3fb5999a029a",
            entryName: "README.TXT", format: .arj)
    }

    @MainActor func testARJNoDataEntryRemainsReadable() async throws {
        try await assertPreview("arj/nodata.arj", method: "no data",
            digest: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            entryName: "NODATA.TXT", format: .arj)
    }

    @MainActor func testMacBinaryCanBePreviewedAndOpened() async throws {
        try await assertPreview("macwrappers/readme.txt.bin", method: "MacBinary (stored)",
            digest: "483eebef2b901614fc93bfe3e6fc37940531f239e82da48b01cc22d099c95b82",
            entryName: "readme.txt", format: .macBinary)
    }

    @MainActor func testAppleSingleCanBePreviewedAndOpened() async throws {
        try await assertPreview("macwrappers/readme.txt.as", method: "AppleSingle (stored)",
            digest: "483eebef2b901614fc93bfe3e6fc37940531f239e82da48b01cc22d099c95b82",
            entryName: "readme.txt", format: .appleSingle)
    }

    @MainActor func testBinHexCanBePreviewedAndOpened() async throws {
        try await assertPreview("macwrappers/readme.txt.hqx", method: "BinHex 4.0 (RLE90)",
            digest: "483eebef2b901614fc93bfe3e6fc37940531f239e82da48b01cc22d099c95b82",
            entryName: "readme.txt", format: .binHex)
    }

    @MainActor func testLzipCanBePreviewedAndOpened() async throws {
        try await assertPreview("lzip/text.lz", method: "LZMA (lzip)",
            digest: "2328a6109a2eb7c2fdbd3fbb3bd400825b7658776e398b50851ce5e99ace96cd",
            format: .lzip)
    }

    @MainActor func testBrotliCanBePreviewedAndOpened() async throws {
        try await assertPreview("brotli/text-q1.br", method: "Brotli",
            digest: "3f4ba7886f4fa4c399481673e0b68d053664e54187bacde11120180d757923fc",
            format: .brotli)
    }

    @MainActor func testPbzxCanBePreviewedAndOpened() async throws {
        try await assertPreview("pbzx/text.pbzx", method: "XZ (pbzx)",
            digest: "8e8a292e72021881fda5869caf746eadd14ed2254b20fac34fbef5ae043dbbfd",
            format: .pbzx)
    }

    @MainActor func testLegacyZIPMethodsCanBePreviewedAndOpened() async throws {
        for (fixture, method) in [
            ("shrink.zip", "shrink"), ("reduce1.zip", "reduce1"), ("reduce2.zip", "reduce2"),
            ("reduce3.zip", "reduce3"), ("reduce4.zip", "reduce4"),
            ("implode-4k-2trees.zip", "implode"), ("implode-4k-3trees.zip", "implode"),
            ("implode-8k-2trees.zip", "implode"), ("implode-8k-3trees.zip", "implode")
        ] {
            try await assertPreview("zip-legacy/" + fixture, method: method,
                digest: "5a3bb49b57d40193fbe5ad5869b029c01f2bdfe046f8a4368438178b923f1c10",
                entryName: "text.txt", format: .zip)
        }
    }

    @MainActor func testZstandardSevenZipCanBePreviewedAndOpened() async throws {
        for level in [1, 19] {
            for (entry, digest) in [
                ("first.bin", "a078b4e0753e13ab07561237b0d9507f9446982a7ae013b8285a713d26bb29d9"),
                ("second.bin", "318e252cf75fc244620e81039294bf77f79a5b5c24edcc51fa8dc9b9bed6a311")
            ] {
                try await assertPreview("sevenzip-zstd/zstd-l\(level).7z", method: "Zstandard",
                    digest: digest, entryName: entry, format: .sevenZip)
            }
        }
    }

    @MainActor func testLzipAndBrotliTarCanBePreviewedButRemainReadOnly() async throws {
        for (fixture, suffix, digest) in [
            ("lzip/bundle.tar.lz", "tar.lz", "04485277f59bc95822b5b056ed79d194907df73273c3337fc621e3531f668ba7"),
            // Brotli の tar 内の値は、既存 debug kaito の sha でも照合した。
            ("brotli/bundle.tar.br", "tar.br", "5f48ac112b3f166a6a6e1a51871cee0d69cc97854f5a5d831be57bc2885c80a1")
        ] {
            try await assertPreview(fixture, method: "tar (stored)", digest: digest,
                                    entryName: "a.txt", format: .tar)
            let directory = try ArchiveTestDirectory()
            let archive = directory.url.appendingPathComponent("bundle." + suffix)
            let original = try fixtureData(fixture)
            try original.write(to: archive)
            let reader = try ArchiveReader.open(url: archive, options: .kaitoFinder())
            XCTAssertEqual(reader.format, .tar)
            let capability = ArchiveCapabilities.inspect(reader: reader, url: archive)
            XCTAssertNil(capability.mode)
            XCTAssertEqual(capability.refusal, .format(suffix))
            XCTAssertEqual(try Data(contentsOf: archive), original)
        }
    }

    @MainActor func testFinderZIPExposesSidecarsAndDeletesOnlyTheSelectedEntry() async throws {
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent("finder.zip")
        try fixtureData("appledouble/finder.zip").write(to: archive)
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
        let entries = await session.entries()
        let reader = try ArchiveReader.open(url: archive, options: .kaitoFinder())
        let exposed = try ArchiveReader.open(url: archive, options: ReaderOptions(appleDoublePolicy: .expose))
        XCTAssertEqual(entries, exposed.entries, "表示と編集に渡す一覧・index を一致させる")
        XCTAssertTrue(entries.contains { $0.name == "__MACOSX/folder/._rsrc.txt" })
        XCTAssertFalse(entries.contains { $0.name.contains("..namedfork") })
        let capabilities = ArchiveCapabilities.inspect(reader: reader, url: archive)
        XCTAssertEqual(capabilities.mode, .inPlace)
        XCTAssertNil(capabilities.refusal)
        XCTAssertEqual(session.capabilities.mode, .inPlace)
        XCTAssertNil(session.capabilities.refusal)
        let originalContents = try Dictionary(uniqueKeysWithValues: exposed.entries.filter { $0.kind == .file }.map {
            ($0.name, try exposed.read($0))
        })
        let root = EntryNode.tree(from: entries)
        let folder = try XCTUnwrap(root.children.first { $0.path == "folder" })
        let selected = try XCTUnwrap(folder.children.first { $0.path == "folder/plain.txt" })
        let result = try await document.remove([selected], progress: Progress())
        XCTAssertEqual(result.removedPaths, ["folder/plain.txt"])
        XCTAssertNil(result.reloadFailure)
        // remove は編集を原本へ保存する。別の .expose reader で保存後の全項目と内容を照合する。
        let saved = try ArchiveReader.open(url: archive, options: ReaderOptions(appleDoublePolicy: .expose))
        XCTAssertEqual(saved.entries.map(\.name), entries.filter { $0.name != "folder/plain.txt" }.map(\.name))
        XCTAssertTrue(saved.entries.contains { $0.name == "__MACOSX/folder/._rsrc.txt" })
        XCTAssertFalse(saved.entries.contains { $0.name.contains("..namedfork") })
        for entry in saved.entries where entry.kind == .file {
            XCTAssertEqual(try saved.read(entry), originalContents[entry.name], entry.name)
        }
    }

    /// 収録 fixture の指定フィールドだけを変え、reader が公開する実際の一覧で判定する。
    private func mutatedFixture(_ fixture: String, script: String) throws -> Data {
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent("fixture")
        try fixtureData(fixture).write(to: archive)
        try directory.run("/usr/bin/python3", ["-c", """
        import sys, struct, zlib, binascii
        p = sys.argv[1]
        d = bytearray(open(p, 'rb').read())
        \(script)
        open(p, 'wb').write(d)
        """, archive.path])
        return try Data(contentsOf: archive)
    }

    @discardableResult private func assertListedButUnreadable(_ bytes: Data, format: ArchiveFormat,
                                                               entryName: String, reason: String) throws -> ArchiveEntry {
        let reader = try ArchiveReader.open(data: bytes, options: .kaitoFinder())
        XCTAssertEqual(reader.format, format)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == entryName })
        XCTAssertEqual(entry.kind, .file)
        XCTAssertFalse(entry.isIncomplete)
        let capability = EntryReadCapability(entry: entry, isDirectory: false, format: reader.format)
        XCTAssertEqual(capability.refusal, .unsupportedMethod(entry.methodDescription))
        XCTAssertFalse(capability.canPreview)
        XCTAssertFalse(capability.canOpen)
        XCTAssertFalse(capability.needsUnlocking)
        if format == .iso || format == .udf {
            // DMGReader は inner.entries をそのまま公開する。同じ実 entry で委譲時の拒否も検査する。
            let inDiskImage = EntryReadCapability(entry: entry, isDirectory: false, format: .dmg)
            XCTAssertEqual(inDiskImage.refusal, capability.refusal)
            XCTAssertFalse(inDiskImage.canPreview)
            XCTAssertFalse(inDiskImage.canOpen)
        }
        // 能力判定そのものは stream を開かず、その後にエンジンの拒否理由との一致を検査する。
        XCTAssertThrowsError(try reader.read(entry)) {
            guard case .unsupportedMethod(let message) = $0 as? KaitoError else {
                return XCTFail("未対応方式として拒否されませんでした: \($0)")
            }
            XCTAssertTrue(message.contains(reason), message)
        }
        return entry
    }

    func testARJGarbledMethod4AndVolumeContinuationsCannotBePreviewed() throws {
        let garbled = try assertListedButUnreadable(fixtureData("arj/garbled.arj"), format: .arj,
                                                    entryName: "README.TXT", reason: "garbled")
        XCTAssertTrue(garbled.isEncrypted)
        for (mutation, reason, key) in [
            ("header[5] = 4", "method 4", ""),
            ("header[4] |= 0x04", "multi-volume", "continuesInNextVolume"),
            ("header[4] |= 0x08\nheader[0] = 34\nheader[30:30] = struct.pack('<I', 123)", "multi-volume", "extendedFilePosition")
        ] {
            let bytes = try mutatedFixture("arj/basic.arj", script: """
            start = d.index(b'README.TXT\\x00') - 30
            size = struct.unpack_from('<H', d, start - 2)[0]
            header = d[start:start + size]
            \(mutation)
            struct.pack_into('<H', d, start - 2, len(header))
            d[start:start + size + 4] = header + struct.pack('<I', zlib.crc32(header))
            """)
            let entry = try assertListedButUnreadable(bytes, format: .arj, entryName: "README.TXT", reason: reason)
            if key.isEmpty { XCTAssertEqual(entry.methodDescription, "compressed fastest") }
            else { XCTAssertNotNil(entry.formatSpecific[key]) }
        }
    }

    func testWIMUnavailableResourcesAndEFSFilesCannotBePreviewed() throws {
        for (mutation, reason) in [
            ("struct.pack_into('<H', d, resource + 24, 2)", "resource in part 2"),
            ("d[resource + 30] ^= 0xff", "resource missing"),
            ("struct.pack_into('<I', d, entry + 8, struct.unpack_from('<I', d, entry + 8)[0] | 0x4000)", "EFS")
        ] {
            let bytes = try mutatedFixture("wim/stored.wim", script: """
            table = struct.unpack_from('<Q', d, 56)[0]
            size = int.from_bytes(d[48:55], 'little')
            metadata = next(i for i in range(table, table + size, 50) if d[i + 7] & 2)
            metadata_start = struct.unpack_from('<Q', d, metadata + 8)[0]
            entry = d.index('readme.txt'.encode('utf-16le'), metadata_start) - 102
            digest = d[entry + 64:entry + 84]
            resource = next(i for i in range(table, table + size, 50) if d[i + 30:i + 50] == digest)
            \(mutation)
            """)
            let entry = try assertListedButUnreadable(bytes, format: .wim, entryName: "readme.txt", reason: reason)
            XCTAssertNotNil(entry.formatSpecific["unsupported"])
        }
    }

    func testDMGDecmpfsFileCannotBePreviewed() throws {
        let entry = try assertListedButUnreadable(fixtureData("dmg/hfs-zlib.dmg.gz"), format: .dmg,
                                                  entryName: "compressed.txt", reason: "decmpfs")
        XCTAssertEqual(entry.formatSpecific["hfsCompressed"], "true")
        XCTAssertEqual(entry.methodDescription, "HFS+ compressed (decmpfs)")
    }

    func testCHMUnknownSectionCannotBePreviewed() throws {
        // KaitoKit の CHMReaderTests と同じく LZXC の署名だけを変える。
        let bytes = try mutatedFixture("chm/basic.chm.gz", script: """
        control = d.index(b'LZXC')
        d[control] = ord('Q')
        """)
        let entry = try assertListedButUnreadable(bytes, format: .chm, entryName: "index.htm", reason: "section compression")
        XCTAssertEqual(entry.methodDescription, "unknown")
        let reader = try ArchiveReader.open(data: bytes, options: .kaitoFinder())
        let system = try XCTUnwrap(reader.entries.first { $0.name == "#SYSTEM" })
        XCTAssertTrue(EntryReadCapability(entry: system, isDirectory: false, format: .chm).canPreview)
        XCTAssertEqual(try reader.read(system).count, 68)
    }

    func testISOZisofs2AndMultiExtentCannotBePreviewed() throws {
        for (mutation, reason) in [
            ("d[zf + 3] = 2", "zisofs"),
            // 同じ directory record を二つの extent として並べる。metadata の範囲内で完結させる。
            ("record = d[start:start + length]\nrecord[25] |= 0x80\nend = (start // 2048 + 1) * 2048\nassert d[end - length:end] == bytes(length)\nd[start + length:end] = d[start:end - length]\nd[start:start + length] = record", "zisofs multi-extent")
        ] {
            let bytes = try mutatedFixture("iso/zisofs-32k.iso.gz", script: """
            pvd = 16 * 2048
            sector = struct.unpack_from('<I', d, pvd + 156 + 2)[0]
            start = sector * 2048
            while True:
                length = d[start]
                assert length > 0
                name = bytes(d[start + 33:start + 33 + d[start + 32]])
                if name == b'TEXT.TXT;1': break
                start += length
            zf = d.index(b'ZF\\x10\\x01pz', start, start + length)
            \(mutation)
            """)
            let entry = try assertListedButUnreadable(bytes, format: .iso, entryName: "text.txt", reason: reason)
            XCTAssertEqual(entry.formatSpecific["unsupported"], reason)
        }
    }

    @MainActor func testISOZisofsRemainsPreviewable() async throws {
        // ISOZisofsTests の原文 SHA-256。未対応 ZF と通常の zisofs を区別する。
        try await assertPreview("iso/zisofs-32k.iso.gz", method: "zisofs (zlib)",
            digest: "fdc944406443a962675237d2789e0a9a879f7832692c608bb763c8e3f0333a57",
            entryName: "text.txt", format: .iso)
    }

    func testZIPTokenizeRemainsUnsupported() throws {
        let bytes = try mutatedFixture("zip-legacy/shrink.zip", script: """
        import io, zipfile
        archive = zipfile.ZipFile(io.BytesIO(d))
        central = archive.start_dir
        for entry in archive.infolist():
            struct.pack_into('<H', d, entry.header_offset + 8, 7)
            struct.pack_into('<H', d, central + 10, 7)
            central += 46 + sum(struct.unpack_from('<HHH', d, central + 28))
        """)
        let entry = try assertListedButUnreadable(bytes, format: .zip, entryName: "text.txt", reason: "7")
        XCTAssertEqual(entry.methodDescription, "method 7")
    }

    func testUDFExtendedAllocationCannotBePreviewed() throws {
        let bytes = try mutatedFixture("udf/pure150.iso.gz", script: """
        # ECMA-167 の FE: file type 5、情報長 2880 の readme.txt を探す。
        matches = [i for i in range(0, len(d), 2048)
                   if d[i:i + 2] == b'\\x05\\x01' and d[i + 27] == 5
                   and struct.unpack_from('<Q', d, i + 56)[0] == 2880]
        assert len(matches) == 1
        entry = matches[0]
        d[entry + 34] = (d[entry + 34] & ~7) | 2
        length = struct.unpack_from('<H', d, entry + 10)[0]
        struct.pack_into('<H', d, entry + 8, binascii.crc_hqx(d[entry + 16:entry + 16 + length], 0))
        d[entry + 4] = sum(d[entry + i] for i in range(16) if i != 4) & 255
        """)
        let entry = try assertListedButUnreadable(bytes, format: .udf, entryName: "readme.txt", reason: "extended allocation")
        XCTAssertEqual(entry.formatSpecific["unsupported"], "UDF extended allocation descriptors")
    }

    func testWIMSolidAndDMGADCFailBeforePublishingAListing() throws {
        let solid = try mutatedFixture("wim/stored.wim", script: "struct.pack_into('<I', d, 12, 0x0e00)")
        let lzms = try mutatedFixture("wim/stored.wim", script:
            "struct.pack_into('<I', d, 16, struct.unpack_from('<I', d, 16)[0] | 0x80000)")
        for (bytes, reason) in [(solid, "LZMS"), (lzms, "LZMS"), (try fixtureData("dmg/hfs-adc.dmg.gz"), "ADC")] {
            XCTAssertThrowsError(try ArchiveReader.open(data: bytes, options: .kaitoFinder())) {
                guard case .unsupportedMethod(let message) = $0 as? KaitoError else {
                    return XCTFail("一覧前の拒否が得られませんでした: \($0)")
                }
                XCTAssertTrue(message.contains(reason), message)
            }
        }
    }

    func testOldGNUAndStarSparseTarFailBeforePublishingAListing() throws {
        for sparse in ["gnu", "star"] {
            let fixture = try ScenarioFixture(script: """
            with tarfile.open(p, 'w', format=tarfile.PAX_FORMAT) as writer:
                entry = tarfile.TarInfo('sparse.bin')
                if '\(sparse)' == 'gnu': entry.type = b'S'
                else: entry.pax_headers = {'SCHILY.filetype': 'sparse', 'SCHILY.realsize': '4096'}
                writer.addfile(entry)
            """, suffix: "tar")
            XCTAssertThrowsError(try ArchiveReader.open(url: fixture.archive, options: .kaitoFinder())) {
                guard case .unsupportedMethod(let reason) = $0 as? KaitoError else {
                    return XCTFail("一覧前の拒否が得られませんでした: \($0)")
                }
                XCTAssertTrue(reason.contains("sparse"), reason)
            }
        }
    }
}
