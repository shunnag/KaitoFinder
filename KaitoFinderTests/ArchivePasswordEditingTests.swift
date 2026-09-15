import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePasswordEditingTests: XCTestCase {
    private let entryName = "distinctive-password-entry-4591.txt"
    private let payload = Data("Contents carried through every password rewrite.".utf8)

    private func archive(in directory: ArchiveTestDirectory, format: GyoshukuKit.ArchiveFormat,
                         settings: ArchiveEncryptionSettings = .init()) throws -> URL {
        let url = directory.url.appendingPathComponent("original." + ArchiveCreationPlan.filenameExtension(for: format))
        let writer = try ArchiveWriter.create(url: url, format: format,
                                              options: settings.applying(to: WriterOptions(), format: format))
        try writer.add(data: payload, as: entryName)
        try writer.finish()
        return url
    }

    private func contents(_ url: URL, password: String? = nil) throws -> [String: Data] {
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
        var result: [String: Data] = [:]
        for entry in reader.entries where entry.kind == .file {
            var bytes = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
            result[entry.name] = bytes
        }
        return result
    }

    private func assertProtected(_ url: URL, password: String, rejectedPassword: String = "wrong",
                                 headers: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try contents(url, password: password), [entryName: payload], file: file, line: line)
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
        XCTAssertTrue(reader.entries.filter { $0.kind == .file }.allSatisfy(\.isEncrypted), file: file, line: line)
        XCTAssertThrowsError(try contents(url), file: file, line: line) {
            XCTAssertEqual(ArchivePasswordChallenge($0), .required, file: file, line: line)
        }
        XCTAssertThrowsError(try contents(url, password: rejectedPassword), file: file, line: line) {
            XCTAssertEqual(ArchivePasswordChallenge($0), .incorrect, file: file, line: line)
        }
        if headers {
            let bytes = try Data(contentsOf: url)
            XCTAssertNil(bytes.range(of: Data(entryName.utf8)), file: file, line: line)
            XCTAssertNil(bytes.range(of: try XCTUnwrap(entryName.data(using: .utf16LittleEndian))), file: file, line: line)
            XCTAssertThrowsError(try ArchiveReader.open(url: url), file: file, line: line)
        }
    }

    @MainActor private func document(at url: URL, directory: ArchiveTestDirectory, password: String? = nil) async throws
        -> (ArchiveDocument, ArchiveWindowController) {
        preserveArchiveWindowFrame()
        let stack = ArchiveUndoStack(clone: { source, destination in
            do { try FileManager.default.copyItem(at: source, to: destination); return 0 }
            catch { return EIO }
        })
        let document = ArchiveDocument(undoStack: stack)
        try document.read(from: url, ofType: "public.archive")
        document.fileURL = url
        if let password, document.isPasswordLocked { try await document.unlock(password: password) }
        if let session = document.session, let password {
            session.setPasswordPrompt { _ in password }
            _ = try await session.preparedPassword()
        }
        let controller = ArchiveWindowController()
        document.addWindowController(controller)
        if let session = document.session {
            controller.display(EntryNode.tree(from: await session.entries()), session: session,
                               materializationController: document.materializationController())
        } else { controller.displayLocked() }
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.sessionCleanup?.value
            await document.materializationCleanup?.value
            withExtendedLifetime(directory) {}
        }
        return (document, controller)
    }

    @MainActor private func lifecycle(format: GyoshukuKit.ArchiveFormat, headers: Bool) async throws {
        let directory = try ArchiveTestDirectory(), url = try archive(in: directory, format: format)
        let original = try Data(contentsOf: url)
        let quarantine = Data("0081;password-tests;KaitoFinder;".utf8)
        try ExtractionQuarantine.apply(quarantine, to: url)
        let (document, controller) = try await document(at: url, directory: directory)
        let session = try XCTUnwrap(document.session), undo = try XCTUnwrap(document.undoManager)
        let first = ArchiveEncryptionSettings(password: "first-key", encryptsSevenZipHeaders: headers)
        let result = try await document.updatePassword(.set, settings: first)
        XCTAssertNil(result.reloadFailure)
        try assertProtected(url, password: "first-key", headers: headers)
        XCTAssertEqual(try ExtractionQuarantine.read(from: url), quarantine)
        XCTAssertTrue(session.hasEncryptedEntries)
        XCTAssertTrue(session.hasKnownPassword)
        XCTAssertEqual(session.capabilities.mode, format == .zip ? .inPlace : .rewrite(.sevenZip))
        XCTAssertTrue(controller.capabilityNotice.isHidden || format == .sevenZip)
        XCTAssertEqual(undo.undoMenuItemTitle, String(localized: "パスワードの設定を取り消す"))
        let protectedBytes = try Data(contentsOf: url)
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(session.hasEncryptedEntries)
        let plainPassword = await session.password
        XCTAssertNil(plainPassword)
        document.redo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(try Data(contentsOf: url), protectedBytes)
        try assertProtected(url, password: "first-key", headers: headers)

        _ = try await document.updatePassword(.change,
            settings: .init(password: "second-key", zipEncryption: .zipCrypto, encryptsSevenZipHeaders: headers))
        try assertProtected(url, password: "second-key", rejectedPassword: "first-key", headers: headers)
        XCTAssertEqual(undo.undoMenuItemTitle, String(localized: "パスワードの変更を取り消す"))
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(try Data(contentsOf: url), protectedBytes)
        try assertProtected(url, password: "first-key", headers: headers)
        document.redo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        try assertProtected(url, password: "second-key", rejectedPassword: "first-key", headers: headers)

        _ = try await document.updatePassword(.remove, settings: .init())
        XCTAssertEqual(try contents(url), [entryName: payload])
        XCTAssertFalse(session.hasEncryptedEntries)
        XCTAssertEqual(undo.undoMenuItemTitle, String(localized: "パスワードの削除を取り消す"))
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        try assertProtected(url, password: "second-key", headers: headers)
        document.redo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(try contents(url), [entryName: payload])
        let removedPassword = await session.password
        XCTAssertNil(removedPassword)
    }

    @MainActor func testZIPSetChangeRemoveAndUndoRedo() async throws { try await lifecycle(format: .zip, headers: false) }
    @MainActor func testSevenZipSetChangeRemoveAndUndoRedo() async throws { try await lifecycle(format: .sevenZip, headers: false) }
    @MainActor func testSevenZipHeaderProtectionSetChangeRemoveAndUndoRedo() async throws {
        try await lifecycle(format: .sevenZip, headers: true)
    }

    func testPasswordOnlyPublishCommitsRewriterWithNoEdits() throws {
        let directory = try ArchiveTestDirectory(), url = try archive(in: directory, format: .zip)
        try ArchiveImportTransaction.publish(archive: url, mode: .rewrite(.zip),
            options: WriterOptions(password: "rewrite-key"), progress: Progress(), willPublish: nil) { rewriter in
            XCTAssertEqual(rewriter.entryNames, [entryName])
            // add / remove / rename を一度も呼ばず commit する。
        }
        try assertProtected(url, password: "rewrite-key")
    }

    func testNewArchiveCreationCarriesEncryptionAndValidatesProtectedHeaders() throws {
        let cases: [(GyoshukuKit.ArchiveFormat, ArchiveEncryptionSettings)] = [
            (.zip, .init(password: "creation-key")),
            (.zip, .init(password: "creation-key", zipEncryption: .zipCrypto)),
            (.sevenZip, .init(password: "creation-key")),
            (.sevenZip, .init(password: "creation-key", encryptsSevenZipHeaders: true))
        ]
        for (format, encryption) in cases {
            let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent(entryName)
            try payload.write(to: source)
            let output = directory.url.appendingPathComponent("created." + ArchiveCreationPlan.filenameExtension(for: format))
            let plan = ArchiveCreationPlan(sources: [source], destination: output, format: format,
                                           options: encryption.applying(to: WriterOptions(), format: format))
            XCTAssertEqual(try ArchiveCreationTransaction.run(plan: plan, progress: Progress()), output)
            try assertProtected(output, password: "creation-key", headers: encryption.encryptsSevenZipHeaders)
        }
    }

    @MainActor func testEncryptedConversionSwitchesDocumentUsingOutputPassword() async throws {
        let directory = try ArchiveTestDirectory()
        let source = try archive(in: directory, format: .zip, settings: .init(password: "source-key"))
        let original = try Data(contentsOf: source)
        let (document, _) = try await document(at: source, directory: directory, password: "source-key")
        let session = try XCTUnwrap(document.session)
        let existing = try await ArchiveCreationController.existingArchive(from: session, progress: Progress())
        let output = directory.url.appendingPathComponent("converted.7z")
        let plan = ArchiveCreationController().creationPlan(sources: [], destination: output, format: .sevenZip,
            existing: existing, encryption: .init(password: "output-key", encryptsSevenZipHeaders: true))
        _ = try ArchiveCreationTransaction.run(plan: plan, progress: Progress())
        try await document.switchBackingFile(to: output, password: plan.options.password)
        XCTAssertEqual(document.fileURL, output)
        XCTAssertEqual(document.session?.capabilities.mode, .rewrite(.sevenZip))
        XCTAssertTrue(try XCTUnwrap(document.session).hasKnownPassword)
        try assertProtected(output, password: "output-key", rejectedPassword: "source-key", headers: true)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testKnownAESAndZipCryptoZIPAppendPreservesExistingRecordAndEncryptsNewEntries() async throws {
        for method in [ZipEncryption.aes256, .zipCrypto] {
            let directory = try ArchiveTestDirectory()
            try payload.write(to: directory.url.appendingPathComponent(entryName))
            let url = directory.url.appendingPathComponent("fixture.zip")
            try directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-tzip", "-pfixture-key",
                method == .zipCrypto ? "-mem=ZipCrypto" : "-mem=AES256", url.path, entryName])
            let before = try ArchiveReader.open(url: url, options: ReaderOptions(password: "fixture-key"))
            let record = try XCTUnwrap(before.rawRecord(of: XCTUnwrap(before.entries.first)))
            let bytes = try Data(contentsOf: url).subdata(in: Int(record.recordRange.lowerBound)..<Int(record.recordRange.upperBound))
            let session = try ArchiveSession(url: url, password: "fixture-key")
            XCTAssertEqual(session.capabilities.mode, .inPlace)
            let added = directory.url.appendingPathComponent("added.txt")
            try Data("new encrypted contents".utf8).write(to: added)
            _ = try await session.append(urls: [added], to: "", progress: Progress())
            let after = try ArchiveReader.open(url: url, options: ReaderOptions(password: "fixture-key"))
            let original = try XCTUnwrap(after.entries.first { $0.name == entryName })
            let afterRecord = try XCTUnwrap(after.rawRecord(of: original))
            XCTAssertEqual(try Data(contentsOf: url).subdata(in: Int(afterRecord.recordRange.lowerBound)..<Int(afterRecord.recordRange.upperBound)), bytes)
            let new = try XCTUnwrap(after.entries.first { $0.name == "added.txt" })
            XCTAssertTrue(new.isEncrypted)
            XCTAssertEqual(new.formatSpecific["encryption"], method == .zipCrypto ? "ZipCrypto" : "AES-256")
            let tree = EntryNode.tree(from: await session.entries())
            let selected = try XCTUnwrap(tree.children.first { $0.path == "added.txt" })
            _ = try await session.rename(ArchiveEditSelection(selected), to: "renamed.txt", progress: Progress())
            XCTAssertEqual(try contents(url, password: "fixture-key")["renamed.txt"], Data("new encrypted contents".utf8))
            let renamedTree = EntryNode.tree(from: await session.entries())
            let renamed = try XCTUnwrap(renamedTree.children.first { $0.path == "renamed.txt" })
            _ = try await session.remove([ArchiveEditSelection(renamed)], progress: Progress())
            try assertProtected(url, password: "fixture-key")
            await session.close()
        }
    }

    func testKnownSevenZipAppendKeepsPasswordAndHeaderProtection() async throws {
        for headers in [false, true] {
            let directory = try ArchiveTestDirectory()
            try payload.write(to: directory.url.appendingPathComponent(entryName))
            let url = directory.url.appendingPathComponent("fixture.7z")
            try directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-t7z", "-pfixture-key",
                headers ? "-mhe=on" : "-mhe=off", url.path, entryName])
            let session = try ArchiveSession(url: url, password: "fixture-key")
            let added = directory.url.appendingPathComponent("added.txt")
            try payload.write(to: added)
            _ = try await session.append(urls: [added], to: "", progress: Progress())
            let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: "fixture-key"))
            XCTAssertEqual(reader.entries.count, 2)
            XCTAssertTrue(reader.entries.allSatisfy(\.isEncrypted))
            XCTAssertEqual(try contents(url, password: "fixture-key"), [entryName: payload, "added.txt": payload])
            if headers {
                XCTAssertThrowsError(try ArchiveReader.open(url: url))
                XCTAssertNil(try Data(contentsOf: url).range(of: XCTUnwrap(entryName.data(using: .utf16LittleEndian))))
            }
            let settings = await session.encryptionSettings()
            XCTAssertEqual(settings.encryptsSevenZipHeaders, headers)
            await session.close()
        }
    }

    @MainActor func testMenuPlacementAndValidationForPlainKnownUnknownLockedTarAndRAR() async throws {
        let delegate = AppDelegate(), menu = delegate.makeMenu()
        let file = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == String(localized: "ファイル") })
        let start = try XCTUnwrap(file.items.firstIndex { $0.action == #selector(ArchiveWindowController.saveArchiveAs(_:)) })
        let selectors = [#selector(ArchiveWindowController.setArchivePassword(_:)),
                         #selector(ArchiveWindowController.changeArchivePassword(_:)), #selector(ArchiveWindowController.removeArchivePassword(_:))]
        let items = Array(file.items[(start + 1)...(start + 3)])
        XCTAssertEqual(items.map(\.action), selectors.map(Optional.some))
        XCTAssertTrue(items.allSatisfy { $0.target == nil && !$0.isHidden })
        for format in [GyoshukuKit.ArchiveFormat.zip, .sevenZip, .tar, .lha] {
            let directory = try ArchiveTestDirectory(), url = try archive(in: directory, format: format)
            let (document, controller) = try await document(at: url, directory: directory)
            XCTAssertEqual(items.map(controller.validateMenuItem), [format == .zip || format == .sevenZip, false, false])
            if format == .tar || format == .lha {
                XCTAssertEqual(items[0].toolTip, String(localized: "この形式は暗号化できません。別名で保存で ZIP か 7z にしてください。"))
                continue
            }
            _ = try await document.updatePassword(.set, settings: .init(password: "menu-key"))
            XCTAssertEqual(items.map(controller.validateMenuItem), [false, true, true])
            (document.undoManager as? ArchiveUndoManager)?.isSuspended = true
            XCTAssertEqual(items.map(controller.validateMenuItem), [false, false, false])
            (document.undoManager as? ArchiveUndoManager)?.isSuspended = false
            let (_, unknown) = try await self.document(at: url, directory: directory)
            XCTAssertEqual(items.map(unknown.validateMenuItem), [false, false, false])
        }
        let lockedDirectory = try ArchiveTestDirectory()
        let lockedURL = try archive(in: lockedDirectory, format: .sevenZip,
            settings: .init(password: "locked-key", encryptsSevenZipHeaders: true))
        let (locked, lockedController) = try await document(at: lockedURL, directory: lockedDirectory)
        XCTAssertTrue(locked.isPasswordLocked)
        XCTAssertEqual(items.map(lockedController.validateMenuItem), [false, false, false])
        let rarDirectory = try ArchiveTestDirectory(), rar = rarDirectory.url.appendingPathComponent("empty.rar")
        try rarDirectory.run("/usr/bin/python3", ["-c", "import struct,zlib; h=lambda t,n: struct.pack('<H',zlib.crc32(t)&65535)+t; main=struct.pack('<BHHHI',0x73,0,13,0,0); end=struct.pack('<BHH',0x7b,0,7); open('empty.rar','wb').write(b'Rar!\\x1a\\x07\\x00'+h(main,0)+h(end,0))"])
        XCTAssertEqual(try ArchiveReader.open(url: rar).format, .rar)
        let (_, rarController) = try await document(at: rar, directory: rarDirectory)
        XCTAssertEqual(items.map(rarController.validateMenuItem), [false, false, false])
    }

    func testUnknownAndIncorrectPasswordsCannotPublishAnEdit() async throws {
        let directory = try ArchiveTestDirectory()
        let url = try archive(in: directory, format: .zip, settings: .init(password: "real-key"))
        let bytes = try Data(contentsOf: url)
        for password in [nil, "incorrect"] as [String?] {
            let session = try ArchiveSession(url: url, password: password)
            if password == nil {
                XCTAssertEqual(session.capabilities.refusal, .encrypted)
                XCTAssertEqual(session.capabilities.readOnlyReason, String(localized: "暗号化されたアーカイブを変更するにはパスワードが必要です。"))
            }
            do { _ = try await session.createFolder(in: "", progress: Progress()); XCTFail("An unverified password must not publish") }
            catch { XCTAssertEqual(try Data(contentsOf: url), bytes) }
            await session.close()
        }
    }

    @MainActor func testPasswordRewriteCancellationAndIdentityFailureKeepBytesPasswordAndUndo() async throws {
        let directory = try ArchiveTestDirectory(), url = try archive(in: directory, format: .zip)
        let original = try Data(contentsOf: url)
        let (document, _) = try await document(at: url, directory: directory)
        let progress = Progress()
        do {
            _ = try await document.updatePassword(.set, settings: .init(password: "unused"), progress: progress,
                                                  willPublish: { progress.cancel() })
            XCTFail("Cancelled rewrite must not publish")
        } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.session).hasKnownPassword)
        let replacement = directory.url.appendingPathComponent("replacement.zip")
        let writer = try ArchiveWriter.create(url: replacement, format: .zip)
        try writer.add(data: Data("external".utf8), as: "external.txt")
        try writer.finish()
        let external = try Data(contentsOf: replacement)
        do {
            _ = try await document.updatePassword(.set, settings: .init(password: "unused"), willPublish: {
                guard Darwin.rename(replacement.path, url.path) == 0 else { throw ExtractionFailure.system(errno) }
            })
            XCTFail("Concurrent replacement must not publish")
        } catch { XCTAssertEqual(try Data(contentsOf: url), external) }
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(try XCTUnwrap(document.session).hasKnownPassword)
    }
}
