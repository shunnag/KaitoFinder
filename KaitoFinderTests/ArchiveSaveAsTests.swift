import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveSaveAsTests: XCTestCase {
    @MainActor private func interface(encrypted: Bool = false, gzip: Bool = false, readOnly: Bool = false) async throws
        -> (ArchiveTestDirectory, ArchiveDocument, ArchiveWindowController, ArchivePreferencesStore) {
        preserveArchiveWindowFrame()
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent(readOnly ? "original.tar.bz2" : (gzip ? "original.tgz" : "original.zip"))
        if readOnly {
            try Data("read-only contents".utf8).write(to: directory.url.appendingPathComponent("file.txt"))
            try directory.run("/usr/bin/tar", ["-cjf", archive.path, "file.txt"])
        } else if encrypted {
            try Data("decrypted contents".utf8).write(to: directory.url.appendingPathComponent("secret.txt"))
            try directory.run("/usr/bin/zip", ["-q", "-P", "known-password", archive.path, "secret.txt"])
        } else {
            let writer = try ArchiveWriter.create(url: archive, format: gzip ? .tarGzip : .zip)
            try writer.add(data: Data("original contents".utf8), as: "folder/file.txt")
            try writer.add(data: Data("hidden contents".utf8), as: "folder/.hidden")
            try writer.finish()
        }
        // undo の機能検証を、テスト用ボリュームの clonefile 対応から独立させる。
        let stack = ArchiveUndoStack(clone: { source, destination in
            do { try FileManager.default.copyItem(at: source, to: destination); return 0 }
            catch { return EIO }
        })
        let document = ArchiveDocument(undoStack: stack, preferencesStore: store)
        let type = readOnly ? "public.bzip2-archive" : (gzip ? "org.gnu.gnu-zip-archive" : "public.zip-archive")
        try document.read(from: archive, ofType: type)
        document.fileURL = archive
        document.fileType = type
        let controller = ArchiveWindowController(preferencesStore: store)
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session)
        let snapshot = await session.snapshot()
        controller.display(EntryNode.tree(from: snapshot.entries), session: session,
                           materializationController: document.materializationController())
        addTeardownBlock { @MainActor in
            document.close()
            await document.sessionCleanup?.value
            await document.materializationCleanup?.value
            await document.undoCleanup?.value
            withExtendedLifetime((suite, directory)) {}
        }
        return (directory, document, controller, store)
    }

    private func contents(_ archive: URL) throws -> [String: Data] {
        let reader = try ArchiveReader.open(url: archive)
        var result: [String: Data] = [:]
        for entry in reader.entries {
            XCTAssertFalse(entry.isEncrypted)
            guard entry.kind == .file else { continue }
            var bytes = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
            result[entry.name] = bytes
        }
        return result
    }

    @MainActor private func assertConversion(gzip: Bool, format: GyoshukuKit.ArchiveFormat) async throws {
        let (directory, document, controller, store) = try await interface(gzip: gzip)
        _ = try await document.createFolder(in: "", baseName: "before-save", progress: Progress())
        XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
        let source = try XCTUnwrap(document.fileURL), original = try Data(contentsOf: source)
        let expected = try contents(source), oldSession = try XCTUnwrap(document.session)
        let oldStack = document.archiveUndoStack
        let oldMaterialization = document.materializationController()
        let oldThumbnails = controller.thumbnailProvider
        let oldTitle = controller.window?.title
        let destination = directory.url.appendingPathComponent("saved." + ArchiveCreationPlan.filenameExtension(for: format))
        let creator = ArchiveCreationController(store: store)
        creator.destinationHandler = { save, parent in
            XCTAssertTrue(parent === controller.window)
            XCTAssertEqual(save.panel.nameFieldStringValue, "original.zip")
            let index = try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: format))
            save.formatPopup.selectItem(at: index)
            save.changeFormat(save.formatPopup)
            XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(ArchiveWindowController.saveArchiveAs(_:)), keyEquivalent: "")))
            return destination
        }
        try await controller.saveArchiveAs(using: creator)
        XCTAssertEqual(document.fileURL, destination)
        XCTAssertEqual(document.fileType, ArchiveSavePanelController.contentType(for: format).identifier)
        XCTAssertEqual(controller.window?.representedURL, destination)
        XCTAssertEqual(controller.window?.title, document.displayName)
        XCTAssertNotEqual(controller.window?.title, oldTitle)
        let session = try XCTUnwrap(document.session)
        XCTAssertFalse(session === oldSession)
        XCTAssertEqual(session.sourceURL, destination)
        XCTAssertEqual(session.format, format == .zip ? KaitoKit.ArchiveFormat.zip : .sevenZip)
        XCTAssertEqual(session.capabilities.mode, format == .zip ? .inPlace : .rewrite(.sevenZip))
        XCTAssertTrue(session.capabilities.canAppend)
        let oldSnapshot = await oldSession.snapshot()
        XCTAssertTrue(oldSnapshot.entries.isEmpty)
        let password = await session.password
        XCTAssertNil(password)
        XCTAssertFalse(document.materializationController() === oldMaterialization)
        XCTAssertFalse(controller.thumbnailProvider === oldThumbnails)
        XCTAssertTrue(oldStack.slots.isEmpty)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canRedo)
        XCTAssertTrue(NSDocumentController.shared.recentDocumentURLs.contains {
            $0.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath()
        })
        XCTAssertEqual(try contents(destination), expected)
        XCTAssertEqual(try Data(contentsOf: source), original)
        // 新しい identity と設定クロージャ、空の undo stack は以降の編集にも使える。
        store.preferences.zipMethod = .stored
        XCTAssertEqual(session.writerOptions(.zip).compressionMethod, .stored)
        _ = try await document.createFolder(in: "", baseName: "after-save", progress: Progress())
        XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertFalse(try ArchiveReader.open(url: destination).entries.contains { $0.name.hasPrefix("after-save") })
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNil(creator.savePanel)
        XCTAssertNil(creator.progressSheet)
        XCTAssertNil(controller.creationController)
    }

    @MainActor func testZIPToSevenZipSwitchesBackingFileAndKeepsOriginalBytes() async throws {
        try await assertConversion(gzip: false, format: .sevenZip)
    }

    @MainActor func testTGZToZIPSwitchesBackingFileAndKeepsOriginalBytes() async throws {
        try await assertConversion(gzip: true, format: .zip)
    }

    @MainActor func testEncryptedZIPUsesKnownPasswordAndSwitchesToDecryptedOutput() async throws {
        let (directory, document, controller, store) = try await interface(encrypted: true)
        let source = try XCTUnwrap(document.fileURL), original = try Data(contentsOf: source)
        let session = try XCTUnwrap(document.session)
        session.setPasswordPrompt { _ in "known-password" }
        _ = try await session.preparedPassword()
        session.setPasswordPrompt { _ in XCTFail("Known password must be reused"); throw CancellationError() }
        let destination = directory.url.appendingPathComponent("decrypted.7z")
        let creator = ArchiveCreationController(store: store)
        creator.destinationHandler = { save, _ in
            save.formatPopup.selectItem(at: 3)
            save.changeFormat(save.formatPopup)
            return destination
        }
        try await controller.saveArchiveAs(using: creator)
        XCTAssertEqual(document.fileURL, destination)
        XCTAssertEqual(try contents(destination), ["secret.txt": Data("decrypted contents".utf8)])
        let password = await document.session?.password
        XCTAssertNil(password)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(try XCTUnwrap(document.session).capabilities.canAppend)
    }

    @MainActor func testSameFileAndAliasesAreRefusedWithoutChangingDocument() async throws {
        let (directory, document, controller, store) = try await interface()
        _ = try await document.createFolder(in: "", baseName: "undo-kept", progress: Progress())
        let source = try XCTUnwrap(document.fileURL), before = try Data(contentsOf: source)
        let session = document.session, type = document.fileType, title = controller.window?.title
        let history = document.archiveUndoStack.slots.map(\.id)
        let symlink = directory.url.appendingPathComponent("symlink.zip"), hardlink = directory.url.appendingPathComponent("hardlink.zip")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        try FileManager.default.linkItem(at: source, to: hardlink)
        for destination in [source, symlink, hardlink] {
            let creator = ArchiveCreationController(store: store)
            creator.destinationHandler = { _, _ in destination }
            do {
                try await controller.saveArchiveAs(using: creator)
                XCTFail("Saving over the source must be refused")
            } catch {
                XCTAssertEqual(ArchiveErrorText.describe(error), String(localized: "元のアーカイブとは別の保存先を選んでください。"))
            }
            XCTAssertEqual(document.fileURL, source)
            XCTAssertEqual(document.fileType, type)
            XCTAssertEqual(controller.window?.title, title)
            XCTAssertTrue(document.session === session)
            XCTAssertEqual(document.archiveUndoStack.slots.map(\.id), history)
            XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
            XCTAssertEqual(try Data(contentsOf: source), before)
            XCTAssertNil(creator.progressSheet)
        }
    }

    @MainActor func testCancellingSavePanelLeavesDocumentAndOriginalUnchanged() async throws {
        let (_, document, controller, store) = try await interface()
        let source = try XCTUnwrap(document.fileURL), before = try Data(contentsOf: source), session = document.session
        let creator = ArchiveCreationController(store: store)
        creator.destinationHandler = { _, _ in nil }
        try await controller.saveArchiveAs(using: creator)
        XCTAssertEqual(document.fileURL, source)
        XCTAssertTrue(document.session === session)
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertNil(creator.savePanel)
        XCTAssertNil(creator.progressSheet)
    }

    @MainActor func testSaveAsMenuPlacementShortcutAndValidation() async throws {
        let (_, document, controller, _) = try await interface(readOnly: true)
        let menu = AppDelegate().makeMenu()
        let file = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == String(localized: "ファイル") })
        let item = try XCTUnwrap(file.items.first { $0.action == #selector(ArchiveWindowController.saveArchiveAs(_:)) })
        XCTAssertEqual(item.title, String(localized: "別名で保存…"))
        XCTAssertEqual(item.keyEquivalent.lowercased(), "s")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertNil(item.target)
        XCTAssertEqual(file.items[file.index(of: item) - 1].action, #selector(NSWindow.performClose(_:)))
        XCTAssertFalse(try XCTUnwrap(document.session).capabilities.canAppend)
        XCTAssertTrue(controller.validateMenuItem(item))
        (document.undoManager as? ArchiveUndoManager)?.isSuspended = true
        XCTAssertFalse(controller.validateMenuItem(item))
        (document.undoManager as? ArchiveUndoManager)?.isSuspended = false
        controller.displayLocked()
        XCTAssertFalse(controller.validateMenuItem(item))
        let empty = ArchiveWindowController()
        defer { empty.close() }
        XCTAssertFalse(empty.validateMenuItem(item))
        XCTAssertFalse(try XCTUnwrap(controller.outlineView.blankAreaMenu).items.contains { $0.action == item.action })
    }

    @MainActor func testReadOnlyTarBzip2CanSaveAsEditableZIP() async throws {
        let (directory, document, controller, store) = try await interface(readOnly: true)
        let source = try XCTUnwrap(document.fileURL), before = try Data(contentsOf: source)
        XCTAssertFalse(try XCTUnwrap(document.session).capabilities.canAppend)
        let destination = directory.url.appendingPathComponent("editable.zip")
        let creator = ArchiveCreationController(store: store)
        creator.destinationHandler = { _, _ in destination }
        try await controller.saveArchiveAs(using: creator)
        XCTAssertEqual(document.fileURL, destination)
        XCTAssertEqual(document.fileType, "public.zip-archive")
        XCTAssertEqual(try XCTUnwrap(document.session).capabilities.mode, .inPlace)
        XCTAssertEqual(try contents(destination), ["file.txt": Data("read-only contents".utf8)])
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    @MainActor func testCommittedOutputStillBecomesBackingFileAfterLateCancellation() async throws {
        let (directory, document, _, _) = try await interface()
        let source = try XCTUnwrap(document.fileURL)
        let destination = directory.url.appendingPathComponent("committed.zip")
        try FileManager.default.copyItem(at: source, to: destination)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await document.switchBackingFile(to: destination)
        }
        try await task.value
        XCTAssertEqual(document.fileURL, destination)
        XCTAssertEqual(document.session?.sourceURL, destination)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: destination))
    }
}
