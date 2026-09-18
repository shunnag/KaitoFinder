import AppKit
import XCTest
@testable import KaitoFinder

private final class TestSoftwareUpdater: NSObject, SoftwareUpdating {
    var isAvailable = true { didSet { notify() } }
    var canCheckForUpdates = true { didSet { notify() } }
    var automaticallyChecksForUpdates = true { didSet { notify() } }
    var automaticallyDownloadsUpdates = false { didSet { notify() } }
    var allowsAutomaticUpdates: Bool { automaticallyChecksForUpdates }
    var lastUpdateCheckDate: Date? { didSet { notify() } }
    var checks = 0
    func start() {}
    func checkForUpdates() { if isAvailable && canCheckForUpdates { checks += 1 } }
    private func notify() { NotificationCenter.default.post(name: SoftwareUpdateController.didChange, object: self) }
}

nonisolated final class SoftwareUpdateTests: XCTestCase {
    @MainActor func testSparklePersistsChoicesWithoutReplacingSavedPreferencesWithDefaults() throws {
        let directory = try ArchiveTestDirectory()
        let identifier = "com.shunnag.KaitoFinder.UpdaterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }
        let contents = directory.url.appendingPathComponent("Test.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "Updater Test",
            "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL",
            "SUFeedURL": "https://updates.example.invalid/appcast.xml",
            "SUPublicEDKey": Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey")!,
            "SUEnableAutomaticChecks": true, "SUAutomaticallyUpdate": false]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        let updater = SoftwareUpdateController(bundle: bundle)
        let suite = try ArchivePreferencesTestDefaults()
        let settings = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults), softwareUpdater: updater)
        defer { settings.close() }
        XCTAssertTrue(updater.isAvailable)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticallyDownloadsUpdates)
        XCTAssertNil(defaults.persistentDomain(forName: identifier)?["SUEnableAutomaticChecks"])
        updater.automaticallyDownloadsUpdates = true
        XCTAssertEqual(settings.automaticallyDownloadsUpdatesCheckbox.state, .on)
        updater.automaticallyChecksForUpdates = false
        XCTAssertEqual(settings.automaticallyChecksForUpdatesCheckbox.state, .off)
        XCTAssertFalse(settings.automaticallyDownloadsUpdatesCheckbox.isEnabled)
        XCTAssertEqual(defaults.persistentDomain(forName: identifier)?["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(defaults.persistentDomain(forName: identifier)?["SUAutomaticallyUpdate"] as? Bool, true)
        let reopened = SoftwareUpdateController(bundle: bundle)
        XCTAssertFalse(reopened.automaticallyChecksForUpdates)
        XCTAssertFalse(reopened.allowsAutomaticUpdates)
        reopened.automaticallyChecksForUpdates = true
        XCTAssertTrue(reopened.automaticallyDownloadsUpdates)
        // updater は明示的に start するまで通信を開始せず、手動確認もできない。
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.checkForUpdates()
        XCTAssertNil(updater.lastUpdateCheckDate)
    }

    @MainActor func testUpdateSettingsFollowLiveChangesAndManualCheckWorksWithAutomaticChecksOff() throws {
        preserveApplicationMenus()
        let suite = try ArchivePreferencesTestDefaults()
        let updater = TestSoftwareUpdater()
        let delegate = AppDelegate(preferencesStore: ArchivePreferencesStore(defaults: suite.defaults), softwareUpdater: updater)
        let menu = delegate.makeMenu()
        let item = try XCTUnwrap(menu.items.first?.submenu?.items.first { $0.action == #selector(AppDelegate.checkForUpdates(_:)) })
        delegate.showPreferences(nil)
        let controller = try XCTUnwrap(delegate.preferencesWindowController)
        defer { controller.close() }
        controller.tabController.selectedTabViewItemIndex = 3
        let window = try XCTUnwrap(controller.window)
        window.layoutIfNeeded()
        let frame = window.frame
        func click(_ button: NSButton) { button.performClick(nil) }
        click(controller.automaticallyDownloadsUpdatesCheckbox)
        XCTAssertTrue(updater.automaticallyDownloadsUpdates)
        click(controller.automaticallyChecksForUpdatesCheckbox)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(controller.automaticallyDownloadsUpdatesCheckbox.isEnabled)
        XCTAssertTrue(updater.automaticallyDownloadsUpdates, "Turning checks off must preserve the download preference")
        XCTAssertTrue(controller.checkForUpdatesButton.isEnabled)
        click(controller.checkForUpdatesButton)
        try performMenuItem(item)
        XCTAssertEqual(updater.checks, 2)
        updater.canCheckForUpdates = false
        menu.items.first?.submenu?.update()
        XCTAssertFalse(item.isEnabled)
        XCTAssertFalse(controller.checkForUpdatesButton.isEnabled)
        updater.lastUpdateCheckDate = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(controller.lastUpdateCheckLabel.stringValue.contains(String(localized: "未確認")))
        updater.automaticallyChecksForUpdates = true
        XCTAssertEqual(controller.automaticallyChecksForUpdatesCheckbox.state, .on)
        XCTAssertTrue(controller.automaticallyDownloadsUpdatesCheckbox.isEnabled)
        updater.automaticallyDownloadsUpdates = false
        XCTAssertEqual(controller.automaticallyDownloadsUpdatesCheckbox.state, .off)
        updater.canCheckForUpdates = true
        menu.items.first?.submenu?.update()
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(controller.checkForUpdatesButton.isEnabled)
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame, frame)
        controller.close()
        delegate.showPreferences(nil)
        XCTAssertTrue(delegate.preferencesWindowController === controller)
        XCTAssertEqual(controller.automaticallyDownloadsUpdatesCheckbox.state, .off)
    }

    @MainActor func testInvalidConfigurationDisablesUpdatingAndRequiresHTTPSAndAnEd25519Key() throws {
        let valid: [String: Any] = ["SUFeedURL": "https://updates.example.invalid/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()]
        XCTAssertTrue(SoftwareUpdateController.isConfigured(valid))
        for feed in ["", "http://updates.example.invalid/appcast.xml", "file:///tmp/feed.xml", "$(SPARKLE_FEED_URL)",
                     "https://user:password@updates.example.invalid/feed.xml"] {
            var info = valid; info["SUFeedURL"] = feed
            XCTAssertFalse(SoftwareUpdateController.isConfigured(info), feed)
        }
        for key in ["", "$(SPARKLE_PUBLIC_ED_KEY)", Data(repeating: 0, count: 31).base64EncodedString()] {
            var info = valid; info["SUPublicEDKey"] = key
            XCTAssertFalse(SoftwareUpdateController.isConfigured(info))
        }
        let updater = TestSoftwareUpdater()
        updater.isAvailable = false; updater.canCheckForUpdates = false
        let suite = try ArchivePreferencesTestDefaults()
        let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults), softwareUpdater: updater)
        defer { controller.close() }
        XCTAssertFalse(controller.automaticallyChecksForUpdatesCheckbox.isEnabled)
        XCTAssertFalse(controller.automaticallyDownloadsUpdatesCheckbox.isEnabled)
        XCTAssertFalse(controller.checkForUpdatesButton.isEnabled)
        XCTAssertEqual(controller.updateAvailabilityLabel.stringValue, String(localized: "このビルドでは自動更新を利用できません。"))
    }

    @MainActor func testUpdatePaneFitsEveryLanguageInBothAppearances() throws {
        for language in LocalizationAcceptance.languages {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let suite = try ArchivePreferencesTestDefaults()
                let updater = TestSoftwareUpdater()
                updater.lastUpdateCheckDate = Date(timeIntervalSince1970: 1_800_000_000)
                let controller = PreferencesWindowController(store: ArchivePreferencesStore(defaults: suite.defaults),
                    bundle: try LocalizationAcceptance.bundle(language), softwareUpdater: updater)
                defer { controller.close() }
                controller.tabController.selectedTabViewItemIndex = 3
                let pane = try XCTUnwrap(controller.tabController.tabViewItems[3].viewController?.view)
                pane.appearance = NSAppearance(named: appearance)
                pane.layoutSubtreeIfNeeded()
                XCTAssertTrue(UISnapshot.overflowViolations(in: pane).isEmpty,
                              "\(language) \(appearance): \(UISnapshot.overflowViolations(in: pane))")
                if ["ja", "en", "de"].contains(language) {
                    try UISnapshot.render(pane, name: "\(language)-software-update-\(appearance.rawValue)")
                }
            }
        }
    }
}
