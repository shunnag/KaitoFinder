import AppKit
import GyoshukuKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePasswordUITests: XCTestCase {
    @MainActor func testSavePanelDelegateValidatesEmptyMismatchAndMatchingPasswords() throws {
        let suite = try ArchivePreferencesTestDefaults()
        let save = ArchiveSavePanel(sources: [], defaults: suite.defaults)
        let destination = URL(fileURLWithPath: "/tmp/password.zip")
        XCTAssertTrue(save.panel.delegate === save)
        XCTAssertEqual(save.encryptionCheckbox.state, .off)
        XCTAssertEqual(save.passwordFields.methodPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(save.passwordFields.headersCheckbox.state, .off)
        XCTAssertNoThrow(try save.panel(save.panel, validate: destination))
        save.encryptionCheckbox.state = .on
        save.changeEncryption(save.encryptionCheckbox)
        XCTAssertThrowsError(try save.panel(save.panel, validate: destination)) {
            XCTAssertEqual(($0 as NSError).localizedDescription, String(localized: "パスワードを入力してください。"))
        }
        save.passwordFields.passwordField.stringValue = "first"
        save.passwordFields.verifyField.stringValue = "second"
        XCTAssertThrowsError(try save.panel(save.panel, validate: destination)) {
            XCTAssertEqual(($0 as NSError).localizedDescription, String(localized: "パスワードが一致しません。"))
        }
        save.passwordFields.verifyField.stringValue = "first"
        XCTAssertNoThrow(try save.panel(save.panel, validate: destination))
        XCTAssertNotNil(save.encryptionSettings.password)
    }

    @MainActor func testFormatSwitchPreservesFieldsAndDisablesUnsupportedEncryptionWithStableHeight() throws {
        let suite = try ArchivePreferencesTestDefaults()
        let save = ArchiveSavePanel(sources: [], defaults: suite.defaults)
        save.encryptionCheckbox.state = .on
        save.passwordFields.fill(.init(password: "kept", zipEncryption: .zipCrypto, encryptsSevenZipHeaders: true))
        save.changeEncryption(save.encryptionCheckbox)
        let accessory = try XCTUnwrap(save.panel.accessoryView), initialHeight = accessory.frame.height
        for (index, format) in ArchiveSavePanelController.formats.enumerated() {
            save.formatPopup.selectItem(at: index)
            save.changeFormat(save.formatPopup)
            let supported = format == .zip || format == .sevenZip
            XCTAssertEqual(save.encryptionCheckbox.isEnabled, supported)
            XCTAssertEqual(save.encryptionNote.isHidden, supported)
            XCTAssertEqual(save.passwordFields.view.isHidden, !supported)
            XCTAssertTrue(save.passwordFields.passwordField.stringValue == "kept")
            XCTAssertTrue(save.passwordFields.verifyField.stringValue == "kept")
            XCTAssertEqual(save.passwordFields.headersCheckbox.isHidden, format != .sevenZip)
            XCTAssertEqual(save.passwordFields.methodPopup.isHiddenOrHasHiddenAncestor, format != .zip)
            XCTAssertEqual(save.encryptionSettings.password != nil, supported)
            XCTAssertEqual(accessory.frame.height, initialHeight, accuracy: 0.5)
            if !supported {
                save.passwordFields.verifyField.stringValue = "mismatch"
                XCTAssertNoThrow(try save.panel(save.panel, validate: URL(fileURLWithPath: "/tmp/output")))
                save.passwordFields.verifyField.stringValue = "kept"
            }
        }
    }

    @MainActor func testPlanCarriesPasswordMethodAndHeadersWithoutOverwritingPreferences() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.zipSkipsCompressedTypes = false
        let creator = ArchiveCreationController(store: store)
        for format in ArchiveSavePanelController.formats {
            let plan = creator.creationPlan(sources: [], destination: URL(fileURLWithPath: "/tmp/output"), format: format,
                level: .maximum, encryption: .init(password: "chosen", zipEncryption: .zipCrypto, encryptsSevenZipHeaders: true))
            XCTAssertEqual(plan.options.password != nil, format == .zip || format == .sevenZip)
            XCTAssertEqual(plan.options.zipEncryption, .zipCrypto)
            XCTAssertEqual(plan.options.encryptsSevenZipHeaders, format == .sevenZip)
            if format == .zip {
                XCTAssertFalse(plan.options.useCompressionHeuristic)
                XCTAssertEqual(plan.options.deflateLevel, 9)
            }
        }
        XCTAssertNil(store.preferences.writerOptions(for: .zip).password)
    }

    @MainActor func testSetAndChangeSheetsValidateInlineAndNeverPrefillTheOldPassword() throws {
        for action in [ArchivePasswordAction.set, .change] {
            let editor = ArchivePasswordEditor(action: action, format: .zip, archiveName: "example.zip",
                                               settings: .init(password: "old", zipEncryption: .zipCrypto))
            let fields = try XCTUnwrap(editor.fields)
            XCTAssertTrue(fields.passwordField.stringValue.isEmpty)
            XCTAssertEqual(fields.methodPopup.indexOfSelectedItem, 1)
            XCTAssertFalse(try XCTUnwrap(editor.alert.buttons.first).isEnabled)
            XCTAssertEqual(fields.notice.stringValue, String(localized: "パスワードを入力してください。"))
            fields.passwordField.stringValue = "new"
            fields.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            XCTAssertEqual(fields.notice.stringValue, String(localized: "パスワードが一致しません。"))
            XCTAssertFalse(editor.alert.buttons[0].isEnabled)
            fields.verifyField.stringValue = "new"
            fields.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            XCTAssertTrue(fields.notice.stringValue.isEmpty)
            XCTAssertTrue(editor.alert.buttons[0].isEnabled)
        }
    }

    @MainActor func testVisibleSavePanelPasswordRowsAndAllThreeSheetsFitInEveryLanguage() throws {
        for language in LocalizationAcceptance.languages {
            let bundle = try LocalizationAcceptance.bundle(language)
            // NSSavePanel の XPC サービスがない環境でも、本番のアクセサリ自体を描画する。
            let fields = ArchivePasswordFields(format: .zip, bundle: bundle)
            fields.fill(.init(password: "snapshot", zipEncryption: .zipCrypto))
            let formats = NSPopUpButton(frame: .zero, pullsDown: false)
            formats.addItems(withTitles: ArchiveSavePanelController.formats.map { ArchiveSavePanelController.title(for: $0, bundle: bundle) })
            let levels = NSPopUpButton(frame: .zero, pullsDown: false)
            levels.addItems(withTitles: ArchiveSavePanelController.Level.allCases.map { $0.title(bundle: bundle) })
            let checkbox = NSButton(checkboxWithTitle: String(localized: "暗号化", bundle: bundle), target: nil, action: nil)
            checkbox.state = .on
            let fixedNote = ArchiveSavePanel.makeNote(String(localized: "7z と LHA の圧縮レベルは固定です", bundle: bundle), width: fields.width)
            let encryptionNote = ArchiveSavePanel.makeNote(String(localized: "tar と LHA は暗号化できません", bundle: bundle), width: fields.width)
            let accessory = ArchiveSavePanel.makeAccessoryView(formatPopup: formats, levelPopup: levels, fixedLevelNote: fixedNote,
                encryptionCheckbox: checkbox, passwordFields: fields, encryptionNote: encryptionNote, bundle: bundle)
            let height = accessory.frame.height
            for (index, format) in ArchiveSavePanelController.formats.enumerated() {
                formats.selectItem(at: index)
                fields.selectFormat(format)
                checkbox.isEnabled = ArchiveEncryptionSettings.supports(format)
                fields.view.isHidden = !checkbox.isEnabled
                fixedNote.isHidden = format != .sevenZip && format != .lha
                encryptionNote.isHidden = checkbox.isEnabled
                ArchivePasswordLayout.size(accessory)
                XCTAssertEqual(accessory.frame.height, height, accuracy: 0.5, language)
                XCTAssertTrue(fields.passwordField.stringValue == "snapshot")
                XCTAssertTrue(fields.verifyField.stringValue == "snapshot")
                let name = "\(language)-encryption-save-\(ArchiveCreationPlan.filenameExtension(for: format))"
                try UISnapshot.render(accessory, name: name)
                XCTAssertTrue(UISnapshot.overflowViolations(in: accessory).isEmpty,
                              name + "\n" + UISnapshot.overflowViolations(in: accessory).joined(separator: "\n"))
            }
            for action in ArchivePasswordAction.allCases {
                for format in [GyoshukuKit.ArchiveFormat.zip, .sevenZip] {
                    let editor = ArchivePasswordEditor(action: action, format: format,
                        archiveName: String(repeating: "旅行の写真", count: 14) + ".zip",
                        settings: .init(zipEncryption: .zipCrypto), bundle: bundle)
                    for state in ["empty", "mismatch", "valid"] {
                        if state != "empty" { editor.fields?.passwordField.stringValue = "snapshot" }
                        if state == "valid" { editor.fields?.verifyField.stringValue = "snapshot" }
                        editor.refreshValidation()
                        let name = "\(language)-password-\(action)-\(format)-\(state)"
                        try UISnapshot.render(editor.alert, name: name)
                        let content = try XCTUnwrap(editor.alert.window.contentView)
                        let failures = UISnapshot.overflowViolations(in: content)
                        XCTAssertTrue(failures.isEmpty, name + "\n" + failures.joined(separator: "\n"))
                        XCTAssertLessThanOrEqual(editor.alert.window.frame.width, 800, name)
                        if action == .remove { break }
                    }
                }
            }
        }
    }
}
