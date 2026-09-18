import AppKit
import Sparkle

/// verify_software_updates.py が作る一時 bundle だけを対象に、実 Sparkle で情報取得を試す。
/// checkForUpdateInformation はダウンロード・インストールを開始しない。
@MainActor final class UpdateProbe: NSObject, SPUUpdaterDelegate {
    var foundVersion: String?
    var finished = false
    var error: NSError?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { foundVersion = item.versionString }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        self.error = error as NSError?
        finished = true
    }
}

@main struct ProbeMain {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2, let bundle = Bundle(path: CommandLine.arguments[1]),
              bundle.bundleIdentifier?.hasPrefix("com.shunnag.KaitoFinder.UpdateProbe.") == true else { exit(2) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let probe = UpdateProbe()
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
            userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: probe)
        try updater.start()
        updater.checkForUpdateInformation()
        let deadline = Date().addingTimeInterval(20)
        while !probe.finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let result: [String: Any] = ["finished": probe.finished, "version": probe.foundVersion ?? "",
            "errorDomain": probe.error?.domain ?? "", "errorCode": probe.error?.code ?? 0,
            "error": probe.error?.localizedDescription ?? "", "checked": updater.lastUpdateCheckDate != nil]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        if !probe.finished { exit(3) }
    }
}
