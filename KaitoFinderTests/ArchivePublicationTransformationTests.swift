import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePublicationTransformationTests: XCTestCase {
    private func edit(_ archive: URL, removing: [String] = ["remove"], renaming: [String: String] = [:],
                      deferred: Bool) async throws {
        let session = try ArchiveSession(url: archive)
        let snapshot = try await session.deferredSnapshot()
        func reference(_ entry: ArchiveEntry) -> ArchivePendingChanges.BaseReference {
            .init(index: entry.index, expectedName: entry.name, baseGeneration: snapshot.generation)
        }
        if deferred {
            var pending = ArchivePendingChanges()
            pending.removals = Set(snapshot.entries.filter { removing.contains($0.name) }.map(reference))
            for entry in snapshot.entries {
                if let name = renaming[entry.name] { pending.renames[reference(entry)] = name }
            }
            let publication = ArchiveSavePublication()
            defer { publication.finish() }
            let result = try await session.savePending(pending, baseGeneration: snapshot.generation,
                progress: Progress(), publication: publication)
            XCTAssertNil(result.reloadFailure)
        } else {
            func selection(_ entry: ArchiveEntry) -> ArchiveEditSelection {
                .init(path: entry.name, isDirectory: entry.kind == .directory, entries: [entry])
            }
            if !removing.isEmpty {
                let result = try await session.remove(snapshot.entries.filter { removing.contains($0.name) }.map(selection),
                                                      progress: Progress())
                XCTAssertNil(result.reloadFailure)
            }
            for entry in snapshot.entries {
                if let name = renaming[entry.name] {
                    let result = try await session.rename(selection(entry), to: name, progress: Progress())
                    XCTAssertNil(result.reloadFailure)
                }
            }
        }
        await session.close()
    }

    func testHardLinkDirectTargetsAndChainsPublishImmediatelyAndDeferred() async throws {
        for suffix in ["tar", "tar.gz", "tar.bz2", "tar.xz"] {
            for deferred in [false, true] {
                for action in ["remove-target", "rename-target", "remove-link", "remove-both"] {
                    let fixture = try ScenarioFixture(script: #"""
                    mode = 'w' + ({'gz': ':gz', 'bz2': ':bz2', 'xz': ':xz'}.get(p.split('.')[-1], ''))
                    with tarfile.open(p, mode) as t:
                        m = tarfile.TarInfo('target'); m.size = 7; t.addfile(m, io.BytesIO(b'payload'))
                        for name, target in [('direct', 'target'), ('chain', 'direct'), ('second', 'target')]:
                            m = tarfile.TarInfo(name); m.type = tarfile.LNKTYPE; m.linkname = target; t.addfile(m)
                    """#, suffix: suffix)
                    let before = try ArchiveReader.open(url: fixture.archive).entries
                    XCTAssertEqual(before.map(\.kind), [.file, .hardlink, .hardlink, .hardlink])
                    XCTAssertEqual(before.map { $0.formatSpecific["hardLinkTargetIndex"] }, [nil, "0", "1", "0"])
                    let removed: [String]
                    switch action {
                    case "remove-target": removed = ["target"]
                    case "remove-link": removed = ["direct"]
                    case "remove-both": removed = ["target", "direct"]
                    default: removed = []
                    }
                    try await edit(fixture.archive, removing: removed,
                                   renaming: action == "rename-target" ? ["target": "renamed"] : [:], deferred: deferred)
                    let reader = try ArchiveReader.open(url: fixture.archive)
                    XCTAssertEqual(reader.entries.count, 4 - removed.count, "\(suffix) \(action) deferred=\(deferred)")
                    for entry in reader.entries {
                        let direct = entry.name == "chain" ? "direct" : "target"
                        let file = entry.name == "target" || entry.name == "renamed" || removed.contains(direct)
                        XCTAssertEqual(entry.kind, file ? .file : .hardlink, entry.name)
                        XCTAssertEqual(entry.uncompressedSize, file ? 7 : 0, entry.name)
                        if file { XCTAssertEqual(try reader.read(entry), Data("payload".utf8), entry.name) }
                        if !file {
                            XCTAssertEqual(entry.formatSpecific["linkPath"],
                                           direct == "target" && action == "rename-target" ? "renamed" : direct)
                        }
                    }
                }
            }
        }
    }

    func testSevenZipAndLHADirectoriesAndEmptyFilesPublish() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.sevenZip, .lha] {
            for deferred in [false, true] {
                let directory = try ArchiveTestDirectory()
                let url = directory.url.appendingPathComponent("original." + ArchiveCreationPlan.filenameExtension(for: format))
                let writer = try ArchiveWriter.create(url: url, format: format)
                try writer.addDirectory("directory")
                try writer.add(data: Data(), as: "empty")
                try writer.add(data: Data(), as: "directory/empty")
                try writer.add(data: Data([1]), as: "remove")
                try writer.finish()
                try await edit(url, deferred: deferred)
                let entries = try ArchiveReader.open(url: url).entries
                XCTAssertEqual(entries.map(\.name).sorted(), ["directory/", "directory/empty", "empty"])
                XCTAssertEqual(entries.first { $0.name == "directory/" }?.kind, .directory)
                XCTAssertEqual(entries.filter { $0.kind == .file }.count, 2)
                XCTAssertTrue(entries.allSatisfy { $0.uncompressedSize == 0 })
            }
        }
    }

    func testTarSymlinksAndSparseLogicalSizesPublish() async throws {
        for deferred in [false, true] {
            let fixture = try ScenarioFixture(script: #"""
            with tarfile.open(p, 'w', format=tarfile.PAX_FORMAT) as t:
                m = tarfile.TarInfo('target'); m.size = 7; t.addfile(m, io.BytesIO(b'payload'))
                for name, target in [('link', 'target'), ('dangling', 'absent'), ('unicode', 'caf\u00e9')]:
                    m = tarfile.TarInfo(name); m.type = tarfile.SYMTYPE; m.linkname = target; t.addfile(m)
                m = tarfile.TarInfo('sparse'); m.size = 3
                m.pax_headers = {'GNU.sparse.size': '8192', 'GNU.sparse.map': '4096,3'}
                t.addfile(m, io.BytesIO(b'abc'))
                m = tarfile.TarInfo('remove'); m.size = 1; t.addfile(m, io.BytesIO(b'x'))
            """#, suffix: "tar")
            let before = try ArchiveReader.open(url: fixture.archive)
            XCTAssertEqual(before.entries.first { $0.name == "sparse" }?.uncompressedSize, 8192)
            try await edit(fixture.archive, deferred: deferred)
            let reader = try ArchiveReader.open(url: fixture.archive)
            XCTAssertEqual(reader.entries.count, 5)
            for (name, target) in [("link", "target"), ("dangling", "absent"), ("unicode", "café")] {
                let entry = try XCTUnwrap(reader.entries.first { $0.name == name })
                XCTAssertEqual(entry.kind, .symlink)
                XCTAssertEqual(entry.uncompressedSize, 0)
                XCTAssertEqual(entry.formatSpecific["linkPath"], target)
            }
            let sparse = try XCTUnwrap(reader.entries.first { $0.name == "sparse" })
            XCTAssertEqual(sparse.kind, .file)
            XCTAssertEqual(sparse.uncompressedSize, 8192)
            XCTAssertEqual(try reader.read(sparse), Data(count: 4096) + Data("abc".utf8) + Data(count: 4093))
        }
    }

    func testLinkSizesFollowOutputContainerDuringPublication() throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tar] {
            let fixture = try ScenarioFixture(script: #"""
            with tarfile.open(p, 'w') as t:
                m = tarfile.TarInfo('target'); m.size = 7; t.addfile(m, io.BytesIO(b'payload'))
                m = tarfile.TarInfo('hard'); m.type = tarfile.LNKTYPE; m.linkname = 'target'; t.addfile(m)
                m = tarfile.TarInfo('soft'); m.type = tarfile.SYMTYPE; m.linkname = 'caf\u00e9'; t.addfile(m)
            """#, suffix: "tar")
            let entries = try ArchiveReader.open(url: fixture.archive).entries
            try ArchiveImportTransaction.publish(archive: fixture.archive, mode: .rewrite(format), options: .init(),
                progress: Progress(), willPublish: nil, expectedOutput: .init(projected: entries, mode: .rewrite(format))) { _ in }
            let reader = try ArchiveReader.open(url: fixture.archive)
            let hard = try XCTUnwrap(reader.entries.first { $0.name == "hard" })
            XCTAssertEqual(hard.kind, format == .tar ? .hardlink : .file)
            XCTAssertEqual(hard.uncompressedSize, format == .tar ? 0 : 7)
            if format == .tar { XCTAssertEqual(hard.formatSpecific["linkPath"], "target") }
            else { XCTAssertEqual(try reader.read(hard), Data("payload".utf8)) }
            let soft = try XCTUnwrap(reader.entries.first { $0.name == "soft" })
            XCTAssertEqual(soft.kind, .symlink)
            XCTAssertEqual(soft.uncompressedSize, format == .tar ? 0 : 5)
        }
    }

    func testZIPUpdaterKeepsDirectoryPayloadAndPasswordRewriteNormalizesIt() async throws {
        let fixture = try ScenarioFixture(script: #"""
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('./', b'root')
            z.writestr('directory/', b'ignored-directory-payload')
            m = zipfile.ZipInfo('link'); m.create_system = 3; m.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(m, 'caf\u00e9'.encode('utf8'))
            z.writestr('remove', b'x')
        """#)
        try await edit(fixture.archive, deferred: false)
        let updated = try ArchiveReader.open(url: fixture.archive).entries
        XCTAssertEqual(updated.first { $0.name == "./" }?.uncompressedSize, 4)
        XCTAssertEqual(updated.first { $0.name == "directory/" }?.uncompressedSize, 25)
        let session = try ArchiveSession(url: fixture.archive)
        let result = try await session.updatePassword(.set, settings: .init(password: "secret"), progress: Progress())
        XCTAssertNil(result.reloadFailure)
        await session.close()
        let reader = try ArchiveReader.open(url: fixture.archive, options: .init(password: "secret"))
        XCTAssertEqual(reader.entries.map(\.name).sorted(), ["directory/", "link"])
        XCTAssertEqual(reader.entries.first { $0.name == "directory/" }?.uncompressedSize, 0)
        let link = try XCTUnwrap(reader.entries.first { $0.name == "link" })
        XCTAssertEqual(link.kind, .symlink)
        XCTAssertEqual(link.uncompressedSize, 5)
        XCTAssertEqual(try reader.read(link), Data("café".utf8))
    }

    func testSevenZipAntiItemPublishesAsAnEmptyFile() async throws {
        let fixture = try ScenarioFixture(script: #"""
        import zlib
        h = bytes([1, 5, 2, 0x10, 1, 0x80, 0x0e, 1, 0xc0, 0x0f, 1, 0xc0])
        names = b'\0' + 'anti\0remove\0'.encode('utf-16-le')
        h += bytes([0x11, len(names)]) + names + bytes([0, 0])
        start = struct.pack('<QQI', 0, len(h), zlib.crc32(h))
        with open(p, 'wb') as f:
            f.write(bytes.fromhex('377abcaf271c0004') + struct.pack('<I', zlib.crc32(start)) + start + h)
        """#, suffix: "7z")
        XCTAssertEqual(try ArchiveReader.open(url: fixture.archive).entries.first?.formatSpecific["anti"], "true")
        try await edit(fixture.archive, deferred: true)
        let reader = try ArchiveReader.open(url: fixture.archive)
        XCTAssertEqual(reader.entries.count, 1)
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertEqual(entry.name, "anti")
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.uncompressedSize, 0)
        XCTAssertEqual(entry.formatSpecific["anti"], "false")
        XCTAssertEqual(try reader.read(entry), Data())
    }
}
