import AppKit
import CryptoKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveRewriteTests: XCTestCase {
    private enum Format: CaseIterable {
        case tar, tgz, tbz2, txz, sevenZip, lha

        var suffix: String {
            switch self {
            case .tar: "tar"
            case .tgz: "tgz"
            case .tbz2: "tbz2"
            case .txz: "txz"
            case .sevenZip: "7z"
            case .lha: "lzh"
            }
        }

        var output: GyoshukuKit.ArchiveFormat {
            switch self {
            case .tar: .tar
            case .tgz: .tarGzip
            case .tbz2: .tarBzip2
            case .txz: .tarXZ
            case .sevenZip: .sevenZip
            case .lha: .lha
            }
        }

        var input: KaitoKit.ArchiveFormat {
            switch self {
            case .tar, .tgz, .tbz2, .txz: .tar
            case .sevenZip: .sevenZip
            case .lha: .lha
            }
        }
    }

    private enum ExpectedEntry: Sendable {
        case file(Data)
        case directory
    }

    private final class Fixture {
        let directory: ArchiveTestDirectory
        let archive: URL
        let format: Format
        static let original: [String: ExpectedEntry] = [
            "original.txt": .file(Data("original\0日本語\n".utf8)),
            "existing": .directory,
            "existing/child.bin": .file(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) }))
        ]

        init(_ format: Format, filename: String? = nil) throws {
            directory = try ArchiveTestDirectory()
            self.format = format
            archive = directory.url.appendingPathComponent(filename ?? "archive." + format.suffix)
            let seed = directory.url
            for (name, entry) in Self.original {
                let url = seed.appendingPathComponent(name)
                switch entry {
                case .directory:
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                case .file(let bytes):
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: url)
                }
            }
            switch format {
            case .tar, .tgz:
                let tar = format == .tar ? archive : directory.url.appendingPathComponent("seed.tar")
                try directory.run("/usr/bin/bsdtar", ["--no-mac-metadata", "--no-xattrs", "-cf", tar.path,
                                                       "-C", seed.path, "original.txt", "existing"])
                if format == .tgz {
                    try directory.run("/usr/bin/gzip", ["-n", tar.path])
                    try FileManager.default.moveItem(at: tar.appendingPathExtension("gz"), to: archive)
                }
            case .tbz2, .txz:
                try directory.run("/usr/bin/bsdtar", ["--no-mac-metadata", "--no-xattrs",
                    format == .tbz2 ? "-cjf" : "-cJf", archive.path, "-C", seed.path, "original.txt", "existing"])
            case .sevenZip:
                try directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-t7z", archive.path, "original.txt", "existing"])
            case .lha:
                let writer = try ArchiveWriter.create(url: archive, format: .lha)
                try writer.add(contentsOf: seed.appendingPathComponent("original.txt"), as: "original.txt")
                try writer.add(contentsOf: seed.appendingPathComponent("existing"), as: "existing")
                try writer.finish()
            }
        }

        func file(_ name: String, data: Data = Data("added".utf8)) throws -> URL {
            let url = directory.url.appendingPathComponent("inputs").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            return url
        }
    }

    private func digest(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }

    private func assertNoWorkDirectory(_ directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".KaitoFinder-add-") || $0.hasPrefix(".gyoshuku-rewrite-") },
                       names.description, file: file, line: line)
    }

    private func assertCapability(_ format: Format, file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try Fixture(format)
        let reader = try ArchiveReader.open(url: fixture.archive)
        XCTAssertEqual(reader.format, format.input, file: file, line: line)
        let before = try digest(fixture.archive)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.url.path).sorted()
        let capability = ArchiveCapabilities.inspect(url: fixture.archive, format: reader.format)
        XCTAssertEqual(capability.mode, .rewrite(format.output), file: file, line: line)
        XCTAssertTrue(capability.canEdit, file: file, line: line)
        XCTAssertNil(capability.refusal, file: file, line: line)
        XCTAssertNil(capability.readOnlyReason, file: file, line: line)
        XCTAssertEqual(capability.rewriteNotice, String(localized: "編集するとアーカイブ全体を再圧縮します"), file: file, line: line)
        XCTAssertEqual(try digest(fixture.archive), before, file: file, line: line)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.url.path).sorted(), files,
                       file: file, line: line)
    }

    func testTarCapabilityUsesRewriteMode() throws { try assertCapability(.tar) }
    func testTGZCapabilityUsesTarGzipDespiteKaitoKitReportingTar() throws { try assertCapability(.tgz) }
    func testSevenZipCapabilityUsesRewriteMode() throws { try assertCapability(.sevenZip) }
    func testLHACapabilityUsesRewriteMode() throws { try assertCapability(.lha) }

    func testTarWrapperDetectionUsesMagicInsteadOfExtension() throws {
        for (format, name) in [(Format.tar, "plain.tgz"), (.tgz, "gzip.tar"), (.tgz, "archive.tar.gz")] {
            let fixture = try Fixture(format, filename: name)
            XCTAssertEqual(ArchiveCapabilities.inspect(url: fixture.archive, format: .tar).mode, .rewrite(format.output))
        }
    }

    func testTarBzip2AndXZCapabilitiesEnableTheCorrectWriter() throws {
        for (flag, name, format) in [("-cjf", "tar.bz2", GyoshukuKit.ArchiveFormat.tarBzip2), ("-cJf", "tar.xz", .tarXZ)] {
            let fixture = try Fixture(.tar)
            let archive = fixture.directory.url.appendingPathComponent("wrapped." + name)
            try fixture.directory.run("/usr/bin/bsdtar", ["--no-mac-metadata", "--no-xattrs", flag, archive.path,
                                                          "-C", fixture.directory.url.path,
                                                          "original.txt"])
            let reader = try ArchiveReader.open(url: archive)
            XCTAssertEqual(reader.format, .tar)
            let capability = ArchiveCapabilities.inspect(url: archive, format: reader.format)
            XCTAssertNil(capability.refusal)
            XCTAssertEqual(capability.mode, .rewrite(format))
            XCTAssertTrue(capability.canEdit)
            XCTAssertNotNil(capability.rewriteNotice)
            XCTAssertNil(capability.readOnlyReason)
        }
    }

    func testTruncatedCompressedTarSignaturesCannotEnableEditing() throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("wrapped.tar")
        let cases: [([UInt8], String)] = [
            ([0x1f, 0x9d], "tar.Z"), ([0x28, 0xb5, 0x2f, 0xfd], "tar.zst"), ([0x5d, 0x00, 0x00], "tar.lzma")
        ]
        for (magic, name) in cases {
            try Data(magic).write(to: archive)
            let capability = ArchiveCapabilities.inspect(url: archive, format: .tar)
            XCTAssertFalse(capability.canEdit, name)
            XCTAssertNil(capability.mode)
            XCTAssertNil(capability.rewriteNotice)
        }
    }

    private func zip(in directory: ArchiveTestDirectory, encrypted: Bool = false) throws -> URL {
        let archive = directory.url.appendingPathComponent("archive.zip")
        try Data("secret contents".utf8).write(to: directory.url.appendingPathComponent("secret.txt"))
        try directory.run("/usr/bin/zip", ["-q"] + (encrypted ? ["-P", "rewrite-test-password"] : [])
                          + [archive.path, "secret.txt"])
        return archive
    }

    private func assertZIPCapability(encrypted: Bool) throws {
        let directory = try ArchiveTestDirectory(), archive = try zip(in: directory, encrypted: encrypted)
        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.entries.contains(where: \.isEncrypted), encrypted)
        let capability = ArchiveCapabilities.inspect(url: archive, format: reader.format,
                                                      password: encrypted ? "rewrite-test-password" : nil)
        XCTAssertEqual(capability.mode, .inPlace)
        XCTAssertTrue(capability.canEdit)
        XCTAssertNil(capability.refusal)
        XCTAssertNil(capability.rewriteNotice)
        try assertNoWorkDirectory(directory.url)
    }

    func testZIPCapabilityStaysInPlace() throws { try assertZIPCapability(encrypted: false) }
    func testEncryptedZIPCapabilityStaysInPlace() throws { try assertZIPCapability(encrypted: true) }

    private func encryptedSevenZip(in directory: ArchiveTestDirectory, headers: Bool) throws -> URL {
        let archive = directory.url.appendingPathComponent("encrypted.7z")
        try Data("secret contents".utf8).write(to: directory.url.appendingPathComponent("secret.txt"))
        try directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-prewrite-test-password"]
                          + (headers ? ["-mhe=on"] : []) + [archive.path, "secret.txt"])
        return archive
    }

    private func assertEncryptedSevenZip(headers: Bool) throws {
        let directory = try ArchiveTestDirectory(), archive = try encryptedSevenZip(in: directory, headers: headers)
        let original = try digest(archive)
        let capability = ArchiveCapabilities.inspect(url: archive, format: .sevenZip)
        XCTAssertEqual(capability.refusal, .encrypted)
        XCTAssertNil(capability.mode)
        XCTAssertFalse(capability.canEdit)
        XCTAssertNil(capability.rewriteNotice)
        XCTAssertEqual(capability.readOnlyReason, String(localized: "暗号化されたアーカイブを変更するにはパスワードが必要です。"))
        XCTAssertEqual(try digest(archive), original)
        try assertNoWorkDirectory(directory.url)
    }

    func testEncryptedSevenZipHeadersAreRefused() throws { try assertEncryptedSevenZip(headers: true) }
    func testEncryptedSevenZipPayloadIsRefused() throws { try assertEncryptedSevenZip(headers: false) }

    @MainActor func testEncryptedSevenZipEditPathsUseKnownPasswordWithoutPrompting() async throws {
        for headers in [false, true] {
            let directory = try ArchiveTestDirectory(), archive = try encryptedSevenZip(in: directory, headers: headers)
            let session = try ArchiveSession(url: archive, password: "rewrite-test-password")
            session.setPasswordPrompt { _ in XCTFail("The known password must be reused"); throw CancellationError() }
            XCTAssertEqual(session.capabilities.mode, .rewrite(.sevenZip))
            _ = try await session.createFolder(in: "", progress: Progress())
            let added = directory.url.appendingPathComponent("added.txt")
            try Data("added encrypted contents".utf8).write(to: added)
            let result = try await session.append(urls: [added], to: "", progress: Progress())
            XCTAssertEqual(result.addedPaths, ["added.txt"])
            XCTAssertTrue(result.failures.isEmpty)
            let selected = try await node("secret.txt", in: session)
            _ = try await session.rename(ArchiveEditSelection(selected), to: "renamed.txt", progress: Progress())
            let renamed = try await node("renamed.txt", in: session)
            _ = try await session.remove([ArchiveEditSelection(renamed)], progress: Progress())
            XCTAssertEqual(session.generation, 4)
            let reader = try ArchiveReader.open(url: archive, options: ReaderOptions(password: "rewrite-test-password"))
            XCTAssertTrue(reader.entries.filter { $0.kind == .file }.allSatisfy(\.isEncrypted))
            try assertNoWorkDirectory(directory.url)
            await session.close()
        }
    }

    @MainActor func testRewritePublishRefusesEncryptionIntroducedAfterCapabilityProbe() async throws {
        let fixture = try Fixture(.sevenZip), document = try document(fixture), session = try XCTUnwrap(document.session)
        let entries = await session.entries()
        let nodes = EntryNode.tree(from: entries).children
        let encrypted = fixture.directory.url.appendingPathComponent("encrypted.7z")
        try fixture.directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-t7z", "-prewrite-test-password",
                                                            encrypted.path, "original.txt", "existing"])
        let replacement = try ArchiveReader.open(url: encrypted)
        XCTAssertEqual(replacement.entries.map(\.name), entries.map(\.name))
        XCTAssertTrue(replacement.entries.contains(where: \.isEncrypted))
        XCTAssertEqual(Darwin.rename(encrypted.path, fixture.archive.path), 0)
        let before = try Data(contentsOf: fixture.archive)
        XCTAssertEqual(session.capabilities.mode, .rewrite(.sevenZip))
        do {
            // 全 entry を削除しても、暗号化された原本を平文の空書庫へ置換しない。
            _ = try await document.remove(nodes, progress: Progress())
            XCTFail("capability 検査後の暗号化を見落としました")
        } catch {
            XCTAssertEqual(error as? ArchiveEditError, .archiveChanged)
            XCTAssertEqual(error.localizedDescription, String(localized: "アーカイブが変更されています。開き直してください。"))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        try assertNoWorkDirectory(fixture.directory.url)
    }

    func testReadOnlyParentRefusesZIPAndEveryRewriteFormat() throws {
        func check(_ archive: URL, format: KaitoKit.ArchiveFormat) throws {
            let parent = archive.deletingLastPathComponent()
            XCTAssertEqual(chmod(parent.path, 0o555), 0)
            defer { XCTAssertEqual(chmod(parent.path, 0o700), 0) }
            let capability = ArchiveCapabilities.inspect(url: archive, format: format)
            guard case .unavailable(let reason) = capability.refusal else { return XCTFail("\(capability)") }
            XCTAssertEqual(reason, String(localized: "アーカイブまたは親フォルダへの書き込み権限がありません。"))
            XCTAssertNil(capability.mode)
            XCTAssertFalse(capability.canEdit)
        }
        for format in Format.allCases {
            let fixture = try Fixture(format)
            try check(fixture.archive, format: format.input)
        }
        let directory = try ArchiveTestDirectory()
        try check(zip(in: directory), format: .zip)
    }

    func testUnrepresentableTarEntryRefusesWithEntryAndReasonWithoutCreatingWork() throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("fifo.tar")
        XCTAssertEqual(mkfifo(directory.url.appendingPathComponent("pipe").path, 0o600), 0)
        try directory.run("/usr/bin/bsdtar", ["--no-mac-metadata", "--no-xattrs", "-cf", archive.path, "pipe"])
        let before = try digest(archive)
        let capability = ArchiveCapabilities.inspect(url: archive, format: .tar)
        let reason = "pipe: この entry 種別は書き込めません"
        XCTAssertEqual(capability.refusal, .unrepresentable(reason))
        XCTAssertNil(capability.mode)
        XCTAssertNil(capability.rewriteNotice)
        XCTAssertEqual(capability.readOnlyReason, String(localized: "このアーカイブには、書き直せない項目があります。\(reason)"))
        XCTAssertEqual(try digest(archive), before)
        try assertNoWorkDirectory(directory.url)
    }

    func testMalformedRewriteCandidateIsUnavailableAndOtherFormatsStayReadOnly() throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("invalid.tar")
        try Data("invalid archive".utf8).write(to: archive)
        for format in [KaitoKit.ArchiveFormat.tar, .sevenZip, .lha] {
            let capability = ArchiveCapabilities.inspect(url: archive, format: format)
            guard case .unavailable = capability.refusal else { return XCTFail("\(capability)") }
            XCTAssertNil(capability.mode)
        }
        for format in KaitoKit.ArchiveFormat.allCases where ![.zip, .tar, .sevenZip, .lha].contains(format) {
            let capability = ArchiveCapabilities.inspect(url: archive, format: format)
            XCTAssertEqual(capability.refusal, .format(format.displayName))
            XCTAssertNil(capability.mode)
        }
        try assertNoWorkDirectory(directory.url)
    }

    @MainActor private func document(_ fixture: Fixture, preferencesStore: ArchivePreferencesStore = .shared) throws -> ArchiveDocument {
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: preferencesStore)
        try document.read(from: fixture.archive, ofType: "archive")
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            withExtendedLifetime(fixture) {}
        }
        return document
    }

    @MainActor func testRemovingEveryMemberKeepsEmptyArchiveReadableEditableAndUndoable() async throws {
        for format in Format.allCases {
            let fixture = try Fixture(format), document = try document(fixture)
            let session = try XCTUnwrap(document.session)
            let original = try digest(fixture.archive)
            let root = EntryNode.tree(from: await session.entries())
            let result = try await document.remove(root.children, progress: Progress())
            XCTAssertTrue(result.published, format.suffix)
            XCTAssertNil(result.reloadFailure, format.suffix)
            let empty = try ArchiveReader.open(url: fixture.archive)
            XCTAssertEqual(empty.format, format.input)
            XCTAssertTrue(empty.entries.isEmpty, format.suffix)
            XCTAssertTrue(session.capabilities.canEdit, format.suffix)
            document.undoManager?.undo()
            await document.undoTask?.value
            XCTAssertEqual(try digest(fixture.archive), original, format.suffix)
            document.undoManager?.redo()
            await document.undoTask?.value
            XCTAssertTrue(try ArchiveReader.open(url: fixture.archive).entries.isEmpty, format.suffix)
            let source = try fixture.file("after-empty.txt", data: Data("added".utf8))
            let appended = try await document.append(urls: [source], to: "", progress: Progress())
            XCTAssertEqual(appended.addedPaths, ["after-empty.txt"])
            XCTAssertNil(appended.reloadFailure)
            XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), ["after-empty.txt": Data("added".utf8)])
        }
    }

    @MainActor private func node(_ name: String, in session: ArchiveSession) async throws -> EntryNode {
        let entries = await session.entries()
        var pending = [EntryNode.tree(from: entries)]
        while let entry = pending.popLast() {
            if entry.path == name { return entry }
            pending.append(contentsOf: entry.children)
        }
        throw ArchiveEditError.staleSelection
    }

    private func nameWithoutTrailingSlash(_ name: String) -> String {
        name.hasSuffix("/") ? String(name.dropLast()) : name
    }

    private func assertContents(_ expected: [String: ExpectedEntry], in archive: URL, format: KaitoKit.ArchiveFormat) throws {
        let reader = try ArchiveReader.open(url: archive)
        let expectedByName = Dictionary(uniqueKeysWithValues: expected.map { (nameWithoutTrailingSlash($0.key), $0.value) })
        XCTAssertEqual(reader.format, format)
        // 7z の directory 名には末尾の / がない。名前の比較と種別の検査を分ける。
        XCTAssertEqual(reader.entries.map { nameWithoutTrailingSlash($0.name) }.sorted(), expectedByName.keys.sorted())
        for entry in reader.entries {
            let expectation = try XCTUnwrap(expectedByName[nameWithoutTrailingSlash(entry.name)], entry.name)
            switch expectation {
            case .directory:
                XCTAssertEqual(entry.kind, .directory, entry.name)
                if format == .sevenZip { XCTAssertEqual(entry.uncompressedSize, 0, entry.name) }
            case .file(let bytes):
                XCTAssertEqual(entry.kind, .file, entry.name)
                XCTAssertEqual(try reader.read(entry), bytes, entry.name)
            }
        }
    }

    private func assertIndependentListing(_ fixture: Fixture, names: Set<String>) throws {
        let expected = Set(names.map(nameWithoutTrailingSlash))
        switch fixture.format {
        case .tar, .tbz2, .txz:
            let listing = try fixture.directory.run("/usr/bin/bsdtar", ["-tf", fixture.archive.path])
            XCTAssertEqual(Set(listing.split(separator: "\n").map { nameWithoutTrailingSlash(String($0)) }), expected)
        case .tgz:
            XCTAssertEqual(Array(try Data(contentsOf: fixture.archive).prefix(2)), [0x1f, 0x8b])
            let listing = try fixture.directory.run("/usr/bin/tar", ["-tzf", fixture.archive.path])
            XCTAssertEqual(Set(listing.split(separator: "\n").map { nameWithoutTrailingSlash(String($0)) }), expected)
        case .sevenZip:
            let listing = try fixture.directory.run("/opt/homebrew/bin/7zz", ["l", "-slt", "-ba", fixture.archive.path])
            let listed = listing.split(separator: "\n").filter { $0.hasPrefix("Path = ") }.map { String($0.dropFirst(7)) }
            XCTAssertEqual(Set(listed.map(nameWithoutTrailingSlash)), expected)
        case .lha: break
        }
    }

    @MainActor private func assertDocumentEditsAndUndo(_ format: Format) async throws {
        let fixture = try Fixture(format), document = try document(fixture), session = try XCTUnwrap(document.session)
        var expected = Fixture.original
        try assertContents(expected, in: fixture.archive, format: format.input)
        var states = [try digest(fixture.archive)]
        let first = Data("first\0file".utf8), second = Data([0, 1, 127, 128, 255]), child = Data("folder child".utf8)
        let firstURL = try fixture.file("first.txt", data: first), secondURL = try fixture.file("second.bin", data: second)
        let folder = try fixture.file("incoming/child.txt", data: child).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: false)
        let progress = Progress()
        let appended = try await document.append(urls: [firstURL, secondURL, folder], to: "", progress: progress)
        XCTAssertTrue(appended.failures.isEmpty)
        XCTAssertNil(appended.reloadFailure)
        XCTAssertEqual(Set(appended.addedPaths), ["first.txt", "second.bin", "incoming", "incoming/child.txt", "incoming/empty"])
        XCTAssertEqual(progress.totalUnitCount, Int64(appended.addedPaths.count + Fixture.original.count + 1))
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        expected.merge(["first.txt": .file(first), "second.bin": .file(second), "incoming": .directory,
                        "incoming/child.txt": .file(child), "incoming/empty": .directory]) { _, new in new }
        try assertContents(expected, in: fixture.archive, format: format.input)
        XCTAssertEqual(session.generation, 1)
        states.append(try digest(fixture.archive))

        let created = try await document.createFolder(in: "existing", baseName: "created", progress: Progress())
        XCTAssertEqual(created.addedPaths, ["existing/created/"])
        XCTAssertNil(created.reloadFailure)
        expected["existing/created"] = .directory
        try assertContents(expected, in: fixture.archive, format: format.input)
        XCTAssertEqual(session.generation, 2)
        states.append(try digest(fixture.archive))

        let firstNode = try await node("first.txt", in: session)
        let renamed = try await document.rename(firstNode, to: "renamed.txt", progress: Progress())
        XCTAssertEqual(renamed.renamedPaths, ["renamed.txt"])
        XCTAssertNil(renamed.reloadFailure)
        expected["renamed.txt"] = expected.removeValue(forKey: "first.txt")
        try assertContents(expected, in: fixture.archive, format: format.input)
        XCTAssertEqual(session.generation, 3)
        states.append(try digest(fixture.archive))

        let secondNode = try await node("second.bin", in: session)
        let removed = try await document.remove([secondNode], progress: Progress())
        XCTAssertEqual(removed.removedPaths, ["second.bin"])
        XCTAssertNil(removed.reloadFailure)
        expected.removeValue(forKey: "second.bin")
        try assertContents(expected, in: fixture.archive, format: format.input)
        XCTAssertEqual(session.generation, 4)
        XCTAssertEqual(document.generation, 4)
        XCTAssertEqual(session.capabilities.mode, .rewrite(format.output))
        XCTAssertEqual(document.archiveUndoStack.slots.count, 4)
        try assertIndependentListing(fixture, names: Set(expected.keys))

        let manager = try XCTUnwrap(document.undoManager)
        for (offset, state) in states.reversed().enumerated() {
            XCTAssertTrue(manager.canUndo)
            manager.undo()
            await document.undoTask?.value
            XCTAssertNil(document.undoFailure)
            XCTAssertEqual(try digest(fixture.archive), state)
            XCTAssertEqual(document.generation, UInt64(5 + offset))
            XCTAssertEqual(session.capabilities.mode, .rewrite(format.output))
        }
        XCTAssertFalse(manager.canUndo)
        try assertContents(Fixture.original, in: fixture.archive, format: format.input)
        try assertNoWorkDirectory(fixture.directory.url)
    }

    @MainActor func testTarDocumentEditsAndUndoRestoreOriginalSHA256() async throws { try await assertDocumentEditsAndUndo(.tar) }
    @MainActor func testTGZDocumentEditsAndUndoRestoreOriginalSHA256() async throws { try await assertDocumentEditsAndUndo(.tgz) }
    @MainActor func testTarBzip2DocumentEditsAndUndoRestoreOriginalSHA256() async throws { try await assertDocumentEditsAndUndo(.tbz2) }
    @MainActor func testTarXZDocumentEditsAndUndoRestoreOriginalSHA256() async throws { try await assertDocumentEditsAndUndo(.txz) }
    @MainActor func testSevenZipDocumentEditsAndUndoRestoreOriginalSHA256() async throws { try await assertDocumentEditsAndUndo(.sevenZip) }
    @MainActor func testLHADocumentEditsAndUndoRestoreOriginalSHA256() async throws { try await assertDocumentEditsAndUndo(.lha) }

    @MainActor func testZIPAppendUsesLatestDocumentPreferences() async throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let directory = try ArchiveTestDirectory(), archive = try zip(in: directory)
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.sessionCleanup?.value
            withExtendedLifetime(directory) {}
        }
        // 開いたセッションにも、その後の変更を同期する。
        try document.read(from: archive, ofType: "archive")
        let session = try XCTUnwrap(document.session)
        XCTAssertEqual(session.capabilities.mode, .inPlace)
        let bytes = Data(repeating: 0x61, count: 200 * 1024)
        var sizes: [UInt64] = []
        for method in [ArchivePreferences.ZipMethod.stored, .deflate] {
            store.preferences.zipMethod = method
            store.preferences.zipLevel = 9
            store.preferences.zipSkipsCompressedTypes = false
            let source = directory.url.appendingPathComponent(method.rawValue + ".txt")
            try bytes.write(to: source)
            let result = try await document.append(urls: [source], to: "", progress: Progress())
            XCTAssertEqual(result.addedPaths, [source.lastPathComponent])
            XCTAssertNil(result.reloadFailure)
            let reader = try ArchiveReader.open(url: archive)
            let entry = try XCTUnwrap(reader.entries.first { $0.name == source.lastPathComponent })
            XCTAssertEqual(entry.uncompressedSize, UInt64(bytes.count))
            sizes.append(try XCTUnwrap(entry.compressedSize))
            var contents = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { contents.append(contentsOf: $0) }
            XCTAssertEqual(contents, bytes)
        }
        XCTAssertEqual(sizes[0], UInt64(bytes.count))
        XCTAssertLessThan(sizes[1], sizes[0])
    }

    @MainActor func testTarGzipRewriteHonoursPreferredCompressionLevel() async throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let bytes = Data(repeating: 0x61, count: 200 * 1024)
        var sizes: [Int] = []
        for level in [1, 9] {
            let fixture = try Fixture(.tgz), document = try document(fixture, preferencesStore: store)
            store.preferences.tarGzipLevel = level
            let source = try fixture.file("repeated.txt", data: bytes)
            let result = try await document.append(urls: [source], to: "", progress: Progress())
            XCTAssertEqual(result.addedPaths, ["repeated.txt"])
            XCTAssertNil(result.reloadFailure)
            sizes.append(try Data(contentsOf: fixture.archive).count)
            try assertContents(Fixture.original.merging(["repeated.txt": .file(bytes)]) { _, new in new },
                               in: fixture.archive, format: .tar)
        }
        XCTAssertGreaterThanOrEqual(sizes[0], sizes[1])
    }

    @MainActor func testTarAppendHonoursPreferredOwnerIDs() async throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        for format in [Format.tar, .tgz, .tbz2, .txz] {
            let fixture = try Fixture(format), document = try document(fixture, preferencesStore: store)
            for preserve in [true, false] {
                store.preferences.tarPreservesOwnerIDs = preserve
                let name = preserve ? "with-owners.txt" : "without-owners.txt"
                let result = try await document.append(urls: [fixture.file(name)], to: "", progress: Progress())
                XCTAssertEqual(result.addedPaths, [name])
                XCTAssertNil(result.reloadFailure)
                let entry = try XCTUnwrap(ArchiveReader.open(url: fixture.archive).entries.first { $0.name == name })
                XCTAssertEqual(entry.formatSpecific["uid"], String(preserve ? getuid() : 0))
                XCTAssertEqual(entry.formatSpecific["gid"], String(preserve ? getgid() : 0))
            }
        }
    }

    @MainActor func testSessionRequestsOptionsForAppendCreateFolderAndEditInEveryMode() async throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences = ArchivePreferences(zipMethod: .stored, zipLevel: 9, zipSkipsCompressedTypes: false,
                                               tarGzipLevel: 1, tarPreservesOwnerIDs: true)
        let preferences = store.preferences
        for format in ArchivePreferences.formats {
            let directory = try ArchiveTestDirectory()
            let source = directory.url.appendingPathComponent("input.txt")
            try Data(repeating: 0x61, count: 1024).write(to: source)
            let archive = directory.url.appendingPathComponent("archive." + ArchiveCreationPlan.filenameExtension(for: format))
            let writer = try ArchiveWriter.create(url: archive, format: format)
            try writer.add(contentsOf: source, as: "seed.txt")
            try writer.finish()
            let requested = Mutex<[GyoshukuKit.ArchiveFormat]>([])
            let session = try ArchiveSession(url: archive, writerOptions: { outputFormat in
                requested.withLock { $0.append(outputFormat) }
                return preferences.writerOptions(for: outputFormat)
            })
            addTeardownBlock { @MainActor in
                await session.close()
                withExtendedLifetime(directory) {}
            }
            let appended = try await session.append(urls: [source], to: "", progress: Progress())
            XCTAssertNil(appended.reloadFailure)
            let created = try await session.createFolder(in: "", baseName: "folder", progress: Progress())
            XCTAssertNil(created.reloadFailure)
            let selection = ArchiveEditSelection(try await node("seed.txt", in: session))
            let renamed = try await session.rename(selection, to: "renamed.txt", progress: Progress())
            XCTAssertNil(renamed.reloadFailure)
            XCTAssertEqual(requested.withLock { $0 }, [format, format, format])
            XCTAssertEqual(session.generation, 3)
            let entries = try ArchiveReader.open(url: archive).entries
            XCTAssertEqual(Set(entries.map { nameWithoutTrailingSlash($0.name) }), ["renamed.txt", "input.txt", "folder"])
            let appendedEntry = try XCTUnwrap(entries.first { $0.name == "input.txt" })
            if [.tar, .tarGzip, .tarBzip2, .tarXZ].contains(format) {
                // フォルダ作成・改名の再書き込みでも、追加時に保存した所有者を失わない。
                XCTAssertEqual(appendedEntry.formatSpecific["uid"], String(getuid()))
            } else if format == .zip {
                XCTAssertEqual(appendedEntry.compressedSize, appendedEntry.uncompressedSize)
            }
        }
    }

    @MainActor func testCancellationDuringRewriteCarryPreservesBytesAndRegistersNoUndo() async throws {
        for format in Format.allCases {
            let fixture = try Fixture(format), document = try document(fixture)
            let before = try Data(contentsOf: fixture.archive), progress = Progress()
            let carried = Mutex(false), published = Mutex(false)
            let total = Int64(Fixture.original.count + 2)
            // 追加一件の後、commit の最初の carry が進捗を増やした瞬間に同期的に取り消す。
            let observation = progress.observe(\.completedUnitCount, options: [.new]) { @Sendable observed, change in
                if observed.totalUnitCount == total, change.newValue == 2 {
                    carried.withLock { $0 = true }
                    observed.cancel()
                }
            }
            defer { observation.invalidate() }
            do {
                _ = try await document.append(urls: [fixture.file("added.txt")], to: "", progress: progress,
                                              willPublish: { published.withLock { $0 = true } })
                XCTFail("carry 中の取消しを無視しました: \(format)")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertTrue(carried.withLock { $0 })
            XCTAssertFalse(published.withLock { $0 })
            XCTAssertEqual(progress.completedUnitCount, 2)
            XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
            XCTAssertEqual(document.generation, 0)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
            try assertNoWorkDirectory(fixture.directory.url)
        }
    }

    @MainActor func testCancellationAfterRewriteCommitDiscardsUndoSlotAndWorkDirectory() async throws {
        for format in Format.allCases {
            let fixture = try Fixture(format), document = try document(fixture)
            let before = try Data(contentsOf: fixture.archive), progress = Progress(), published = Mutex(false)
            do {
                _ = try await document.append(urls: [fixture.file("added.txt")], to: "", progress: progress, willPublish: {
                    published.withLock { $0 = true }
                    XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount - 1)
                    progress.cancel()
                })
                XCTFail("公開直前の取消しを無視しました: \(format)")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            XCTAssertTrue(published.withLock { $0 })
            XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
            XCTAssertEqual(document.generation, 0)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
            try assertNoWorkDirectory(fixture.directory.url)
        }
    }

    private func xattr(_ name: String, at url: URL) throws -> Data {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw ExtractionFailure.system(errno) }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard count >= 0 else { throw ExtractionFailure.system(errno) }
        XCTAssertEqual(count, size)
        return data
    }

    @MainActor func testTarAppendPreservesModeQuarantineAndEveryExtendedAttribute() async throws {
        let fixture = try Fixture(.tar)
        XCTAssertEqual(chmod(fixture.archive.path, 0o600), 0)
        let tags = try PropertyListSerialization.data(fromPropertyList: ["KaitoFinder\n6"], format: .binary, options: 0)
        let attributes: [String: Data] = [
            "com.apple.quarantine": Data("0083;00000001;KaitoFinderTests;rewrite".utf8),
            "user.kf-test": Data([0, 1, 128, 255]),
            "com.apple.metadata:_kMDItemUserTags": tags,
            "user.kf-empty": Data()
        ]
        for (name, data) in attributes {
            let status = data.withUnsafeBytes { setxattr(fixture.archive.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            guard status == 0 else { throw ExtractionFailure.system(errno) }
            XCTAssertEqual(try xattr(name, at: fixture.archive), data)
        }
        let document = try document(fixture)
        let result = try await document.append(urls: [fixture.file("added.txt")], to: "", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["added.txt"])
        XCTAssertNil(result.reloadFailure)
        var info = stat()
        XCTAssertEqual(lstat(fixture.archive.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600)
        for (name, data) in attributes { XCTAssertEqual(try xattr(name, at: fixture.archive), data, name) }
    }

    @MainActor func testExtensionlessTarRewriteUsesBinWorkFile() async throws {
        let fixture = try Fixture(.tar, filename: "archive"), document = try document(fixture)
        let root = fixture.directory.url
        _ = try await document.append(urls: [fixture.file("added.txt")], to: "", progress: Progress(), willPublish: {
            let work = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".KaitoFinder-add-") })
            XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("archive.bin").path))
        })
        XCTAssertEqual(document.session?.capabilities.mode, .rewrite(.tar))
        try assertContents(Fixture.original.merging(["added.txt": .file(Data("added".utf8))]) { _, new in new },
                           in: fixture.archive, format: .tar)
    }

    @MainActor private func labels(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    @MainActor func testWindowRewriteNoticeContainsRecompressionAndZIPDoesNot() async throws {
        let frameAutosave = ArchiveWindowFrameAutosave()
        defer { frameAutosave.restore() }
        let notice = String(localized: "編集するとアーカイブ全体を再圧縮します")
        let controller = ArchiveWindowController()
        defer { controller.close() }
        controller.displayLocked()
        let capabilityNotice = try XCTUnwrap(labels(in: try XCTUnwrap(controller.window?.contentView))
            .first { $0.identifier?.rawValue == "archive.capability-notice" })
        for format in Format.allCases {
            let fixture = try Fixture(format), session = try ArchiveSession(url: fixture.archive)
            let snapshot = await session.snapshot()
            controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
            XCTAssertEqual(capabilityNotice.stringValue, notice, format.suffix)
            XCTAssertFalse(capabilityNotice.isHidden, format.suffix)
            await session.close()
        }
        let directory = try ArchiveTestDirectory(), archive = try zip(in: directory)
        let session = try ArchiveSession(url: archive), snapshot = await session.snapshot()
        controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
        XCTAssertEqual(capabilityNotice.stringValue, "")
        XCTAssertTrue(capabilityNotice.isHidden)
        await session.close()

        let fixture = try Fixture(.tar)
        let readOnlyArchive = fixture.directory.url.appendingPathComponent("archive.tar.zst")
        try fixture.directory.run("/opt/homebrew/bin/zstd", ["-q", fixture.archive.path, "-o", readOnlyArchive.path])
        let readOnlySession = try ArchiveSession(url: readOnlyArchive), readOnlySnapshot = await readOnlySession.snapshot()
        let readOnlyReason = try XCTUnwrap(readOnlySession.capabilities.readOnlyReason)
        controller.display(EntryNode.tree(from: readOnlySnapshot.entries), session: readOnlySession,
                           generation: readOnlySnapshot.generation)
        XCTAssertEqual(capabilityNotice.stringValue, readOnlyReason)
        XCTAssertFalse(capabilityNotice.isHidden)
        await readOnlySession.close()

        controller.displayLocked()
        XCTAssertEqual(capabilityNotice.stringValue, "")
        XCTAssertTrue(capabilityNotice.isHidden)
        XCTAssertFalse(controller.lockedPlaceholder.isHidden)
    }

    func testRewriteNoticeAndRefusalsHaveJapaneseCatalogEntries() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("KaitoFinder/Resources/Localizable.xcstrings"))) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        XCTAssertNil(strings["ファイルやフォルダをドラッグ、またはペーストして追加できます"])
        XCTAssertNil(strings["プレビュー・外部アプリで開く項目は読み取り専用の一時コピーです。変更はアーカイブに保存されません。"])
        for key in ["編集するとアーカイブ全体を再圧縮します", "暗号化されたアーカイブを変更するにはパスワードが必要です。",
                    "このアーカイブには、書き直せない項目があります。%@"] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let japanese = try XCTUnwrap(localizations["ja"] as? [String: Any])
            let unit = try XCTUnwrap(japanese["stringUnit"] as? [String: Any])
            XCTAssertEqual(unit["value"] as? String, key)
        }
    }
}
