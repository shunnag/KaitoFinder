import AppKit
import Sparkle

/// 設定画面とメニューは同じ updater を使う。設定の永続化は Sparkle に任せる。
protocol SoftwareUpdating: NSObjectProtocol {
    var isAvailable: Bool { get }
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var allowsAutomaticUpdates: Bool { get }
    var lastUpdateCheckDate: Date? { get }
    func start()
    func checkForUpdates()
}

final class SoftwareUpdateController: NSObject, SoftwareUpdating {
    static let shared = SoftwareUpdateController()
    static let didChange = Notification.Name("SoftwareUpdateStateDidChange")

    private let updater: SPUUpdater
    private let configured: Bool
    private var started = false
    private(set) var startError: Error?
    private var observations: [NSKeyValueObservation] = []

    init(bundle: Bundle = .main) {
        configured = Self.isConfigured(bundle.infoDictionary ?? [:])
        // SPUUpdater を直接所有し、初期化エラーは設定画面で扱う。更新 UI は Sparkle 標準。
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                             userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: nil)
        super.init()
        observe(\.automaticallyChecksForUpdates)
        observe(\.automaticallyDownloadsUpdates)
        observe(\.allowsAutomaticUpdates)
        observe(\.canCheckForUpdates)
        observe(\.lastUpdateCheckDate)
    }

    static func isConfigured(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32
        else { return false }
        return true
    }

    var isAvailable: Bool { configured && startError == nil }
    var canCheckForUpdates: Bool { isAvailable && started && updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { guard isAvailable else { return }; updater.automaticallyChecksForUpdates = newValue }
    }
    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { guard isAvailable, allowsAutomaticUpdates else { return }; updater.automaticallyDownloadsUpdates = newValue }
    }
    var allowsAutomaticUpdates: Bool { isAvailable && updater.allowsAutomaticUpdates }
    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func start() {
        guard configured, !started, startError == nil else { return }
        do { try updater.start(); started = true }
        catch { startError = error; NSLog("Unable to start software updates: %@", String(describing: error)) }
        notifyChange()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    private func observe<Value>(_ keyPath: KeyPath<SPUUpdater, Value>) {
        observations.append(updater.observe(keyPath) { [weak self] _, _ in
            // Sparkle のこれらのプロパティは main thread 専用で KVO 準拠。
            MainActor.assumeIsolated { self?.notifyChange() }
        })
    }

    private func notifyChange() { NotificationCenter.default.post(name: Self.didChange, object: self) }
}
