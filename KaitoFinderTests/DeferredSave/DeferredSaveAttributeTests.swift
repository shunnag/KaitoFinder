import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSaveAttributeTests: XCTestCase {
    private final class RecordingEditor: ArchiveEditing {
        struct DirectoryCall: Equatable { let path: String; let date: Date?; let owners: ArchiveOwnerIDs? }
        var entryNames: [String] { [] }
        var files: [(URL, String, ArchiveOwnerIDs?)] = []
        var directories: [DirectoryCall] = []
        var plainFileCalls = 0
        func add(contentsOf url: URL, as path: String) throws { plainFileCalls += 1; files.append((url, path, nil)) }
        func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws { files.append((url, path, ownerIDs)) }
        func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws {
            directories.append(.init(path: path, date: modificationDate, owners: ownerIDs))
        }
        func addDirectory(_ path: String) throws { XCTFail("Replay must pass the reserved date") }
        func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?) throws { XCTFail("Unexpected data addition") }
        func remove(entriesAt indices: [Int]) throws { XCTFail("Unexpected removal") }
        func rename(entryAt index: Int, to path: String) throws { XCTFail("Unexpected rename") }
        func commit() throws {}
    }

    func testReplayPassesSourceOwnersAndReservedDirectoryDatesWithoutTemporaryDirectories() throws {
        let directory = try ArchiveTestDirectory(), file = directory.url.appendingPathComponent("file")
        try Data("data".utf8).write(to: file)
        let fileStamp = try ArchiveImportSourceStamp(file), folderStamp = try ArchiveImportSourceStamp(directory.url)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var pending = ArchivePendingChanges()
        pending.additions = [.init(id: UUID(), path: "file", stagedURL: file, sourceStamp: fileStamp, stagedStamp: fileStamp),
                             .init(id: UUID(), path: "directory/", stagedURL: directory.url, sourceStamp: folderStamp,
                                   stagedStamp: folderStamp, reservedAt: date)]
        pending.createdFolders = [.init(id: UUID(), path: "created/", date: date)]
        let plan = try ArchiveSaveReplayPlan(base: [], generation: 0, pending: pending, format: .tar)
        for preserving in [false, true] {
            let editor = RecordingEditor()
            try plan.replay(on: editor, progress: Progress(), preservingOwnerIDs: preserving)
            XCTAssertEqual(editor.files.count, 1)
            XCTAssertEqual(editor.files.first?.0, file)
            XCTAssertEqual(editor.files.first?.2, preserving ? .init(user: fileStamp.userID, group: fileStamp.groupID) : nil)
            XCTAssertEqual(editor.plainFileCalls, preserving ? 0 : 1)
            XCTAssertEqual(editor.directories, ["directory/", "created/"].map {
                .init(path: $0, date: date, owners: preserving ? .init(user: 0, group: 0) : nil)
            })
        }
    }

    func testDeferredDirectoryDatesAndCarriedOwnersWithKeepAndReset() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip, .sevenZip, .lha] {
            for owners: CarriedOwnerIDs in [.keep, .reset] {
                let directory = try ArchiveTestDirectory(), raw = try TarUpdateFixture.archive(directory.url)
                let archive: URL
                if format == .tar { archive = raw }
                else {
                    archive = directory.url.appendingPathComponent("wrapped." + ArchiveCreationPlan.filenameExtension(for: format))
                    let rewriter = try ArchiveRewriter.open(url: raw, output: archive, format: format)
                    try rewriter.commit()
                }
                let folder = directory.url.appendingPathComponent("incoming")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let stamp = try ArchiveImportSourceStamp(folder), date = Date(timeIntervalSince1970: 1_700_000_000)
                let session = try ArchiveSession(url: archive, writerOptions: { output in .init(preserveOwnerIDs: output == .tar || output == .tarGzip, carriedTarOwnerIDs: owners) })
                let snapshot = try await session.deferredSnapshot()
                var pending = ArchivePendingChanges()
                pending.additions = [.init(id: UUID(), path: "directory/", stagedURL: folder, sourceStamp: stamp, stagedStamp: stamp, reservedAt: date)]
                pending.createdFolders = [.init(id: UUID(), path: "created/", date: date)]
                let publication = ArchiveSavePublication(); defer { publication.finish() }
                let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
                XCTAssertNil(result.reloadFailure)
                let entries = try ArchiveReader.open(url: archive).entries
                for name in ["directory/", "created/"] {
                    let entry = try XCTUnwrap(entries.first { $0.name == name })
                    XCTAssertEqual(entry.modificationDate, date, "\(format)")
                    if format == .tar || format == .tarGzip {
                        XCTAssertEqual(entry.formatSpecific["uid"], "0"); XCTAssertEqual(entry.formatSpecific["gid"], "0")
                    }
                }
                if format == .tar || format == .tarGzip {
                    let entry = try XCTUnwrap(entries.first { $0.name == "keep" })
                    XCTAssertEqual(entry.formatSpecific["uid"], owners == .keep ? "501" : "0")
                    XCTAssertEqual(entry.formatSpecific["gid"], owners == .keep ? "20" : "0")
                }
                await session.close()
            }
        }
    }

    func testDeferredTarAdditionUsesOriginalSourceOwnersInsteadOfStagingOwners() async throws {
        let source = URL(fileURLWithPath: "/etc/hosts"), sourceStamp = try ArchiveImportSourceStamp(source)
        guard sourceStamp.userID != getuid() else { throw XCTSkip("Needs a source owned by another user") }
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip] {
            let directory = try ArchiveTestDirectory(), staged = directory.url.appendingPathComponent("staged")
            try Data(contentsOf: source).write(to: staged)
            let stamp = try ArchiveImportSourceStamp(staged)
            XCTAssertNotEqual(stamp.userID, sourceStamp.userID)
            let archive = directory.url.appendingPathComponent("original." + ArchiveCreationPlan.filenameExtension(for: format))
            let writer = try ArchiveWriter.create(url: archive, format: format)
            try writer.add(data: Data("keep".utf8), as: "keep"); try writer.finish()
            let session = try ArchiveSession(url: archive, writerOptions: { _ in .init(preserveOwnerIDs: true) })
            let snapshot = try await session.deferredSnapshot()
            var pending = ArchivePendingChanges()
            pending.additions = [.init(id: UUID(), path: "hosts", stagedURL: staged, sourceStamp: sourceStamp, stagedStamp: stamp)]
            let publication = ArchiveSavePublication(); defer { publication.finish() }
            let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
            XCTAssertNil(result.reloadFailure)
            let reader = try ArchiveReader.open(url: archive), added = try XCTUnwrap(reader.entries.last)
            XCTAssertEqual(added.name, "hosts")
            XCTAssertEqual(added.formatSpecific["uid"], String(sourceStamp.userID)); XCTAssertEqual(added.formatSpecific["gid"], String(sourceStamp.groupID))
            XCTAssertEqual(try reader.read(added), try Data(contentsOf: source))
            await session.close()
        }
    }

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
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tar, .tarGzip, .lha] {
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
        let rewriter = try ArchiveRewriter.open(url: fixture.archive, output: output, format: .tarGzip,
                                                options: .init(preserveOwnerIDs: true))
        try plan.replay(on: rewriter, progress: Progress(), preservingOwnerIDs: true)
        try rewriter.commit()
        let entries = try ArchiveReader.open(url: output).entries
        let file = try XCTUnwrap(entries.first { $0.kind == .file })
        XCTAssertEqual(file.name, "移動/" + base[0].name)
        XCTAssertEqual(file.formatSpecific["uid"], "4294967294")
        XCTAssertEqual(file.formatSpecific["gid"], "3999999999")
        XCTAssertEqual(try DeferredSaveFixture.contents(output)[file.name], Data("payload".utf8))
        XCTAssertEqual(entries.first { $0.kind == .directory }?.formatSpecific["uid"], "0")
    }
}
