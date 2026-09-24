import AppKit
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveSplitSaveAsTests: XCTestCase {
    @MainActor func testSaveAsBothModesSameNoneAndCustomKeepsOriginalAndSwitchesDocument() async throws {
        for behavior: ArchivePreferences.SaveBehavior in [.immediate, .onSave] {
            for choice in 0..<3 { // original, none, custom
                let fixture = try DeferredSplitSaveFixture(format: .zip, behavior: behavior), document = fixture.document
                defer { document.close() }
                var expected = fixture.contents
                if behavior == .onSave {
                    _ = try await document.rename(fixture.node("file0.txt"), to: "pending.txt", progress: Progress())
                    _ = try await document.append(urls: [fixture.file(count: 95000)], to: "", progress: Progress())
                    expected["pending.txt"] = expected.removeValue(forKey: "file0.txt")
                    expected["added.txt"] = DeferredSplitSaveFixture.bytes(95000)
                }
                let destination = fixture.root.appendingPathComponent("new-name.zip")
                let creator = ArchiveCreationController(store: fixture.store)
                creator.destinationHandler = { save, _ in
                    let controls = try XCTUnwrap(save.splitControls)
                    XCTAssertEqual(controls.choices.indexOfSelectedItem, 1)
                    XCTAssertEqual(try controls.schedule(), .uniform(size: UInt64(fixture.size)))
                    save.formatPopup.selectItem(at: try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: .zip)))
                    save.changeFormat(save.formatPopup)
                    if choice == 1 { controls.choices.selectItem(at: 0) }
                    if choice == 2 {
                        controls.choices.selectItem(at: controls.choices.numberOfItems - 1)
                        controls.number.stringValue = "64"; controls.units.selectItem(at: 0)
                    }
                    controls.changeChoice(nil)
                    return destination
                }
                if behavior == .onSave { try await document.savePendingAs(using: creator, on: nil, progress: Progress()) }
                else {
                    let controller = ArchiveWindowController(preferencesStore: fixture.store)
                    document.addWindowController(controller)
                    let session = try XCTUnwrap(document.session), snapshot = await session.snapshot()
                    controller.display(EntryNode.tree(from: snapshot.entries), session: session,
                        materializationController: document.materializationController())
                    try await controller.saveArchiveAs(using: creator)
                }
                let output = choice == 1 ? destination : destination.appendingPathExtension("001")
                XCTAssertEqual(document.fileURL?.resolvingSymlinksInPath(), output.resolvingSymlinksInPath())
                XCTAssertEqual(document.session?.sourceURL.resolvingSymlinksInPath(), output.resolvingSymlinksInPath())
                XCTAssertEqual(try fixture.parts(), fixture.original)
                XCTAssertEqual(try DeferredSaveFixture.contents(output), expected)
                XCTAssertEqual(document.fileModificationDate, try FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate] as? Date)
                XCTAssertFalse(document.isDocumentEdited)
                XCTAssertFalse(document.undoManager!.canUndo)
                XCTAssertTrue(document.pendingChanges.isEmpty)
                if choice == 1 {
                    XCTAssertNil(document.session?.volumeLayout)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("001").path))
                } else {
                    let size = UInt64(choice == 0 ? fixture.size : 65536)
                    let layout = try XCTUnwrap(document.session?.volumeLayout)
                    XCTAssertEqual(layout.savedSchedule, .uniform(size: size))
                    XCTAssertTrue(layout.volumes.dropLast().allSatisfy { $0.length == size })
                    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.nextVolumeURL.path))
                    let joined = try layout.volumes.reduce(into: Data()) { $0.append(try Data(contentsOf: $1.url)) }
                    XCTAssertEqual(joined, fixture.work.bytes)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("new-name.z01").path))
                }
            }
        }
    }

    @MainActor func testSingleFileSourceCustomSplitAndOneVolumeMetadata() async throws {
        for behavior: ArchivePreferences.SaveBehavior in [.immediate, .onSave] {
            let fixture = try DeferredSaveFixture(behavior: behavior), document = fixture.document
            defer { document.close() }
            let creator = ArchiveCreationController(store: fixture.store)
            let output = fixture.directory.url.appendingPathComponent("single-to-split.zip")
            creator.destinationHandler = { save, _ in
                let controls = try XCTUnwrap(save.splitControls)
                XCTAssertNil(try controls.schedule()); XCTAssertEqual(controls.choices.numberOfItems, 2)
                controls.choices.selectItem(at: 1); controls.number.stringValue = "64"; controls.units.selectItem(at: 0)
                return output
            }
            if behavior == .onSave { try await document.savePendingAs(using: creator, on: nil, progress: Progress()) }
            else {
                document.configureSplitCreation(creator)
                let existing = try await ArchiveCreationController.existingArchive(from: XCTUnwrap(document.session), progress: Progress())
                let gate = try await creator.create(sources: [], existing: existing)
                try await document.switchBackingFile(to: XCTUnwrap(gate))
            }
            let gate = output.appendingPathExtension("001")
            XCTAssertEqual(document.fileURL?.resolvingSymlinksInPath(), gate.resolvingSymlinksInPath())
            XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
            XCTAssertEqual(document.session?.volumeLayout?.volumes.count, 1)
            XCTAssertEqual(document.session?.volumeLayout?.uniformSize, 65536)
            let reopened = try ArchiveSession(url: gate, allowsImmediateSplitSave: true)
            XCTAssertTrue(reopened.capabilities.splitIrreversible)
            XCTAssertEqual(reopened.volumeLayout?.savedSchedule, .uniform(size: 65536))
            await reopened.close()
        }
    }

    @MainActor func testNewSetRejectsGateEveryPlannedMemberAndNextNameBeforeWriting() async throws {
        let fixture = try DeferredSplitSaveFixture(format: .tar), session = try XCTUnwrap(fixture.document.session)
        defer { fixture.document.close() }
        let existing = try await ArchiveCreationController.existingArchive(from: session, progress: Progress())
        let destination = fixture.root.appendingPathComponent("new.tar")
        let size = UInt64(fixture.size)
        // Stored tar W has the same length as the original (all entries carried unchanged).
        let length = fixture.original.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        let volumes = try VolumePlan(totalLength: length, schedule: .uniform(size: size), scheme: .numbered(stem: "new.tar", width: 3))
        var plan = ArchiveCreationPlan(sources: [], destination: destination, format: .tar, existing: existing)
        plan.splitSchedule = .uniform(size: size)
        for name in volumes.volumes.map(\.name) + [volumes.nextVolumeName] {
            let occupied = fixture.root.appendingPathComponent(name), sentinel = Data("keep occupant".utf8)
            try sentinel.write(to: occupied)
            var hooks = ArchiveSplitSaveHooks()
            hooks.didProduceWork = { _ in XCTFail("Must refuse occupied names before W") }
            XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: plan, progress: Progress(),
                volumeIndex: fixture.index, metadataStore: fixture.metadata, splitHooks: hooks)) { error in
                    XCTAssertEqual((error as? ArchiveSplitSaveFailure)?.errorDescription, String(localized: "同じ名前の分割ファイルが既にあります。"))
                }
            XCTAssertEqual(try Data(contentsOf: occupied), sentinel)
            XCTAssertEqual(try fixture.parts(), fixture.original)
            XCTAssertTrue(try fixture.index.entries().isEmpty)
            try FileManager.default.removeItem(at: occupied)
        }
    }

    @MainActor func testLateCollisionPreservesForeignFileAndSource() async throws {
        let fixture = try DeferredSplitSaveFixture(), session = try XCTUnwrap(fixture.document.session)
        defer { fixture.document.close() }
        let existing = try await ArchiveCreationController.existingArchive(from: session, progress: Progress())
        let destination = fixture.root.appendingPathComponent("collision.7z"), foreign = destination.appendingPathExtension("001")
        var plan = ArchiveCreationPlan(sources: [], destination: destination, format: .sevenZip, existing: existing)
        plan.splitSchedule = .uniform(size: 65536)
        XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: plan, progress: Progress(), willPublish: {
            try Data("foreign".utf8).write(to: foreign)
        }, volumeIndex: fixture.index, metadataStore: fixture.metadata))
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
        XCTAssertEqual(try fixture.parts(), fixture.original)
        XCTAssertTrue(try fixture.index.entries().isEmpty)
    }

    @MainActor func testSplitControlsValidateSizeAndKeepAccessoryDimensionsStable() throws {
        let defaults = try ArchivePreferencesTestDefaults()
        let save = ArchiveSavePanel(sources: [], existingURL: URL(fileURLWithPath: "/tmp/source.zip"), defaults: defaults.defaults)
        let controls = try XCTUnwrap(save.splitControls), accessory = try XCTUnwrap(save.panel.accessoryView)
        let before = accessory.fittingSize
        controls.choices.selectItem(at: 1); controls.changeChoice(nil)
        controls.units.selectItem(at: 0)
        for invalid in ["0", "63", "-64", "nan", "999999999999999999999999999"] {
            controls.number.stringValue = invalid
            XCTAssertThrowsError(try controls.schedule(), invalid)
        }
        controls.number.stringValue = "64"
        XCTAssertEqual(try controls.schedule(), .uniform(size: 65536))
        for (unit, size) in [(0, UInt64(65536)), (1, UInt64(67108864)), (2, UInt64(68719476736))] {
            controls.units.selectItem(at: unit)
            XCTAssertEqual(try controls.schedule(), .uniform(size: size))
        }
        accessory.layoutSubtreeIfNeeded()
        XCTAssertEqual(accessory.fittingSize, before)
        XCTAssertNil(ArchiveSavePanel(sources: [], defaults: defaults.defaults).splitControls, "New Archive remains unchanged")
    }

    @MainActor func testSplitAccessoryFitsEveryLanguageWithEncryption() throws {
        let layout = ArchiveVolumeLayout(scheme: .numbered(stem: "original.zip", width: 3),
            volumes: [.init(url: URL(fileURLWithPath: "/tmp/original.zip.001"), length: 65536)], openedVolumeIndex: 0)
        for language in LocalizationAcceptance.languages {
            let bundle = try LocalizationAcceptance.bundle(language)
            let fields = ArchivePasswordFields(format: .zip, minimumLabelWidth: ArchiveSavePanel.minimumLabelWidth(bundle: bundle), bundle: bundle)
            let formats = NSPopUpButton(), levels = NSPopUpButton()
            formats.addItem(withTitle: "ZIP"); levels.addItem(withTitle: String(localized: "標準", bundle: bundle))
            let controls = ArchiveSaveSplitControls(layout: layout, bundle: bundle)
            let accessory = ArchiveSavePanel.makeAccessoryView(formatPopup: formats, levelPopup: levels,
                fixedLevelNote: ArchiveSavePanel.makeNote("", width: fields.width),
                encryptionCheckbox: NSButton(checkboxWithTitle: String(localized: "暗号化", bundle: bundle), target: nil, action: nil),
                passwordFields: fields, encryptionNote: ArchiveSavePanel.makeNote("", width: fields.width),
                splitControls: controls, bundle: bundle)
            ArchivePasswordLayout.size(accessory)
            try UISnapshot.render(accessory, name: "save-split-" + language)
            XCTAssertTrue(UISnapshot.overflowViolations(in: accessory).isEmpty, language)
        }
    }

    @MainActor func testFATAndExFATNewSetMetadataStaysInApplicationStore() async throws {
        for format in ["MS-DOS FAT32", "ExFAT"] {
            let disk = try VolumePublishTestDisk(format)
            addTeardownBlock { try disk.detach() }
            let fixture = try DeferredSplitSaveFixture(), session = try XCTUnwrap(fixture.document.session)
            defer { fixture.document.close() }
            let existing = try await ArchiveCreationController.existingArchive(from: session, progress: Progress())
            let output = disk.mount.appendingPathComponent("saved.7z")
            var plan = ArchiveCreationPlan(sources: [], destination: output, format: .sevenZip, existing: existing)
            plan.splitSchedule = .uniform(size: 65536); plan.allowHazardousVolume = true
            let gate = try ArchiveCreationTransaction.run(plan: plan, progress: Progress(), volumeIndex: fixture.index, metadataStore: fixture.metadata)
            XCTAssertEqual(try DeferredSaveFixture.contents(gate), fixture.contents)
            XCTAssertEqual(try fixture.metadata.entry(for: gate)?.publication.layout.schedule, .uniform(size: 65536))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: disk.mount.path).contains { $0.hasPrefix("._") })
            let reopened = try ArchiveSession(url: gate, allowsImmediateSplitSave: true, volumeMetadataStore: fixture.metadata)
            XCTAssertEqual(reopened.volumeLayout?.uniformSize, 65536)
            await reopened.close()
        }
    }
}
