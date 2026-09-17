import AppKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveConflictUITests: XCTestCase {
    @MainActor private func drop(_ urls: [URL], into controller: ArchiveWindowController) throws {
        let view = controller.outlineView
        let info = FileURLDragInfo(urls: urls, window: controller.window, location: .zero)
        defer { info.draggingPasteboard.releaseGlobally() }
        XCTAssertTrue(controller.outlineView(view, acceptDrop: info, item: nil, childIndex: -1))
        XCTAssertTrue(controller.operationInFlight)
    }

    @MainActor func testDropComparesBothContentsAndReplacesAsOneUndoableBatch() async throws {
        NSApp.activate(ignoringOtherApps: true)
        let fixture = try ScenarioFixture(), source = try fixture.file("in/original.txt", bytes: Data("new contents".utf8))
        let extra = try fixture.file("in/extra.txt")
        let (document, controller) = try await scenarioDocument(fixture), before = try ScenarioFixture.digest(fixture.archive)
        controller.showWindow(nil)
        try drop([source, extra], into: controller)
        try await scenarioWait { controller.conflictPrompt != nil }
        let prompt = try XCTUnwrap(controller.conflictPrompt)
        XCTAssertTrue(prompt.alert.window.sheetParent === controller.window)
        XCTAssertEqual(prompt.conflict.existing.size, 8)
        XCTAssertEqual(prompt.conflict.incoming.size, 12)
        XCTAssertTrue(prompt.alert.buttons[0].hasDestructiveAction)
        XCTAssertEqual(prompt.alert.buttons[1].keyEquivalent, "\r")
        XCTAssertNil(prompt.applyToRemaining.superview)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            prompt.alert.window.appearance = NSAppearance(named: appearance)
            try UISnapshot.render(prompt.alert, name: "conflict-presented-\(appearance.rawValue)")
            let violations = UISnapshot.overflowViolations(in: try XCTUnwrap(prompt.alert.accessoryView))
            XCTAssertTrue(violations.isEmpty, violations.joined(separator: "\n"))
        }
        prompt.compareButton.performClick(nil)
        try await scenarioWait { prompt.preview?.loadedURLs.allSatisfy { $0 != nil } == true }
        let preview = try XCTUnwrap(prompt.preview)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preview.loadedURLs[0])), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preview.loadedURLs[1])), Data("new contents".utf8))
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        try UISnapshot.render(try XCTUnwrap(preview.window), name: "conflict-content-comparison")
        if let path = ProcessInfo.processInfo.environment["KAITOFINDER_CONFLICT_CAPTURE_DIRECTORY"] {
            // Quick Look の XPC 描画は cacheDisplay に含まれないため、実画面の検証を別に行う。
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try await Task.sleep(for: .seconds(1))
            let request: [String: Any] = ["window": try XCTUnwrap(preview.window).windowNumber,
                                         "bundle": Bundle.main.bundleIdentifier ?? ""]
            try JSONSerialization.data(withJSONObject: request).write(to: directory.appendingPathComponent("request.json"), options: .atomic)
            try await scenarioWait { FileManager.default.fileExists(atPath: directory.appendingPathComponent("complete").path) }
        }
        preview.close()
        prompt.alert.buttons[0].performClick(nil)
        await controller.extractionTask?.value
        XCTAssertNil(controller.failureAlert)
        XCTAssertNil(controller.conflictPrompt)
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), ["original.txt": Data("new contents".utf8), "extra.txt": Data("added".utf8)])
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        XCTAssertFalse(document.undoManager?.canUndo == true)
    }

    @MainActor func testMultipleConflictSheetsUseReplaceThenSkipRemainingAndStillAddNewFiles() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z:\n for n in ['a', 'b', 'c']: z.writestr(n, n.encode())")
        let sources = try ["a", "b", "c", "d"].map { try fixture.file("in/" + $0) }
        let (document, controller) = try await scenarioDocument(fixture)
        controller.showWindow(nil)
        try drop(sources, into: controller)
        try await scenarioWait { controller.conflictPrompt?.conflict.path == "a" }
        let first = try XCTUnwrap(controller.conflictPrompt)
        XCTAssertEqual(first.conflict.remainingCount, 3)
        XCTAssertNotNil(first.applyToRemaining.superview)
        first.alert.buttons[0].performClick(nil)
        try await scenarioWait { controller.conflictPrompt?.conflict.path == "b" }
        let second = try XCTUnwrap(controller.conflictPrompt)
        XCTAssertEqual(second.conflict.remainingCount, 2)
        XCTAssertEqual(second.applyToRemaining.state, .off)
        second.applyToRemaining.performClick(nil)
        second.alert.buttons[1].performClick(nil)
        await controller.extractionTask?.value
        XCTAssertNil(controller.failureAlert)
        XCTAssertNil(controller.conflictPrompt)
        XCTAssertEqual(document.generation, 1)
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), ["a": Data("added".utf8), "b": Data("b".utf8), "c": Data("c".utf8), "d": Data("added".utf8)])
    }

    @MainActor func testCancelAndWindowClosureWhileAwaitingChoiceLeaveNoMutationOrHangingTask() async throws {
        for closeWindow in [false, true] {
            let fixture = try ScenarioFixture(), source = try fixture.file("in/original.txt")
            let (document, controller) = try await scenarioDocument(fixture), before = try ScenarioFixture.digest(fixture.archive)
            controller.showWindow(nil)
            try drop([source], into: controller)
            try await scenarioWait { controller.conflictPrompt != nil }
            let task = try XCTUnwrap(controller.extractionTask)
            if closeWindow { document.close() }
            else { controller.conflictPrompt?.alert.buttons[2].performClick(nil) }
            await task.value
            XCTAssertNil(controller.conflictPrompt)
            XCTAssertNil(controller.extractionTask)
            XCTAssertNil(controller.failureAlert)
            XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
            XCTAssertFalse(document.undoManager?.canUndo == true)
        }
    }

    @MainActor func testComparisonLayoutInEveryLanguageAndAppearanceWithLongNames() async throws {
        let fixture = try ScenarioFixture(), session = try ArchiveSession(url: fixture.archive)
        let name = String(repeating: "旅行 Report ", count: 12) + ".txt"
        let item = ArchiveConflictItem(name: name, location: "/Users/Test/" + name, kind: .file,
            size: 1_234_567, modificationDate: Date(timeIntervalSince1970: 1_760_000_000), entryCount: 1,
            source: .file(fixture.archive))
        let conflict = ArchiveImportConflict(path: name, existing: item, incoming: item, remainingCount: 1000)
        for language in LocalizationAcceptance.languages {
            let bundle = try LocalizationAcceptance.bundle(language)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let prompt = ArchiveConflictPrompt(conflict: conflict, session: session, bundle: bundle)
                prompt.alert.window.appearance = NSAppearance(named: appearance)
                try UISnapshot.render(prompt.alert, name: "\(language)-conflict-long-\(appearance.rawValue)")
                let violations = UISnapshot.overflowViolations(in: try XCTUnwrap(prompt.alert.window.contentView))
                XCTAssertTrue(violations.isEmpty, "\(language): \(violations)")
                XCTAssertLessThanOrEqual(prompt.alert.window.frame.width, 720)
            }
        }
    }
}
