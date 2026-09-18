import AppKit

// Operates only on UUID-labelled copies under the installation test's own root.
// No AX events, screen capture, or controls for the user's application.
@main struct VerificationAppControl {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let prefix = "com.shunnag.KaitoFinder.UpdateInstallVerification."
        guard args.count == 4, ["inspect", "launch", "terminate"].contains(args[1]),
              args[2].hasPrefix(prefix), UUID(uuidString: String(args[2].dropFirst(prefix.count))) != nil else { exit(2) }
        let url = URL(fileURLWithPath: args[3]).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.contains("/kaitofinder-install-verify-"), url.lastPathComponent == "KaitoFinder.app",
              url.deletingLastPathComponent().lastPathComponent == "installed",
              Bundle(url: url)?.bundleIdentifier == args[2] else { exit(2) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        func matches() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier: args[2]).filter {
                $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == url && !$0.isTerminated
            }
        }
        if args[1] == "launch" {
            guard matches().isEmpty else { exit(3) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.createsNewApplicationInstance = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else if args[1] == "terminate" {
            let applications = matches()
            guard applications.allSatisfy({ $0.terminate() }) else { exit(4) }
            let deadline = Date().addingTimeInterval(10)
            while applications.contains(where: { !$0.isTerminated }), Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard applications.allSatisfy(\.isTerminated) else { exit(5) }
        }
        let rows: [[String: Any]] = matches().map {
            ["pid": $0.processIdentifier, "finishedLaunching": $0.isFinishedLaunching,
             "bundlePath": $0.bundleURL?.path ?? "", "executablePath": $0.executableURL?.path ?? ""]
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self))
    }
}
