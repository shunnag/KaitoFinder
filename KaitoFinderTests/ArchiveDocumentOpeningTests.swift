import AppKit
import KaitoKit
import QuickLookUI
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveDocumentOpeningTests: XCTestCase {
    private func fixtureDirectory() throws -> ArchiveTestDirectory {
        let directory = try ArchiveTestDirectory()
        try FileManager.default.createDirectory(at: directory.url.appendingPathComponent("nested/deeper"),
                                                withIntermediateDirectories: true)
        for name in ["nested/deeper/one.txt", "nested/deeper/two.txt", "note.txt"] {
            try Data(name.utf8).write(to: directory.url.appendingPathComponent(name))
        }
        return directory
    }

    @MainActor func testZIPOpensThroughDocumentController() async throws {
        let directory = try fixtureDirectory(), archive = directory.url.appendingPathComponent("opening.zip")
        try directory.run("/usr/bin/zip", ["-q", "-D", archive.path,
                                           "nested/deeper/one.txt", "nested/deeper/two.txt", "note.txt"])
        try await assertOpensThroughDocumentController(archive, in: directory)
    }

    @MainActor func testTGZOpensThroughDocumentController() async throws {
        let directory = try fixtureDirectory(), archive = directory.url.appendingPathComponent("opening.tgz")
        try directory.run("/usr/bin/bsdtar", ["--no-mac-metadata", "--no-xattrs", "-czf", archive.path,
                                              "nested", "note.txt"])
        try await assertOpensThroughDocumentController(archive, in: directory)
    }

    @MainActor func testInvalidZIPReturnsLocalizedDocumentErrorWithUnderlyingKaitoError() async throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("bad.zip")
        try Data("not an archive".utf8).write(to: archive)
        try requireDocumentTypeLookup(archive)
        let (document, error) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(NSDocument?, (any Error)?), Never>) in
            NSDocumentController.shared.openDocument(withContentsOf: archive, display: false) { document, _, error in
                continuation.resume(returning: (document, error))
            }
        }
        defer { document?.close() }
        XCTAssertNil(document)
        let failure = try XCTUnwrap(error) as NSError
        XCTAssertEqual(failure.domain, "com.shunnag.KaitoFinder.document")
        XCTAssertEqual(failure.code, 1)
        XCTAssertTrue(failure.localizedDescription.contains(
            ArchiveAlertText.informativeText(ArchiveErrorText.describe(KaitoError.unsupportedFormat))))
        XCTAssertFalse(failure.localizedDescription.contains("Unsupported archive format"))
        XCTAssertEqual(failure.localizedFailureReason,
                       ArchiveAlertText.informativeText(ArchiveErrorText.describe(KaitoError.unsupportedFormat)))
        var underlying = failure
        var foundUnsupportedFormat = false
        for _ in 0..<2 {
            guard let next = underlying.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            if let kaitoError = next as? KaitoError, case .unsupportedFormat = kaitoError {
                foundUnsupportedFormat = true
                break
            }
            underlying = next
        }
        XCTAssertTrue(foundUnsupportedFormat, "Expected KaitoError.unsupportedFormat in the underlying error chain")
    }

    @MainActor func testInvalidZIPReadWrapsFailureBeforeInstallingSession() throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("bad.zip")
        try Data("not an archive".utf8).write(to: archive)
        let document = ArchiveDocument()
        defer { document.close() }
        XCTAssertThrowsError(try document.read(from: archive, ofType: "public.zip-archive")) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "com.shunnag.KaitoFinder.document")
            XCTAssertEqual(failure.code, 1)
            XCTAssertEqual(failure.localizedDescription, String(localized: "アーカイブを開けませんでした"))
            XCTAssertEqual(failure.localizedFailureReason,
                           ArchiveAlertText.informativeText(ArchiveErrorText.describe(KaitoError.unsupportedFormat)))
            XCTAssertTrue(failure.userInfo[NSUnderlyingErrorKey] is KaitoError)
        }
        XCTAssertNil(document.session)
        XCTAssertFalse(document.isPasswordLocked)
    }

    @MainActor func testHeaderEncryptedReadKeepsLockedDocumentWithoutPresentingPrompt() throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("locked.7z")
        try Data("secret".utf8).write(to: directory.url.appendingPathComponent("secret.txt"))
        try directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-pfixture-password", "-mhe=on", archive.path, "secret.txt"])
        let document = ArchiveDocument()
        defer { document.close() }
        try document.read(from: archive, ofType: "org.7-zip.7-zip-archive")
        XCTAssertTrue(document.isPasswordLocked)
        XCTAssertEqual(document.lockedURL, archive)
        XCTAssertNil(document.session)
        XCTAssertTrue(document.windowControllers.isEmpty)
    }

    @MainActor func testLaunchArgumentsReportMissingPathAndContinueOpeningFixture() async throws {
        preserveArchiveWindowFrame()
        let directory = try fixtureDirectory(), archive = directory.url.appendingPathComponent("launch.zip")
        let missing = directory.url.appendingPathComponent("missing.zip")
        try directory.run("/usr/bin/zip", ["-q", "-D", archive.path, "note.txt"])
        try requireDocumentTypeLookup(archive)
        let suite = try ArchivePreferencesTestDefaults()
        let delegate = AppDelegate(preferencesStore: ArchivePreferencesStore(defaults: suite.defaults))
        addTeardownBlock { @MainActor in
            for document in NSDocumentController.shared.documents where document.fileURL == archive {
                document.close()
                if let document = document as? ArchiveDocument {
                    await document.undoCleanup?.value
                    await document.materializationCleanup?.value
                    await document.sessionCleanup?.value
                }
            }
            withExtendedLifetime(directory) {}
        }
        var presented: [NSError] = []
        let hadFiles = delegate.openLaunchArguments([missing.path, archive.path]) { presented.append($0) }
        XCTAssertTrue(hadFiles)
        XCTAssertEqual(presented.count, 1)
        if let error = presented.first {
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error.code, NSFileNoSuchFileError)
            XCTAssertEqual(error.userInfo[NSFilePathErrorKey] as? String, missing.path)
            XCTAssertEqual(error.userInfo[NSURLErrorKey] as? URL, missing)
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !NSDocumentController.shared.documents.contains(where: {
            $0.fileURL == archive && $0.windowControllers.first?.window != nil
        }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let document = try XCTUnwrap(NSDocumentController.shared.documents.first { $0.fileURL == archive } as? ArchiveDocument)
        XCTAssertNotNil(document.session)
        XCTAssertNotNil(document.windowControllers.first?.window)
    }

    @MainActor func testMissingLaunchArgumentKeepsWelcomeEligibleAndIgnoresOptions() throws {
        let directory = try ArchiveTestDirectory(), missing = directory.url.appendingPathComponent("missing.zip")
        let suite = try ArchivePreferencesTestDefaults()
        let delegate = AppDelegate(preferencesStore: ArchivePreferencesStore(defaults: suite.defaults))
        var presented: [NSError] = []
        let hadFiles = delegate.openLaunchArguments(["-ignored-option", missing.path]) { presented.append($0) }
        XCTAssertFalse(hadFiles)
        XCTAssertEqual(presented.count, 1)
        XCTAssertEqual(presented.first?.domain, NSCocoaErrorDomain)
        XCTAssertEqual(presented.first?.code, NSFileNoSuchFileError)
        XCTAssertEqual(presented.first?.userInfo[NSFilePathErrorKey] as? String, missing.path)
        XCTAssertEqual(presented.first?.userInfo[NSURLErrorKey] as? URL, missing)
        XCTAssertTrue(AppDelegate.shouldShowWelcome(argumentsHadFiles: hadFiles, hasDocuments: false, preference: true))
    }

    private func requireDocumentTypeLookup(_ url: URL) throws {
        do { _ = try url.resourceValues(forKeys: [.contentTypeKey]) }
        catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            guard underlying?.domain == NSOSStatusErrorDomain, underlying?.code == -10813 else { throw error }
            throw XCTSkip("LaunchServicesがファイル型を返せません。sandbox外で文書オープンを再検証してください。")
        }
    }

    @MainActor func testQuickLookForSelectedZIPRowSurvivesForegroundAsyncLoading() async throws {
        let directory = try fixtureDirectory(), archive = directory.url.appendingPathComponent("preview.zip")
        // 行 0 が仮想フォルダではなく、プレビュー可能なファイルになる ZIP を開く。
        try directory.run("/usr/bin/zip", ["-q", "-D", archive.path, "note.txt"])
        try await assertQuickLook(archive, in: directory, name: "note.txt", expected: Data("note.txt".utf8))
    }

    @MainActor func testQuickLookForXZAndLegacyZstandardZIPRows() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("KaitoKit/Tests/Fixtures/zip-modern")
        let expected = Data(String(repeating: "XZ and Zstandard ZIP interoperability 日本語\n", count: 800).utf8)
        for name in ["xz.zip", "xz-aes.zip", "xz-zipcrypto.zip", "zstd20.zip", "zstd-aes20.zip"] {
            let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent(name)
            let encoded = try Data(contentsOf: fixtures.appendingPathComponent(name + ".b64"))
            try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters)).write(to: archive)
            try await assertQuickLook(archive, in: directory, name: "payload.txt", expected: expected,
                                      password: "KaitoFixture")
        }
    }

    @MainActor private func assertQuickLook(_ archive: URL, in directory: ArchiveTestDirectory,
                                            name: String, expected: Data, password: String? = nil) async throws {
        NSApp.activate()
        let controller = try await assertOpensThroughDocumentController(archive, in: directory,
            expectedTopLevelPaths: [name])
        if let password {
            let document = try XCTUnwrap(controller.document as? ArchiveDocument)
            document.session?.setPasswordPrompt { _ in password }
        }
        let window = try XCTUnwrap(controller.window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.outlineView)
        let activationDeadline = ContinuousClock.now + .seconds(5)
        while !NSApp.isActive, ContinuousClock.now < activationDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard NSApp.isActive else {
            throw XCTSkip("テスト host が前面になれない環境では QuickLookUI の非同期読み込みを起こせない")
        }
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        try performMenuItem(menuItem(#selector(NSText.selectAll(_:)), in: mainMenu))
        XCTAssertEqual(controller.outlineView.selectedRow, 0)
        let previewCommand = try menuItem(#selector(ArchiveWindowController.togglePreviewPanel(_:)), in: mainMenu)
        try performMenuItem(previewCommand)

        // 前面時の QuickLookUI の非同期読み込みと、main actor での URL 公開を両方進める。
        let previewDeadline = Date().addingTimeInterval(1.5)
        while Date() < previewDeadline {
            runMainRunLoop(until: min(previewDeadline, Date().addingTimeInterval(0.01)))
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true)
        let panel = try XCTUnwrap(QLPreviewPanel.shared())
        XCTAssertTrue(panel.currentController as AnyObject? === controller)
        let previewURL = try XCTUnwrap(controller.previewPanel(panel, previewItemAt: 0)?.previewItemURL)
        XCTAssertEqual(try Data(contentsOf: previewURL), expected)
        try performMenuItem(previewCommand)
        let hideDeadline = Date().addingTimeInterval(2)
        while panel.isVisible, Date() < hideDeadline {
            runMainRunLoop(until: min(hideDeadline, Date().addingTimeInterval(0.01)))
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testDocumentCreationDisablesConcurrentReading() {
        // Concurrent reading makes AppKit invoke the @MainActor initializer on its
        // "NSDocumentController Opening" queue, causing the measured EXC_BREAKPOINT/SIGTRAP.
        XCTAssertFalse(ArchiveDocument.canConcurrentlyReadDocuments(ofType: "public.zip-archive"))
    }

    @MainActor private func runMainRunLoop(until date: Date) {
        RunLoop.main.run(until: date)
    }

    @MainActor @discardableResult private func assertOpensThroughDocumentController(
        _ url: URL, in directory: ArchiveTestDirectory, expectedTopLevelPaths: [String] = ["nested", "note.txt"]
    ) async throws -> ArchiveWindowController {
        preserveArchiveWindowFrame()
        let (openedDocument, error) = await withCheckedContinuation {
            (continuation: CheckedContinuation<(NSDocument?, (any Error)?), Never>) in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                continuation.resume(returning: (document, error))
            }
        }
        XCTAssertNil(error)
        let document = try XCTUnwrap(openedDocument as? ArchiveDocument)
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            XCTAssertFalse(NSDocumentController.shared.documents.contains { $0 === document })
            withExtendedLifetime(directory) {}
        }
        XCTAssertTrue(NSDocumentController.shared.documents.contains { $0 === document })
        XCTAssertEqual(document.fileURL, url)
        XCTAssertNotNil(document.windowControllers.first?.window)
        let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        let outlineView = controller.outlineView
        func topLevelPaths() -> [String] {
            (0..<outlineView.numberOfRows).compactMap { row in
                guard outlineView.level(forRow: row) == 0 else { return nil }
                return (outlineView.item(atRow: row) as? EntryNode)?.path
            }.sorted()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while topLevelPaths() != expectedTopLevelPaths, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(topLevelPaths(), expectedTopLevelPaths)
        return controller
    }
}
