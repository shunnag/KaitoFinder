import AppKit
import CryptoKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveEditTests: XCTestCase {
    @MainActor func testPendingRegistryTracksDocumentAppendUntilSuccessOrCancellation() async throws {
        for cancel in [false, true] {
            let fixture = try ScenarioFixture(), source = try fixture.file("appended.txt")
            let (document, _) = try await scenarioDocument(fixture)
            let file = fixture.root.appendingPathComponent("pending.json")
            try Data("[]".utf8).write(to: file)
            let registry = PendingWorkRegistry(fileURL: file), gate = ScenarioGate(), progress = Progress()
            let before = try Data(contentsOf: fixture.archive)
            defer { gate.release() }
            let task = Task {
                try await ArchiveImportTransaction.pendingWorkRegistry.withValue(registry) {
                    try await document.append(urls: [source], to: "", progress: progress, willPublish: { gate.pauseOnce() })
                }
            }
            try await scenarioWait { gate.isEntered }
            let entries = try PendingWorkRegistryTests.entries(in: file)
            XCTAssertEqual(entries.count, 1)
            let work = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".KaitoFinder-add-") })
            XCTAssertEqual((entries.first?["path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                           work.resolvingSymlinksInPath().path)
            XCTAssertNotNil(entries.first?["device"])
            XCTAssertNotNil(entries.first?["inode"])
            if cancel { progress.cancel() }
            gate.release()
            do {
                let result = try await task.value
                XCTAssertFalse(cancel)
                XCTAssertEqual(result.addedPaths, ["appended.txt"])
            } catch {
                XCTAssertTrue(cancel)
                XCTAssertTrue(error is CancellationError)
                XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
            XCTAssertTrue(try PendingWorkRegistryTests.entries(in: file).isEmpty)
        }
    }

    @MainActor func testPendingRegistryTracksPublicationUntilSuccessOrFailure() async throws {
        enum Failure: Error { case injected }
        for fail in [false, true] {
            let fixture = try ScenarioFixture(), source = try fixture.file("added.txt")
            let file = fixture.root.appendingPathComponent("pending.json")
            try Data("[]".utf8).write(to: file)
            let registry = PendingWorkRegistry(fileURL: file), gate = ScenarioGate()
            let archive = fixture.archive, before = try Data(contentsOf: archive)
            defer { gate.release() }
            let task = Task.detached {
                try ArchiveImportTransaction.publish(archive: archive, mode: .inPlace, options: .init(), progress: Progress(),
                    willPublish: {
                        gate.pauseOnce()
                        if fail { throw Failure.injected }
                    }, registry: registry) { updater in
                        try updater.add(contentsOf: source, as: "added.txt")
                    }
            }
            try await scenarioWait { gate.isEntered }
            let entries = try PendingWorkRegistryTests.entries(in: file)
            XCTAssertEqual(entries.count, 1)
            let work = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.root, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".KaitoFinder-add-") })
            XCTAssertEqual((entries.first?["path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                           work.resolvingSymlinksInPath().path)
            XCTAssertNotNil(entries.first?["device"])
            XCTAssertNotNil(entries.first?["inode"])
            gate.release()
            do {
                try await task.value
                XCTAssertFalse(fail)
                XCTAssertEqual(try ScenarioFixture.contents(archive)["added.txt"], Data("added".utf8))
            } catch {
                XCTAssertTrue(fail)
                guard case Failure.injected = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertEqual(try Data(contentsOf: archive), before)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
            XCTAssertTrue(try PendingWorkRegistryTests.entries(in: file).isEmpty)
        }
    }

    func testRegistryWriteFailureDoesNotPreventPublication() throws {
        let fixture = try ScenarioFixture(), source = try fixture.file("added.txt")
        let blocker = try fixture.file("registry-parent")
        let registry = PendingWorkRegistry(fileURL: blocker.appendingPathComponent("pending.json"))
        XCTAssertThrowsError(try registry.register(fixture.root.appendingPathComponent(".KaitoFinder-add-probe")))
        try ArchiveImportTransaction.publish(archive: fixture.archive, mode: .inPlace, options: .init(), progress: Progress(),
            willPublish: nil, registry: registry) { updater in
                try updater.add(contentsOf: source, as: "added.txt")
            }
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive)["added.txt"], Data("added".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".KaitoFinder-add-") })
    }

    private final class Fixture {
        let directory: ArchiveTestDirectory
        var root: URL { directory.url }
        let archive: URL

        init(filename: String = "archive.zip", script: String = #"""
        with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            for name, data in [('keep.txt', b'keep\x00bytes'), ('remove.txt', b'remove me'),
                               ('folder/', b''), ('folder/a.txt', b'alpha'), ('folder/deep/', b''),
                               ('folder/deep/b.bin', bytes(range(256))*4), ('virtual/a.txt', b'virtual a'),
                               ('virtual/deeper/b.txt', b'virtual b'), ('folderish/keep.txt', b'outside')]:
                z.writestr(name, data)
        """#) throws {
            directory = try ArchiveTestDirectory()
            archive = directory.url.appendingPathComponent(filename)
            try directory.run("/usr/bin/python3", ["-c", "import sys, zipfile, tarfile, io, struct, zlib\np=sys.argv[1]\n" + script, archive.path])
        }

        @discardableResult static func run(_ tool: String, _ arguments: [String], allowed: [Int32] = [0]) throws -> String {
            try ArchiveTestDirectory().run(tool, arguments, allowed: allowed)
        }
    }

    @MainActor func testFixtureDamageAndToolScratchFilesAreIsolated() async throws {
        let damaged = try Fixture(), independent = try Fixture()
        XCTAssertNotEqual(damaged.root, independent.root)
        let before = try Data(contentsOf: independent.archive)
        let carried = try records(independent.archive)
        let scratch = "import os, pathlib; pathlib.Path('scratch').write_text(os.environ['TMPDIR'])"
        try damaged.directory.run("/usr/bin/python3", ["-c", scratch])
        XCTAssertEqual(try String(contentsOf: damaged.root.appendingPathComponent("scratch"), encoding: .utf8),
                       damaged.root.appendingPathComponent("tmp").path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: independent.root.appendingPathComponent("scratch").path))
        try Data("broken fixture".utf8).write(to: damaged.archive)
        XCTAssertThrowsError(try ArchiveReader.open(url: damaged.archive))
        XCTAssertEqual(try Data(contentsOf: independent.archive), before)
        let session = try ArchiveSession(url: independent.archive)
        let selection = ArchiveEditSelection(try await node("remove.txt", in: session))
        let result = try await session.remove([selection], progress: Progress())
        XCTAssertTrue(result.published)
        XCTAssertNil(result.reloadFailure)
        XCTAssertFalse(try ArchiveReader.open(url: independent.archive).entries.contains { $0.name == "remove.txt" })
        try assertCarried(carried, to: independent.archive, removed: ["remove.txt"])
    }

    private struct Record {
        let nameBytes: [UInt8]
        let local: Data
        let payload: Data
        let contents: Data
    }

    private final class Gate: Sendable {
        let entered = Mutex(false)
        let release = DispatchSemaphore(value: 0)
        func wait() {
            XCTAssertFalse(Thread.isMainThread)
            entered.withLock { $0 = true }
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
    }

    @MainActor private func waitForGate(_ gate: Gate) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !gate.entered.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(gate.entered.withLock { $0 })
    }

    private func records(_ url: URL) throws -> [String: Record] {
        let bytes = try Data(contentsOf: url), reader = try ArchiveReader.open(url: url)
        var result: [String: Record] = [:]
        for entry in reader.entries {
            let raw = try XCTUnwrap(reader.rawRecord(of: entry))
            var contents = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { contents.append(contentsOf: $0) }
            result[entry.name] = Record(nameBytes: entry.rawName.bytes,
                local: bytes.subdata(in: Int(raw.recordRange.lowerBound)..<Int(raw.recordRange.upperBound)),
                payload: bytes.subdata(in: Int(raw.payloadRange.lowerBound)..<Int(raw.payloadRange.upperBound)),
                contents: contents)
        }
        return result
    }

    private func digest(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }

    private func assertCarried(_ before: [String: Record], to url: URL, removed: Set<String> = [],
                               renamed: [String: String] = [:]) throws {
        let after = try records(url)
        let expected = before.keys.filter { !removed.contains($0) }.map { renamed[$0] ?? $0 }
        XCTAssertEqual(try ArchiveReader.open(url: url).entries.map(\.name).sorted(), expected.sorted())
        for (name, record) in before where !removed.contains(name) {
            let surviving = try XCTUnwrap(after[renamed[name] ?? name])
            XCTAssertEqual(surviving.contents, record.contents)
            XCTAssertEqual(surviving.payload, record.payload)
            if renamed[name] == nil {
                XCTAssertEqual(surviving.local, record.local)
                XCTAssertEqual(surviving.nameBytes, record.nameBytes)
            }
        }
    }

    @MainActor private func node(_ path: String, in session: ArchiveSession) async throws -> EntryNode {
        let entries = await session.entries()
        var pending = [EntryNode.tree(from: entries)]
        while let node = pending.popLast() {
            if node.path == path { return node }
            pending.append(contentsOf: node.children)
        }
        throw ArchiveEditError.staleSelection
    }

    @MainActor private func document(_ fixture: Fixture, stack: ArchiveUndoStack = ArchiveUndoStack()) throws -> ArchiveDocument {
        let document = ArchiveDocument(undoStack: stack)
        try document.read(from: fixture.archive, ofType: "zip")
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
        }
        return document
    }

    @MainActor private func undo(_ document: ArchiveDocument) async throws {
        let manager = try XCTUnwrap(document.undoManager)
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
    }

    @MainActor private func redo(_ document: ArchiveDocument) async throws {
        let manager = try XCTUnwrap(document.undoManager)
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
    }

    func testUpdaterIndexMismatchRefusesDeleteAndRenameWithoutChangingBytes() throws {
        let fixture = try Fixture(), before = try Data(contentsOf: fixture.archive)
        let entries = try ArchiveReader.open(url: fixture.archive).entries
        let entry = try XCTUnwrap(entries.first)
        let wrong = ArchiveEditPlan.Entry(index: entry.index, expectedName: "not-the-entry-at-this-index", isDirectory: false)
        let opened = Mutex(0), published = Mutex(0)
        for plan in [ArchiveEditPlan(removals: [wrong], renames: [], existing: entries),
                     ArchiveEditPlan(removals: [], renames: [.init(entry: wrong, path: "renamed.txt")], existing: entries)] {
            let progress = Progress()
            XCTAssertThrowsError(try ArchiveEditTransaction.run(plan: plan, archive: fixture.archive, mode: .inPlace, progress: progress,
                willOpenUpdater: { opened.withLock { $0 += 1 } }, willPublish: { published.withLock { $0 += 1 } })) {
                XCTAssertEqual($0 as? ArchiveEditError, .indexMismatch(entry.index))
            }
            XCTAssertEqual(progress.completedUnitCount, 0)
            XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        }
        // 本物の updater を開いた後の照合で拒否されたことを確認する。
        XCTAssertEqual(opened.withLock { $0 }, 2)
        XCTAssertEqual(published.withLock { $0 }, 0)
    }

    func testIndexIdentityDoesNotFoldCanonicallyEquivalentNames() throws {
        let fixture = try Fixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('café.txt', b'original')")
        let entries = try ArchiveReader.open(url: fixture.archive).entries, original = try digest(fixture.archive)
        let entry = try XCTUnwrap(entries.first)
        let nfc = entry.name.precomposedStringWithCanonicalMapping
        let expected = entry.name.utf8.elementsEqual(nfc.utf8) ? entry.name.decomposedStringWithCanonicalMapping : nfc
        XCTAssertEqual(entry.name, expected)
        XCTAssertFalse(entry.name.utf8.elementsEqual(expected.utf8))
        let plan = ArchiveEditPlan(removals: [.init(index: entry.index, expectedName: expected, isDirectory: false)],
                                   renames: [], existing: entries)
        XCTAssertThrowsError(try ArchiveEditTransaction.run(plan: plan, archive: fixture.archive, mode: .inPlace, progress: Progress())) {
            XCTAssertEqual($0 as? ArchiveEditError, .indexMismatch(entry.index))
        }
        XCTAssertEqual(try digest(fixture.archive), original)
    }

    @MainActor func testArchiveReplacementBeforeEditRefusesStaleSessionDeleteAndRenameWithoutUndo() async throws {
        // 同数で選択外の名前だけを変える場合と、zip が旧一覧まで一致する末尾追加を分ける。
        for names in [["keep.txt", "replacement.txt"], ["keep.txt", "other.txt", "added.txt"]] {
            for rename in [false, true] {
                let fixture = try Fixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('keep.txt', b'keep')\n z.writestr('other.txt', b'other')")
                let document = try document(fixture), session = try XCTUnwrap(document.session)
                let existing = await session.entries(), selected = try await node("keep.txt", in: session)
                let entry = try XCTUnwrap(selected.entry), original = try digest(fixture.archive)
                XCTAssertEqual(existing.map(\.name), ["keep.txt", "other.txt"])

                let replacement = fixture.root.appendingPathComponent("replacement.zip")
                let writer = try ArchiveWriter.create(url: replacement)
                for name in names { try writer.add(data: Data("replacement \(name)".utf8), as: name) }
                try writer.finish()
                let expected = try digest(replacement)
                XCTAssertNotEqual(expected, original)
                // 原本の inode を書き換えずに置換し、session の reader には旧一覧を保持させる。
                guard Darwin.rename(replacement.path, fixture.archive.path) == 0 else { throw ExtractionFailure.system(errno) }
                let cached = await session.entries(), current = try ArchiveReader.open(url: fixture.archive).entries
                XCTAssertEqual(cached, existing)
                XCTAssertEqual(current.map(\.name), names)
                XCTAssertEqual(current[entry.index].index, entry.index)
                XCTAssertTrue(current[entry.index].name.utf8.elementsEqual(entry.name.utf8))
                XCTAssertEqual(current[entry.index].kind, entry.kind)
                XCTAssertEqual(try digest(fixture.archive), expected)

                let published = Mutex(0)
                // document 経由で同じ session を使い、公開と undo 登録まで拒否されることを確かめる。
                do {
                    if rename {
                        _ = try await document.rename(selected, to: "renamed.txt", progress: Progress(),
                                                      willPublish: { published.withLock { $0 += 1 } })
                    } else {
                        _ = try await document.remove([selected], progress: Progress(),
                                                      willPublish: { published.withLock { $0 += 1 } })
                    }
                    XCTFail("置換前の一覧で書庫を変更しました")
                } catch { XCTAssertEqual(error as? ArchiveEditError, .archiveChanged) }
                XCTAssertEqual(try digest(fixture.archive), expected)
                XCTAssertEqual(session.generation, 0)
                XCTAssertEqual(published.withLock { $0 }, 0)
                XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
                XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
                XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
            }
        }
    }

    @MainActor func testDeletingFilePreservesEverySurvivingRecordAndPassesUnzip() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try records(fixture.archive)
        let selected = try await node("remove.txt", in: session)
        let result = try await session.remove([ArchiveEditSelection(selected)], progress: Progress())
        XCTAssertEqual(result.removedPaths, ["remove.txt"])
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(session.generation, 1)
        try assertCarried(before, to: fixture.archive, removed: ["remove.txt"])
        XCTAssertTrue(try Fixture.run("/usr/bin/unzip", ["-t", fixture.archive.path]).contains("No errors detected"))
    }

    @MainActor func testDeletingVirtualFolderRemovesExactlyItsDescendants() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try records(fixture.archive), folder = try await node("virtual", in: session)
        XCTAssertTrue(folder.isVirtual)
        _ = try await session.remove([ArchiveEditSelection(folder)], progress: Progress())
        try assertCarried(before, to: fixture.archive, removed: ["virtual/a.txt", "virtual/deeper/b.txt"])
    }

    @MainActor func testDeletingRealDirectoryRemovesItsRecordAndAllDescendants() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try records(fixture.archive), folder = try await node("folder", in: session)
        XCTAssertFalse(folder.isVirtual)
        _ = try await session.remove([ArchiveEditSelection(folder)], progress: Progress())
        try assertCarried(before, to: fixture.archive, removed: Set(before.keys.filter { $0.hasPrefix("folder/") }))
        XCTAssertFalse(try ArchiveReader.open(url: fixture.archive).entries.contains { $0.name.hasPrefix("folder/") })
    }

    @MainActor func testRenamingFileChangesOnlyItsNameAndPreservesCompressedPayload() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try records(fixture.archive), file = try await node("remove.txt", in: session)
        let result = try await session.rename(ArchiveEditSelection(file), to: "renamed-longer.txt", progress: Progress())
        XCTAssertEqual(result.renamedPaths, ["renamed-longer.txt"])
        XCTAssertNil(result.reloadFailure)
        try assertCarried(before, to: fixture.archive, renamed: ["remove.txt": "renamed-longer.txt"])
    }

    @MainActor func testRenamingRealDirectoryRewritesEveryPrefixAndPreservesTrailingSlashes() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try records(fixture.archive), folder = try await node("folder", in: session)
        _ = try await session.rename(ArchiveEditSelection(folder), to: "renamed", progress: Progress())
        let changed = Dictionary(uniqueKeysWithValues: before.keys.filter { $0.hasPrefix("folder/") }
            .map { ($0, "renamed/" + $0.dropFirst("folder/".count)) })
        try assertCarried(before, to: fixture.archive, renamed: changed)
        let directories = try ArchiveReader.open(url: fixture.archive).entries.filter { $0.kind == .directory }.map(\.name)
        XCTAssertEqual(directories, ["renamed/", "renamed/deep/"])
        XCTAssertTrue(try Fixture.run("/usr/bin/unzip", ["-t", fixture.archive.path]).contains("No errors detected"))
    }

    @MainActor func testRenamingVirtualFolderRewritesDescendantsWithoutInventingDirectoryRecord() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try records(fixture.archive), folder = try await node("virtual", in: session)
        XCTAssertTrue(folder.isVirtual)
        _ = try await session.rename(ArchiveEditSelection(folder), to: "moved", progress: Progress())
        try assertCarried(before, to: fixture.archive, renamed: ["virtual/a.txt": "moved/a.txt", "virtual/deeper/b.txt": "moved/deeper/b.txt"])
    }

    @MainActor func testDirectoryRenameHandlesCanonicalPrefixSpellingsAndWritesNFCNames() async throws {
        let fixture = try Fixture(script: #"""
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('café/', b'')
            z.writestr('cafe\u0301/child', b'child')
            z.writestr('keep', b'keep')
        """#)
        let session = try ArchiveSession(url: fixture.archive), before = try records(fixture.archive)
        let directory = try await node("café", in: session)
        _ = try await session.rename(ArchiveEditSelection(directory), to: "re\u{301}pertoire", progress: Progress())
        try assertCarried(before, to: fixture.archive, renamed: ["café/": "répertoire/", "cafe\u{301}/child": "répertoire/child"])
        for entry in try ArchiveReader.open(url: fixture.archive).entries {
            XCTAssertEqual(entry.rawName.bytes, Array(entry.name.precomposedStringWithCanonicalMapping.utf8))
        }
    }

    @MainActor func testCP932NameBytesSurviveNeighbourDeletion() async throws {
        let fixture = try Fixture(script: #"""
        pack=lambda f,*v:struct.pack('<'+f,*v)
        records=b''; central=b''
        for text in ['remove.txt', '日本語.txt', '保存.txt']:
            name=text.encode('cp932'); data=b'legacy contents'; crc=zlib.crc32(data)
            local=pack('IHHHHHIIIHH',0x04034b50,20,0,0,0,0x21,crc,len(data),len(data),len(name),0)+name+data
            central+=pack('IHHHHHHIIIHHHHHII',0x02014b50,0x0314,20,0,0,0,0x21,crc,len(data),len(data),len(name),0,0,0,0,0o100644<<16,len(records))+name
            records+=local
        open(p,'wb').write(records+central+pack('IHHHHIIH',0x06054b50,0,0,3,3,len(central),len(records),0))
        """#)
        let before = try records(fixture.archive), session = try ArchiveSession(url: fixture.archive)
        XCTAssertEqual(before["日本語.txt"]?.nameBytes, [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x2E, 0x74, 0x78, 0x74])
        let file = try await node("remove.txt", in: session)
        _ = try await session.remove([ArchiveEditSelection(file)], progress: Progress())
        try assertCarried(before, to: fixture.archive, removed: ["remove.txt"])
    }

    @MainActor private func assertInvalidName(_ name: String, expected: ArchiveEditError) async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let original = try digest(fixture.archive), opened = Mutex(0), published = Mutex(0)
        let file = try await node("remove.txt", in: session)
        do {
            _ = try await session.edit(renaming: [.init(selection: ArchiveEditSelection(file), name: name)], progress: Progress(),
                willOpenUpdater: { opened.withLock { $0 += 1 } }, willPublish: { published.withLock { $0 += 1 } })
            XCTFail("不正な名称を受理しました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, expected) }
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertEqual(session.generation, 0)
        XCTAssertEqual(opened.withLock { $0 }, 0)
        XCTAssertEqual(published.withLock { $0 }, 0)
        // 同じフックを成功操作でも通し、常にゼロを返すだけの検査にしない。
        _ = try await session.edit(renaming: [.init(selection: ArchiveEditSelection(file), name: "valid.txt")], progress: Progress(),
            willOpenUpdater: { opened.withLock { $0 += 1 } }, willPublish: { published.withLock { $0 += 1 } })
        XCTAssertEqual(opened.withLock { $0 }, 1)
        XCTAssertEqual(published.withLock { $0 }, 1)
    }

    @MainActor func testCollisionIsRefusedBeforeOpeningUpdater() async throws {
        try await assertInvalidName("keep.txt", expected: .collision("keep.txt"))
    }

    @MainActor func testEmptyNameIsRefusedBeforeOpeningUpdater() async throws {
        try await assertInvalidName("", expected: .invalidName(""))
    }

    @MainActor func testParentComponentIsRefusedBeforeOpeningUpdater() async throws {
        try await assertInvalidName("..", expected: .invalidName(".."))
    }

    @MainActor func testNULIsRefusedBeforeOpeningUpdater() async throws {
        try await assertInvalidName("bad\0name", expected: .invalidName("bad\0name"))
    }

    @MainActor func testOtherWriterPathRestrictionsAreValidatedBeforeOpeningUpdater() async throws {
        for name in [".", "a/b", "a\\b", "a:b", String(repeating: "x", count: 65536)] {
            try await assertInvalidName(name, expected: .invalidName(name))
        }
    }

    @MainActor func testNFCSiblingFileRealDirectoryAndVirtualDirectoryCollisionsAreRefused() async throws {
        let fixture = try Fixture(script: #"""
        with zipfile.ZipFile(p, 'w') as z:
            for name in ['café.txt', 'real/', 'virtual/child', 'source']:
                z.writestr(name, b'')
        """#)
        let session = try ArchiveSession(url: fixture.archive), original = try digest(fixture.archive), opened = Mutex(0)
        let file = try await node("source", in: session)
        for name in ["cafe\u{301}.txt", "real", "virtual"] {
            do {
                _ = try await session.edit(renaming: [.init(selection: ArchiveEditSelection(file), name: name)], progress: Progress(),
                                           willOpenUpdater: { opened.withLock { $0 += 1 } })
                XCTFail("同名の兄弟を受理しました")
            } catch { guard case .collision = error as? ArchiveEditError else { return XCTFail("\(error)") } }
            XCTAssertEqual(try digest(fixture.archive), original)
        }
        XCTAssertEqual(opened.withLock { $0 }, 0)
    }

    @MainActor func testInvalidDescendantPathRefusesWholeDirectoryRenameBeforeOpeningUpdater() async throws {
        let fixture = try Fixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('dir/good', b'good')\n z.writestr('dir/../bad', b'bad')")
        let session = try ArchiveSession(url: fixture.archive), original = try digest(fixture.archive), opened = Mutex(0)
        let folder = try await node("dir", in: session)
        do {
            _ = try await session.edit(renaming: [.init(selection: ArchiveEditSelection(folder), name: "new")], progress: Progress(),
                                       willOpenUpdater: { opened.withLock { $0 += 1 } })
            XCTFail("不正な子孫を改名しました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .invalidName("new/../bad")) }
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertEqual(opened.withLock { $0 }, 0)
    }

    @MainActor func testInvalidMixedRequestQueuesNothing() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let original = try digest(fixture.archive), opened = Mutex(0)
        let removing = try await node("remove.txt", in: session), renaming = try await node("folder", in: session)
        do {
            _ = try await session.edit(removing: [ArchiveEditSelection(removing)],
                renaming: [.init(selection: ArchiveEditSelection(renaming), name: "virtual")], progress: Progress(),
                willOpenUpdater: { opened.withLock { $0 += 1 } })
            XCTFail("一部だけ有効な変更を受理しました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .collision("virtual")) }
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertEqual(session.generation, 0)
        XCTAssertEqual(opened.withLock { $0 }, 0)
    }

    @MainActor func testRenamingTwoVirtualFoldersToSameNameRefusesBeforeOpeningUpdater() async throws {
        let fixture = try Fixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('one/a', b'a')\n z.writestr('two/b', b'b')")
        let session = try ArchiveSession(url: fixture.archive), original = try digest(fixture.archive), opened = Mutex(0)
        let one = try await node("one", in: session), two = try await node("two", in: session)
        XCTAssertTrue(one.isVirtual)
        XCTAssertTrue(two.isVirtual)
        do {
            _ = try await session.edit(renaming: [one, two].map { .init(selection: ArchiveEditSelection($0), name: "new") },
                                       progress: Progress(), willOpenUpdater: { opened.withLock { $0 += 1 } })
            XCTFail("仮想フォルダ同士を暗黙に併合しました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .collision("new")) }
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertEqual(opened.withLock { $0 }, 0)
        XCTAssertEqual(session.generation, 0)
    }

    @MainActor func testOverlappingDeleteAndRenameRefusesWholeRequest() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive), original = try digest(fixture.archive)
        let parent = try await node("folder", in: session), child = try await node("folder/a.txt", in: session)
        do {
            _ = try await session.edit(removing: [ArchiveEditSelection(parent)],
                renaming: [.init(selection: ArchiveEditSelection(child), name: "new")], progress: Progress())
            XCTFail("削除する子を同時に改名しました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .conflictingSelection) }
        XCTAssertEqual(try digest(fixture.archive), original)
    }

    @MainActor private func assertUndoRoundTrip(rename: Bool) async throws {
        let fixture = try Fixture(), document = try document(fixture), original = try digest(fixture.archive)
        let session = try XCTUnwrap(document.session), selected = try await node("folder", in: session)
        if rename { _ = try await document.rename(selected, to: "changed", progress: Progress()) }
        else { _ = try await document.remove([selected], progress: Progress()) }
        let changed = try digest(fixture.archive)
        XCTAssertNotEqual(changed, original)
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
        XCTAssertEqual(try digest(XCTUnwrap(document.archiveUndoStack.slots.first).url), original)
        try await undo(document)
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        try await redo(document)
        XCTAssertEqual(try digest(fixture.archive), changed)
        XCTAssertEqual(document.generation, 3)
        if document.saveBehavior == .immediate { XCTAssertFalse(document.isDocumentEdited) }
    }

    @MainActor func testDeleteUndoAndRedoRestoreFullArchiveSHA256() async throws { try await assertUndoRoundTrip(rename: false) }
    @MainActor func testRenameUndoAndRedoRestoreFullArchiveSHA256() async throws { try await assertUndoRoundTrip(rename: true) }

    @MainActor func testMixedDeleteAndRenamePublishOnceWithOneGenerationAndUndoEntry() async throws {
        let fixture = try Fixture(), document = try document(fixture), original = try digest(fixture.archive)
        let session = try XCTUnwrap(document.session), before = try records(fixture.archive), published = Mutex(0)
        let removing = try await node("remove.txt", in: session), renaming = try await node("keep.txt", in: session)
        let result = try await document.edit(removing: [ArchiveEditSelection(removing)],
            renaming: [.init(selection: ArchiveEditSelection(renaming), name: "remove.txt")], progress: Progress(),
            willPublish: { published.withLock { $0 += 1 } })
        XCTAssertTrue(result.published)
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(published.withLock { $0 }, 1)
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
        try assertCarried(before, to: fixture.archive, removed: ["remove.txt"], renamed: ["keep.txt": "remove.txt"])
        let changed = try digest(fixture.archive)
        try await undo(document)
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        try await redo(document)
        XCTAssertEqual(try digest(fixture.archive), changed)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
    }

    @MainActor func testFailureAfterCloneDiscardsSlotAndRegistersNoUndoForDeleteAndRename() async throws {
        for rename in [false, true] {
            let fixture = try Fixture(), directories = Mutex<[URL]>([])
            let stack = ArchiveUndoStack { source, destination in
                XCTAssertFalse(Thread.isMainThread)
                directories.withLock { $0.append(destination.deletingLastPathComponent()) }
                return ArchiveUndoStack.cloneFile(from: source, to: destination)
            }
            let document = try document(fixture, stack: stack), original = try digest(fixture.archive)
            let selected = try await node("remove.txt", in: XCTUnwrap(document.session)), archive = fixture.archive
            var info = stat()
            XCTAssertEqual(lstat(archive.path, &info), 0)
            let replacementMode: mode_t = info.st_mode & 0o777 == 0o600 ? 0o644 : 0o600
            let failIdentity: @Sendable () throws -> Void = {
                // clone 後の identity 検査を実際に失敗させ、原本の byte は保つ。
                guard chmod(archive.path, replacementMode) == 0 else { throw ExtractionFailure.system(errno) }
            }
            do {
                if rename { _ = try await document.rename(selected, to: "new", progress: Progress(), willPublish: failIdentity) }
                else { _ = try await document.remove([selected], progress: Progress(), willPublish: failIdentity) }
                XCTFail("別操作で変わった原本へ公開しました")
            } catch { XCTAssertTrue(error is ExtractionFailure) }
            XCTAssertEqual(try digest(fixture.archive), original)
            XCTAssertEqual(document.generation, 0)
            XCTAssertEqual(directories.withLock { $0.count }, 1)
            for directory in directories.withLock({ $0 }) { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path)) }
            XCTAssertTrue(stack.slots.isEmpty)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
        }
    }

    @MainActor func testDeletingAllEntriesProducesEmptyZIPAcceptedByUnzipAnd7zzOutput() async throws {
        let fixture = try Fixture(), document = try document(fixture), original = try digest(fixture.archive)
        let session = try XCTUnwrap(document.session), entries = await session.entries()
        let root = EntryNode.tree(from: entries)
        let result = try await document.remove(root.children, progress: Progress())
        XCTAssertEqual(result.removedPaths.count, entries.count)
        XCTAssertNil(result.reloadFailure)
        XCTAssertTrue(try ArchiveReader.open(url: fixture.archive).entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.archive).count, 22)
        let unzip = try Fixture.run("/usr/bin/unzip", ["-t", fixture.archive.path], allowed: [1])
        XCTAssertTrue(unzip.contains("zipfile is empty"), unzip)
        let seven = try Fixture.run("/opt/homebrew/bin/7zz", ["t", fixture.archive.path])
        XCTAssertTrue(seven.contains("Everything is Ok"), seven)
        XCTAssertTrue(seven.contains("Files: 0"), seven)
        try await undo(document)
        XCTAssertEqual(try digest(fixture.archive), original)
    }

    @MainActor func testReadOnlyCapabilitiesRefuseDeleteRenameAndMixedEditsBeforeOpeningUpdater() async throws {
        for (filename, script) in [
            ("archive.tar.lzma", "with tarfile.open(p, 'w') as t:\n i=tarfile.TarInfo('old'); i.size=1; t.addfile(i, io.BytesIO(b'x'))\nimport lzma; raw=open(p,'rb').read(); open(p,'wb').write(lzma.compress(raw,format=lzma.FORMAT_ALONE))"),
            ("archive.zip", "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('old', b'x')\nwith open(p, 'ab') as f: f.write(b'trailing')")
        ] {
            let fixture = try Fixture(filename: filename, script: script), session = try ArchiveSession(url: fixture.archive)
            let original = try digest(fixture.archive), opened = Mutex(0)
            XCTAssertFalse(session.capabilities.canEdit)
            XCTAssertNotNil(session.capabilities.refusal)
            XCTAssertNotNil(session.capabilities.readOnlyReason)
            let selected = ArchiveEditSelection(try await node("old", in: session))
            for (removing, renaming) in [([selected], [ArchiveEditRename]()),
                                        ([], [.init(selection: selected, name: "new")]),
                                        ([selected], [.init(selection: selected, name: "new")])] {
                do {
                    _ = try await session.edit(removing: removing, renaming: renaming, progress: Progress(),
                                               willOpenUpdater: { opened.withLock { $0 += 1 } })
                    XCTFail("読み取り専用の書庫を変更しました")
                } catch { guard case .refused = error as? ExtractionFailure else { return XCTFail("\(error)") } }
                XCTAssertEqual(try digest(fixture.archive), original)
            }
            XCTAssertEqual(opened.withLock { $0 }, 0)
            XCTAssertEqual(session.generation, 0)
        }
    }

    @MainActor func testPendingDeleteAndRenameRejectAllOtherDocumentMutations() async throws {
        for rename in [false, true] {
            let fixture = try Fixture(), document = try document(fixture), gate = Gate()
            let session = try XCTUnwrap(document.session), original = try digest(fixture.archive)
            let selected = try await node("remove.txt", in: session), other = try await node("keep.txt", in: session)
            let added = fixture.root.appendingPathComponent("added.txt")
            try Data("added".utf8).write(to: added)
            let task = Task {
                if rename { return try await document.rename(selected, to: "changed", progress: Progress(), willPublish: { gate.wait() }) }
                return try await document.remove([selected], progress: Progress(), willPublish: { gate.wait() })
            }
            defer { gate.release.signal() }
            try await waitForGate(gate)
            do { _ = try await document.remove([other], progress: Progress()); XCTFail("処理中の削除を受理しました") }
            catch { XCTAssertTrue(error is ExtractionFailure) }
            do { _ = try await document.rename(other, to: "second", progress: Progress()); XCTFail("処理中の改名を受理しました") }
            catch { XCTAssertTrue(error is ExtractionFailure) }
            do { _ = try await document.append(urls: [added], to: "", progress: Progress()); XCTFail("処理中の追加を受理しました") }
            catch { XCTAssertTrue(error is ExtractionFailure) }
            XCTAssertEqual(try digest(fixture.archive), original)
            XCTAssertEqual(document.generation, 0)
            gate.release.signal()
            let result = try await task.value
            XCTAssertTrue(result.published)
            XCTAssertEqual(document.generation, 1)
            XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
            try await undo(document)
            XCTAssertEqual(try digest(fixture.archive), original)
        }
    }

    @MainActor func testCloseCancelsPendingDeleteAndWaitsForSlotCleanup() async throws {
        let fixture = try Fixture(), document = try document(fixture), original = try digest(fixture.archive), gate = Gate()
        let selected = try await node("remove.txt", in: XCTUnwrap(document.session))
        let task = Task { try await document.remove([selected], progress: Progress(), willPublish: { gate.wait() }) }
        defer { gate.release.signal() }
        try await waitForGate(gate)
        document.close()
        gate.release.signal()
        do { _ = try await task.value; XCTFail("close 後に未公開の削除を完了しました") }
        catch { XCTAssertTrue(error is CancellationError) }
        await document.undoCleanup?.value
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testCancellationAfterCloneDoesNotPublishRenameOrRegisterUndo() async throws {
        let fixture = try Fixture(), document = try document(fixture), original = try digest(fixture.archive), progress = Progress()
        let selected = try await node("folder", in: XCTUnwrap(document.session))
        do {
            _ = try await document.rename(selected, to: "new", progress: progress, willPublish: { progress.cancel() })
            XCTFail("取り消した改名を公開しました")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testStaleFolderSelectionRefusesToLeaveNewChildrenOrphaned() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let selected = ArchiveEditSelection(try await node("folder", in: session))
        let added = fixture.root.appendingPathComponent("new.txt")
        try Data("new child".utf8).write(to: added)
        _ = try await session.append(urls: [added], to: "folder", progress: Progress())
        let original = try digest(fixture.archive)
        do { _ = try await session.remove([selected], progress: Progress()); XCTFail("古い部分木だけを削除しました") }
        catch { XCTAssertEqual(error as? ArchiveEditError, .staleSelection) }
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertEqual(session.generation, 1)
    }

    @MainActor func testNoOpEditDoesNotPublishAdvanceGenerationOrAddUndo() async throws {
        let fixture = try Fixture(), document = try document(fixture), session = try XCTUnwrap(document.session)
        let removed = try await node("remove.txt", in: session)
        _ = try await document.remove([removed], progress: Progress())
        let original = try digest(fixture.archive), selected = try await node("keep.txt", in: session), published = Mutex(0)
        let rename = try await document.rename(selected, to: "keep.txt", progress: Progress(), willPublish: { published.withLock { $0 += 1 } })
        let remove = try await document.remove([], progress: Progress(), willPublish: { published.withLock { $0 += 1 } })
        XCTAssertFalse(rename.published)
        XCTAssertFalse(remove.published)
        XCTAssertEqual(published.withLock { $0 }, 0)
        XCTAssertEqual(try digest(fixture.archive), original)
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
        XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testNewFolderAddsExactlyOneDirectoryAndPreservesEveryExistingRecord() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try records(fixture.archive), progress = Progress()
        let result = try await session.createFolder(in: "folder", baseName: "名称未設定フォルダ", progress: progress)
        XCTAssertEqual(result.addedPaths, ["folder/名称未設定フォルダ/"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(result.reloadFailure)
        let after = try records(fixture.archive), entries = await session.entries()
        XCTAssertEqual(after.count, before.count + 1)
        let added = try XCTUnwrap(entries.first { $0.name == result.addedPaths.first })
        XCTAssertEqual(added.kind, .directory)
        XCTAssertEqual(added.uncompressedSize, 0)
        for (name, record) in before {
            let surviving = try XCTUnwrap(after[name])
            XCTAssertEqual(surviving.local, record.local, name)
            XCTAssertEqual(surviving.payload, record.payload, name)
            XCTAssertEqual(surviving.contents, record.contents, name)
            XCTAssertEqual(surviving.nameBytes, record.nameBytes, name)
        }
        XCTAssertEqual(session.generation, 1)
        XCTAssertEqual(progress.completedUnitCount, 2)
        XCTAssertEqual(progress.totalUnitCount, 2)
        XCTAssertTrue(try fixture.directory.run("/usr/bin/unzip", ["-t", fixture.archive.path]).contains("No errors detected"))
    }

    @MainActor func testNewFolderCollisionNumbersIncludeFilesAndVirtualFolders() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        for expected in ["名称未設定フォルダ/", "名称未設定フォルダ 2/", "名称未設定フォルダ 3/"] {
            let result = try await session.createFolder(in: "", baseName: "名称未設定フォルダ", progress: Progress())
            XCTAssertEqual(result.addedPaths, [expected])
        }
        let occupied = try Fixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('名称未設定フォルダ', b'file')\n z.writestr('名称未設定フォルダ 2/hidden', b'child')\n z.writestr('名称未設定フォルダ 3/', b'')")
        let other = try ArchiveSession(url: occupied.archive)
        let result = try await other.createFolder(in: "", baseName: "名称未設定フォルダ", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["名称未設定フォルダ 4/"])
    }

    @MainActor func testNewFolderInVirtualParentDoesNotInventAncestorRecords() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = await session.entries()
        let result = try await session.createFolder(in: "virtual/deeper", baseName: "名称未設定フォルダ", progress: Progress())
        let after = await session.entries()
        XCTAssertEqual(result.addedPaths, ["virtual/deeper/名称未設定フォルダ/"])
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertFalse(after.contains { $0.name == "virtual/" || $0.name == "virtual/deeper/" })
    }

    @MainActor func testNewFolderCapturesAtPublishAndHasOneUndoRedoEntryWithFullSHA256() async throws {
        let fixture = try Fixture(), before = try digest(fixture.archive), archive = fixture.archive
        let captures = Mutex(0), publications = Mutex(0)
        let stack = ArchiveUndoStack { source, destination in
            captures.withLock { $0 += 1 }
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let document = try document(fixture, stack: stack)
        _ = try await document.createFolder(in: "", progress: Progress(), willPublish: {
            XCTAssertEqual(captures.withLock { $0 }, 1)
            XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: archive))), before)
            publications.withLock { $0 += 1 }
        })
        XCTAssertEqual(publications.withLock { $0 }, 1)
        XCTAssertEqual(captures.withLock { $0 }, 1)
        XCTAssertEqual(stack.slots.count, 1)
        XCTAssertEqual(try digest(XCTUnwrap(stack.slots.first).url), before)
        XCTAssertEqual(document.undoManager?.undoActionName, String(localized: "新規フォルダ"))
        let after = try digest(fixture.archive)
        XCTAssertNotEqual(after, before)
        try await undo(document)
        XCTAssertEqual(try digest(fixture.archive), before)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        try await redo(document)
        XCTAssertEqual(try digest(fixture.archive), after)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
    }

    @MainActor func testNewFolderCancellationAtPublishDiscardsUndoAndLeavesBytesUnchanged() async throws {
        let fixture = try Fixture(), document = try document(fixture), before = try digest(fixture.archive)
        let progress = Progress()
        do {
            _ = try await document.createFolder(in: "", progress: progress, willPublish: { progress.cancel() })
            XCTFail("取消し後にフォルダを公開しました")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try digest(fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testNewFolderValidatesNamesAndParentsBeforeOpeningUpdater() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive), before = try digest(fixture.archive)
        let opened = Mutex(0)
        for name in ["", ".", "..", "a/b", "a\\b", "a:b", "bad\0name", String(repeating: "x", count: 65535)] {
            do {
                _ = try await session.createFolder(in: "folder", baseName: name, progress: Progress(),
                                                   willOpenUpdater: { opened.withLock { $0 += 1 } })
                XCTFail("不正な名称を受理しました")
            } catch { guard case .invalidName = error as? ArchiveEditError else { return XCTFail("\(error)") } }
        }
        for parent in ["missing", "keep.txt"] {
            do {
                _ = try await session.createFolder(in: parent, progress: Progress(),
                                                   willOpenUpdater: { opened.withLock { $0 += 1 } })
                XCTFail("存在しない親フォルダを受理しました")
            } catch { XCTAssertEqual(error as? ArchiveEditError, .staleSelection) }
        }
        XCTAssertEqual(opened.withLock { $0 }, 0)
        XCTAssertEqual(try digest(fixture.archive), before)
        let result = try await session.createFolder(in: "", baseName: "cafe\u{301}", progress: Progress(),
                                                    willOpenUpdater: { opened.withLock { $0 += 1 } })
        XCTAssertEqual(opened.withLock { $0 }, 1)
        XCTAssertTrue(try XCTUnwrap(result.addedPaths.first).utf8.elementsEqual("café/".utf8))
    }

    @MainActor func testNewFolderReadOnlyRefusalPrecedesUpdaterAndExposesReason() async throws {
        let cases: [(String, String, Bool)] = [
            ("archive.tar.lzma", "with tarfile.open(p, 'w') as t:\n i=tarfile.TarInfo('old'); i.size=1; t.addfile(i, io.BytesIO(b'x'))\nimport lzma; raw=open(p,'rb').read(); open(p,'wb').write(lzma.compress(raw,format=lzma.FORMAT_ALONE))", false),
            ("archive.zip", "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('old', b'x')\nwith open(p, 'ab') as f: f.write(b'trailing')", false),
            ("archive.zip", "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('old', b'x')", true)
        ]
        for (filename, script, readOnlyMode) in cases {
            let fixture = try Fixture(filename: filename, script: script)
            if readOnlyMode { XCTAssertEqual(chmod(fixture.archive.path, 0o444), 0) }
            let session = try ArchiveSession(url: fixture.archive)
            let before = try digest(fixture.archive), opened = Mutex(0)
            let reason = try XCTUnwrap(session.capabilities.readOnlyReason)
            XCTAssertFalse(reason.isEmpty)
            do {
                _ = try await session.createFolder(in: "", progress: Progress(),
                                                   willOpenUpdater: { opened.withLock { $0 += 1 } })
                XCTFail("読み取り専用の書庫を変更しました")
            } catch {
                guard case .refused(let message) = error as? ExtractionFailure else { return XCTFail("\(error)") }
                XCTAssertEqual(message, reason)
            }
            XCTAssertEqual(opened.withLock { $0 }, 0)
            XCTAssertEqual(try digest(fixture.archive), before)
            XCTAssertEqual(session.generation, 0)
        }
    }

    @MainActor func testNewFolderRejectsStaleArchiveBeforePublication() async throws {
        let fixture = try Fixture(), document = try document(fixture), session = try XCTUnwrap(document.session)
        let writer = try ArchiveUpdater.open(url: fixture.archive)
        try writer.addDirectory("externally-added/")
        try writer.commit()
        let before = try digest(fixture.archive), published = Mutex(0)
        do {
            _ = try await document.createFolder(in: "", progress: Progress(), willPublish: { published.withLock { $0 += 1 } })
            XCTFail("古い一覧で作成先を決めました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .archiveChanged) }
        XCTAssertEqual(published.withLock { $0 }, 0)
        XCTAssertEqual(try digest(fixture.archive), before)
        XCTAssertEqual(session.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
    }

    private func moveFixture(realDirectory: Bool = false, extra: [String] = [], tar: Bool = false) throws -> Fixture {
        let names = (realDirectory ? ["a/"] : []) + ["a/x.txt", "a/y.txt", "b/", "c/deep/z.txt", "root.txt"] + extra
        // JSONSerialization は既定で / を \/ に逃がし、Python がそのまま名前に取り込む。
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: names, options: [.withoutEscapingSlashes]), as: UTF8.self)
        return try Fixture(filename: tar ? "archive.tar" : "archive.zip", script: """
        names = \(encoded)
        if p.endswith('.tar'):
            with tarfile.open(p, 'w', format=tarfile.USTAR_FORMAT) as a:
                for name in names:
                    item = tarfile.TarInfo(name)
                    if name.endswith('/'):
                        item.type = tarfile.DIRTYPE
                        a.addfile(item)
                    else:
                        data = name.encode() + b'\\x00payload'
                        item.size = len(data)
                        a.addfile(item, io.BytesIO(data))
        else:
            with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as a:
                for name in names:
                    a.writestr(name, b'' if name.endswith('/') else name.encode() + b'\\x00payload')
        """)
    }

    @MainActor private func moveSelection(_ path: String, entries: [ArchiveEntry]) throws -> ArchiveEditSelection {
        let root = EntryNode.tree(from: entries)
        let node = try XCTUnwrap(ArchiveViewState(selectedPaths: [path], expandedPaths: [], topPath: nil).resolve(in: root).selected.first)
        return ArchiveEditSelection(node)
    }

    @MainActor private func assertMoveRefusal(_ fixture: Fixture, removing: [ArchiveEditSelection] = [],
                                              renaming: [ArchiveEditRename] = [], moving: [ArchiveEditMove],
                                              expected: ArchiveEditError, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try Data(contentsOf: fixture.archive), entries = try ArchiveReader.open(url: fixture.archive).entries
        XCTAssertThrowsError(try ArchiveEditPlan.build(removing: removing, renaming: renaming, moving: moving, existing: entries),
                             file: file, line: line) {
            XCTAssertEqual($0 as? ArchiveEditError, expected, file: file, line: line)
            XCTAssertFalse($0.localizedDescription.isEmpty, file: file, line: line)
        }
        let session = try ArchiveSession(url: fixture.archive), opened = Mutex(0), published = Mutex(0)
        do {
            _ = try await session.edit(removing: removing, renaming: renaming, moving: moving, progress: Progress(),
                willOpenUpdater: { opened.withLock { $0 += 1 } }, willPublish: { published.withLock { $0 += 1 } })
            XCTFail("拒否する移動を公開しました", file: file, line: line)
        } catch { XCTAssertEqual(error as? ArchiveEditError, expected, file: file, line: line) }
        XCTAssertEqual(opened.withLock { $0 }, 0, file: file, line: line)
        XCTAssertEqual(published.withLock { $0 }, 0, file: file, line: line)
        XCTAssertEqual(session.generation, 0, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before, file: file, line: line)
    }

    @MainActor func testMovePlanMapsFilesRealAndVirtualSubtreesAndVirtualDestinations() throws {
        for realDirectory in [false, true] {
            let fixture = try moveFixture(realDirectory: realDirectory)
            let entries = try ArchiveReader.open(url: fixture.archive).entries
            let cases: [(String, String, [String: String])] = [
                ("a/x.txt", "b", ["a/x.txt": "b/x.txt"]),
                ("a", "b", realDirectory
                    ? ["a/": "b/a/", "a/x.txt": "b/a/x.txt", "a/y.txt": "b/a/y.txt"]
                    : ["a/x.txt": "b/a/x.txt", "a/y.txt": "b/a/y.txt"]),
                ("root.txt", "c/deep", ["root.txt": "c/deep/root.txt"]),
                ("a/x.txt", "", ["a/x.txt": "x.txt"])
            ]
            for (source, folder, expected) in cases {
                let selection = try moveSelection(source, entries: entries)
                let plan = try ArchiveEditPlan.build(removing: [], renaming: [],
                    moving: [.init(selection: selection, folder: folder)], existing: entries)
                XCTAssertTrue(plan.removals.isEmpty)
                XCTAssertEqual(plan.renames.count, expected.count)
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: plan.renames.map { ($0.entry.expectedName, $0.path) }), expected)
                try plan.verifyNames(entries.map(\.name))
            }
        }
    }

    @MainActor func testMoveRefusesSameLocationOwnSubtreesAndMissingOrFileDestinationsAtomically() async throws {
        let fixture = try moveFixture(), entries = try ArchiveReader.open(url: fixture.archive).entries
        let cases: [(String, String, ArchiveEditError)] = [
            ("a/x.txt", "a", .sameLocation("a/x.txt")),
            ("a/x.txt", "a/", .sameLocation("a/x.txt")),
            ("root.txt", "", .sameLocation("root.txt")),
            ("a", "a", .destinationInsideSource("a")),
            ("a", "a/sub", .destinationInsideSource("a")),
            ("a/x.txt", "nope", .missingFolder("nope")),
            ("a/x.txt", "root.txt", .missingFolder("root.txt"))
        ]
        for (source, folder, expected) in cases {
            try await assertMoveRefusal(fixture, moving: [.init(selection: moveSelection(source, entries: entries), folder: folder)],
                                        expected: expected)
        }
        // 同名の子があっても、ファイル自身やその下を移動先フォルダとは認めない。
        let malformed = try moveFixture(extra: ["root.txt/sub/child.txt"])
        let malformedEntries = try ArchiveReader.open(url: malformed.archive).entries
        for folder in ["root.txt", "root.txt/sub"] {
            try await assertMoveRefusal(malformed,
                moving: [.init(selection: moveSelection("a/x.txt", entries: malformedEntries), folder: folder)],
                expected: .missingFolder(folder))
        }
    }

    @MainActor func testMoveRefusesExistingVirtualAndBatchNameCollisionsAtomically() async throws {
        let cases: [([String], [String], String)] = [
            (["b/x.txt"], ["c/deep/z.txt", "a/x.txt"], "b/x.txt"),
            (["c/x.txt"], ["a/x.txt", "c/x.txt"], "b/x.txt"),
            (["b/a/hidden.txt"], ["a"], "b/a"),
            (["a/café.txt", "b/cafe\u{301}.txt"], ["a/café.txt"], "b/café.txt")
        ]
        for (extra, sources, collision) in cases {
            let fixture = try moveFixture(extra: extra), entries = try ArchiveReader.open(url: fixture.archive).entries
            let moves = try sources.map { ArchiveEditMove(selection: try moveSelection($0, entries: entries), folder: "b") }
            try await assertMoveRefusal(fixture, moving: moves, expected: .collision(collision))
        }
    }

    @MainActor func testMoveRefusesConflictingRenameRemovalAndOverlappingSelections() async throws {
        let fixture = try moveFixture(), entries = try ArchiveReader.open(url: fixture.archive).entries
        let file = try moveSelection("a/x.txt", entries: entries), folder = try moveSelection("a", entries: entries)
        let move = ArchiveEditMove(selection: file, folder: "b")
        try await assertMoveRefusal(fixture, removing: [file], moving: [move], expected: .conflictingSelection)
        try await assertMoveRefusal(fixture, renaming: [.init(selection: file, name: "new.txt")],
                                    moving: [move], expected: .conflictingSelection)
        try await assertMoveRefusal(fixture, renaming: [.init(selection: folder, name: "new")],
                                    moving: [move], expected: .conflictingSelection)
        try await assertMoveRefusal(fixture, moving: [.init(selection: folder, folder: "b"), move], expected: .conflictingSelection)
    }

    @MainActor func testMoveUsesCanonicalEquivalenceForParentsSubtreesAndDescendants() async throws {
        let fixture = try moveFixture(extra: ["café/one.txt", "cafe\u{301}/deep/two.txt", "desté/"])
        let entries = try ArchiveReader.open(url: fixture.archive).entries
        let source = try moveSelection("café", entries: entries)
        let plan = try ArchiveEditPlan.build(removing: [], renaming: [],
            moving: [.init(selection: source, folder: "deste\u{301}/")], existing: entries)
        let paths = plan.renames.map(\.path).sorted()
        XCTAssertEqual(paths, ["desté/café/deep/two.txt", "desté/café/one.txt"])
        XCTAssertTrue(paths.allSatisfy { $0.utf8.elementsEqual($0.precomposedStringWithCanonicalMapping.utf8) })
        try await assertMoveRefusal(fixture,
            moving: [.init(selection: moveSelection("café/one.txt", entries: entries), folder: "cafe\u{301}/")],
            expected: .sameLocation("café/one.txt"))
        try await assertMoveRefusal(fixture, moving: [.init(selection: source, folder: "cafe\u{301}/missing")],
                                    expected: .destinationInsideSource(source.path))
    }

    private func moveContents(_ url: URL) throws -> [String: Data] {
        let reader = try ArchiveReader.open(url: url)
        var contents: [String: Data] = [:]
        for entry in reader.entries {
            var bytes = Data()
            if entry.kind != .directory {
                try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
            }
            contents[entry.name] = bytes
        }
        return contents
    }

    @MainActor private func assertDocumentMoveUndoRedo(tar: Bool) async throws {
        let fixture = try moveFixture(realDirectory: true, tar: tar), document = try document(fixture)
        let session = try XCTUnwrap(document.session), before = try digest(fixture.archive), contents = try moveContents(fixture.archive)
        XCTAssertEqual(session.capabilities.mode, tar ? .rewrite(.tar) : .inPlace)
        let folder = try await node("a", in: session), file = try await node("root.txt", in: session), published = Mutex(0)
        let result = try await document.move([folder, file], to: "b", progress: Progress(), willPublish: { published.withLock { $0 += 1 } })
        XCTAssertTrue(result.published)
        XCTAssertNil(result.reloadFailure)
        XCTAssertTrue(result.removedPaths.isEmpty)
        XCTAssertEqual(Set(result.renamedPaths), ["b/a/", "b/a/x.txt", "b/a/y.txt", "b/root.txt"])
        let expected = Dictionary(uniqueKeysWithValues: contents.map { name, bytes in
            (name.hasPrefix("a/") || name == "root.txt" ? "b/" + name : name, bytes)
        })
        XCTAssertEqual(try moveContents(fixture.archive), expected)
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(published.withLock { $0 }, 1)
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
        let manager = try XCTUnwrap(document.undoManager)
        XCTAssertEqual(manager.undoActionName, String(localized: "移動"))
        XCTAssertTrue(manager.undoMenuItemTitle.contains(String(localized: "移動")))
        let after = try digest(fixture.archive)
        XCTAssertNotEqual(after, before)
        try await undo(document)
        XCTAssertEqual(try digest(fixture.archive), before)
        XCTAssertEqual(try moveContents(fixture.archive), contents)
        XCTAssertFalse(manager.canUndo)
        try await redo(document)
        XCTAssertEqual(try digest(fixture.archive), after)
        XCTAssertEqual(try moveContents(fixture.archive), expected)
        XCTAssertFalse(manager.canRedo)
    }

    @MainActor func testZIPDocumentMovePublishesIdenticalContentsAndOneMoveUndoRedoStep() async throws {
        try await assertDocumentMoveUndoRedo(tar: false)
    }

    @MainActor func testTarDocumentMovePublishesIdenticalContentsAndOneMoveUndoRedoStep() async throws {
        try await assertDocumentMoveUndoRedo(tar: true)
    }

    @MainActor func testMoveRejectsStaleSubtreesAndUpdaterNamesWithoutPublishing() async throws {
        let fixture = try moveFixture(), session = try ArchiveSession(url: fixture.archive)
        let selection = ArchiveEditSelection(try await node("a", in: session))
        let added = fixture.root.appendingPathComponent("new.txt")
        try Data("new child".utf8).write(to: added)
        _ = try await session.append(urls: [added], to: "a", progress: Progress())
        let before = try digest(fixture.archive), opened = Mutex(0)
        do {
            _ = try await session.edit(moving: [.init(selection: selection, folder: "b")], progress: Progress(),
                                       willOpenUpdater: { opened.withLock { $0 += 1 } })
            XCTFail("古い部分木だけを移動しました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .staleSelection) }
        XCTAssertEqual(opened.withLock { $0 }, 0)
        XCTAssertEqual(try digest(fixture.archive), before)
        XCTAssertEqual(session.generation, 1)

        let replaced = try moveFixture(), document = try document(replaced), current = try XCTUnwrap(document.session)
        let node = try await node("a/x.txt", in: current)
        let updater = try ArchiveUpdater.open(url: replaced.archive)
        try updater.addDirectory("externally-added/")
        try updater.commit()
        let replacedBytes = try digest(replaced.archive), published = Mutex(0)
        do {
            _ = try await document.move([node], to: "b", progress: Progress(), willPublish: { published.withLock { $0 += 1 } })
            XCTFail("古い一覧で移動を公開しました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .archiveChanged) }
        XCTAssertEqual(try digest(replaced.archive), replacedBytes)
        XCTAssertEqual(published.withLock { $0 }, 0)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testMoveCancellationAtPublishLeavesArchiveAndUndoUnchanged() async throws {
        for tar in [false, true] {
            let fixture = try moveFixture(tar: tar), document = try document(fixture), before = try digest(fixture.archive)
            let selected = try await node("a", in: XCTUnwrap(document.session)), progress = Progress()
            do {
                _ = try await document.move([selected], to: "b", progress: progress, willPublish: { progress.cancel() })
                XCTFail("取り消した移動を公開しました")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(try digest(fixture.archive), before)
            XCTAssertEqual(document.generation, 0)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        }
    }

    @MainActor func testReadOnlyArchiveRefusesMoveBeforeOpeningUpdater() async throws {
        let fixture = try Fixture(filename: "archive.tar.lzma", script: """
        with tarfile.open(p, 'w') as t:
            i = tarfile.TarInfo('a/x.txt'); i.size = 1; t.addfile(i, io.BytesIO(b'x'))
        import lzma; raw=open(p,'rb').read(); open(p,'wb').write(lzma.compress(raw,format=lzma.FORMAT_ALONE))
        """)
        let session = try ArchiveSession(url: fixture.archive), before = try digest(fixture.archive), opened = Mutex(0)
        let selected = ArchiveEditSelection(try await node("a/x.txt", in: session))
        do {
            _ = try await session.edit(moving: [.init(selection: selected, folder: "")], progress: Progress(),
                                       willOpenUpdater: { opened.withLock { $0 += 1 } })
            XCTFail("読み取り専用の書庫を移動で変更しました")
        } catch {
            guard case .refused(let reason) = error as? ExtractionFailure else { return XCTFail("\(error)") }
            XCTAssertEqual(reason, session.capabilities.readOnlyReason)
        }
        XCTAssertEqual(opened.withLock { $0 }, 0)
        XCTAssertEqual(try digest(fixture.archive), before)
        XCTAssertEqual(session.generation, 0)
    }
}
