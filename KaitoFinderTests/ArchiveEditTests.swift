import AppKit
import CryptoKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveEditTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let archive: URL

        init(script: String = #"""
        with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            for name, data in [('keep.txt', b'keep\x00bytes'), ('remove.txt', b'remove me'),
                               ('folder/', b''), ('folder/a.txt', b'alpha'), ('folder/deep/', b''),
                               ('folder/deep/b.bin', bytes(range(256))*4), ('virtual/a.txt', b'virtual a'),
                               ('virtual/deeper/b.txt', b'virtual b'), ('folderish/keep.txt', b'outside')]:
                z.writestr(name, data)
        """#) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("KaitoFinder-EditTests-" + UUID().uuidString)
            archive = root.appendingPathComponent("archive.zip")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.run("/usr/bin/python3", ["-c", "import sys, zipfile, tarfile, io, struct, zlib\np=sys.argv[1]\n" + script, archive.path])
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult static func run(_ tool: String, _ arguments: [String], allowed: [Int32] = [0]) throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(allowed.contains(process.terminationStatus), text)
            return text
        }
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
            XCTAssertThrowsError(try ArchiveEditTransaction.run(plan: plan, archive: fixture.archive, progress: progress,
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
        XCTAssertThrowsError(try ArchiveEditTransaction.run(plan: plan, archive: fixture.archive, progress: Progress())) {
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
                } catch { XCTAssertEqual(error as? ArchiveEditError, .staleSelection) }
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
        XCTAssertFalse(document.isDocumentEdited)
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
        for script in ["with tarfile.open(p, 'w') as t:\n i=tarfile.TarInfo('old'); i.size=1; t.addfile(i, io.BytesIO(b'x'))",
                       "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('old', b'x')\nwith open(p, 'ab') as f: f.write(b'trailing')"] {
            let fixture = try Fixture(script: script), session = try ArchiveSession(url: fixture.archive)
            let original = try digest(fixture.archive), opened = Mutex(0)
            XCTAssertFalse(session.capabilities.canAppend)
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
}
