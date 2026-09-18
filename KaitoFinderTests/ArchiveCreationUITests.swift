import AppKit
import GyoshukuKit
import KaitoKit
import UniformTypeIdentifiers
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveCreationUITests: XCTestCase {
    @MainActor func testCompressionLevelMappingRoundTripsEveryChoice() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let save = ArchiveSavePanel(sources: [], store: store)
        let creator = ArchiveCreationController(store: store)
        for (index, level) in ArchiveSavePanelController.Level.allCases.enumerated() {
            save.levelPopup.selectItem(at: index)
            XCTAssertTrue(save.levelPopup.sendAction(save.levelPopup.action, to: save.levelPopup.target))
            XCTAssertEqual(save.controller.level, level)
            XCTAssertEqual(save.controller.selectedLevelIndex, index)
            let plan = creator.creationPlan(sources: [], destination: URL(fileURLWithPath: "/tmp/test.zip"),
                                             format: .zip, level: save.controller.level)
            XCTAssertEqual(plan.options.compressionMethod, level == .none ? .stored : .deflate)
            XCTAssertEqual(plan.options.deflateLevel, level == .none ? 6 : level.rawValue)
        }
        XCTAssertEqual(store.preferences.zipLevel, 6)
        XCTAssertEqual(store.preferences.zipMethod, .deflate)
    }

    @MainActor func testInitialCompressionLevelUsesNearestPreferenceWithHigherTie() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let expected: [ArchiveSavePanelController.Level] = [.fast, .fast, .fast, .normal, .normal, .normal, .high, .high, .maximum]
        for value in 1...9 {
            for format in [GyoshukuKit.ArchiveFormat.zip, .tarGzip, .tarBzip2] {
                store.preferences.defaultFormat = format
                store.preferences.zipLevel = value
                store.preferences.tarGzipLevel = value
                store.preferences.tarBzip2Level = value
                let controller = ArchiveSavePanelController(store: store)
                XCTAssertEqual(controller.level, expected[value - 1])
                XCTAssertEqual(controller.levels[controller.selectedLevelIndex], expected[value - 1])
            }
        }
        store.preferences.defaultFormat = .zip
        store.preferences.zipMethod = .stored
        XCTAssertEqual(ArchiveSavePanelController(store: store).level, .none)
    }

    @MainActor func testFormatChangeResetsLevelAndDisablesFixedFormats() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.zipLevel = 9
        store.preferences.tarGzipLevel = 1
        let save = ArchiveSavePanel(sources: [], store: store)
        XCTAssertEqual(save.controller.level, .maximum)
        save.controller.selectLevel(at: 2)
        for (index, format) in ArchiveSavePanelController.formats.enumerated() {
            save.formatPopup.selectItem(at: index)
            XCTAssertTrue(save.formatPopup.sendAction(save.formatPopup.action, to: save.formatPopup.target))
            XCTAssertEqual(save.levelPopup.isEnabled, format == .zip || format == .tarGzip || format == .tarBzip2)
            XCTAssertEqual(save.levelPopup.numberOfItems, save.controller.levels.count)
            XCTAssertEqual(save.levelPopup.indexOfSelectedItem, save.controller.selectedLevelIndex)
            switch format {
            case .zip: XCTAssertEqual(save.controller.level, .maximum)
            case .tarGzip:
                XCTAssertEqual(save.controller.level, .fast)
                XCTAssertFalse(save.controller.levels.contains(.none))
            case .tarBzip2:
                XCTAssertEqual(save.controller.level, .maximum)
                XCTAssertFalse(save.controller.levels.contains(.none))
            case .tar: XCTAssertEqual(save.controller.level, .normal)
            case .tarXZ, .sevenZip, .lha:
                XCTAssertEqual(save.controller.level, .normal)
                save.controller.selectLevel(at: 0)
                XCTAssertEqual(save.controller.level, .normal)
            }
        }
        XCTAssertEqual(store.preferences.zipLevel, 9)
        XCTAssertEqual(store.preferences.tarGzipLevel, 1)
    }

    @MainActor func testPanelLevelOverridesStoredZIPAndPreservesOtherWriterPreferences() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.zipMethod = .stored
        store.preferences.zipSkipsCompressedTypes = false
        store.preferences.tarPreservesOwnerIDs = true
        let creator = ArchiveCreationController(store: store)
        let zip = creator.creationPlan(sources: [], destination: URL(fileURLWithPath: "/tmp/test.zip"), format: .zip, level: .high)
        XCTAssertEqual(zip.options.compressionMethod, .deflate)
        XCTAssertEqual(zip.options.deflateLevel, 8)
        XCTAssertFalse(zip.options.useCompressionHeuristic)
        for level in [ArchiveSavePanelController.Level.fast, .normal, .high, .maximum] {
            let tar = creator.creationPlan(sources: [], destination: URL(fileURLWithPath: "/tmp/test.tar.gz"), format: .tarGzip, level: level)
            XCTAssertEqual(tar.options.deflateLevel, level.rawValue)
            XCTAssertTrue(tar.options.preserveOwnerIDs)
        }
    }

    @MainActor func testCreationUsesConfirmedPanelChoiceWithoutPersistingLevel() async throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let directory = try ArchiveTestDirectory(), creator = ArchiveCreationController(store: store)
        let source = directory.url.appendingPathComponent("repeated.txt")
        let bytes = Data(repeating: 0x61, count: 8192)
        try bytes.write(to: source)
        let destination = directory.url.appendingPathComponent("stored.zip")
        creator.destinationHandler = { save, _ in
            save.levelPopup.selectItem(at: 0)
            save.changeLevel(save.levelPopup)
            return destination
        }
        let result = try await creator.create(sources: [source])
        XCTAssertEqual(result, destination)
        let entry = try XCTUnwrap(ArchiveReader.open(url: destination).entries.first)
        XCTAssertEqual(entry.compressedSize, UInt64(bytes.count))
        XCTAssertEqual(store.preferences.zipMethod, .deflate)
        XCTAssertEqual(store.preferences.zipLevel, 6)
    }

    private final class Preferences {
        let name = "KaitoFinder-CreationTests-" + UUID().uuidString
        let defaults: UserDefaults
        init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: name)) }
        deinit { defaults.removePersistentDomain(forName: name) }
    }

    @MainActor func testSavePanelPopupUpdatesTheSelectedContentType() throws {
        let preferences = try Preferences()
        let save = ArchiveSavePanel(sources: [URL(fileURLWithPath: "/tmp/a.jpg")], defaults: preferences.defaults)
        let cases: [(GyoshukuKit.ArchiveFormat, String, String)] = [
            (.zip, "zip", "public.zip-archive"), (.tar, "tar", "public.tar-archive"),
            (.tarGzip, "tar.gz", "com.shunnag.KaitoFinder.save-tar-gzip"),
            (.tarBzip2, "tar.bz2", "com.shunnag.KaitoFinder.save-tar-bzip2"), (.tarXZ, "tar.xz", "com.shunnag.KaitoFinder.save-tar-xz"),
            (.sevenZip, "7z", "org.7-zip.7-zip-archive"), (.lha, "lzh", "com.shunnag.KaitoFinder.lzh-archive")
        ]
        XCTAssertTrue(save.formatPopup.target === save)
        for (index, value) in cases.enumerated() {
            let (format, suffix, identifier) = value
            save.formatPopup.selectItem(at: index)
            XCTAssertTrue(save.formatPopup.sendAction(save.formatPopup.action, to: save.formatPopup.target))
            let type = try XCTUnwrap(UTType(identifier) ?? UTType(filenameExtension: suffix))
            XCTAssertNotEqual(type, .data)
            XCTAssertEqual(save.controller.format, format)
            XCTAssertEqual(save.controller.allowedContentTypes, [type])
            XCTAssertEqual(save.panel.currentContentType, type)
            XCTAssertEqual(save.panel.allowedContentTypes,
                           ArchiveSavePanelController.panelContentTypes)
        }
        XCTAssertEqual(save.formatPopup.itemTitles, ["ZIP", "tar", "tar.gz", "tar.bz2", "tar.xz", "7z", "LHA"])
    }

    @MainActor func testSavePanelValidatesTarGzipFilenameExtensions() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.defaultFormat = .tarGzip
        let save = ArchiveSavePanel(sources: [], store: store), list = ".tar.gz, .tgz"
        XCTAssertThrowsError(try save.panel(save.panel, validate: URL(fileURLWithPath: "/tmp/result.gz"))) {
            XCTAssertEqual(($0 as NSError).userInfo[NSLocalizedDescriptionKey] as? String,
                           String(localized: "この形式のファイル名は次の拡張子で終わる必要があります: \(list)"))
        }
        for name in ["result.tar.gz", "result.tgz", "result.TAR.GZ", "result.TGZ"] {
            XCTAssertNoThrow(try save.panel(save.panel, validate: URL(fileURLWithPath: "/tmp/" + name)))
        }
    }

    @MainActor func testSavePanelRemembersEveryFormatInAnIsolatedDefaultsSuite() throws {
        let preferences = try Preferences()
        let suffixes = ["zip", "tar", "tar.gz", "tar.bz2", "tar.xz", "7z", "lzh"]
        let controller = ArchiveSavePanelController(defaults: preferences.defaults)
        XCTAssertEqual(controller.format, .zip)
        for (index, format) in ArchiveSavePanelController.formats.enumerated() {
            controller.selectFormat(at: index)
            XCTAssertEqual(preferences.defaults.string(forKey: "ArchiveCreationFormat"), suffixes[index])
            let restored = ArchiveSavePanelController(defaults: preferences.defaults)
            XCTAssertEqual(restored.format, format)
            XCTAssertEqual(restored.selectedIndex, index)
        }
    }

    @MainActor func testSavePanelUnknownRememberedFormatFallsBackToZIP() throws {
        let preferences = try Preferences()
        preferences.defaults.set("rar", forKey: "ArchiveCreationFormat")
        let controller = ArchiveSavePanelController(defaults: preferences.defaults)
        XCTAssertEqual(controller.format, .zip)
        XCTAssertEqual(controller.allowedContentTypes, [.zip])
        XCTAssertEqual(controller.selectedIndex, 0)
    }

    @MainActor func testFormatSwitchIgnoresInvalidIndices() throws {
        let preferences = try Preferences(), controller = ArchiveSavePanelController(defaults: preferences.defaults)
        controller.selectFormat(at: 6)
        controller.selectFormat(at: -1)
        controller.selectFormat(at: ArchivePreferences.formats.count)
        XCTAssertEqual(controller.format, .lha)
    }

    @MainActor func testSharedSavePanelDefaultsAndConversionName() throws {
        let directory = try ArchiveTestDirectory(), preferences = try Preferences()
        let source = directory.url.appendingPathComponent("a.jpg")
        try Data("image".utf8).write(to: source)
        let save = ArchiveSavePanel(sources: [source], defaults: preferences.defaults)
        XCTAssertEqual(save.panel.directoryURL?.standardizedFileURL.resolvingSymlinksInPath(), directory.url.resolvingSymlinksInPath())
        XCTAssertEqual(save.panel.nameFieldStringValue, "a.jpg.zip")
        XCTAssertTrue(save.panel.canCreateDirectories)
        XCTAssertTrue(save.panel.isExtensionHidden)
        let accessory = try XCTUnwrap(save.panel.accessoryView)
        var pending = [accessory], labels: [String] = []
        while let view = pending.popLast() {
            if let field = view as? NSTextField { labels.append(field.stringValue) }
            pending.append(contentsOf: view.subviews)
        }
        XCTAssertTrue(labels.contains(String(localized: "tar と LHA は暗号化できません")))
        XCTAssertEqual(labels.filter { $0 == String(localized: "フォーマット") }, [String(localized: "フォーマット")])
        XCTAssertEqual(save.formatPopup.accessibilityLabel(), String(localized: "フォーマット"))
        preferences.defaults.set("tar.gz", forKey: "ArchiveCreationFormat")
        let conversion = ArchiveSavePanel(sources: [source], existingURL: directory.url.appendingPathComponent("Original.tar.bz2"),
                                          defaults: preferences.defaults)
        XCTAssertEqual(conversion.panel.nameFieldStringValue, "Original.gz")
        XCTAssertEqual(conversion.controller.format, .tarGzip)
        XCTAssertEqual(conversion.formatPopup.indexOfSelectedItem, 2)
    }

    @MainActor func testFileMenuStartsWithCommandNAndDoesNotOpenUntitledDocuments() throws {
        preserveApplicationMenus()
        let delegate = AppDelegate(), menu = delegate.makeMenu()
        let file = try XCTUnwrap(menu.items.compactMap(\.submenu).first { $0.title == String(localized: "ファイル") })
        let first = try XCTUnwrap(file.items.first)
        XCTAssertEqual(first.title, String(localized: "新規アーカイブ…"))
        XCTAssertEqual(first.action, #selector(AppDelegate.newArchive(_:)))
        XCTAssertTrue(first.target === delegate)
        XCTAssertEqual(first.keyEquivalent, "n")
        XCTAssertEqual(first.keyEquivalentModifierMask, [.command])
        XCTAssertFalse(delegate.applicationShouldOpenUntitledFile(.shared))
    }

    @MainActor func testFinderServicesDeclarationAndObjectiveCSelector() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("KaitoFinder/Info.plist")), format: nil) as? [String: Any])
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let service = try XCTUnwrap(services.first { $0["NSMessage"] as? String == "compressFiles" })
        XCTAssertEqual(service["NSSendFileTypes"] as? [String], ["public.item"])
        XCTAssertEqual(service["NSPortName"] as? String, "KaitoFinder")
        XCTAssertEqual(service["NSMenuItem"] as? [String: String], ["default": "KaitoFinderで圧縮"])
        XCTAssertEqual(service["NSRequiredContext"] as? [String: String], ["NSApplicationIdentifier": "com.apple.finder"])
        XCTAssertNil(plist["LSFileQuarantineEnabled"])
        XCTAssertTrue(AppDelegate().responds(to: #selector(AppDelegate.compressFiles(_:userData:error:))))
    }

    @MainActor func testFinderServicesReadFileAndFolderURLsFromPasteboard() throws {
        let directory = try ArchiveTestDirectory(), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else {
            throw XCTSkip("Named pasteboard service is unavailable in this environment")
        }
        let file = directory.url.appendingPathComponent("file.txt"), folder = directory.url.appendingPathComponent("folder", isDirectory: true)
        try Data("file".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([file as NSURL, folder as NSURL, NSURL(string: "https://example.com/archive.zip")!]))
        XCTAssertEqual(AppDelegate.filesToCompress(from: pasteboard), [file, folder])
    }

    @MainActor func testFinderCompressionRemovesDuplicateURLsPreservingOrder() throws {
        let directory = try ArchiveTestDirectory(), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else { throw XCTSkip("名前付きペーストボードを利用できない") }
        let first = directory.url.appendingPathComponent("first.txt"), second = directory.url.appendingPathComponent("second.txt")
        try Data().write(to: first)
        try Data().write(to: second)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([first as NSURL, second as NSURL, first as NSURL]))
        XCTAssertEqual(AppDelegate.filesToCompress(from: pasteboard), [first, second])
    }

    @MainActor func testFinderCompressionDeduplicatesStandardizedSymlinkPathsKeepingFirstURL() throws {
        let directory = try ArchiveTestDirectory(), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else { throw XCTSkip("名前付きペーストボードを利用できない") }
        let file = directory.url.appendingPathComponent("file.txt"), link = directory.url.appendingPathComponent("link.txt")
        let second = directory.url.appendingPathComponent("second.txt")
        try Data().write(to: file)
        try Data().write(to: second)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let normalized = directory.url.appendingPathComponent("./file.txt")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([link as NSURL, second as NSURL, file as NSURL, normalized as NSURL]))
        XCTAssertEqual(AppDelegate.filesToCompress(from: pasteboard), [link, second])
    }

    private func entry(encrypted: Bool) -> ArchiveEntry {
        ArchiveEntry(index: 0, rawName: RawName(bytes: Array("file.txt".utf8)), name: "file.txt", pathComponents: ["file.txt"],
                     kind: .file, uncompressedSize: 1, compressedSize: 1, modificationDate: nil, posixPermissions: nil,
                     isEncrypted: encrypted, solidGroup: -1, crc32: nil, methodDescription: "stored", formatSpecific: [:])
    }

    @MainActor func testConversionNoticeIncludesFormatAndEncryptionParagraphOnlyWhenNeeded() throws {
        let app = Bundle(for: ArchiveDocument.self)
        for language in ["ja", "en"] {
            let bundle = try XCTUnwrap(Bundle(url: XCTUnwrap(app.url(forResource: language, withExtension: "lproj"))))
            let normal = ArchiveConversionNotice(formatName: "tar.bz2", entries: [entry(encrypted: false)], bundle: bundle)
            let encrypted = ArchiveConversionNotice(formatName: "7z", entries: [entry(encrypted: false), entry(encrypted: true)], bundle: bundle)
            let paragraph = String(localized: "新しいアーカイブの暗号化設定は、保存時に変更できます。", bundle: bundle)
            XCTAssertTrue(normal.messageText.contains("tar.bz2"))
            XCTAssertTrue(encrypted.messageText.contains("7z"))
            XCTAssertFalse(normal.informativeText.contains(paragraph))
            XCTAssertEqual(encrypted.informativeText, normal.informativeText + "\n\n" + paragraph)
            if language == "ja" {
                XCTAssertEqual(normal.messageText, "このtar.bz2アーカイブは変更できません")
                XCTAssertEqual(normal.informativeText, "中身と追加する項目で新しいアーカイブを作れます。元のアーカイブは変わりません。")
                XCTAssertEqual(String(localized: "アーカイブ", bundle: bundle) + ".zip", "アーカイブ.zip")
                XCTAssertEqual(ArchiveAlertText.informativeText("詳細", bundle: bundle), "詳細。")
                XCTAssertEqual(ArchiveAlertText.informativeText("詳細。\n", bundle: bundle), "詳細。")
                XCTAssertEqual(ArchiveAlertText.informativeText("Details.", bundle: bundle), "Details。")
                XCTAssertEqual(ArchiveAlertText.informativeText(".hidden.\n", bundle: bundle), ".hidden。")
            } else {
                XCTAssertEqual(normal.messageText, "This tar.bz2 archive cannot be modified")
                XCTAssertEqual(paragraph, "You can change the new archive’s encryption settings when you save it.")
                XCTAssertEqual(ArchiveAlertText.informativeText("Details", bundle: bundle), "Details.")
                XCTAssertEqual(ArchiveAlertText.informativeText("Details.\n", bundle: bundle), "Details.")
                XCTAssertEqual(ArchiveAlertText.informativeText(".hidden.\n", bundle: bundle), ".hidden.")
            }
            XCTAssertEqual(ArchiveAlertText.informativeText(" \n", bundle: bundle), "")
        }
    }

    @MainActor func testStandaloneProgressPanelFloatsAndFinishesWithoutAParent() throws {
        let progress = Progress(totalUnitCount: 2)
        let sheet = ExtractionProgressSheet(progress: progress, title: String(localized: "アーカイブを作成中…"))
        defer { sheet.finish() }
        sheet.beginStandalone()
        let panel = try XCTUnwrap(sheet.window)
        XCTAssertNil(panel.sheetParent)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.title, String(localized: "アーカイブを作成中…"))
        sheet.cancelExtraction(nil)
        XCTAssertTrue(progress.isCancelled)
        sheet.finish()
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor func testCompressedTarAliasesValidateAndPreserveDottedStems() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        for (format, extensions) in [(GyoshukuKit.ArchiveFormat.tarBzip2, ["tar.bz2", "tbz2", "tbz"]), (.tarXZ, ["tar.xz", "txz"])] {
            for ext in extensions {
                store.preferences.defaultFormat = format
                let save = ArchiveSavePanel(sources: [], store: store)
                let name = "photos.backup." + ext.uppercased()
                XCTAssertNoThrow(try save.panel(save.panel, validate: URL(fileURLWithPath: "/tmp/" + name)))
                XCTAssertThrowsError(try save.panel(save.panel, validate: URL(fileURLWithPath: "/tmp/plain." + (format == .tarXZ ? "xz" : "bz2"))))
                XCTAssertEqual(ArchiveSavePanelController.filenameStem(name, format: format), "photos.backup")
            }
        }
        for level in [ArchiveSavePanelController.Level.fast, .normal, .high, .maximum] {
            let base = WriterOptions(deflateLevel: 3, bzip2Level: 9, preserveOwnerIDs: true)
            let selected = level.applying(to: base, format: .tarBzip2)
            XCTAssertEqual(selected.bzip2Level, level.rawValue)
            XCTAssertEqual(selected.deflateLevel, 3)
            XCTAssertTrue(selected.preserveOwnerIDs)
        }
    }

    @MainActor func testPresentedCompressedTarSavePanelAcceptsExactFilenameAndSwitchesFromEncryption() async throws {
        guard let request = ProcessInfo.processInfo.environment["KAITOFINDER_NATIVE_SAVE_REQUEST"] else {
            throw XCTSkip("Run Tools/verify_ui_integration.py for native Save confirmation")
        }
        let directory = try ArchiveTestDirectory()
        for format in [GyoshukuKit.ArchiveFormat.tarBzip2, .tarXZ, .tarGzip] {
            let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
            let save = ArchiveSavePanel(sources: [], store: store, reducesMotion: { false })
            save.panel.directoryURL = directory.url
            save.panel.prompt = "Save"
            save.panel.nameFieldStringValue = "review.zip"
            let accessory = try XCTUnwrap(save.panel.accessoryView)
            var response: NSApplication.ModalResponse?
            let initialHeight = accessory.fittingSize.height
            save.panel.begin { response = $0 }
            defer { save.panel.cancel(nil) }
            try await scenarioWait { save.panel.isVisible && abs(accessory.frame.height - initialHeight) < 0.5 }
            save.encryptionCheckbox.performClick(nil)
            try await scenarioWait { save.passwordFields.passwordField.currentEditor() != nil }
            save.passwordFields.passwordField.stringValue = "temporary"
            save.formatPopup.selectItem(at: try XCTUnwrap(ArchivePreferences.formats.firstIndex(of: format)))
            save.changeFormat(save.formatPopup)
            try await scenarioWait {
                save.passwordFields.view.isHidden
                    && abs(accessory.frame.height - (accessory.subviews.first?.fittingSize.height ?? 0)) < 0.5
                    && UISnapshot.overflowViolations(in: accessory).isEmpty
            }
            XCTAssertNil(save.encryptionSettings.password)
            XCTAssertFalse(save.passwordFields.passwordField.isEnabled)
            XCTAssertNil(save.passwordFields.passwordField.currentEditor())
            XCTAssertEqual(save.levelPopup.isEnabled, format != .tarXZ)
            XCTAssertTrue(UISnapshot.overflowViolations(in: accessory).isEmpty)
            let name = "review." + ArchiveCreationPlan.filenameExtension(for: format)
            try UISnapshot.render(accessory, name: "save-" + ArchiveCreationPlan.filenameExtension(for: format))
            NSApp.activate()
            let payload = try JSONSerialization.data(withJSONObject: ["pid": getpid(), "saveTitle": try XCTUnwrap(save.panel.prompt),
                                                                    "expectedName": "review"])
            try payload.write(to: URL(fileURLWithPath: request), options: .atomic)
            try await scenarioWait { response != nil }
            XCTAssertEqual(response, .OK)
            XCTAssertEqual(save.panel.url?.lastPathComponent, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.appendingPathComponent(name).path))
        }
    }


    @MainActor func testPresentedSavePanelSwitchesEveryFormatWithoutDuplicatingExtensions() async throws {
        guard let request = ProcessInfo.processInfo.environment["KAITOFINDER_NATIVE_SAVE_REQUEST"] else {
            throw XCTSkip("Run Tools/verify_ui_integration.py for native Save confirmation")
        }
        let directory = try ArchiveTestDirectory()
        // A source archive compressed as a file retains its complete name;
        // converting an opened archive replaces only its archive extension.
        for (initial, conversion) in ArchivePreferences.formats.flatMap({ [($0, true), ($0, false)] }) {
            let originalName = initial == .tarXZ ? "review.TXZ" : initial == .tarBzip2 ? "review.TBZ"
                : "review." + ArchiveCreationPlan.filenameExtension(for: initial)
            let stem = conversion ? "review" : originalName
            let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
            store.preferences.defaultFormat = initial
            let source = directory.url.appendingPathComponent(originalName)
            let finalName = stem + "." + ArchiveCreationPlan.filenameExtension(for: initial)
            let destination = directory.url.appendingPathComponent(finalName)
            let original = Data("Source archive name verification".utf8)
            let existing = Data("Existing destination verification".utf8)
            if !conversion {
                try original.write(to: source)
                try existing.write(to: destination)
            }
            let save = ArchiveSavePanel(sources: conversion ? [] : [source], existingURL: conversion ? source : nil,
                                        store: store, reducesMotion: { false })
            save.panel.directoryURL = directory.url
            save.panel.prompt = "Save"
            let accessory = try XCTUnwrap(save.panel.accessoryView), height = accessory.fittingSize.height
            var response: NSApplication.ModalResponse?
            save.panel.begin { response = $0 }
            defer { save.panel.cancel(nil) }
            try await scenarioWait { save.panel.isVisible && abs(accessory.frame.height - height) < 0.5 }
            for format in ArchivePreferences.formats + [.tarGzip, .tarXZ, .tarBzip2, .zip, initial] {
                save.formatPopup.selectItem(at: try XCTUnwrap(ArchivePreferences.formats.firstIndex(of: format)))
                save.changeFormat(save.formatPopup)
                try await scenarioWait {
                    abs(accessory.frame.height - (accessory.subviews.first?.fittingSize.height ?? 0)) < 0.5
                        && UISnapshot.overflowViolations(in: accessory).isEmpty
                }
                XCTAssertEqual(save.panel.currentContentType, ArchiveSavePanelController.contentType(for: format))
                XCTAssertFalse(save.encryptionSettings.password != nil)
                XCTAssertTrue(save.passwordFields.view.isHidden)
            }
            var confirmation: [String: Any] = ["pid": getpid(), "saveTitle": "Save", "expectedName": stem]
            if !conversion { confirmation["confirmationText"] = finalName }
            let payload = try JSONSerialization.data(withJSONObject: confirmation)
            try payload.write(to: URL(fileURLWithPath: request), options: .atomic)
            try await scenarioWait { response != nil }
            XCTAssertEqual(response, .OK)
            XCTAssertEqual(save.panel.url?.lastPathComponent, finalName)
            if !conversion {
                XCTAssertEqual(try Data(contentsOf: source), original)
                XCTAssertEqual(try Data(contentsOf: destination), existing)
            }
        }
    }

    @MainActor func testPresentedSavePanelPreservesTypedNamesAndConfirmsTheExactOverwrite() async throws {
        guard let request = ProcessInfo.processInfo.environment["KAITOFINDER_NATIVE_SAVE_REQUEST"] else {
            throw XCTSkip("Run Tools/verify_ui_integration.py for native Save confirmation")
        }
        for format in ArchivePreferences.formats {
            let extensions = ArchiveCreationPlan.acceptedExtensions(for: format)
            for suffix in extensions + extensions.map({ $0.uppercased() }) {
                let directory = try ArchiveTestDirectory()
                let enteredName = "report.backup." + suffix
                let destination = directory.url.appendingPathComponent(enteredName)
                let original = Data("Existing verification file".utf8)
                let overwrite = (format == .tarBzip2 && suffix == "tar.bz2") || (format == .tarXZ && suffix == "txz")
                if overwrite { try original.write(to: destination) }
                let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
                store.preferences.defaultFormat = format
                let save = ArchiveSavePanel(sources: [URL(fileURLWithPath: "/tmp/review")], store: store)
                save.panel.directoryURL = directory.url
                save.panel.prompt = "Save"
                var response: NSApplication.ModalResponse?
                save.panel.begin { response = $0 }
                defer { save.panel.cancel(nil) }
                try await scenarioWait { save.panel.isVisible }
                var payload: [String: Any] = ["pid": getpid(), "saveTitle": "Save", "expectedName": "review", "enteredName": enteredName]
                if overwrite { payload["confirmationText"] = enteredName }
                try JSONSerialization.data(withJSONObject: payload).write(to: URL(fileURLWithPath: request), options: .atomic)
                try await scenarioWait { response != nil }
                XCTAssertEqual(response, .OK)
                XCTAssertEqual(save.panel.url?.lastPathComponent, enteredName)
                if overwrite { XCTAssertEqual(try Data(contentsOf: destination), original) }
                else { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
            }
        }
    }

    @MainActor func testPresentedSavePanelSwitchesFormatsAfterEditingTheName() async throws {
        guard let path = ProcessInfo.processInfo.environment["KAITOFINDER_NATIVE_SAVE_REQUEST"] else {
            throw XCTSkip("Run Tools/verify_ui_integration.py for native Save confirmation")
        }
        let request = URL(fileURLWithPath: path), completed = request.deletingPathExtension().appendingPathExtension("done")
        // Explicit names use native one-component extension replacement. Keep the
        // entered basename and use short extensions that also survive re-editing.
        let shortExtensions: [GyoshukuKit.ArchiveFormat: String] = [.tarGzip: "tgz", .tarBzip2: "tbz2", .tarXZ: "txz"]
        for initial in [GyoshukuKit.ArchiveFormat.zip, .tarGzip, .tarBzip2, .tarXZ] {
            for target in [GyoshukuKit.ArchiveFormat.tarGzip, .tarBzip2, .tarXZ] where target != initial {
                let outputExtension = try XCTUnwrap(shortExtensions[target])
                let enteredStem = initial == .zip ? "edited.report" : "edited.report.tar"
                let directory = try ArchiveTestDirectory()
                let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
                store.preferences.defaultFormat = initial
                let save = ArchiveSavePanel(sources: [directory.url.appendingPathComponent("review")], store: store)
                save.panel.prompt = "Save"
                var response: NSApplication.ModalResponse?
                save.panel.begin { response = $0 }
                defer { save.panel.cancel(nil) }
                try await scenarioWait { save.panel.isVisible }
                let payload: [String: Any] = ["pid": getpid(), "saveTitle": "Save", "expectedName": "review", "editOnly": true,
                                             "initialFormat": ArchiveSavePanelController.title(for: initial),
                                             "selectedFormat": ArchiveSavePanelController.title(for: target),
                                             "enteredName": "edited.report." + ArchiveCreationPlan.filenameExtension(for: initial)]
                try JSONSerialization.data(withJSONObject: payload).write(to: request, options: .atomic)
                try await scenarioWait { FileManager.default.fileExists(atPath: completed.path) }
                try FileManager.default.removeItem(at: completed)
                try await scenarioWait { save.controller.format == target }
                XCTAssertEqual(save.controller.format, target)
                if initial == .zip, target == .tarGzip {
                    var selected = target
                    for next in [GyoshukuKit.ArchiveFormat.tarBzip2, .tarXZ, .tarGzip] {
                        let change: [String: Any] = ["pid": getpid(), "saveTitle": "Save", "editOnly": true,
                                                   "expectedName": "edited.report." + (try XCTUnwrap(shortExtensions[selected])),
                                                   "initialFormat": ArchiveSavePanelController.title(for: selected),
                                                   "selectedFormat": ArchiveSavePanelController.title(for: next)]
                        try JSONSerialization.data(withJSONObject: change).write(to: request, options: .atomic)
                        try await scenarioWait { FileManager.default.fileExists(atPath: completed.path) }
                        try FileManager.default.removeItem(at: completed)
                        try await scenarioWait { save.controller.format == next }
                        selected = next
                    }
                }
                let renameWithoutExtension = (initial == .zip && target == .tarXZ)
                    || (initial == .tarGzip && target == .tarBzip2)
                if renameWithoutExtension {
                    let edit: [String: Any] = ["pid": getpid(), "saveTitle": "Save", "editOnly": true,
                                              "expectedName": enteredStem + "." + outputExtension,
                                              "enteredName": "retitled"]
                    try JSONSerialization.data(withJSONObject: edit).write(to: request, options: .atomic)
                    try await scenarioWait { FileManager.default.fileExists(atPath: completed.path) }
                    try FileManager.default.removeItem(at: completed)
                }
                let finalName = (renameWithoutExtension ? "retitled" : enteredStem) + "." + outputExtension
                let destination = directory.url.appendingPathComponent(finalName)
                let overwrite = initial == .tarBzip2 && target == .tarXZ
                let sentinel = Data("Original verification file".utf8)
                if overwrite { try sentinel.write(to: destination) }
                var confirmation: [String: Any] = ["pid": getpid(), "saveTitle": "Save",
                                                   "expectedName": renameWithoutExtension ? "retitled" : finalName]
                if overwrite { confirmation["confirmationText"] = finalName }
                try JSONSerialization.data(withJSONObject: confirmation)
                    .write(to: request, options: .atomic)
                try await scenarioWait { response != nil }
                XCTAssertEqual(response, .OK)
                XCTAssertEqual(save.panel.url?.lastPathComponent, finalName)
                if overwrite { XCTAssertEqual(try Data(contentsOf: destination), sentinel) }
            }
        }
    }

}
