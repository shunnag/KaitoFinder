import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSplitSaveInteropTests: XCTestCase {
    private static func require(_ executable: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Missing \(executable)") }
    }
    private static func command(_ executable: String, _ arguments: [String], at directory: URL) throws -> String {
        try require(executable)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = directory; process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        return text
    }
    @MainActor func testSevenZipVolumeCreatorAndInfoZIPByteSplitInteroperateAfterSave() async throws {
        try Self.require("/opt/homebrew/bin/7zz")
        try Self.require("/usr/bin/zip")
        for format: GyoshukuKit.ArchiveFormat in [.sevenZip, .tar, .zip] {
            let fixture = try DeferredSplitSaveFixture(format: format, volumeSize: 16 * 1024, external: { whole, directory in
                let names = (0..<4).map { "file\($0).txt" }
                for (i, name) in names.enumerated() {
                    try DeferredSplitSaveFixture.bytes(9728, seed: UInt64(i + 1)).write(to: directory.appendingPathComponent(name))
                }
                let output = directory.appendingPathComponent("interop." + ArchiveCreationPlan.filenameExtension(for: format))
                let data: Data
                if format == .zip {
                    _ = try Self.command("/usr/bin/zip", ["-0", output.path] + names, at: directory)
                    data = try Data(contentsOf: output)
                } else {
                    _ = try Self.command("/opt/homebrew/bin/7zz", ["a", format == .tar ? "-ttar" : "-t7z", "-v16k", output.path] + names, at: directory)
                    var joined = Data()
                    for i in 1...128 {
                        let part = output.appendingPathExtension(String(format: "%03d", i))
                        guard FileManager.default.fileExists(atPath: part.path) else { break }
                        joined.append(try Data(contentsOf: part))
                    }
                    data = joined
                }
                try data.write(to: whole)
            })
            defer { fixture.document.close() }
            _ = try await fixture.document.remove([fixture.node("file0.txt")], progress: Progress())
            _ = try await fixture.document.rename(fixture.node("file1.txt"), to: "renamed.txt", progress: Progress())
            _ = try await fixture.document.append(urls: [fixture.file(count: 30_000)], to: "", progress: Progress())
            try await fixture.save()
            var expected = fixture.contents
            expected.removeValue(forKey: "file0.txt"); expected["renamed.txt"] = expected.removeValue(forKey: "file1.txt")
            expected["added.txt"] = DeferredSplitSaveFixture.bytes(30_000)
            try fixture.assertSaved(expected: expected)
            let test = try Self.command("/opt/homebrew/bin/7zz", ["t", fixture.gate.path], at: fixture.root)
            XCTAssertFalse(test.lowercased().contains("data after the end"), test)
            XCTAssertFalse(test.contains("Tail"), test)
            let listing = try Self.command("/opt/homebrew/bin/7zz", ["l", fixture.gate.path], at: fixture.root)
            XCTAssertTrue(listing.contains("Volumes: \(try fixture.parts().count)"), listing)
        }
    }

    @MainActor func testWorkProducerCanJoinToDifferentStemAndRejectsSourceBeforeReplaying() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tarGzip] {
            let fixture = try DeferredSplitSaveFixture(format: format)
            defer { fixture.document.close() }
            let session = try XCTUnwrap(fixture.document.session), layout = try XCTUnwrap(session.volumeLayout)
            let snapshot = await session.snapshot(), identity = await session.sourceIdentity
            var pending = ArchivePendingChanges()
            pending.renames[.init(index: 0, expectedName: snapshot.entries[0].name, baseGeneration: snapshot.generation)] = "renamed.txt"
            let plan = try ArchiveSaveReplayPlan(base: snapshot.entries, generation: snapshot.generation, pending: pending)
            let input = try ArchiveVolumeInput(layout: layout, expected: identity)
            let work = fixture.directory.url.appendingPathComponent("different-name." + ArchiveCreationPlan.filenameExtension(for: format))
            let mode = try XCTUnwrap(session.capabilities.mode)
            // Source identity is independent of any new-set output scheme/schedule.
            _ = try ArchiveSplitWorkProducer.produce(source: input, workURL: work, mode: mode, password: nil,
                options: WriterOptions(), plan: plan, progress: Progress(), verifyAssembledInput: { try input.verify($0) })
            XCTAssertTrue(try DeferredSaveFixture.contents(work).keys.contains("renamed.txt"))
            XCTAssertEqual(try fixture.parts(), fixture.original)
            try FileManager.default.removeItem(at: work)
            try SplitArchiveFixture.touch(layout.volumes[2].url)
            do {
                _ = try ArchiveSplitWorkProducer.produce(source: input, workURL: work, mode: mode, password: nil,
                    options: WriterOptions(), plan: plan, progress: Progress(), verifyAssembledInput: { try input.verify($0) })
                XCTFail("Must reject before replay")
            } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
        }
    }

    @MainActor func testInfoZIPNativeSplitRemainsReadOnlyInOnSaveMode() async throws {
        try Self.require("/opt/homebrew/bin/7zz")
        try Self.require("/usr/bin/zip")
        let directory = try ArchiveTestDirectory(), root = try volumePublishTestURL(directory.url)
        let source = root.appendingPathComponent("payload.bin"), gate = root.appendingPathComponent("native.zip")
        try DeferredSplitSaveFixture.bytes(180_000).write(to: source)
        _ = try Self.command("/usr/bin/zip", ["-0", "-s", "64k", gate.path, source.lastPathComponent], at: root)
        let defaults = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: defaults.defaults)
        store.preferences.saveBehavior = .onSave
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        defer { document.close() }
        try document.read(from: gate, ofType: ArchiveDocumentController.splitVolumeType)
        document.fileURL = gate
        XCTAssertEqual(document.session?.capabilities.refusal, .nativeSplitArchive)
        do { _ = try await document.createFolder(in: "", progress: Progress()); XCTFail("Native split is M7") } catch { }
        XCTAssertTrue(document.pendingChanges.isEmpty)
    }

    @MainActor func testBusyIsRetryableAndSizeLimitChoosesBeforeBegin() async throws {
        let fixture = try DeferredSplitSaveFixture(), document = fixture.document
        defer { document.close() }
        _ = try await document.createFolder(in: "", progress: Progress())
        let layout = try XCTUnwrap(document.session?.volumeLayout).publicationLayout(), identity = await document.session!.sourceIdentity
        let owner = try VolumeSetPublication.begin(.init(parent: layout.gateURL.deletingLastPathComponent(), layout: layout, expected: identity,
            schedule: .uniform(size: UInt64(fixture.size))), estimatedOutputLength: 40000, index: fixture.index)
        defer { owner.cancel() }
        do { try await fixture.save(); XCTFail("Busy") } catch { }
        XCTAssertEqual(document.splitSaveFailure?.kind, .retry)
        XCTAssertTrue(document.isDocumentEdited); XCTAssertTrue(document.session!.capabilities.canEdit)
        XCTAssertEqual(try fixture.parts(), fixture.original)
        owner.cancel()
        try await fixture.save()

        let many = try DeferredSplitSaveFixture(count: 128)
        defer { many.document.close() }
        let begins = Mutex(0)
        var choices = 0
        many.document.splitSaveHooks.willBegin = { _ in begins.withLock { $0 += 1 } }
        many.document.splitScheduleChooser = { _, tooMany in XCTAssertTrue(tooMany); choices += 1; return .size(65536) }
        _ = try await many.document.append(urls: [many.file(count: 20_000)], to: "", progress: Progress())
        try await many.save()
        XCTAssertEqual(choices, 1); XCTAssertEqual(begins.withLock { $0 }, 1)
        XCTAssertThrowsError(try ArchiveSplitScheduleChoice.size(65535).schedule(for: layout))
    }

    @MainActor func testAnyVolumePermissionRefusalAndImmediateModeStayProtected() async throws {
        let fixture = try DeferredSplitSaveFixture()
        defer { fixture.document.close() }
        let third = fixture.gate.deletingPathExtension().appendingPathExtension("003")
        XCTAssertEqual(chmod(third.path, 0o444), 0)
        defer { _ = chmod(third.path, 0o600) }
        try await fixture.reopen()
        XCTAssertFalse(fixture.document.session!.capabilities.canEdit)
        do { _ = try await fixture.document.createFolder(in: "", progress: Progress()); XCTFail("Read-only member") } catch { }
        XCTAssertEqual(try fixture.parts(), fixture.original)
        var preferences = fixture.store.preferences
        preferences.saveBehavior = .immediate
        fixture.store.preferences = preferences
        try await fixture.reopen()
        let immediate = fixture.document
        XCTAssertEqual(immediate.saveBehavior, .immediate)
        XCTAssertFalse(immediate.session!.capabilities.canEdit)
        immediate.splitMutationConfirmation = { _ in XCTFail("Unwritable member"); return .alertFirstButtonReturn }
        immediate.splitSaveHooks.willBegin = { _ in XCTFail("Unwritable member") }
        do { _ = try await immediate.createFolder(in: "", progress: Progress()); XCTFail("Read-only") } catch { }
        XCTAssertEqual(try fixture.parts(), fixture.original)
    }
}
