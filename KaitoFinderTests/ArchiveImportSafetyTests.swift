import AppKit
import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveImportSafetyTests: XCTestCase {
    private let quarantine = Data("0081;12345678;ImportSafetyTests;".utf8)

    @MainActor private final class RecordingWindow: NSWindow {
        var requestedSheets: [NSWindow] = []
        override func beginSheet(_ sheetWindow: NSWindow,
                                 completionHandler handler: ((NSApplication.ModalResponse) -> Void)? = nil) {
            // エラーシートは表示せず、要求された時点で検出する。
            requestedSheets.append(sheetWindow)
        }
    }

    @concurrent private static func largeFile(in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("large.bin")
        var bytes = Data(count: 1024 * 1024)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        for _ in 0..<64 { try handle.write(contentsOf: bytes) }
        return url
    }

    private static func isWriting(in directory: URL, prefix: String, filename: String) -> Bool {
        let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.filter { $0.lastPathComponent.hasPrefix(prefix) }.contains {
            let file = $0.appendingPathComponent(filename)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value ?? 0
            return size > 1024 * 1024
        }
    }

    @MainActor func testImmediateImportCancelledInsideFileStopsWithoutAlert() async throws {
        let fixture = try DeferredSaveFixture(behavior: .immediate), document = fixture.document
        defer { document.close() }
        let source = try await Self.largeFile(in: fixture.directory.url)
        preserveArchiveWindowFrame()
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        let original = try XCTUnwrap(controller.window)
        let window = RecordingWindow(contentRect: original.contentRect(forFrameRect: original.frame),
                                     styleMask: original.styleMask, backing: .buffered, defer: false)
        window.contentView = original.contentView
        window.delegate = original.delegate
        controller.window = window
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session), snapshot = await session.snapshot()
        controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
        let reachedAdd = Mutex(false)
        ArchiveImportTransaction.willAddFileForTesting.withValue({ url in
            reachedAdd.withLock { $0 = true }
            XCTAssertEqual(url, source)
            guard !Thread.isMainThread else { XCTFail("追加は worker で実行する"); return }
            let cancellationHandled = DispatchSemaphore(value: 0)
            DispatchQueue.main.sync {
                guard let sheet = controller.editProgressSheet else { XCTFail("進捗シートがありません"); return }
                XCTAssertEqual(sheet.progress.completedUnitCount, 0)
                let handler = sheet.progress.cancellationHandler
                sheet.progress.cancellationHandler = {
                    handler?()
                    cancellationHandled.signal()
                }
                sheet.cancelExtraction(nil)
            }
            // Progress の取消しハンドラは非同期に呼ばれる場合がある。
            XCTAssertEqual(cancellationHandled.wait(timeout: .now() + 5), .success)
            // hook 自体は throw せず、add 内部の Task.checkCancellation を通す。
            XCTAssertTrue(Task.isCancelled)
        }) { controller.startImport(urls: [source], incoming: nil, folder: "") }
        let task = try XCTUnwrap(controller.extractionTask), sheet = try XCTUnwrap(controller.editProgressSheet)
        await task.value
        XCTAssertTrue(reachedAdd.withLock { $0 })
        XCTAssertEqual(sheet.progress.completedUnitCount, 0)
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(controller.failureAlert)
        XCTAssertTrue(window.requestedSheets.allSatisfy { $0 === sheet.window }, "Cancellation must not request an error alert")
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertFalse(Self.isWriting(in: fixture.directory.url, prefix: ".KaitoFinder-add-", filename: "archive.zip"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.url.path).contains { $0.hasPrefix(".KaitoFinder-add-") })
    }

    @MainActor func testNewArchivePanelCancellationStopsSingleFileCompression() async throws {
        let fixture = try DeferredSaveFixture()
        defer { fixture.document.close() }
        let source = try await Self.largeFile(in: fixture.directory.url)
        let output = fixture.directory.url.appendingPathComponent("created.zip")
        let creator = ArchiveCreationController(store: fixture.store)
        creator.destinationHandler = { _, _ in output }
        let saving = Task { try await creator.create(sources: [source]) }
        try await scenarioWait { Self.isWriting(in: fixture.directory.url, prefix: ".KaitoFinder-new-", filename: "archive.zip") }
        let sheet = try XCTUnwrap(creator.progressSheet)
        XCTAssertEqual(sheet.progress.completedUnitCount, 0)
        sheet.cancelExtraction(nil)
        do { _ = try await saving.value; XCTFail("Cancelled creation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertNil(creator.progressSheet)
        XCTAssertFalse(Self.isWriting(in: fixture.directory.url, prefix: ".KaitoFinder-new-", filename: "archive.zip"))
    }

    func testAppendPropagatesQuarantineFromNestedFilesAndDirectories() async throws {
        for format in [GyoshukuKit.ArchiveFormat.zip, .tar] {
            for markDirectory in [false, true] {
                let directory = try ArchiveTestDirectory()
                let archive = directory.url.appendingPathComponent("archive." + ArchiveCreationPlan.filenameExtension(for: format))
                let writer = try ArchiveWriter.create(url: archive, format: format)
                try writer.add(data: Data("original".utf8), as: "original.txt")
                try writer.finish()
                let source = directory.url.appendingPathComponent("input", isDirectory: true)
                let nested = source.appendingPathComponent("nested", isDirectory: true)
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
                let file = nested.appendingPathComponent("new.txt")
                try Data("new".utf8).write(to: file)
                try ExtractionQuarantine.apply(quarantine, to: markDirectory ? nested : file)
                XCTAssertNil(try ExtractionQuarantine.read(from: archive))
                XCTAssertNil(try ExtractionQuarantine.read(from: source))

                let session = try ArchiveSession(url: archive)
                let result = try await session.append(urls: [source], to: "", progress: Progress())
                XCTAssertTrue(result.failures.isEmpty)
                XCTAssertNil(result.reloadFailure)
                XCTAssertEqual(try ExtractionQuarantine.read(from: archive), quarantine, "\(format), directory=\(markDirectory)")
                let output = directory.url.appendingPathComponent("output", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                let extracted = try await ExtractionService.extract(ExtractionSelection(entries: await session.entries()),
                                                                     from: session, to: output)
                XCTAssertTrue(extracted.failures.isEmpty)
                XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("input/nested/new.txt")), Data("new".utf8))
                XCTAssertEqual(try ExtractionQuarantine.read(from: output.appendingPathComponent("input/nested/new.txt")), quarantine)
                await session.close()
            }
        }
    }

    func testAppendPreservesOriginalQuarantineAndCancellationDoesNotPublishNewQuarantine() async throws {
        let fixture = try ScenarioFixture()
        let file = try fixture.file("new.txt")
        try ExtractionQuarantine.apply(quarantine, to: file)
        let original = Data("0081;87654321;OriginalArchive;".utf8)
        try ExtractionQuarantine.apply(original, to: fixture.archive)
        let session = try ArchiveSession(url: fixture.archive)
        let before = try ScenarioFixture.digest(fixture.archive)
        let progress = Progress()
        do {
            _ = try await session.append(urls: [file], to: "", progress: progress, willPublish: { progress.cancel() })
            XCTFail("Cancellation must prevent publication")
        } catch is CancellationError {}
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        XCTAssertEqual(try ExtractionQuarantine.read(from: fixture.archive), original)
        _ = try await session.append(urls: [file], to: "", progress: Progress())
        XCTAssertEqual(try ExtractionQuarantine.read(from: fixture.archive), original)
        await session.close()
    }

    func testCreationPropagatesQuarantineFromNestedEmptyDirectory() throws {
        let fixture = try ScenarioFixture()
        let source = try fixture.folder("input"), nested = try fixture.folder("input/empty")
        try ExtractionQuarantine.apply(quarantine, to: nested)
        XCTAssertNil(try ExtractionQuarantine.read(from: source))
        let output = fixture.root.appendingPathComponent("created.zip")
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: [source], destination: output, format: .zip), progress: Progress())
        XCTAssertEqual(try ExtractionQuarantine.read(from: output), quarantine)
        XCTAssertEqual(Set(try ArchiveReader.open(url: output).entries.map(\.name)), ["input/", "input/empty/"])
    }

    func testCreationCannotReplaceAnImportedDescendantOrItsHardLink() throws {
        for hardLink in [false, true] {
            let fixture = try ScenarioFixture()
            let source = try fixture.folder("input")
            let original = try fixture.file("input/existing.zip", bytes: Data("irreplaceable source".utf8))
            let output: URL
            if hardLink {
                output = fixture.root.appendingPathComponent("alias.zip")
                try FileManager.default.linkItem(at: original, to: output)
            } else { output = original }
            let before = try Data(contentsOf: original)
            XCTAssertThrowsError(try ArchiveCreationTransaction.run(
                plan: .init(sources: [source], destination: output, format: .zip), progress: Progress())) {
                guard case ExtractionFailure.refused(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
                XCTAssertEqual(reason, String(localized: "作成元の項目とは別の保存先を選んでください。"))
            }
            XCTAssertEqual(try Data(contentsOf: original), before)
            XCTAssertEqual(try Data(contentsOf: output), before)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".KaitoFinder-new-") })
        }
    }

    func testCreationCanSaveANewArchiveInsideItsSourceDirectory() throws {
        let fixture = try ScenarioFixture(), source = try fixture.folder("input")
        _ = try fixture.file("input/keep.txt", bytes: Data("keep".utf8))
        let output = source.appendingPathComponent("new.zip")
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: [source], destination: output, format: .zip), progress: Progress())
        XCTAssertEqual(try ScenarioFixture.contents(output), ["input/keep.txt": Data("keep".utf8)])
    }
}
