import AppKit
import GyoshukuKit
import KaitoKit
import ObjectiveC
import XCTest
@testable import KaitoFinder

/// presentFailure が AppKit に渡すエラーを記録し、テスト中のアプリ全体のモーダルを防ぐ。
@MainActor private final class ReadOnlyConversionErrors {
    private var method: Method?
    private var original: IMP?
    private var replacement: IMP?
    private(set) var errors: [NSError] = []
    private(set) var errorsBeforeFormatChoice: [NSError] = []
    var formatChoiceCount = 0

    init() throws {
        let method = try XCTUnwrap(class_getInstanceMethod(type(of: NSApplication.shared),
                                                          #selector(NSApplication.presentError(_:))))
        let record: @convention(block) (NSApplication, NSError) -> Bool = { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.errors.append(error)
                if self.formatChoiceCount == 0 { self.errorsBeforeFormatChoice.append(error) }
            }
            return false
        }
        let replacement = imp_implementationWithBlock(record)
        original = method_setImplementation(method, replacement)
        self.method = method
        self.replacement = replacement
    }

    func restore() {
        guard let method, let original, let replacement else { return }
        method_setImplementation(method, original)
        imp_removeBlock(replacement)
        self.method = nil
        self.original = nil
        self.replacement = nil
    }

    isolated deinit { restore() }
}

nonisolated final class ReadOnlyDropConversionUITests: XCTestCase {
    @MainActor func testNativeDropIntoReadOnlyArchiveConvertsToTarAfterChoosingFormat() async throws {
        try await assertConversion(format: .tar)
    }

    @MainActor func testNativeDropIntoReadOnlyArchiveRefusesZIPAfterChoosingFormat() async throws {
        try await assertConversion(format: .zip)
    }

    @MainActor private func assertConversion(format: GyoshukuKit.ArchiveFormat) async throws {
        _ = NSApplication.shared
        let fixture = try ScenarioFixture(script: #"""
        with tarfile.open(p, 'w') as t:
            entry = tarfile.TarInfo(r'x\y')
            entry.size = len(b'payload')
            t.addfile(entry, io.BytesIO(b'payload'))
        """#, suffix: "tar")
        let tarBzip2 = try fixture.pythonArchive("original.tar.bz2", script: """
        with tarfile.open(p, 'w:bz2') as t:
            entry = tarfile.TarInfo('old.txt')
            entry.size = len(b'original content')
            t.addfile(entry, io.BytesIO(b'original content'))
        """)
        // ConversionIncomingNameTests と同じ外側の圧縮で、編集非対応の書庫を作る。
        let readOnly = fixture.root.appendingPathComponent("original.tar.lzma")
        try fixture.directory.run(ExternalTool.python3, ["-c", "import bz2, lzma, sys; open(sys.argv[2], 'wb').write(lzma.compress(bz2.decompress(open(sys.argv[1], 'rb').read()), format=lzma.FORMAT_ALONE))", tarBzip2.path, readOnly.path])
        let sourceDigest = try ScenarioFixture.digest(fixture.archive)
        let targetDigest = try ScenarioFixture.digest(readOnly)
        defer {
            XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), sourceDigest)
            XCTAssertEqual(try ScenarioFixture.digest(readOnly), targetDigest)
        }
        let defaults = try ArchivePreferencesTestDefaults()
        let store = ArchivePreferencesStore(defaults: defaults.defaults)
        let (sourceDocument, source) = try await scenarioDocument(fixture, preferencesStore: store)
        defer { sourceDocument.close() }
        let (targetDocument, target) = try await scenarioDocument(fixture, url: readOnly, preferencesStore: store)
        defer { targetDocument.close() }
        XCTAssertFalse(try XCTUnwrap(targetDocument.session).capabilities.canEdit)
        XCTAssertEqual(try ScenarioFixture.contents(readOnly), ["old.txt": Data("original content".utf8)])
        let destination = fixture.root.appendingPathComponent("converted." + ArchiveCreationPlan.filenameExtension(for: format))
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path))
        let errors = try ReadOnlyConversionErrors()
        var createdDocuments: [NSDocument] = []
        func closeCreatedDocuments() {
            for document in NSDocumentController.shared.documents where document.fileURL == destination {
                if !createdDocuments.contains(where: { $0 === document }) { createdDocuments.append(document) }
                document.close()
            }
        }
        defer {
            // 途中で assertion / unwrap が失敗しても、ドラッグ先のシートと処理を残さない。
            for controller in [source, target] {
                let sheets = controller.window?.sheets ?? []
                controller.cancelExtraction()
                for sheet in sheets {
                    sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
                    sheet.orderOut(nil)
                }
            }
            closeCreatedDocuments()
        }
        addTeardownBlock { @MainActor in
            // 取消しの完了まで捕捉を維持し、publish 直後に失敗した場合の遅い open も回収する。
            defer { closeCreatedDocuments(); errors.restore() }
            await target.extractionTask?.value
            await source.extractionTask?.value
            if FileManager.default.fileExists(atPath: destination.path), createdDocuments.isEmpty, errors.errors.isEmpty {
                try await self.scenarioWait {
                    NSDocumentController.shared.documents.contains { $0.fileURL == destination } || !errors.errors.isEmpty
                }
            }
            closeCreatedDocuments()
            for document in createdDocuments.compactMap({ $0 as? ArchiveDocument }) {
                await document.undoCleanup?.value
                await document.materializationCleanup?.value
                await document.sessionCleanup?.value
            }
            withExtendedLifetime(defaults) {}
        }

        var sawNativePromise = false
        try await dragSelection(from: source, to: target, tabbed: false, expectedCount: 1, paths: ["x\\y"]) { info in
            XCTAssertTrue((info.draggingSource as? NSView) === source.outlineView)
            XCTAssertTrue(info.draggingDestinationWindow === target.window)
            XCTAssertEqual(source.draggedNodes.map { Data($0.path.utf8) }, [Data("x\\y".utf8)])
            let pasteboard = AppKitArchivePasteboard(pasteboard: info.draggingPasteboard)
            XCTAssertEqual(ArchiveIncomingPasteboard.representation(pasteboard), .promises)
            sawNativePromise = pasteboard.hasPromises
        }
        XCTAssertTrue(sawNativePromise)
        try await scenarioWait { target.conversionConfirmation != nil || target.failureAlert != nil || !errors.errors.isEmpty }
        XCTAssertNil(target.failureAlert)
        XCTAssertTrue(errors.errors.isEmpty, "形式選択前にエラーを提示しない")
        let alert = try XCTUnwrap(target.conversionConfirmation)
        let firstButton = try XCTUnwrap(alert.buttons.first)
        XCTAssertEqual(firstButton.title, String(localized: "新規アーカイブを作成…"))
        XCTAssertTrue(alert.window.sheetParent === target.window)
        // offerConversion の完了処理は startConversion で creator を同期的に設定する。
        // await を挟まず、MainActor の変換 Task が保存パネルへ進む前に確定先を渡す。
        firstButton.performClick(nil)
        let creator = try XCTUnwrap(target.creationController, "確認ボタンから同期的に変換を開始する")
        XCTAssertNil(target.conversionConfirmation)
        XCTAssertNil(creator.savePanel)
        creator.destinationHandler = { save, parent in
            XCTAssertTrue(parent === target.window)
            XCTAssertTrue(errors.errors.isEmpty, "名前の検証は保存形式を選んだ後")
            XCTAssertNil(target.failureAlert)
            errors.formatChoiceCount += 1
            save.formatPopup.selectItem(at: try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: format)))
            save.changeFormat(save.formatPopup)
            XCTAssertEqual(save.controller.format, format)
            XCTAssertNil(save.splitControls)
            return destination
        }
        alert.window.orderOut(nil)
        try await scenarioWait { target.extractionTask == nil }
        XCTAssertEqual(errors.formatChoiceCount, 1)
        XCTAssertTrue(errors.errorsBeforeFormatChoice.isEmpty, "形式選択前のエラー: \(errors.errorsBeforeFormatChoice)")
        XCTAssertNil(target.creationController)
        XCTAssertNil(target.failureAlert)

        if format == .tar {
            XCTAssertTrue(errors.errors.isEmpty, "\(errors.errors)")
            try await scenarioWait {
                NSDocumentController.shared.documents.contains {
                    $0.fileURL == destination && ($0 as? ArchiveDocument)?.session != nil && !$0.windowControllers.isEmpty
                }
            }
            let document = try XCTUnwrap(NSDocumentController.shared.documents.first { $0.fileURL == destination } as? ArchiveDocument)
            let entries = await (try XCTUnwrap(document.session)).entries()
            XCTAssertEqual(entries.count, 2)
            XCTAssertEqual(Set(entries.map { Data($0.name.utf8) }), Set([Data("old.txt".utf8), Data("x\\y".utf8)]))
            let reader = try ArchiveReader.open(url: destination)
            let incoming = try XCTUnwrap(reader.entries.first { Data($0.name.utf8) == Data("x\\y".utf8) })
            let original = try XCTUnwrap(reader.entries.first { Data($0.name.utf8) == Data("old.txt".utf8) })
            XCTAssertEqual(try reader.read(incoming), Data("payload".utf8))
            XCTAssertEqual(try reader.read(original), Data("original content".utf8))
            closeCreatedDocuments()
        } else {
            XCTAssertEqual(errors.errors.count, 1)
            let error = try XCTUnwrap(errors.errors.first)
            XCTAssertEqual(error.domain, "com.shunnag.KaitoFinder.creation")
            XCTAssertEqual(error.code, 1)
            XCTAssertEqual(error.localizedDescription, String(localized: "アーカイブを作成できませんでした"))
            let reason = try XCTUnwrap(error.localizedFailureReason)
            XCTAssertTrue(reason.contains(String(localized: "安全でない追加先パスです: \("x\\y")。")), reason)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)), before)
            XCTAssertFalse(NSDocumentController.shared.documents.contains { $0.fileURL == destination })
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".KaitoFinder-new-") })
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertNil(target.window?.attachedSheet)
    }
}
