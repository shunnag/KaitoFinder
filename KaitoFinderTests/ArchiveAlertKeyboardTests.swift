import AppKit
import KaitoKit
import XCTest
@testable import KaitoFinder

// Presentation through a real document window is covered by ArchiveConflictUITests.
nonisolated final class ArchiveAlertKeyboardTests: XCTestCase {
    @MainActor private func installApplicationMenu() throws {
        preserveApplicationMenus()
        let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
        let menu = delegate.makeMenu()
        NSApp.mainMenu = menu
        let save = try menuItem(#selector(ArchiveDocument.saveArchiveDocument(_:)), in: menu)
        XCTAssertEqual(save.keyEquivalent, "s")
        XCTAssertEqual(save.keyEquivalentModifierMask, [.command])
        XCTAssertFalse(save.isHidden)
    }

    @MainActor private func makeConflictPrompt(session: ArchiveSession, bundle: Bundle) -> ArchiveConflictPrompt {
        let item = ArchiveConflictItem(name: "original.txt", location: "archive.zip", kind: .file,
            size: 8, modificationDate: nil, entryCount: 1, source: nil)
        let conflict = ArchiveImportConflict(path: item.name, existing: item, incoming: item, remainingCount: 2)
        return ArchiveConflictPrompt(conflict: conflict, session: session, bundle: bundle)
    }

    @MainActor private func assertConflictShortcuts(_ prompt: ArchiveConflictPrompt,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        let buttons = prompt.alert.buttons
        XCTAssertEqual(buttons.map(\.keyEquivalent), ["", "\r", "\u{1b}"], file: file, line: line)
        XCTAssertEqual(buttons[1].keyEquivalentModifierMask, [], file: file, line: line)
        XCTAssertEqual(buttons[2].keyEquivalentModifierMask, [], file: file, line: line)
        XCTAssertTrue(buttons[0].hasDestructiveAction, file: file, line: line)
        XCTAssertTrue(prompt.alert.window.defaultButtonCell === buttons[1].cell, file: file, line: line)
    }

    @MainActor func testPlainAlertDefaultSurvivesLayoutWithSaveMenu() throws {
        try installApplicationMenu()
        let alert = NSAlert()
        alert.messageText = "Test alert"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        XCTAssertEqual(alert.buttons.map(\.keyEquivalent), ["\r", "\u{1b}"])
        XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[0].cell)
        alert.layout()
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertTrue(alert.window.defaultButtonCell === alert.buttons[0].cell)
    }

    @MainActor func testConflictShortcutsSurviveLayoutWithSaveMenu() throws {
        try installApplicationMenu()
        let fixture = try ScenarioFixture(), session = try ArchiveSession(url: fixture.archive)
        for bundle in [Bundle.main, try LocalizationAcceptance.bundle("ja"), try LocalizationAcceptance.bundle("en")] {
            let prompt = makeConflictPrompt(session: session, bundle: bundle)
            assertConflictShortcuts(prompt)
            prompt.alert.layout()
            assertConflictShortcuts(prompt)
        }
    }

    @MainActor private func otherAlerts() throws -> [NSAlert] {
        let password = ArchivePasswordPrompt(challenge: .required)
        let editors = [ArchivePasswordAction.set, .change, .remove].map {
            ArchivePasswordEditor(action: $0, format: .zip, archiveName: "archive.zip")
        }
        let report = ArchiveBatchExtractor.Report(extracted: [], failures: [
            .init(archive: URL(fileURLWithPath: "/tmp/archive.zip"), reason: "Test failure")
        ], cancelled: false)
        return [password.alert] + editors.map(\.alert) + [
            ArchiveConversionNotice.makeAlert(formatName: "ZIP", entries: []),
            ArchiveWindowController.makeDeletionConfirmation(),
            ArchiveWindowController.makeEditFailureAlert("Test failure"),
            ArchiveWindowController.makeImportFailureAlert("Test failure"),
            ArchiveWindowController.makeFailureAlert("Test failure"),
            try XCTUnwrap(ArchiveBatchExtractionController.failureAlert(for: report))
        ]
    }

    @MainActor func testOtherAlertDefaultsSurviveLayoutWithSaveMenu() throws {
        try installApplicationMenu()
        for alert in try otherAlerts() {
            alert.layout()
            // No ordering, activation, or GUI-session precondition belongs in a layout test.
            let cell = try XCTUnwrap(alert.window.defaultButtonCell, alert.messageText)
            XCTAssertEqual(cell.keyEquivalent, "\r", alert.messageText)
            alert.layout()
            XCTAssertTrue(alert.window.defaultButtonCell === cell, alert.messageText)
            XCTAssertEqual(cell.keyEquivalent, "\r", alert.messageText)
        }
    }
}
