import AppKit
import Darwin
import Foundation
import XCTest
@testable import KaitoFinder

nonisolated final class ScenarioExternalChangeTests: XCTestCase {
    @MainActor func testReplacementWithIdenticalNamesRefusesEveryEditAndPreservesUndo() async throws {
        for operation in 0..<4 {
            let fixture = try ScenarioFixture(), (document, controller) = try await scenarioDocument(fixture)
            let node = try XCTUnwrap(controller.outlineView.item(atRow: 0) as? EntryNode)
            let replacement = try fixture.pythonArchive("replacement.zip", script: "with zipfile.ZipFile(p, 'w') as z: z.writestr('original.txt', b'replaced')")
            XCTAssertEqual(Darwin.rename(replacement.path, fixture.archive.path), 0)
            let before = try ScenarioFixture.digest(fixture.archive), source = try fixture.file("new.txt")
            do {
                switch operation {
                case 0: _ = try await document.append(urls: [source], to: "", progress: Progress())
                case 1: _ = try await document.createFolder(in: "", progress: Progress())
                case 2: _ = try await document.remove([node], progress: Progress())
                default: _ = try await document.rename(node, to: "renamed.txt", progress: Progress())
                }
                XCTFail("差し替え前の内容に対する編集を公開しました")
            } catch {
                XCTAssertEqual(error as? ArchiveEditError, .archiveChanged)
                XCTAssertEqual(error.localizedDescription, String(localized: "アーカイブが変更されています。開き直してください。"))
            }
            XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
            XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
            XCTAssertFalse(try XCTUnwrap(document.undoManager).canUndo)
            XCTAssertEqual(document.generation, 0)
        }
    }

    @MainActor func testDeletedSourceRefusesExtractionAndEditAndWindowCanReload() async throws {
        let fixture = try ScenarioFixture(), (document, controller) = try await scenarioDocument(fixture)
        let session = try XCTUnwrap(document.session), out = try fixture.folder("out")
        let original = try Data(contentsOf: fixture.archive)
        try FileManager.default.removeItem(at: fixture.archive)
        for extracting in [true, false] {
            do {
                if extracting { _ = try await fixture.extract(to: out, session: session) }
                else { _ = try await document.createFolder(in: "", progress: Progress()) }
                XCTFail("削除された原本への操作を受理しました")
            } catch {
                XCTAssertEqual(String(describing: error), String(localized: "アーカイブの原本を確認できません。"))
            }
        }
        XCTAssertTrue(try ScenarioFixture.files(under: out).isEmpty)
        XCTAssertTrue(document.archiveUndoStack.slots.isEmpty)
        XCTAssertNotNil(controller.window)
        controller.setFilterQuery("original")
        XCTAssertEqual(controller.outlineView.numberOfRows, 1)
        try original.write(to: fixture.archive)
        try await document.reloadAfterMutation()
        _ = try await document.createFolder(in: "", baseName: "recovered", progress: Progress())
        XCTAssertTrue(try ScenarioFixture.contents(fixture.archive).keys.contains("original.txt"))
        XCTAssertTrue(try XCTUnwrap(document.undoManager).canUndo)
    }

    @MainActor func testReloadOfEncryptedReplacementUpdatesFormatAndReadOnlyCapability() async throws {
        let fixture = try ScenarioFixture(), (document, controller) = try await scenarioDocument(fixture)
        let source = try fixture.file("secret.txt"), replacement = fixture.root.appendingPathComponent("encrypted.7z")
        try fixture.directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-psecret", "-mhe=off", replacement.path, source.path])
        XCTAssertEqual(Darwin.rename(replacement.path, fixture.archive.path), 0)
        try await document.reloadAfterMutation()
        let session = try XCTUnwrap(document.session)
        XCTAssertEqual(session.format, .sevenZip)
        XCTAssertEqual(session.capabilities.refusal, .encrypted)
        XCTAssertEqual(controller.capabilityNotice.stringValue, session.capabilities.readOnlyReason)
        XCTAssertFalse(controller.validateMenuItem(NSMenuItem(title: "", action: #selector(controller.newFolder(_:)), keyEquivalent: "")))
        let entries = await session.entries()
        XCTAssertEqual(entries.map(\.name), ["secret.txt"])
        XCTAssertTrue(entries.allSatisfy(\.isEncrypted))
    }
}
