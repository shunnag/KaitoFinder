import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable public import KaitoFinder

/// 新規フォルダの公開と取り消し・やり直しを確かめる（8 テスト）。
nonisolated final class ArchiveNewFolderEditTests: XCTestCase, EditTestSupport {
    @MainActor func testNewFolderAddsExactlyOneDirectoryAndPreservesEveryExistingRecord() async throws {
        let fixture = try EditTestFixture(), session = try ArchiveSession(url: fixture.archive)
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
        XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 1)
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        XCTAssertTrue(try fixture.directory.run(ExternalTool.unzip, ["-t", fixture.archive.path]).contains("No errors detected"))
    }

    @MainActor func testNewFolderCollisionNumbersIncludeFilesAndVirtualFolders() async throws {
        let fixture = try EditTestFixture(), session = try ArchiveSession(url: fixture.archive)
        for expected in ["名称未設定フォルダ/", "名称未設定フォルダ 2/", "名称未設定フォルダ 3/"] {
            let result = try await session.createFolder(in: "", baseName: "名称未設定フォルダ", progress: Progress())
            XCTAssertEqual(result.addedPaths, [expected])
        }
        let occupied = try EditTestFixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('名称未設定フォルダ', b'file')\n z.writestr('名称未設定フォルダ 2/hidden', b'child')\n z.writestr('名称未設定フォルダ 3/', b'')")
        let other = try ArchiveSession(url: occupied.archive)
        let result = try await other.createFolder(in: "", baseName: "名称未設定フォルダ", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["名称未設定フォルダ 4/"])
    }

    @MainActor func testNewFolderInVirtualParentDoesNotInventAncestorRecords() async throws {
        let fixture = try EditTestFixture(), session = try ArchiveSession(url: fixture.archive)
        let before = await session.entries()
        let result = try await session.createFolder(in: "virtual/deeper", baseName: "名称未設定フォルダ", progress: Progress())
        let after = await session.entries()
        XCTAssertEqual(result.addedPaths, ["virtual/deeper/名称未設定フォルダ/"])
        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertFalse(after.contains { $0.name == "virtual/" || $0.name == "virtual/deeper/" })
    }

    @MainActor func testNewFolderCapturesAtPublishAndHasOneUndoRedoEntryWithFullSHA256() async throws {
        let fixture = try EditTestFixture(), before = try ArchiveOracle.digest(fixture.archive), archive = fixture.archive
        let captures = Mutex(0), publications = Mutex(0)
        let stack = ArchiveUndoStack { source, destination in
            captures.withLock { $0 += 1 }
            return ArchiveUndoStack.cloneFile(from: source, to: destination)
        }
        let document = try document(fixture, stack: stack)
        _ = try await document.createFolder(in: "", progress: Progress(), willPublish: {
            XCTAssertEqual(captures.withLock { $0 }, 1)
            XCTAssertEqual(try ArchiveOracle.digest(archive), before)
            publications.withLock { $0 += 1 }
        })
        XCTAssertEqual(publications.withLock { $0 }, 1)
        XCTAssertEqual(captures.withLock { $0 }, 1)
        XCTAssertEqual(stack.slots.count, 1)
        XCTAssertEqual(try ArchiveOracle.digest(XCTUnwrap(stack.slots.first).url), before)
        XCTAssertEqual(document.undoManager?.undoActionName, String(localized: "新規フォルダ"))
        let after = try ArchiveOracle.digest(fixture.archive)
        XCTAssertNotEqual(after, before)
        try await undo(document)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        try await redo(document)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), after)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
    }

    @MainActor func testNewFolderCancellationAtPublishDiscardsUndoAndLeavesBytesUnchanged() async throws {
        let fixture = try EditTestFixture(), document = try document(fixture), before = try ArchiveOracle.digest(fixture.archive)
        let progress = Progress()
        do {
            _ = try await document.createFolder(in: "", progress: progress, willPublish: { progress.cancel() })
            XCTFail("取消し後にフォルダを公開しました")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testNewFolderValidatesNamesAndParentsBeforeOpeningUpdater() async throws {
        let fixture = try EditTestFixture(), session = try ArchiveSession(url: fixture.archive), before = try ArchiveOracle.digest(fixture.archive)
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
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
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
            let fixture = try EditTestFixture(filename: filename, script: script)
            if readOnlyMode { XCTAssertEqual(chmod(fixture.archive.path, 0o444), 0) }
            let session = try ArchiveSession(url: fixture.archive)
            let before = try ArchiveOracle.digest(fixture.archive), opened = Mutex(0)
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
            XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
            XCTAssertEqual(session.generation, 0)
        }
    }

    @MainActor func testNewFolderRejectsStaleArchiveBeforePublication() async throws {
        let fixture = try EditTestFixture(), document = try document(fixture), session = try XCTUnwrap(document.session)
        let writer = try ArchiveUpdater.open(url: fixture.archive)
        try writer.addDirectory("externally-added/")
        try writer.commit()
        let before = try ArchiveOracle.digest(fixture.archive), published = Mutex(0)
        do {
            _ = try await document.createFolder(in: "", progress: Progress(), willPublish: { published.withLock { $0 += 1 } })
            XCTFail("古い一覧で作成先を決めました")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .archiveChanged) }
        XCTAssertEqual(published.withLock { $0 }, 0)
        XCTAssertEqual(try ArchiveOracle.digest(fixture.archive), before)
        XCTAssertEqual(session.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
    }
}
