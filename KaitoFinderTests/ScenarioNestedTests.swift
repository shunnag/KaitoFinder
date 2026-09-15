import AppKit
import Darwin
import Foundation
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioNestedTests: XCTestCase {
    @MainActor func testOpenInnerArchiveShowsTemporaryCopyRefusalAndOuterCloseRemovesIt() async throws {
        let fixture = try ScenarioFixture(script: #"""
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, 'w') as z: z.writestr('inside.txt', b'inner bytes')
        with zipfile.ZipFile(p, 'w') as z: z.writestr('inner.zip', inner.getvalue())
        """#)
        let (outer, controller) = try await scenarioDocument(fixture)
        let before = try ScenarioFixture.digest(fixture.archive)
        controller.outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let materialization = try XCTUnwrap(outer.materializationController())
        controller.openEntry(nil)
        try await scenarioWait {
            guard let url = materialization.item(at: 0)?.previewItemURL else { return false }
            return NSDocumentController.shared.document(for: url)?.windowControllers.first?.window != nil
        }
        let temporary = try XCTUnwrap(materialization.item(at: 0)?.previewItemURL)
        let inner = try XCTUnwrap(NSDocumentController.shared.document(for: temporary) as? ArchiveDocument)
        defer { inner.close() }
        XCTAssertFalse(inner === outer)
        XCTAssertNotEqual(temporary, fixture.archive)
        XCTAssertEqual(try ScenarioFixture.contents(temporary), ["inside.txt": Data("inner bytes".utf8)])
        let session = try XCTUnwrap(inner.session)
        XCTAssertEqual(session.capabilities.refusal, .temporaryCopy)
        let reason = String(localized: "一時的なコピーのため変更できません。")
        XCTAssertEqual(session.capabilities.readOnlyReason, reason)
        let innerController = try XCTUnwrap(inner.windowControllers.first as? ArchiveWindowController)
        try await scenarioWait { innerController.capabilityNotice.stringValue == reason }
        XCTAssertFalse(innerController.validateMenuItem(NSMenuItem(title: "", action: #selector(innerController.newFolder(_:)), keyEquivalent: "")))
        // POSIX属性を変更しても、一時コピーの出自による拒否は維持する。
        XCTAssertEqual(chmod(temporary.path, 0o600), 0)
        try await inner.reloadAfterMutation()
        XCTAssertEqual(session.capabilities.refusal, .temporaryCopy)
        do { _ = try await inner.createFolder(in: "", progress: Progress()); XCTFail("一時コピーを編集しました") }
        catch { XCTAssertEqual(String(describing: error), reason) }
        XCTAssertTrue(inner.archiveUndoStack.slots.isEmpty)
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        outer.close()
        await outer.materializationCleanup?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        inner.close()
        await inner.sessionCleanup?.value
    }

    func testTemporaryCopyNoticeHasAllTenTranslations() throws {
        let key = "一時的なコピーのため変更できません。"
        let translations = try XCTUnwrap(LocalizationAcceptance.catalog().strings[key]).localizations
        XCTAssertEqual(Set(translations.keys), Set(LocalizationAcceptance.languages))
        for language in LocalizationAcceptance.languages {
            XCTAssertEqual(try LocalizationAcceptance.bundle(language).localizedString(forKey: key, value: nil, table: nil),
                           translations[language]?.stringUnit.value)
        }
    }
}
