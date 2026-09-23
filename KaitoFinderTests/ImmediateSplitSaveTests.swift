import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ImmediateSplitSaveTests: XCTestCase {
    @MainActor func testEveryEditConfirmsBeforeWritingAndUsesTheSameSplitPipeline() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.sevenZip, .tarGzip, .zip] {
            let clones = Mutex(0)
            let stack = ArchiveUndoStack(clone: { _, _ in clones.withLock { $0 += 1 }; return EIO }, cloneSupportQuery: { _ in true })
            let fixture = try DeferredSplitSaveFixture(format: format, behavior: .immediate, undoStack: stack)
            let document = fixture.document, session = try XCTUnwrap(document.session)
            defer { document.close() }
            XCTAssertTrue(session.capabilities.splitIrreversible)
            XCTAssertFalse(document.canUndoNextMutation)
            XCTAssertFalse(session.usesPendingReading)
            let spelling = document.fileURL
            var allowed = false, confirmations = 0
            document.splitMutationConfirmation = { alert in
                confirmations += 1
                XCTAssertEqual(alert.messageText, String(localized: "分割アーカイブへの変更は取り消せません。"))
                XCTAssertEqual(alert.informativeText, String(localized: "すべての巻を書き直して、同じ巻サイズで分割し直します。"))
                XCTAssertEqual(alert.buttons[0].keyEquivalent, "")
                XCTAssertEqual(alert.buttons[1].keyEquivalent, "\r")
                XCTAssertNotNil(alert.suppressionButton)
                return allowed ? .alertFirstButtonReturn : .alertSecondButtonReturn
            }
            let add = try fixture.file("added.txt"), paste = try fixture.file("pasted.txt"), drop = try fixture.file("dropped.txt")
            var expected = fixture.contents
            let operations: [(String, @MainActor () async throws -> Void)] = [
                ("add", { _ = try await document.append(urls: [add], to: "", progress: Progress()); expected["added.txt"] = DeferredSplitSaveFixture.bytes(6000) }),
                ("paste", { _ = try await document.append(urls: [paste], to: "", progress: Progress()); expected["pasted.txt"] = DeferredSplitSaveFixture.bytes(6000) }),
                ("drop", { _ = try await document.append(urls: [drop], to: "", progress: Progress()); expected["dropped.txt"] = DeferredSplitSaveFixture.bytes(6000) }),
                ("delete", { _ = try await document.remove([fixture.node("file0.txt")], progress: Progress()); expected.removeValue(forKey: "file0.txt") }),
                ("rename", { _ = try await document.rename(fixture.node("file1.txt"), to: "renamed.txt", progress: Progress()); expected["renamed.txt"] = expected.removeValue(forKey: "file1.txt") }),
                ("folder", { _ = try await document.createFolder(in: "", baseName: "folder", progress: Progress()) }),
                ("move", { _ = try await document.move([fixture.node("file2.txt")], to: "folder", progress: Progress()); expected["folder/file2.txt"] = expected.removeValue(forKey: "file2.txt") }),
                ("copy", {
                    let incoming = fixture.directory.url.appendingPathComponent("incoming", isDirectory: true)
                    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: incoming) }
                    let payload = ArchiveEntryPayload(node: try await fixture.node("file3.txt"), session: session, generation: document.generation)
                    try ArchiveCopyOut.check(await ExtractionService.extract([payload], from: session, to: incoming, progress: Progress()))
                    _ = try await document.append(urls: [incoming.appendingPathComponent("file3.txt")], to: "folder", progress: Progress())
                    expected["folder/file3.txt"] = expected["file3.txt"]
                }),
                ("replace", {
                    let replacement = try fixture.file("file3.txt", count: 19000)
                    _ = try await document.append(urls: [replacement], to: "", progress: Progress(), resolveConflict: { _ in .init(choice: .replace) })
                    expected["file3.txt"] = DeferredSplitSaveFixture.bytes(19000)
                })
            ]
            for (name, operation) in operations {
                let before = try fixture.parts(), generation = document.generation, prompts = confirmations
                allowed = false
                do { try await operation(); XCTFail("Cancel must stop \(name)") } catch is CancellationError { }
                XCTAssertEqual(try fixture.parts(), before, name)
                XCTAssertEqual(document.generation, generation, name)
                allowed = true
                try await operation()
                XCTAssertEqual(confirmations, prompts + 2, name)
                XCTAssertEqual(document.generation, generation + 1, name)
                try assertPublished(fixture, expected: expected)
                XCTAssertEqual(document.fileURL, spelling, "Keep the original URL spelling")
            }
            if format != .tarGzip {
                for action: ArchivePasswordAction in [.set, .change, .remove] {
                    let password = action == .remove ? nil : action == .set ? "first-secret" : "second-secret"
                    let settings = ArchiveEncryptionSettings(password: password)
                    let before = try fixture.parts(), prompts = confirmations
                    allowed = false
                    do { _ = try await document.updatePassword(action, settings: settings); XCTFail("Cancel password") } catch is CancellationError { }
                    XCTAssertEqual(try fixture.parts(), before)
                    allowed = true
                    _ = try await document.updatePassword(action, settings: settings)
                    XCTAssertEqual(confirmations, prompts + 2)
                    try assertPublished(fixture, expected: expected, password: password)
                }
            }
            XCTAssertEqual(clones.withLock { $0 }, 0, "Never capture a .001 undo slot")
        }
    }

    @MainActor private func assertPublished(_ fixture: DeferredSplitSaveFixture, expected: [String: Data], password: String? = nil) throws {
        let document = fixture.document, parts = try fixture.parts()
        let layout = try XCTUnwrap(document.session?.volumeLayout)
        XCTAssertEqual(parts.reduce(into: Data()) { $0.append($1) }, fixture.work.bytes)
        XCTAssertTrue(parts.dropLast().allSatisfy { $0.count == fixture.size })
        XCTAssertTrue(try XCTUnwrap(parts.last).count <= fixture.size)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.nextVolumeURL.path))
        XCTAssertEqual(try DeferredSaveFixture.contents(fixture.gate, password: password), expected)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(document.undoManager!.canUndo)
        XCTAssertFalse(document.undoManager!.canRedo)
        XCTAssertFalse(document.isDocumentEdited)
        XCTAssertTrue(document.pendingChanges.isEmpty)
        XCTAssertEqual(layout.savedSchedule, .uniform(size: UInt64(fixture.size)))
    }

    @MainActor func testSuppressionIsPerDocumentAndHazardConsentPrecedesPublication() async throws {
        let first = try DeferredSplitSaveFixture(behavior: .immediate), second = try DeferredSplitSaveFixture(behavior: .immediate)
        defer { first.document.close(); second.document.close() }
        var prompts = 0, hazards = 0, consent = false
        first.document.splitMutationConfirmation = { alert in prompts += 1; alert.suppressionButton?.state = .on; return .alertFirstButtonReturn }
        first.document.splitSaveHooks.operations.volumeInfo = { directory in
            let info = try VolumePublishFS.volumeInfo(directory)
            return .init(uuid: info.uuid, cacheIdentity: info.cacheIdentity, fileSystem: info.fileSystem, available: info.available, hazard: "file-provider")
        }
        first.document.splitHazardConsent = { _ in hazards += 1; return consent }
        do { _ = try await first.document.createFolder(in: "", baseName: "cancelled", progress: Progress()); XCTFail("Consent") } catch is CancellationError { }
        XCTAssertEqual(try first.parts(), first.original)
        consent = true
        for name in ["one", "two"] { _ = try await first.document.createFolder(in: "", baseName: name, progress: Progress()) }
        XCTAssertEqual(prompts, 1); XCTAssertEqual(hazards, 2)
        second.document.splitMutationConfirmation = { _ in prompts += 1; return .alertSecondButtonReturn }
        do { _ = try await second.document.createFolder(in: "", progress: Progress()); XCTFail("Second document must prompt") } catch is CancellationError { }
        XCTAssertEqual(prompts, 2); XCTAssertEqual(try second.parts(), second.original)
    }

    @MainActor func testOtherWritableFormatsAndUnevenRefusal() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarBzip2, .tarXZ, .lha] {
            let fixture = try DeferredSplitSaveFixture(format: format, behavior: .immediate)
            defer { fixture.document.close() }
            fixture.document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
            _ = try await fixture.document.createFolder(in: "", progress: Progress())
            try assertPublished(fixture, expected: fixture.contents)
        }
        let uneven = try DeferredSplitSaveFixture(uneven: true, behavior: .immediate)
        defer { uneven.document.close() }
        XCTAssertEqual(uneven.document.session?.capabilities.refusal, .unevenSplitArchive)
        XCTAssertEqual(uneven.document.session?.capabilities.readOnlyReason, String(localized: "巻サイズが揃っていない分割アーカイブは、設定で「保存時にまとめて書き込む」を選ぶと編集できます。"))
        uneven.document.splitMutationConfirmation = { _ in XCTFail("Read-only"); return .alertFirstButtonReturn }
        do { _ = try await uneven.document.createFolder(in: "", progress: Progress()); XCTFail("Uneven") } catch { }
        XCTAssertEqual(try uneven.parts(), uneven.original)
    }

    @MainActor func testSuccessfulSplitEditClearsPreexistingSingleFileUndoSlots() async throws {
        let directory = try ArchiveTestDirectory(), old = directory.url.appendingPathComponent("old.zip")
        try Data("old single archive".utf8).write(to: old)
        let clones = Mutex(0)
        let stack = ArchiveUndoStack(clone: { source, target in
            clones.withLock { $0 += 1 }
            do { try FileManager.default.copyItem(at: source, to: target); return 0 }
            catch { return EIO }
        }, cloneSupportQuery: { _ in true })
        stack.resolveCloneSupport(for: old)
        stack.recordMutation(try stack.capture(old))
        XCTAssertEqual(stack.slots.count, 1)
        let fixture = try DeferredSplitSaveFixture(behavior: .immediate, undoStack: stack)
        defer { fixture.document.close() }
        fixture.document.undoManager!.beginUndoGrouping()
        fixture.document.undoManager!.registerUndo(withTarget: fixture.document) { _ in XCTFail("Stale undo must never execute") }
        fixture.document.undoManager!.endUndoGrouping()
        XCTAssertTrue(fixture.document.undoManager!.canUndo)
        fixture.document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
        _ = try await fixture.document.createFolder(in: "", progress: Progress())
        XCTAssertTrue(stack.slots.isEmpty)
        XCTAssertFalse(fixture.document.undoManager!.canUndo)
        XCTAssertEqual(clones.withLock { $0 }, 1, "Only the seeded single file was captured")
    }

    @MainActor func testVolumeLimitRefusesWithoutChangingTheImmediateSchedule() async throws {
        let fixture = try DeferredSplitSaveFixture(behavior: .immediate)
        defer { fixture.document.close() }
        fixture.document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
        fixture.document.splitScheduleChooser = { _, _ in XCTFail("Immediate edits must preserve S"); return .single }
        fixture.document.splitSaveHooks.willBegin = { _ in XCTFail("Reject before W") }
        do {
            _ = try await fixture.document.append(urls: [fixture.file(count: 1_200_000)], to: "", progress: Progress())
            XCTFail("Too many volumes")
        } catch { XCTAssertEqual((error as? ArchiveSplitSaveFailure)?.kind, .tooManyVolumes) }
        XCTAssertEqual(try fixture.parts(), fixture.original)
        XCTAssertFalse(fixture.document.isDocumentEdited)
    }

    @MainActor func testRollbackKeepsImmediateSplitEditableWithoutUndo() async throws {
        let directory = try ArchiveTestDirectory(), old = directory.url.appendingPathComponent("old.zip")
        try Data("old single archive".utf8).write(to: old)
        let stack = ArchiveUndoStack(clone: { source, target in
            do { try FileManager.default.copyItem(at: source, to: target); return 0 } catch { return EIO }
        }, cloneSupportQuery: { _ in true })
        stack.resolveCloneSupport(for: old)
        stack.recordMutation(try stack.capture(old))
        let fixture = try DeferredSplitSaveFixture(behavior: .immediate, undoStack: stack), document = fixture.document
        document.undoManager!.beginUndoGrouping()
        document.undoManager!.registerUndo(withTarget: document) { _ in XCTFail("Stale undo must never execute") }
        document.undoManager!.endUndoGrouping()
        XCTAssertTrue(document.undoManager!.canUndo)
        XCTAssertEqual(stack.slots.count, 1)
        defer { document.close() }
        document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
        document.splitSaveHooks.fault = { if $0 == .s7 { throw VolumePublishError.validationFailed } }
        do { _ = try await document.createFolder(in: "", progress: Progress()); XCTFail("Rollback") } catch { }
        XCTAssertEqual(document.splitSaveFailure?.kind, .rolledBack)
        XCTAssertEqual(document.splitSaveFailure?.keepsPendingChanges, false)
        XCTAssertFalse(document.session!.requiresSplitRecovery)
        XCTAssertFalse(document.undoManager!.canUndo)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertEqual(try fixture.parts(), fixture.original)
        document.splitSaveHooks.fault = { _ in }
        _ = try await document.createFolder(in: "", progress: Progress())
        XCTAssertTrue(document.session!.capabilities.canEdit)
        XCTAssertEqual(document.fileModificationDate, try FileManager.default.attributesOfItem(atPath: fixture.gate.path)[.modificationDate] as? Date)
    }
}
