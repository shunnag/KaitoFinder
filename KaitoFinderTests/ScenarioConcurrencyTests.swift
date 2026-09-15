import AppKit
import Foundation
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioConcurrencyTests: XCTestCase {
    @MainActor func testSlowExtractionDisablesPasteNewFolderAndDeleteUntilCompletion() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as z: z.writestr('large.bin', b'x' * (4 * 1024 * 1024))")
        let (document, controller) = try await scenarioDocument(fixture), session = try XCTUnwrap(document.session)
        let source = try fixture.file("pasted.txt"), out = try fixture.folder("out"), gate = ScenarioGate()
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            gate.release()
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { data in
                let item = NSPasteboardItem()
                for (type, bytes) in data { item.setData(bytes, forType: type) }
                return item
            })
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([source as NSURL]) else { throw XCTSkip("ペーストボードを利用できない") }
        controller.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let nodes = controller.selectedNodes, before = try ScenarioFixture.digest(fixture.archive)
        let payloads = ArchiveEntryPayload.payloads(for: nodes, archiveURL: fixture.archive, generation: document.generation)
        controller.startExtraction(payloads, session: session, destination: out, showProgress: false, entryCount: 1,
                                   didWrite: { _ in gate.pauseOnce() })
        let task = try XCTUnwrap(controller.extractionTask)
        try await scenarioWait { gate.isEntered }
        XCTAssertTrue(controller.operationInFlight)
        let selectors = [#selector(controller.paste(_:)), #selector(controller.newFolder(_:)), #selector(controller.deleteEntries(_:))]
        for action in selectors {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item))
            if action != #selector(controller.paste(_:)) {
                XCTAssertEqual(item.toolTip, String(localized: "別の操作が完了するまでお待ちください。"))
            }
        }
        controller.paste(nil)
        controller.newFolder(nil)
        controller.deleteEntries(nil)
        XCTAssertNil(controller.deletionConfirmation)
        XCTAssertNil(controller.editProgressSheet)
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        gate.release()
        await task.value
        XCTAssertFalse(controller.operationInFlight)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("large.bin")), Data(repeating: 0x78, count: 4 * 1024 * 1024))
        for action in selectors { XCTAssertTrue(controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))) }
        // メニューが再び有効になった後、同じ文書で三種類の編集が公開できることも確認する。
        controller.paste(nil)
        await controller.extractionTask?.value
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive)["pasted.txt"], Data("added".utf8))
        _ = try await document.createFolder(in: "", baseName: "after", progress: Progress())
        _ = try await document.remove(nodes, progress: Progress())
        let entries = await session.entries()
        XCTAssertEqual(Set(entries.map(\.name)), ["pasted.txt", "after/"])
        XCTAssertEqual(document.archiveUndoStack.slots.count, 3)
    }

    @MainActor func testOpeningSameArchiveTwiceReturnsOneDocument() async throws {
        let fixture = try ScenarioFixture()
        let first = try await NSDocumentController.shared.openDocument(withContentsOf: fixture.archive, display: false)
        let second = try await NSDocumentController.shared.openDocument(withContentsOf: fixture.archive, display: false)
        let document = try XCTUnwrap(first.0 as? ArchiveDocument)
        defer { document.close() }
        XCTAssertTrue(first.0 === second.0)
        XCTAssertTrue(second.1)
        XCTAssertEqual(NSDocumentController.shared.documents.filter { $0.fileURL == fixture.archive }.count, 1)
        let entries = await document.session?.entries()
        XCTAssertEqual(entries?.map(\.name), ["original.txt"])
        document.close()
        await document.sessionCleanup?.value
    }

    @MainActor func testDifferentDocumentsActuallyWriteConcurrently() async throws {
        let script = "with zipfile.ZipFile(p, 'w') as z: z.writestr('large.bin', b'x' * (1024 * 1024))"
        let first = try ScenarioFixture(script: script), second = try ScenarioFixture(script: script)
        let (firstDocument, firstController) = try await scenarioDocument(first)
        let (secondDocument, secondController) = try await scenarioDocument(second)
        let firstGate = ScenarioGate(), secondGate = ScenarioGate()
        defer { firstGate.release(); secondGate.release() }
        var outputs: [URL] = []
        for (fixture, document, controller, gate) in [(first, firstDocument, firstController, firstGate), (second, secondDocument, secondController, secondGate)] {
            let session = try XCTUnwrap(document.session), out = try fixture.folder("out")
            outputs.append(out)
            let tree = EntryNode.tree(from: await session.entries())
            let payloads = ArchiveEntryPayload.payloads(for: tree.children, archiveURL: fixture.archive, generation: 0)
            controller.startExtraction(payloads, session: session, destination: out, showProgress: false, entryCount: 1,
                                       didWrite: { _ in gate.pauseOnce() })
        }
        let tasks = [try XCTUnwrap(firstController.extractionTask), try XCTUnwrap(secondController.extractionTask)]
        try await scenarioWait { firstGate.isEntered && secondGate.isEntered }
        XCTAssertTrue(firstController.operationInFlight && secondController.operationInFlight)
        firstGate.release()
        secondGate.release()
        for task in tasks { await task.value }
        for out in outputs {
            XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("large.bin")), Data(repeating: 0x78, count: 1024 * 1024))
        }
        XCTAssertFalse(firstController.operationInFlight || secondController.operationInFlight)
        XCTAssertTrue(firstDocument.archiveUndoStack.slots.isEmpty && secondDocument.archiveUndoStack.slots.isEmpty)
    }
}
