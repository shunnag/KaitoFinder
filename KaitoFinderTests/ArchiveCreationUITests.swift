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
            for format in [GyoshukuKit.ArchiveFormat.zip, .tarGzip] {
                store.preferences.defaultFormat = format
                store.preferences.zipLevel = value
                store.preferences.tarGzipLevel = value
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
            XCTAssertEqual(save.levelPopup.isEnabled, format == .zip || format == .tarGzip)
            XCTAssertEqual(save.levelPopup.numberOfItems, save.controller.levels.count)
            XCTAssertEqual(save.levelPopup.indexOfSelectedItem, save.controller.selectedLevelIndex)
            switch format {
            case .zip: XCTAssertEqual(save.controller.level, .maximum)
            case .tarGzip:
                XCTAssertEqual(save.controller.level, .fast)
                XCTAssertFalse(save.controller.levels.contains(.none))
            case .tar: XCTAssertEqual(save.controller.level, .normal)
            case .sevenZip, .lha:
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

    @MainActor func testSavePanelPopupUpdatesContentTypesAndSwapsEveryExtension() throws {
        let preferences = try Preferences()
        let save = ArchiveSavePanel(sources: [URL(fileURLWithPath: "/tmp/a.jpg")], defaults: preferences.defaults)
        let cases: [(GyoshukuKit.ArchiveFormat, String, String)] = [
            (.zip, "zip", "public.zip-archive"), (.tar, "tar", "public.tar-archive"),
            (.tarGzip, "tar.gz", "org.gnu.gnu-zip-archive"),
            (.sevenZip, "7z", "org.7-zip.7-zip-archive"), (.lha, "lzh", "public.lha-archive")
        ]
        XCTAssertTrue(save.formatPopup.target === save)
        for (index, value) in cases.enumerated() {
            let (format, suffix, identifier) = value
            save.formatPopup.selectItem(at: index)
            XCTAssertTrue(save.formatPopup.sendAction(save.formatPopup.action, to: save.formatPopup.target))
            // tar.gz の保存には末尾 gz に合う .gzip を使う。他の形式は登録か拡張子から解決する。
            let type: UTType = format == .tarGzip ? .gzip : try XCTUnwrap(UTType(identifier) ?? UTType(filenameExtension: suffix))
            XCTAssertNotEqual(type, .data)
            XCTAssertEqual(save.controller.format, format)
            XCTAssertEqual(save.controller.allowedContentTypes, [type])
            XCTAssertEqual(save.panel.allowedContentTypes, [type])
            XCTAssertEqual(save.panel.nameFieldStringValue, "a.jpg." + suffix)
        }
        XCTAssertEqual(save.formatPopup.itemTitles, ["ZIP", "tar", "tar.gz", "7z", "LHA"])
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
        let suffixes = ["zip", "tar", "tar.gz", "7z", "lzh"]
        let controller = ArchiveSavePanelController(defaults: preferences.defaults)
        XCTAssertEqual(controller.format, .zip)
        var filename = "Docs.zip"
        for (index, format) in ArchiveSavePanelController.formats.enumerated() {
            filename = controller.selectFormat(at: index, filename: filename)
            XCTAssertEqual(preferences.defaults.string(forKey: "ArchiveCreationFormat"), suffixes[index])
            let restored = ArchiveSavePanelController(defaults: preferences.defaults)
            XCTAssertEqual(restored.format, format)
            XCTAssertEqual(restored.selectedIndex, index)
            XCTAssertEqual(filename, "Docs." + suffixes[index])
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

    @MainActor func testFormatSwitchPreservesEditedStemsAndRemovesCompoundExtensions() throws {
        let preferences = try Preferences(), controller = ArchiveSavePanelController(defaults: preferences.defaults)
        let gzip = controller.selectFormat(at: 2, filename: "photos.backup.zip")
        XCTAssertEqual(gzip, "photos.backup.tar.gz")
        XCTAssertEqual(controller.selectFormat(at: 3, filename: gzip), "photos.backup.7z")
        XCTAssertEqual(controller.selectFormat(at: 4, filename: "edited.name"), "edited.name.lzh")
        XCTAssertEqual(controller.selectFormat(at: -1, filename: "unchanged.lzh"), "unchanged.lzh")
        XCTAssertEqual(controller.selectFormat(at: 5, filename: "unchanged.lzh"), "unchanged.lzh")
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
        XCTAssertFalse(save.panel.isExtensionHidden)
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
        XCTAssertEqual(conversion.panel.nameFieldStringValue, "Original.tar.gz")
        XCTAssertEqual(conversion.controller.format, .tarGzip)
        XCTAssertEqual(conversion.formatPopup.indexOfSelectedItem, 2)
    }

    @MainActor func testFileMenuStartsWithCommandNAndDoesNotOpenUntitledDocuments() throws {
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
}
