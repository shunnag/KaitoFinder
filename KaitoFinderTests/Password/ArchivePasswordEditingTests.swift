import AppKit
import Darwin
@_spi(Testing) @testable import GyoshukuKit
@_spi(ZipRawLayout) import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

/// 書庫のパスワードの設定・変更・解除（ZIP・7z・7z の header 保護）と、既知のパスワードでの追加・変換を ArchiveSession・
/// ArchivePasswordVerification・ArchiveImportTransaction で確かめる（取り消し・やり直しを含む）。書庫は ExternalTool と
/// ArchiveReencryptionTestSupport で作る。観測点は bytesReadForTesting・willCommitUpdaterForTesting ほか。
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

    private func assertProtected(_ url: URL, password: String, rejectedPassword: String = "wrong",
                                 headers: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try ArchiveOracle.contents(url, password: password), [entryName: payload], file: file, line: line)
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
        XCTAssertTrue(reader.entries.filter { $0.kind == .file }.allSatisfy(\.isEncrypted), file: file, line: line)
        XCTAssertThrowsError(try ArchiveOracle.contents(url), file: file, line: line) {
            XCTAssertEqual(ArchivePasswordChallenge($0), .required, file: file, line: line)
        }
        XCTAssertThrowsError(try ArchiveOracle.contents(url, password: rejectedPassword), file: file, line: line) {
            XCTAssertEqual(ArchivePasswordChallenge($0), .incorrect, file: file, line: line)
        }
        if headers {
            let bytes = try Data(contentsOf: url)
            XCTAssertNil(bytes.range(of: Data(entryName.utf8)), file: file, line: line)
            XCTAssertNil(bytes.range(of: try XCTUnwrap(entryName.data(using: .utf16LittleEndian))), file: file, line: line)
            XCTAssertThrowsError(try ArchiveReader.open(url: url), file: file, line: line)
        }
    }

    private func selection(_ entry: ArchiveEntry) -> ArchiveEditSelection {
        .init(path: entry.name, isDirectory: entry.kind == .directory, entries: [entry])
    }

    func testImmediateAESMutationsRetainVerificationButExternalReloadDoesNot() async throws {
        let directory = try ArchiveTestDirectory(), url = directory.url.appendingPathComponent("verified.zip")
        let bytes = Data(repeating: 0x5a, count: 256 * 1024)
        var options = WriterOptions(); options.password = "known"
        let writer = try ArchiveWriter.create(url: url, options: options)
        for name in ["first", "second", "third"] { try writer.add(data: bytes, as: name) }
        try writer.finish()
        let session = try ArchiveSession(url: url, password: "known")
        let before = ArchivePasswordVerification.bytesReadForTesting.withLock { $0 }
        let entries1 = await session.entries()
        let first = try XCTUnwrap(entries1.first)
        _ = try await session.rename(selection(first), to: "renamed", progress: Progress())
        let verified = ArchivePasswordVerification.bytesReadForTesting.withLock { $0 }
        XCTAssertEqual(verified - before, UInt64(bytes.count * 3))
        let entries2 = await session.entries()
        let renamed = try XCTUnwrap(entries2.first)
        _ = try await session.rename(selection(renamed), to: "again", progress: Progress())
        let removals = await session.entries()
        _ = try await session.remove([selection(try XCTUnwrap(removals.first))], progress: Progress())
        let added = directory.url.appendingPathComponent("added")
        try bytes.write(to: added)
        _ = try await session.append(urls: [added], to: "", progress: Progress())
        _ = try await session.createFolder(in: "", progress: Progress())
        _ = try await session.updatePassword(.change, settings: .init(password: "new-key"), progress: Progress())
        let entries3 = await session.entries()
        let next = try XCTUnwrap(entries3.first)
        _ = try await session.rename(selection(next), to: "last", progress: Progress())
        XCTAssertEqual(ArchivePasswordVerification.bytesReadForTesting.withLock { $0 }, verified)

        let external = directory.url.appendingPathComponent("external.zip")
        try FileManager.default.copyItem(at: url, to: external)
        XCTAssertEqual(rename(external.path, url.path), 0)
        try await session.reloadAfterMutation()
        let entries4 = await session.entries()
        let externalEntry = try XCTUnwrap(entries4.first)
        _ = try await session.rename(selection(externalEntry), to: "external-rename", progress: Progress())
        XCTAssertEqual(ArchivePasswordVerification.bytesReadForTesting.withLock { $0 } - verified, UInt64(bytes.count * 3))
        await session.close()
    }

    func testPendingPublishRetainsVerificationUnlessReplacedBeforeReload() async throws {
        let directory = try ArchiveTestDirectory()
        let url = try archive(in: directory, format: .zip, settings: .init(password: "known"))
        let session = try ArchiveSession(url: url, password: "known")
        _ = try await session.preparedPassword()
        let before = ArchivePasswordVerification.bytesReadForTesting.withLock { $0 }
        for index in 0..<3 {
            let snapshot = await session.snapshot(), entry = try XCTUnwrap(snapshot.entries.first)
            var pending = ArchivePendingChanges()
            pending.renames[.init(index: entry.index, expectedName: entry.name, baseGeneration: snapshot.generation)] = "rename-\(index)"
            let replacement = directory.url.appendingPathComponent("replacement.zip")
            let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(),
                publication: ArchiveSavePublication(), willReload: {
                    if index == 2 {
                        try FileManager.default.copyItem(at: url, to: replacement)
                        guard rename(replacement.path, url.path) == 0 else { throw ExtractionFailure.system(errno) }
                    }
                })
            XCTAssertNil(result.reloadFailure)
            _ = try await session.preparedPassword()
            XCTAssertEqual(ArchivePasswordVerification.bytesReadForTesting.withLock { $0 } - before,
                           index == 2 ? UInt64(payload.count) : 0)
        }
        await session.close()
    }

    func testFailedReloadClearsVerificationEvenWhenSameBytesCanBeReopened() async throws {
        let directory = try ArchiveTestDirectory()
        let url = try archive(in: directory, format: .zip, settings: .init(password: "known"))
        let session = try ArchiveSession(url: url, password: "known")
        _ = try await session.preparedPassword()
        let before = ArchivePasswordVerification.bytesReadForTesting.withLock { $0 }
        do {
            try await session.reloadAfterMutation(willOpen: { throw CocoaError(.fileReadUnknown) })
            XCTFail("Expected reload failure")
        } catch { }
        XCTAssertNil(session.entryVerification)
        try await session.reloadAfterMutation()
        let entries5 = await session.entries()
        let entry = try XCTUnwrap(entries5.first)
        _ = try await session.rename(selection(entry), to: "after-failure", progress: Progress())
        XCTAssertEqual(ArchivePasswordVerification.bytesReadForTesting.withLock { $0 } - before, UInt64(payload.count))
        await session.close()
    }

    func testUndoDoesNotPromoteUnverifiedEncryptedEntries() async throws {
        let directory = try ArchiveTestDirectory(), url = directory.url.appendingPathComponent("partial.zip")
        var options = WriterOptions(); options.password = "known"
        let writer = try ArchiveWriter.create(url: url, options: options)
        for name in ["one", "two"] { try writer.add(data: payload, as: name) }
        try writer.finish()
        let session = try ArchiveSession(url: url, password: "known")
        let item = ArchiveEntryPayload(archiveURL: url, generation: 0, entryIndex: 0, path: "one", isDirectory: false)
        _ = try await session.resolveForExtraction([item])
        let stack = ArchiveUndoStack(clone: { source, destination in
            do { try FileManager.default.copyItem(at: source, to: destination); return 0 }
            catch { return EIO }
        })
        let encryption = await session.encryptionSettings()
        let slot = try XCTUnwrap(stack.capture(url, encryption: encryption, verification: session.entryVerification))
        XCTAssertEqual(slot.verification?.indices, [0])
        let entries = await session.entries()
        _ = try await session.rename(selection(try XCTUnwrap(entries.first)), to: "renamed", progress: Progress())
        stack.recordMutation(slot)
        let before = ArchivePasswordVerification.bytesReadForTesting.withLock { $0 }
        try await session.restoreUndoSlot(slot.id, from: stack)
        _ = try await session.preparedPassword()
        XCTAssertEqual(ArchivePasswordVerification.bytesReadForTesting.withLock { $0 } - before, UInt64(payload.count))
        await stack.dispose()
        await session.close()
    }

    @MainActor func testUndoRedoCarryOnlyVerifiedCapturedEncryptedEntries() async throws {
        let directory = try ArchiveTestDirectory()
        let url = try archive(in: directory, format: .zip, settings: .init(password: "known"))
        let (document, _) = try await document(at: url, directory: directory, password: "known")
        let session = try XCTUnwrap(document.session)
        let before = ArchivePasswordVerification.bytesReadForTesting.withLock { $0 }
        _ = try await document.createFolder(in: "", baseName: "added-folder", progress: Progress())
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        _ = try await session.preparedPassword()
        document.redo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        _ = try await session.preparedPassword()
        XCTAssertEqual(ArchivePasswordVerification.bytesReadForTesting.withLock { $0 }, before)
    }

    @MainActor private func document(at url: URL, directory: ArchiveTestDirectory, password: String? = nil) async throws
        -> (ArchiveDocument, ArchiveWindowController) {
        let stack = ArchiveUndoStack(clone: { source, destination in
            do { try FileManager.default.copyItem(at: source, to: destination); return 0 }
            catch { return EIO }
        })
        let document = ArchiveDocument(undoStack: stack)
        try document.read(from: url, ofType: "public.archive")
        document.fileURL = url
        if let password, document.isPasswordLocked { try await document.unlock(password: password) }
        if let session = document.session, let password {
            session.setPasswordPrompt(PasswordPrompts.fixed(password))
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
        XCTAssertEqual(session.capabilities.mode, format == .zip ? .inPlace : .update(.sevenZip))
        XCTAssertTrue(controller.capabilityNotice.isHidden)
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
        let changedBytes = try Data(contentsOf: url)
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
        XCTAssertEqual(try Data(contentsOf: url), changedBytes)
        try assertProtected(url, password: "second-key", rejectedPassword: "first-key", headers: headers)

        _ = try await document.updatePassword(.remove, settings: .init())
        let removedBytes = try Data(contentsOf: url)
        XCTAssertEqual(try ArchiveOracle.contents(url), [entryName: payload])
        XCTAssertFalse(session.hasEncryptedEntries)
        XCTAssertEqual(undo.undoMenuItemTitle, String(localized: "パスワードの削除を取り消す"))
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(try Data(contentsOf: url), changedBytes)
        try assertProtected(url, password: "second-key", headers: headers)
        document.redo(nil)
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
        XCTAssertEqual(try Data(contentsOf: url), removedBytes)
        XCTAssertEqual(try ArchiveOracle.contents(url), [entryName: payload])
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
            options: WriterOptions(password: "rewrite-key"), progress: Progress(), willPublish: nil,
            expectedOutput: .init(projected: try ArchiveReader.open(url: url).entries, mode: .rewrite(.zip))) { rewriter in
            XCTAssertEqual(rewriter.entryNames, [entryName])
            // add / remove / rename を一度も呼ばず commit する。
        }
        try assertProtected(url, password: "rewrite-key")
    }

    func testPasswordOnlyPublishCommitsUpdaterWithByteProgressAndCancellation() throws {
        for cancel in [false, true] {
            let directory = try ArchiveTestDirectory(), url = directory.url.appendingPathComponent("progress.zip")
            let body = Data(repeating: 0x5a, count: 8 * 1024 * 1024)
            let writer = try ArchiveWriter.create(url: url, options: .init(compressionMethod: .stored))
            try writer.add(data: body, as: entryName); try writer.finish()
            let original = try Data(contentsOf: url), progress = Progress()
            let options = WriterOptions(password: "updater-key")
            let entries = try ArchiveReader.open(url: url).entries
            let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 1, additions: [], itemCount: 1,
                carriedBytes: ArchiveWriteProgress.carriedBytes(entries), changesExisting: true))
            let units = Mutex<[Int64]>([])
            do {
                try ArchiveWriteProgress.didCreditForTesting.withValue({ slot, done, total in
                    guard slot == .commit else { return }
                    XCTAssertLessThan(done, total)
                    units.withLock { $0.append(done) }
                    if cancel, done > 1 { progress.cancel() }
                }) {
                    try ArchiveImportTransaction.publish(archive: url, mode: .inPlace, options: options, progress: progress,
                        ledger: ledger, willPublish: nil,
                        expectedOutput: .init(projected: entries, mode: .inPlace, zipEncryption: .init(options))) { editor in
                            try XCTUnwrap(editor as? ArchiveUpdater).reencryptExistingEntries(currentPassword: nil)
                            ledger.didCount()
                        }
                }
                XCTAssertFalse(cancel)
                XCTAssertEqual(try ArchiveOracle.contents(url, password: "updater-key"), [entryName: body])
                XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 1)
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                let values = units.withLock { $0 }
                XCTAssertEqual(values.last, progress.totalUnitCount - 1)
                XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
                XCTAssertTrue(values.contains { $0 > 1 && $0 < progress.totalUnitCount - 1 })
            } catch is CancellationError {
                XCTAssertTrue(cancel)
                XCTAssertEqual(try Data(contentsOf: url), original)
            }
            XCTAssertFalse(units.withLock { $0.isEmpty })
            try ArchiveOracle.assertNoWorkFiles(in: directory.url)
        }
    }

    func testZIPPasswordMatrixPreservesStoredPayloadAndMetadataAndAdoptsReader() async throws {
        for input in [nil, ZipEncryption.aes256, .zipCrypto] {
            for output in [nil, ZipEncryption.aes256, .zipCrypto] where input != nil || output != nil {
                let fixture = try ArchiveReencryptionTestSupport.fixture(), url = fixture.archive
                let original = try ArchiveReencryptionTestSupport.snapshot(url)
                if let input {
                    let updater = try ArchiveUpdater.open(url: url, options: .init(password: "old", zipEncryption: input))
                    try updater.reencryptExistingEntries(currentPassword: nil); try updater.commit()
                }
                let session = try ArchiveSession(url: url, password: input == nil ? nil : "old")
                let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([]), adoptions = Mutex<[ArchiveReaderAdoption]>([])
                let settings = ArchiveEncryptionSettings(password: output == nil ? nil : "new", zipEncryption: output ?? .aes256)
                let progress = Progress()
                try await ArchiveStageDiagnostics.observer.withValue({ event in
                    if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
                }) {
                    try await ArchiveSession.readerAdoptionObserverForTesting.withValue({ event in adoptions.withLock { $0.append(event) } }) {
                        let result = try await session.updatePassword(input == nil ? .set : output == nil ? .remove : .change,
                            settings: settings, progress: progress)
                        XCTAssertNil(result.reloadFailure)
                    }
                }
                XCTAssertTrue(stages.withLock { $0.contains(.updaterOpen) })
                XCTAssertFalse(stages.withLock { $0.contains(.rewriterOpen) || $0.contains(.reloadOpen) })
                XCTAssertEqual(adoptions.withLock { $0 }, [.adopted])
                XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 1); XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                XCTAssertEqual(try ArchiveReencryptionTestSupport.snapshot(url, password: settings.password), original)
                try ArchiveReencryptionTestSupport.assertEncryption(url, settings: settings)
                await session.close()
            }
        }
    }

    func testNonRelocatablePasswordEditFallsBackOnceAndResetsProgress() async throws {
        let directory = try ArchiveTestDirectory(), url = try archive(in: directory, format: .zip)
        let session = try ArchiveSession(url: url), progress = Progress(), attempts = Mutex(0)
        let resets = Mutex((last: Int64(0), count: 0))
        let observation = progress.observe(\.completedUnitCount) { value, _ in
            resets.withLock {
                if value.completedUnitCount == 0 && $0.last > 0 { $0.count += 1 }
                $0.last = value.completedUnitCount
            }
        }
        defer { observation.invalidate() }
        let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
        try await ArchiveStageDiagnostics.observer.withValue({ event in
            if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
        }) {
            try await ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
                attempts.withLock { $0 += 1 }
                progress.completedUnitCount += 300
                throw UpdaterError.nonRelocatableEntry(index: 0, name: "entry", reason: "offset")
            }) {
                let result = try await session.updatePassword(.set, settings: .init(password: "fallback"), progress: progress)
                XCTAssertNil(result.reloadFailure)
            }
        }
        XCTAssertEqual(attempts.withLock { $0 }, 1)
        XCTAssertEqual(resets.withLock { $0.count }, 1)
        XCTAssertTrue(stages.withLock { $0.contains(.updaterOpen) && $0.contains(.rewriterOpen) })
        XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 1); XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        try assertProtected(url, password: "fallback")
        try ArchiveOracle.assertNoWorkFiles(in: directory.url)
        await session.close()
    }

    func testSevenZipBeginningPasswordEditsStillUseRewriter() async throws {
        let directory = try ArchiveTestDirectory(), url = try archive(in: directory, format: .sevenZip)
        let session = try ArchiveSession(url: url, writerOptions: { _ in WriterOptions(additionPlacement: .beginning) })
        for action: ArchivePasswordAction in [.set, .change, .remove] {
            let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([]), progress = Progress()
            try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
            }) {
                let result = try await session.updatePassword(action,
                    settings: .init(password: action == .set ? "first" : "second"), progress: progress)
                XCTAssertNil(result.reloadFailure)
            }
            XCTAssertTrue(stages.withLock { $0.contains(.rewriterOpen) })
            XCTAssertFalse(stages.withLock { $0.contains(.updaterOpen) })
            XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 1)
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        }
        await session.close()
    }

    @MainActor func testCorruptReencryptedOutputDoesNotPromptOrDisableEditing() async throws {
        let directory = try ArchiveTestDirectory()
        let url = try archive(in: directory, format: .zip, settings: .init(password: "old"))
        let original = try Data(contentsOf: url)
        let (document, _) = try await document(at: url, directory: directory, password: "old")
        let session = try XCTUnwrap(document.session), prompts = PasswordPrompts.counting(), damaged = Mutex(false)
        session.setPasswordPrompt(prompts.prompt)
        do {
            try await ZipReencryption.$testingObserver.withValue({ event in
                guard event.phase == .v0 else { return }
                let parent = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasPrefix(".KaitoFinder-add-") })
                let work = parent.appendingPathComponent("archive.zip")
                let reader = try ArchiveReader.open(url: work, options: .init(password: "new"))
                let raw = try XCTUnwrap(reader.zipRawRecordLayout(at: 0))
                var bytes = try Data(contentsOf: work)
                bytes[Int(raw.payloadRange.upperBound - 1)] ^= 1
                try bytes.write(to: work)
                damaged.withLock { $0 = true }
            }) {
                _ = try await document.updatePassword(.change, settings: .init(password: "new"))
            }
            XCTFail("Corrupt output must not publish")
        } catch {
            guard case UpdaterError.reencryptionFailed = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertNil(ArchivePasswordChallenge(error))
        }
        XCTAssertTrue(damaged.withLock { $0 }); XCTAssertEqual(prompts.count, 0)
        XCTAssertTrue(session.capabilities.canEdit)
        let password = await session.password
        XCTAssertEqual(password, "old")
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        try ArchiveOracle.assertNoWorkFiles(in: directory.url)
        _ = try await document.updatePassword(.change, settings: .init(password: "retry"))
        try assertProtected(url, password: "retry", rejectedPassword: "old")
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
        XCTAssertEqual(document.session?.capabilities.mode, .update(.sevenZip))
        XCTAssertTrue(try XCTUnwrap(document.session).hasKnownPassword)
        try assertProtected(output, password: "output-key", rejectedPassword: "source-key", headers: true)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor func testKnownAESAndZipCryptoZIPAppendPreservesExistingRecordAndEncryptsNewEntries() async throws {
        for method in [ZipEncryption.aes256, .zipCrypto] {
            let directory = try ArchiveTestDirectory()
            try payload.write(to: directory.url.appendingPathComponent(entryName))
            let url = directory.url.appendingPathComponent("fixture.zip")
            try directory.run(ExternalTool.sevenZip, ["a", "-bd", "-y", "-tzip", "-pfixture-key",
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
            XCTAssertEqual(try ArchiveOracle.contents(url, password: "fixture-key")["renamed.txt"], Data("new encrypted contents".utf8))
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
            try directory.run(ExternalTool.sevenZip, ["a", "-bd", "-y", "-t7z", "-pfixture-key",
                headers ? "-mhe=on" : "-mhe=off", url.path, entryName])
            let session = try ArchiveSession(url: url, password: "fixture-key")
            let added = directory.url.appendingPathComponent("added.txt")
            try payload.write(to: added)
            _ = try await session.append(urls: [added], to: "", progress: Progress())
            let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: "fixture-key"))
            XCTAssertEqual(reader.entries.count, 2)
            XCTAssertTrue(reader.entries.allSatisfy(\.isEncrypted))
            XCTAssertEqual(try ArchiveOracle.contents(url, password: "fixture-key"), [entryName: payload, "added.txt": payload])
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
        preserveApplicationMenus()
        let delegate = AppDelegate(), menu = delegate.makeMenu()
        let file = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == String(localized: "ファイル") })
        let start = try XCTUnwrap(file.items.firstIndex { $0.action == #selector(ArchiveWindowController.saveArchiveAs(_:)) })
        let selectors = [#selector(ArchiveWindowController.setArchivePassword(_:)),
                         #selector(ArchiveWindowController.changeArchivePassword(_:)), #selector(ArchiveWindowController.removeArchivePassword(_:))]
        XCTAssertEqual(file.items[start + 1].action, #selector(NSDocument.revertToSaved(_:)))
        let items = Array(file.items[(start + 2)...(start + 4)])
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
        try rarDirectory.run(ExternalTool.python3, ["-c", "import struct,zlib; h=lambda t,n: struct.pack('<H',zlib.crc32(t)&65535)+t; main=struct.pack('<BHHHI',0x73,0,13,0,0); end=struct.pack('<BHH',0x7b,0,7); open('empty.rar','wb').write(b'Rar!\\x1a\\x07\\x00'+h(main,0)+h(end,0))"])
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
