import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveSaveAsTests: XCTestCase {
    @MainActor private func interface(encrypted: Bool = false, gzip: Bool = false, readOnly: Bool = false) async throws
        -> (ArchiveTestDirectory, ArchiveDocument, ArchiveWindowController, ArchivePreferencesStore) {
        preserveArchiveWindowFrame()
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent(readOnly ? "original.tar.lzma" : (gzip ? "original.tgz" : "original.zip"))
        if readOnly {
            try Data("read-only contents".utf8).write(to: directory.url.appendingPathComponent("file.txt"))
            try directory.run("/usr/bin/tar", ["-cf", archive.path, "file.txt"])
            try directory.run("/usr/bin/python3", ["-c", "import sys; p=sys.argv[1]; import lzma; raw=open(p,'rb').read(); open(p,'wb').write(lzma.compress(raw,format=lzma.FORMAT_ALONE))", archive.path])
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
        let type = readOnly ? "public.data" : (gzip ? "org.gnu.gnu-zip-archive" : "public.zip-archive")
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
        XCTAssertTrue(session.capabilities.canEdit)
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

    @MainActor func testSaveAsKeepsAcceptedPromiseAliveUntilDelayedWriteCompletes() async throws {
        let (directory, document, _, _) = try await interface()
        let oldSession = try XCTUnwrap(document.session)
        let original = try Data(contentsOf: oldSession.sourceURL)
        let entries = await oldSession.entries()
        let entry = try XCTUnwrap(entries.first { $0.name == "folder/file.txt" })
        let payload = ArchiveEntryPayload(archiveURL: oldSession.sourceURL, generation: oldSession.generation,
            entryIndex: entry.index, path: entry.name, isDirectory: false)
        let registry = FilePromiseRegistry.shared
        let promise = try registry.register(payload: payload, session: oldSession)
        registry.began(sessionID: 902, promises: [promise.id])
        registry.ended(sessionID: 902)
        defer { registry.sweep(now: Date().addingTimeInterval(registry.gracePeriod + 1)) }
        let delegate = try XCTUnwrap(promise.provider.delegate as? ArchiveFilePromise)
        let destination = directory.url.appendingPathComponent("saved.7z")
        let writer = try ArchiveWriter.create(url: destination, format: .sevenZip)
        try writer.add(data: Data("original contents".utf8), as: entry.name)
        try writer.finish()

        try await document.switchBackingFile(to: destination)
        XCTAssertFalse(document.session === oldSession)
        XCTAssertEqual(document.session?.format, .sevenZip)
        let retained = await oldSession.snapshot()
        XCTAssertFalse(retained.entries.isEmpty)
        let output = directory.url.appendingPathComponent("promised.txt")
        let calls = Mutex(0), failure = Mutex<(any Error)?>(nil)
        delegate.filePromiseProvider(promise.provider, writePromiseTo: output) { @Sendable error in
            failure.withLock { $0 = error }
            calls.withLock { $0 += 1 }
        }
        try await scenarioWait { calls.withLock { $0 } == 1 }
        await document.sessionCleanup?.value
        XCTAssertNil(failure.withLock { $0 })
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(try Data(contentsOf: output), Data("original contents".utf8))
        let closed = await oldSession.snapshot()
        XCTAssertTrue(closed.entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: oldSession.sourceURL), original)
    }

    @MainActor func testDocumentCloseAfterSaveAsCancelsRetainedPromiseWithoutWaitingForExpiry() async throws {
        let (directory, document, _, _) = try await interface()
        let oldSession = try XCTUnwrap(document.session)
        let payload = ArchiveEntryPayload(archiveURL: oldSession.sourceURL, generation: oldSession.generation,
            entryIndex: nil, path: "folder/file.txt", isDirectory: false)
        let registry = FilePromiseRegistry.shared
        let promise = try registry.register(payload: payload, session: oldSession)
        defer { registry.sweep(now: Date().addingTimeInterval(registry.gracePeriod + 1)) }
        let delegate = try XCTUnwrap(promise.provider.delegate as? ArchiveFilePromise)
        let destination = directory.url.appendingPathComponent("saved.7z")
        let writer = try ArchiveWriter.create(url: destination, format: .sevenZip)
        try writer.add(data: Data("original contents".utf8), as: payload.path)
        try writer.finish()
        try await document.switchBackingFile(to: destination)
        let newSession = try XCTUnwrap(document.session)
        document.close()
        let cleanup = document.sessionCleanup
        var finished = false
        let wait = Task { await cleanup?.value; finished = true }
        try await scenarioWait { finished }
        await wait.value
        let oldSnapshot = await oldSession.snapshot(), newSnapshot = await newSession.snapshot()
        XCTAssertTrue(oldSnapshot.entries.isEmpty)
        XCTAssertTrue(newSnapshot.entries.isEmpty)
        let output = directory.url.appendingPathComponent("cancelled.txt")
        let calls = Mutex(0), failure = Mutex<(any Error)?>(nil)
        delegate.filePromiseProvider(promise.provider, writePromiseTo: output) { @Sendable error in
            failure.withLock { $0 = error }
            calls.withLock { $0 += 1 }
        }
        try await scenarioWait { calls.withLock { $0 } == 1 }
        XCTAssertTrue(failure.withLock { $0 } is CancellationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor func testEncryptedZIPCanExplicitlyDisableProtectionInSaveAs() async throws {
        let (directory, document, controller, store) = try await interface(encrypted: true)
        let source = try XCTUnwrap(document.fileURL), original = try Data(contentsOf: source)
        let session = try XCTUnwrap(document.session)
        session.setPasswordPrompt { _ in "known-password" }
        _ = try await session.preparedPassword()
        session.setPasswordPrompt { _ in XCTFail("Known password must be reused"); throw CancellationError() }
        let destination = directory.url.appendingPathComponent("decrypted.7z")
        let creator = ArchiveCreationController(store: store)
        creator.destinationHandler = { save, _ in
            XCTAssertEqual(save.encryptionCheckbox.state, .on)
            XCTAssertTrue(save.passwordFields.passwordField.stringValue == "known-password")
            XCTAssertTrue(save.passwordFields.verifyField.stringValue == "known-password")
            save.formatPopup.selectItem(at: try XCTUnwrap(ArchivePreferences.formats.firstIndex(of: .sevenZip)))
            save.changeFormat(save.formatPopup)
            save.encryptionCheckbox.state = .off
            save.changeEncryption(save.encryptionCheckbox)
            return destination
        }
        try await controller.saveArchiveAs(using: creator)
        XCTAssertEqual(document.fileURL, destination)
        XCTAssertEqual(try contents(destination), ["secret.txt": Data("decrypted contents".utf8)])
        let password = await document.session?.password
        XCTAssertNil(password)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertTrue(try XCTUnwrap(document.session).capabilities.canEdit)
    }

    @MainActor func testEncryptedSaveAsDefaultsToProtectedCopyAndReopensWithOutputPassword() async throws {
        let (directory, document, controller, store) = try await interface(encrypted: true)
        let source = try XCTUnwrap(document.fileURL), original = try Data(contentsOf: source)
        let session = try XCTUnwrap(document.session)
        session.setPasswordPrompt { _ in "known-password" }
        let destination = directory.url.appendingPathComponent("protected.7z")
        let creator = ArchiveCreationController(store: store)
        creator.destinationHandler = { save, _ in
            XCTAssertEqual(save.encryptionCheckbox.state, .on)
            XCTAssertTrue(save.passwordFields.passwordField.stringValue == "known-password")
            XCTAssertTrue(save.passwordFields.verifyField.stringValue == "known-password")
            save.formatPopup.selectItem(at: try XCTUnwrap(ArchivePreferences.formats.firstIndex(of: .sevenZip)))
            save.changeFormat(save.formatPopup)
            save.passwordFields.headersCheckbox.state = .on
            return destination
        }
        try await controller.saveArchiveAs(using: creator)
        XCTAssertEqual(document.fileURL, destination)
        let copiedSession = try XCTUnwrap(document.session)
        XCTAssertTrue(copiedSession.hasKnownPassword)
        XCTAssertTrue(copiedSession.hasEncryptedEntries)
        XCTAssertEqual(copiedSession.capabilities.mode, .rewrite(.sevenZip))
        XCTAssertThrowsError(try ArchiveReader.open(url: destination))
        let reader = try ArchiveReader.open(url: destination, options: ReaderOptions(password: "known-password"))
        let entry = try XCTUnwrap(reader.entries.first)
        XCTAssertTrue(entry.isEncrypted)
        var bytes = Data()
        try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
        XCTAssertEqual(bytes, Data("decrypted contents".utf8))
        XCTAssertEqual(try Data(contentsOf: source), original)
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

    @MainActor func testSaveAsRefusesArchiveReplacedWhileChoosingDestination() async throws {
        let (directory, document, controller, store) = try await interface()
        _ = try await document.createFolder(in: "", baseName: "undo-kept", progress: Progress())
        let source = try XCTUnwrap(document.fileURL), session = try XCTUnwrap(document.session)
        let stack = document.archiveUndoStack, history = stack.slots.map(\.id)
        let undoManager = try XCTUnwrap(document.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        let destination = directory.url.appendingPathComponent("saved.zip")
        let replacement = directory.url.appendingPathComponent("replacement.zip")
        let creator = ArchiveCreationController(store: store)
        creator.destinationHandler = { _, _ in
            let writer = try ArchiveWriter.create(url: replacement, format: .zip)
            try writer.add(data: Data("replacement contents".utf8), as: "folder/file.txt")
            try writer.add(data: Data("replacement hidden contents".utf8), as: "folder/.hidden")
            try writer.addDirectory("undo-kept")
            try writer.finish()
            guard rename(replacement.path, source.path) == 0 else { throw ExtractionFailure.system(errno) }
            return destination
        }
        do {
            try await controller.saveArchiveAs(using: creator)
            XCTFail("Saving a replaced archive must be refused")
        } catch {
            guard case ExtractionFailure.refused(let reason) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(reason, String(localized: "処理中にアーカイブが別の操作で変更されました。"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(document.fileURL, source)
        XCTAssertTrue(document.session === session)
        XCTAssertTrue(document.archiveUndoStack === stack)
        XCTAssertEqual(stack.slots.map(\.id), history)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertFalse(undoManager.canRedo)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
            .contains { $0.hasPrefix(".KaitoFinder-new-") || $0.hasPrefix(".gyoshuku-rewrite-") })
        XCTAssertNil(creator.savePanel)
        XCTAssertNil(creator.progressSheet)
        XCTAssertNil(controller.creationController)
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
        preserveApplicationMenus()
        let (_, document, controller, _) = try await interface(readOnly: true)
        let menu = AppDelegate().makeMenu()
        let file = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == String(localized: "ファイル") })
        let item = try XCTUnwrap(file.items.first { $0.action == #selector(ArchiveWindowController.saveArchiveAs(_:)) })
        XCTAssertEqual(item.title, String(localized: "別名で保存…"))
        XCTAssertEqual(item.keyEquivalent.lowercased(), "s")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertNil(item.target)
        XCTAssertEqual(file.items[file.index(of: item) - 1].action, #selector(NSWindow.performClose(_:)))
        XCTAssertFalse(try XCTUnwrap(document.session).capabilities.canEdit)
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
        XCTAssertFalse(try XCTUnwrap(document.session).capabilities.canEdit)
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
        try await assertLateCancellationKeepsCommittedOutput(gzip: false)
    }

    // 圧縮 tar は KaitoKit が一時展開の途中で Task の取消しを検査する（K2）。公開後の再オープンは
    // 取消し済み Task でも成功しなければならない。
    @MainActor func testCommittedCompressedTarStillBecomesBackingFileAfterLateCancellation() async throws {
        try await assertLateCancellationKeepsCommittedOutput(gzip: true)
    }

    @MainActor private func assertLateCancellationKeepsCommittedOutput(gzip: Bool) async throws {
        let (directory, document, _, _) = try await interface(gzip: gzip)
        let source = try XCTUnwrap(document.fileURL)
        let destination = directory.url.appendingPathComponent(gzip ? "committed.tgz" : "committed.zip")
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
