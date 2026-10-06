import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable public import KaitoFinder

/// 移動の公開と取り消し・やり直し、拒否条件を確かめる（12 テスト）。
nonisolated final class ArchiveMoveEditTests: XCTestCase, EditTestSupport {
    private func moveFixture(realDirectory: Bool = false, extra: [String] = [], tar: Bool = false) throws -> EditTestFixture {
        let names = (realDirectory ? ["a/"] : []) + ["a/x.txt", "a/y.txt", "b/", "c/deep/z.txt", "root.txt"] + extra
        // JSONSerialization は既定で / を \/ に逃がし、Python がそのまま名前に取り込む。
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: names, options: [.withoutEscapingSlashes]), as: UTF8.self)
        return try EditTestFixture(filename: tar ? "archive.tar" : "archive.zip", script: """
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

    @MainActor private func assertMoveRefusal(_ fixture: EditTestFixture, removing: [ArchiveEditSelection] = [],
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

    @MainActor func testMoveWithResolverRefusesOwnDirectoryAndSubtreeAtomically() async throws {
        let fixture = try moveFixture(extra: ["dir/sub/child.txt"]), session = try ArchiveSession(url: fixture.archive)
        let dirSelection = ArchiveEditSelection(try await node("dir", in: session))
        let before = try Data(contentsOf: fixture.archive)
        var conflicts = 0
        for folder in ["dir", "dir/sub"] {
            do {
                _ = try await session.move([dirSelection], to: folder, progress: Progress(), resolveConflict: { _ in
                    conflicts += 1
                    return .init(choice: .replace)
                })
                XCTFail("自分自身や子孫への移動を受け入れました")
            } catch { XCTAssertEqual(error as? ArchiveEditError, .destinationInsideSource("dir")) }
        }
        XCTAssertEqual(conflicts, 0)
        XCTAssertEqual(session.generation, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    @MainActor func testMoveWithResolverSkipsSameLocationEvenForStaleSelection() async throws {
        let fixture = try moveFixture(extra: ["dir/file.txt"]), session = try ArchiveSession(url: fixture.archive)
        let selection = ArchiveEditSelection(try await node("dir/file.txt", in: session))
        let stale = ArchiveEditSelection(path: selection.path, isDirectory: selection.isDirectory,
            entries: selection.entries.map { $0.pendingCopy(name: "dir/stale.txt") })
        let before = try Data(contentsOf: fixture.archive)
        var conflicts = 0
        for selection in [selection, stale] {
            let result = try await session.move([selection], to: "dir", progress: Progress(), resolveConflict: { _ in
                conflicts += 1
                return .init(choice: .replace)
            })
            XCTAssertTrue(result.removedPaths.isEmpty)
            XCTAssertTrue(result.renamedPaths.isEmpty)
            XCTAssertFalse(result.published)
            XCTAssertNil(result.reloadFailure)
        }
        XCTAssertEqual(conflicts, 0)
        XCTAssertEqual(session.generation, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
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
        let session = try XCTUnwrap(document.session), before = try ArchiveOracle.digest(fixture.archive), contents = try moveContents(fixture.archive)
        XCTAssertEqual(session.capabilities.mode, tar ? .update(.tar) : .inPlace)
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
        let after = try ArchiveOracle.digest(fixture.archive)
        XCTAssertNotEqual(after, before)
        try await undo(document)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertEqual(try moveContents(fixture.archive), contents)
        XCTAssertFalse(manager.canUndo)
        try await redo(document)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), after)
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
        let before = try ArchiveOracle.digest(fixture.archive), opened = Mutex(0)
        do {
            _ = try await session.edit(moving: [.init(selection: selection, folder: "b")], progress: Progress(),
                                       willOpenUpdater: { opened.withLock { $0 += 1 } })
            XCTFail("古い部分木だけを移動しました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .staleSelection) }
        XCTAssertEqual(opened.withLock { $0 }, 0)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertEqual(session.generation, 1)

        let replaced = try moveFixture(), document = try document(replaced), current = try XCTUnwrap(document.session)
        let node = try await node("a/x.txt", in: current)
        let updater = try ArchiveUpdater.open(url: replaced.archive)
        try updater.addDirectory("externally-added/")
        try updater.commit()
        let replacedBytes = try ArchiveOracle.digest(replaced.archive), published = Mutex(0)
        do {
            _ = try await document.move([node], to: "b", progress: Progress(), willPublish: { published.withLock { $0 += 1 } })
            XCTFail("古い一覧で移動を公開しました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .archiveChanged) }
        XCTAssertEqual(try ArchiveOracle.digest(replaced.archive), replacedBytes)
        XCTAssertEqual(published.withLock { $0 }, 0)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testMoveCancellationAtPublishLeavesArchiveAndUndoUnchanged() async throws {
        for tar in [false, true] {
            let fixture = try moveFixture(tar: tar), document = try document(fixture), before = try ArchiveOracle.digest(fixture.archive)
            let selected = try await node("a", in: XCTUnwrap(document.session)), progress = Progress()
            do {
                _ = try await document.move([selected], to: "b", progress: progress, willPublish: { progress.cancel() })
                XCTFail("取り消した移動を公開しました")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
            XCTAssertEqual(document.generation, 0)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        }
    }

    @MainActor func testReadOnlyArchiveRefusesMoveBeforeOpeningUpdater() async throws {
        let fixture = try EditTestFixture(filename: "archive.tar.zst", script: """
        with tarfile.open(p, 'w') as t:
            i = tarfile.TarInfo('a/x.txt'); i.size = 1; t.addfile(i, io.BytesIO(b'x'))
        import struct; raw=open(p,'rb').read(); open(p,'wb').write(bytes.fromhex('28b52ffda0') + struct.pack('<I',len(raw)) + struct.pack('<I',(len(raw)<<3)|1)[:3] + raw)
        """)
        let session = try ArchiveSession(url: fixture.archive), before = try ArchiveOracle.digest(fixture.archive), opened = Mutex(0)
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
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertEqual(session.generation, 0)
    }
}
