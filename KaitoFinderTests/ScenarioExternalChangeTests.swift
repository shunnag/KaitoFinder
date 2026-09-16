import AppKit
import Darwin
import Foundation
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioExternalChangeTests: XCTestCase {
    @MainActor func testLastUsedDateXattrAfterOpeningDoesNotInvalidateTheSession() async throws {
        let fixture = try ScenarioFixture(), (document, _) = try await scenarioDocument(fixture)
        let session = try XCTUnwrap(document.session), generation = document.generation
        let identity = try ArchiveImportTransaction.identity(fixture.archive)
        var before = stat(), after = stat()
        XCTAssertEqual(lstat(fixture.archive.path, &before), 0)
        let bytes = [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(bytes.withUnsafeBytes {
            setxattr(fixture.archive.path, "com.apple.lastuseddate#PS", $0.baseAddress, 16, 0, 0)
        }, 0)
        XCTAssertEqual(lstat(fixture.archive.path, &after), 0)
        XCTAssertNotEqual([before.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec],
                          [after.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec])
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertEqual(try ArchiveImportTransaction.identity(fixture.archive), identity)

        _ = try await session.extractionSnapshot()
        let result = try await document.createFolder(in: "", progress: Progress())
        XCTAssertEqual(result.addedPaths.count, 1)
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(document.generation, generation + 1)
        XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testMtimeChangeRefusesSessionReadsAndEdits() async throws {
        let fixture = try ScenarioFixture(), (document, _) = try await scenarioDocument(fixture)
        let session = try XCTUnwrap(document.session)
        let identity = try ArchiveImportTransaction.identity(fixture.archive), digest = try ScenarioFixture.digest(fixture.archive)
        var before = stat(), after = stat()
        XCTAssertEqual(lstat(fixture.archive.path, &before), 0)
        let times = [timeval(tv_sec: before.st_atimespec.tv_sec, tv_usec: 0),
                     timeval(tv_sec: before.st_mtimespec.tv_sec + 60, tv_usec: 0)]
        XCTAssertEqual(times.withUnsafeBufferPointer { utimes(fixture.archive.path, $0.baseAddress) }, 0)
        XCTAssertEqual(lstat(fixture.archive.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertNotEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertNotEqual(try ArchiveImportTransaction.identity(fixture.archive), identity)
        for extracting in [true, false] {
            do {
                if extracting { _ = try await session.extractionSnapshot() }
                else { _ = try await document.createFolder(in: "", progress: Progress()) }
                XCTFail("更新日時が変わった原本への操作を受理しました")
            } catch { XCTAssertEqual(error as? ArchiveEditError, .archiveChanged) }
        }
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), digest)
        XCTAssertEqual(document.generation, 0)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testReplacementWithIdenticalNamesRefusesEveryEditAndPreservesUndo() async throws {
        for operation in 0..<4 {
            let fixture = try ScenarioFixture(), (document, controller) = try await scenarioDocument(fixture)
            let node = try XCTUnwrap(controller.outlineView.item(atRow: 0) as? EntryNode)
            let replacement = try fixture.pythonArchive("replacement.zip", script: "with zipfile.ZipFile(p, 'w') as z: z.writestr('original.txt', b'replaced')")
            XCTAssertEqual(Darwin.rename(replacement.path, fixture.archive.path), 0)
            let before = try ScenarioFixture.digest(fixture.archive), source = try fixture.file("new.txt")
            do {
                switch operation {
                case 0: _ = try await document.append(urls: [source], to: "", progress: Progress())
                case 1: _ = try await document.createFolder(in: "", progress: Progress())
                case 2: _ = try await document.remove([node], progress: Progress())
                default: _ = try await document.rename(node, to: "renamed.txt", progress: Progress())
                }
                XCTFail("差し替え前の内容に対する編集を公開しました")
            } catch {
                XCTAssertEqual(error as? ArchiveEditError, .archiveChanged)
                XCTAssertEqual(error.localizedDescription, String(localized: "アーカイブが変更されています。開き直してください。"))
            }
            XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
            XCTAssertEqual(document.generation, 0)
        }
    }

    @MainActor private func assertReplacementRefusesRestore(redo: Bool) async throws {
        let fixture = try ScenarioFixture(), (document, controller) = try await scenarioDocument(fixture)
        let result = try await document.createFolder(in: "", baseName: "added", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["added/"])
        XCTAssertNil(result.reloadFailure)
        let manager = try XCTUnwrap(document.undoManager)
        XCTAssertTrue(manager.canUndo)
        XCTAssertEqual(document.archiveUndoStack.slots.count, 1)
        // 失敗は undoFailure で検証し、NSDocument のエラーシートは表示しない。
        document.removeWindowController(controller)
        defer { document.addWindowController(controller) }
        if redo {
            document.undo(nil)
            let task = try XCTUnwrap(document.undoTask)
            await task.value
            XCTAssertNil(document.undoFailure)
            XCTAssertTrue(manager.canRedo)
        }
        let generation = document.generation, slots = document.archiveUndoStack.slots
        let slotDigests = try slots.map { try ScenarioFixture.digest($0.url) }
        let identity = try ArchiveImportTransaction.identity(fixture.archive)
        let replacement = try fixture.pythonArchive("replacement.zip", script:
            "with zipfile.ZipFile(p, 'w') as z: z.writestr('external.txt', b'external replacement')")
        XCTAssertEqual(Darwin.rename(replacement.path, fixture.archive.path), 0)
        XCTAssertNotEqual(try ArchiveImportTransaction.identity(fixture.archive)[1], identity[1])
        let externalDigest = try ScenarioFixture.digest(fixture.archive)

        if redo { document.redo(nil) } else { document.undo(nil) }
        let task = try XCTUnwrap(document.undoTask)
        await task.value

        XCTAssertEqual(document.undoFailure as? ArchiveEditError, .archiveChanged)
        let message = String(localized: "アーカイブが変更されています。開き直してください。")
        XCTAssertEqual(document.undoFailure?.localizedDescription, message)
        XCTAssertEqual(document.undoFailure.map { ArchiveErrorText.describe($0) }, message)
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), externalDigest)
        XCTAssertEqual(document.generation, generation)
        let retained = document.archiveUndoStack.slots
        XCTAssertEqual(retained.count, slots.count)
        XCTAssertEqual(retained.map(\.id), slots.map(\.id))
        XCTAssertEqual(retained.map(\.url), slots.map(\.url))
        XCTAssertEqual(retained.map(\.isRedo), slots.map(\.isRedo))
        XCTAssertEqual(try retained.map { try ScenarioFixture.digest($0.url) }, slotDigests)
        XCTAssertEqual(manager.canUndo, !redo)
        XCTAssertEqual(manager.canRedo, redo)
    }

    @MainActor func testUndoRefusesExternalReplacementAndPreservesHistory() async throws {
        try await assertReplacementRefusesRestore(redo: false)
    }

    @MainActor func testRedoRefusesExternalReplacementAndPreservesHistory() async throws {
        try await assertReplacementRefusesRestore(redo: true)
    }

    @MainActor func testDeletedSourceRefusesExtractionAndEditAndWindowCanReload() async throws {
        let fixture = try ScenarioFixture(), (document, controller) = try await scenarioDocument(fixture)
        let session = try XCTUnwrap(document.session), out = try fixture.folder("out")
        let original = try Data(contentsOf: fixture.archive)
        try FileManager.default.removeItem(at: fixture.archive)
        for extracting in [true, false] {
            do {
                if extracting { _ = try await fixture.extract(to: out, session: session) }
                else { _ = try await document.createFolder(in: "", progress: Progress()) }
                XCTFail("削除された原本への操作を受理しました")
            } catch {
                XCTAssertEqual(String(describing: error), String(localized: "アーカイブの原本を確認できません。"))
            }
        }
        XCTAssertTrue(try ScenarioFixture.files(under: out).isEmpty)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertNotNil(controller.window)
        controller.setFilterQuery("original")
        XCTAssertEqual(controller.outlineView.numberOfRows, 1)
        try original.write(to: fixture.archive)
        try await document.reloadAfterMutation()
        _ = try await document.createFolder(in: "", baseName: "recovered", progress: Progress())
        XCTAssertTrue(try ScenarioFixture.contents(fixture.archive).keys.contains("original.txt"))
        XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testReloadOfEncryptedReplacementUpdatesFormatAndReadOnlyCapability() async throws {
        let fixture = try ScenarioFixture(), (document, controller) = try await scenarioDocument(fixture)
        let source = try fixture.file("secret.txt"), replacement = fixture.root.appendingPathComponent("encrypted.7z")
        try fixture.directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-psecret", "-mhe=off", replacement.path, source.path])
        XCTAssertEqual(Darwin.rename(replacement.path, fixture.archive.path), 0)
        try await document.reloadAfterMutation()
        let session = try XCTUnwrap(document.session)
        XCTAssertEqual(session.format, .sevenZip)
        XCTAssertEqual(session.capabilities.refusal, .encrypted)
        XCTAssertEqual(controller.capabilityNotice.stringValue, session.capabilities.readOnlyReason)
        XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(controller.newFolder(_:)), keyEquivalent: "")))
        let entries = await session.entries()
        XCTAssertEqual(entries.map(\.name), ["secret.txt"])
        XCTAssertTrue(entries.allSatisfy(\.isEncrypted))
    }
}
