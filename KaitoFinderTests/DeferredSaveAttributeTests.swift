import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSaveAttributeTests: XCTestCase {
    private struct Attributes: Equatable {
        let mode: UInt16
        let seconds: Int64
        let nanoseconds: Int64
        let xattrs: [String: Data]
        init(_ url: URL) throws {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
            mode = info.st_mode & 0o7777
            seconds = Int64(info.st_mtimespec.tv_sec)
            nanoseconds = Int64(info.st_mtimespec.tv_nsec)
            let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { throw ExtractionFailure.system(errno) }
            var names = [CChar](repeating: 0, count: size)
            let count = names.withUnsafeMutableBufferPointer { listxattr(url.path, $0.baseAddress, $0.count, XATTR_NOFOLLOW) }
            guard count >= 0 else { throw ExtractionFailure.system(errno) }
            var result: [String: Data] = [:]
            for bytes in names.prefix(count).split(separator: 0) {
                let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { throw ExtractionFailure.system(errno) }
                var value = Data(count: size)
                let count = value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
                guard count >= 0 else { throw ExtractionFailure.system(errno) }
                result[name] = Data(value.prefix(count))
            }
            xattrs = result
        }
    }

    @MainActor private func extract(_ names: [String], fixture: DeferredSaveFixture) async throws -> URL {
        let output = fixture.directory.url.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let session = try XCTUnwrap(fixture.document.session)
        var payloads: [ArchiveEntryPayload] = []
        for name in names {
            let node = try await fixture.node(name)
            payloads.append(ArchiveEntryPayload(node: node, session: session, generation: fixture.document.generation))
        }
        try ArchiveCopyOut.check(await ExtractionService.extract(payloads, from: session, to: output, progress: Progress()))
        return output
    }

    @MainActor func testPendingAndSavedDirectoryFileDatesModesAndXattrsMatchInEveryFormat() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tarGzip, .lha] {
            let fixture = try DeferredSaveFixture(format: format), document = fixture.document
            defer { document.close() }
            let source = fixture.directory.url.appendingPathComponent("source")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let file = source.appendingPathComponent("file.txt")
            try Data("payload".utf8).write(to: file)
            let tag = try PropertyListSerialization.data(fromPropertyList: ["Blue\n4"], format: .binary, options: 0)
            let tagName = "com.apple.metadata:_kMDItemUserTags"
            for url in [source, file] {
                XCTAssertEqual(tag.withUnsafeBytes { setxattr(url.path, tagName, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }, 0)
                try FileManager.default.setAttributes([.posixPermissions: url == source ? 0o700 : 0o751,
                    .modificationDate: Date(timeIntervalSince1970: 1_700_000_000.75)], ofItemAtPath: url.path)
            }
            _ = try await document.append(urls: [source], to: "", progress: Progress())
            _ = try await document.createFolder(in: "", baseName: "created", progress: Progress())
            let before = try await extract(["source", "created"], fixture: fixture)
            let paths = ["source", "source/file.txt", "created"]
            let attributes = try paths.map { try Attributes(before.appendingPathComponent($0)) }
            XCTAssertEqual(attributes[0].mode, 0o755 & ~ExtractionPermissions.processMask)
            XCTAssertEqual(attributes[1].mode, 0o751 & ~ExtractionPermissions.processMask)
            XCTAssertEqual(attributes[1].seconds, 1_700_000_000)
            XCTAssertEqual(attributes[1].nanoseconds, 0)
            XCTAssertTrue(attributes.allSatisfy { $0.xattrs[tagName] == nil })
            let projected = try await document.projectedEntries()
            try await fixture.save()
            let after = try await extract(["source", "created"], fixture: fixture)
            XCTAssertEqual(try paths.map { try Attributes(after.appendingPathComponent($0)) }, attributes, "\(format)")
            let saved = try ArchiveReader.open(url: fixture.archive).entries
            for name in ["source/", "source/file.txt", "created/"] {
                let projectedEntry = try XCTUnwrap(projected.first { $0.name == name })
                let savedEntry = try XCTUnwrap(saved.first { $0.name == name })
                XCTAssertEqual(projectedEntry.modificationDate, savedEntry.modificationDate, "\(format) \(name)")
                XCTAssertEqual(projectedEntry.posixPermissions, savedEntry.posixPermissions, "\(format) \(name)")
            }
        }
    }

    @MainActor func testDeferredTarPreservesSourceOwnerIDsThroughSaveAndSaveAs() async throws {
        let source = URL(fileURLWithPath: "/etc/hosts")
        let stamp = try ArchiveImportSourceStamp(source)
        guard stamp.userID != getuid() else { throw XCTSkip("Needs a readable source owned by another user") }
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip, .tarBzip2, .tarXZ] {
            for saveAs in [false, true] {
                let fixture = try DeferredSaveFixture(format: format), document = fixture.document
                defer { document.close() }
                fixture.store.preferences.tarPreservesOwnerIDs = true
                _ = try await document.append(urls: [source], to: "", progress: Progress())
                _ = try await document.createFolder(in: "", baseName: "created", progress: Progress())
                let addition = try XCTUnwrap(document.pendingChanges.additions.first)
                XCTAssertEqual(addition.sourceStamp.userID, stamp.userID)
                XCTAssertEqual(addition.sourceStamp.groupID, stamp.groupID)
                XCTAssertNotEqual(try ArchiveImportSourceStamp(addition.stagedURL).userID, stamp.userID)
                let destination: URL
                if saveAs {
                    destination = fixture.directory.url.appendingPathComponent("saved." + ArchiveCreationPlan.filenameExtension(for: format))
                    let index = try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: format))
                    let output = destination, creator = ArchiveCreationController(store: fixture.store)
                    creator.destinationHandler = { save, _ in
                        save.formatPopup.selectItem(at: index)
                        save.changeFormat(save.formatPopup)
                        return output
                    }
                    try await document.savePendingAs(using: creator, on: nil, progress: Progress())
                    XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
                } else { destination = fixture.archive; try await fixture.save() }
                let entries = try ArchiveReader.open(url: destination).entries
                let saved = try XCTUnwrap(entries.first { $0.name == "hosts" })
                XCTAssertEqual(saved.formatSpecific["uid"], String(stamp.userID))
                XCTAssertEqual(saved.formatSpecific["gid"], String(stamp.groupID))
                let directory = try XCTUnwrap(entries.first { $0.name == "created/" })
                XCTAssertEqual(directory.formatSpecific["uid"], "0", "Same as immediate addDirectory")
                XCTAssertEqual(directory.formatSpecific["gid"], "0")
                XCTAssertEqual(try DeferredSaveFixture.contents(destination)["hosts"], try Data(contentsOf: source))
            }
        }
    }

    func testTarOwnerCarrierPreservesLargeIDsAndPAXPaths() throws {
        let fixture = try ScenarioFixture(script: """
        with tarfile.open(p, 'w:gz', format=tarfile.PAX_FORMAT) as archive:
            item = tarfile.TarInfo('日本語/' + 'long-' * 30 + '.txt')
            item.uid, item.gid, item.size, item.mtime = 4294967294, 3999999999, 7, 1700000000
            archive.addfile(item, io.BytesIO(b'payload'))
        """, suffix: "tar.gz")
        let base = try ArchiveReader.open(url: fixture.archive).entries
        var pending = ArchivePendingChanges()
        pending.renames[.init(index: 0, expectedName: base[0].name, baseGeneration: 0)] = "移動/" + base[0].name
        pending.createdFolders.append(.init(id: UUID(), path: "created/"))
        let plan = try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending)
        let output = fixture.root.appendingPathComponent("saved.tar.gz")
        try ArchiveDeferredTarWriter.write(source: fixture.archive, password: nil, output: output, format: .tarGzip,
                                           options: .init(preserveOwnerIDs: true), plan: plan, progress: Progress())
        let entries = try ArchiveReader.open(url: output).entries
        let file = try XCTUnwrap(entries.first { $0.kind == .file })
        XCTAssertEqual(file.name, "移動/" + base[0].name)
        XCTAssertEqual(file.formatSpecific["uid"], "4294967294")
        XCTAssertEqual(file.formatSpecific["gid"], "3999999999")
        XCTAssertEqual(try DeferredSaveFixture.contents(output)[file.name], Data("payload".utf8))
        XCTAssertEqual(entries.first { $0.kind == .directory }?.formatSpecific["uid"], "0")
    }
}
