import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePublicationTransformationTests: XCTestCase {
    private func edit(_ archive: URL, removing: [String] = ["remove"], renaming: [String: String] = [:],
                      deferred: Bool, options: WriterOptions = .init()) async throws {
        let session = try ArchiveSession(url: archive, writerOptions: { _ in options })
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
            try await assertHardLinkPublications(suffix: suffix, usesUpdaterRule: true)
        }
    }

    func testCompressedTarHardLinksUseRewriterRuleWithAdditionsFirst() async throws {
        try await assertHardLinkPublications(suffix: "tar.gz", options: .init(additionPlacement: .beginning),
                                            usesUpdaterRule: false)
    }

    private func assertHardLinkPublications(suffix: String, options: WriterOptions = .init(),
                                            usesUpdaterRule: Bool) async throws {
        for deferred in [false, true] {
            for action in ["remove-target", "rename-target", "remove-link", "remove-both"] {
                let context = "\(suffix) \(action) deferred=\(deferred) placement=\(options.additionPlacement)"
                let fixture = try ScenarioFixture(script: #"""
                mode = 'w' + ({'gz': ':gz', 'bz2': ':bz2', 'xz': ':xz'}.get(p.split('.')[-1], ''))
                with tarfile.open(p, mode) as t:
                    m = tarfile.TarInfo('target'); m.size = 7; t.addfile(m, io.BytesIO(b'payload'))
                    for name, target in [('direct', 'target'), ('chain', 'direct'), ('second', 'target')]:
                        m = tarfile.TarInfo(name); m.type = tarfile.LNKTYPE; m.linkname = target; t.addfile(m)
                """#, suffix: suffix)
                let before = try ArchiveReader.open(url: fixture.archive).entries
                XCTAssertEqual(before.map(\.kind), [.file, .hardlink, .hardlink, .hardlink], context)
                XCTAssertEqual(before.map { $0.formatSpecific["hardLinkTargetIndex"] }, [nil, "0", "1", "0"], context)
                let removed: [String]
                switch action {
                case "remove-target": removed = ["target"]
                case "remove-link": removed = ["direct"]
                case "remove-both": removed = ["target", "direct"]
                default: removed = []
                }
                try await edit(fixture.archive, removing: removed,
                               renaming: action == "rename-target" ? ["target": "renamed"] : [:],
                               deferred: deferred, options: options)
                let reader = try ArchiveReader.open(url: fixture.archive)
                XCTAssertEqual(reader.entries.count, 4 - removed.count, context)
                for entry in reader.entries {
                    var direct = entry.name == "chain" ? "direct" : "target"
                    let file: Bool
                    if usesUpdaterRule {
                        file = entry.index == 0
                        if removed.contains(direct) { direct = reader.entries[0].name }
                    } else {
                        file = entry.name == "target" || entry.name == "renamed" || removed.contains(direct)
                    }
                    let memberContext = "\(context) \(entry.name)"
                    XCTAssertEqual(entry.kind, file ? .file : .hardlink, memberContext)
                    XCTAssertEqual(entry.uncompressedSize, file ? 7 : 0, memberContext)
                    if file { XCTAssertEqual(try reader.read(entry), Data("payload".utf8), memberContext) }
                    if !file {
                        XCTAssertEqual(entry.formatSpecific["linkPath"],
                                       direct == "target" && action == "rename-target" ? "renamed" : direct, memberContext)
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
                progress: Progress(),
                ledger: .forTesting(plan: .init(counted: 0,
                    additions: [], itemCount: 0,
                    carriedBytes: ArchiveWriteProgress.carriedBytes(entries), changesExisting: false)), willPublish: nil, expectedOutput: .init(projected: entries, mode: .rewrite(format))) { _ in }
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

    func testZIPUpdaterKeepsDirectoryPayloadIncludingPasswordEdits() async throws {
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
        let original = try Data(contentsOf: fixture.archive)
        let session = try ArchiveSession(url: fixture.archive)
        let result = try await session.updatePassword(.set, settings: .init(password: "secret"), progress: Progress())
        XCTAssertNil(result.reloadFailure)
        await session.close()
        let reader = try ArchiveReader.open(url: fixture.archive, options: .init(password: "secret"))
        XCTAssertEqual(reader.entries.map(\.name).sorted(), ["./", "directory/", "link"])
        XCTAssertEqual(reader.entries.first { $0.name == "./" }?.uncompressedSize, 4)
        XCTAssertEqual(reader.entries.first { $0.name == "directory/" }?.uncompressedSize, 25)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), original)
        let link = try XCTUnwrap(reader.entries.first { $0.name == "link" })
        XCTAssertEqual(link.kind, .symlink)
        XCTAssertEqual(link.uncompressedSize, 5)
        XCTAssertEqual(try reader.read(link), Data("café".utf8))
    }

    private func sevenZipAntiFixture() throws -> ScenarioFixture {
        try ScenarioFixture(script: #"""
        import zlib
        h = bytes([1, 5, 2, 0x10, 1, 0x80, 0x0e, 1, 0xc0, 0x0f, 1, 0xc0])
        names = b'\0' + 'anti\0remove\0'.encode('utf-16-le')
        h += bytes([0x11, len(names)]) + names + bytes([0, 0])
        start = struct.pack('<QQI', 0, len(h), zlib.crc32(h))
        with open(p, 'wb') as f:
            f.write(bytes.fromhex('377abcaf271c0004') + struct.pack('<I', zlib.crc32(start)) + start + h)
        """#, suffix: "7z")
    }

    func testSevenZipAntiItemPublishesAsAnEmptyFile() async throws {
        for deferred in [false, true] {
            let fixture = try sevenZipAntiFixture(), trace = SevenZipUpdateTrace()
            XCTAssertEqual(try ArchiveReader.open(url: fixture.archive).entries.first?.formatSpecific["anti"], "true")
            // 先頭への追加設定は、anti を書けない従来の rewriter を使う。
            try await trace.observing {
                try await edit(fixture.archive, deferred: deferred, options: .init(additionPlacement: .beginning))
            }
            trace.assertRoute([.rewriterOpen])
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

    @MainActor func testSevenZipUpdaterPreservesAntiItemAndReadBehavior() async throws {
        for deferred in [false, true] {
            let fixture = try sevenZipAntiFixture(), trace = SevenZipUpdateTrace()
            XCTAssertEqual(try ArchiveReader.open(url: fixture.archive).entries.map(\.name), ["anti", "remove"])
            try await assertAntiItemReadBehavior(fixture.archive, output: fixture.folder("before"))
            try await trace.observing { try await edit(fixture.archive, deferred: deferred) }
            trace.assertRoute([.updaterOpen])
            XCTAssertEqual(trace.adoptions.withLock { $0 }, [.adopted])
            XCTAssertEqual(trace.stages.withLock { $0.filter { [.verificationOpen, .entryComparison, .publish].contains($0) } },
                           [.verificationOpen, .entryComparison, .publish])
            XCTAssertEqual(try ArchiveReader.open(url: fixture.archive).entries.map(\.name), ["anti"])
            try await assertAntiItemReadBehavior(fixture.archive, output: fixture.folder("after"))
        }
    }

    @MainActor private func assertAntiItemReadBehavior(_ archive: URL, output: URL) async throws {
        let reader = try ArchiveReader.open(url: archive)
        let entry = try XCTUnwrap(reader.entries.first { $0.name == "anti" })
        XCTAssertEqual(entry.kind, .file)
        XCTAssertEqual(entry.uncompressedSize, 0)
        XCTAssertEqual(entry.formatSpecific["anti"], "true")
        XCTAssertEqual(entry.formatSpecific["emptyStream"], "true")
        XCTAssertEqual(try reader.read(entry), Data())

        let session = try ArchiveSession(url: archive), snapshot = await session.snapshot()
        let node = try XCTUnwrap(EntryNode.tree(from: snapshot.entries).children.first { $0.path == "anti" })
        XCTAssertFalse(node.isDirectory)
        XCTAssertEqual(node.entry?.formatSpecific["anti"], "true")
        let payload = ArchiveEntryPayload(node: node, session: session, generation: snapshot.generation)
        let capability = EntryReadCapability(entry: node.entry, isDirectory: node.isDirectory, format: session.format)
        XCTAssertTrue(capability.canPreview)
        XCTAssertTrue(capability.canOpen)

        let extracted = output.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        let result = try await ExtractionService.extract([payload], from: session, to: extracted, progress: Progress())
        try ArchiveCopyOut.check(result)
        XCTAssertEqual(result.written.map { $0.url.lastPathComponent }, ["anti"])
        let extractedURL = try XCTUnwrap(result.written.first?.url)
        XCTAssertEqual(try extractedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, true)
        XCTAssertEqual(try Data(contentsOf: extractedURL), Data())

        let preview = ArchivePreviewItem(payload: payload, capability: capability, requiresProgress: false)
        let controller = ArchiveMaterializationController(session: session,
            temporaryDirectory: .init(root: output.appendingPathComponent("preview")))
        controller.failed = { XCTFail($0) }
        controller.updatePreviewSelection([preview])
        controller.display(index: 0) { XCTAssertTrue($0 === preview) }
        await controller.task?.value
        let previewURL = try XCTUnwrap(preview.previewItemURL)
        XCTAssertEqual(preview.previewItemTitle, "anti")
        XCTAssertEqual(try Data(contentsOf: previewURL), Data())
        await controller.close().value

        let copied = try await ArchiveCopyOut.prepare([payload], from: session, progress: Progress(),
            temporaryDirectory: .init(root: output.appendingPathComponent("copy")))
        XCTAssertEqual(copied.paths, ["anti"])
        XCTAssertEqual(copied.urls.map(\.lastPathComponent), ["anti"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(copied.urls.first)), Data())
        await session.close()
    }
}
