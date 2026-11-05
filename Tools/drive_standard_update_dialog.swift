import AppKit
import ApplicationServices
import Foundation

// 公開版の標準 Sparkle ダイアログを、更新確認→インストール→再起動の順に操作する。
// GUI セッション内で実行すること（ssh からは gui-run を使う）。
// 指定したアプリをその場で置き換えるため、使い捨てのコピーだけを渡す。
// 実際の設定ドメイン com.shunnag.KaitoFinder を使うので、設定を退避してから実行する。
let launchTimeout: TimeInterval = 30
let installButtonTimeout: TimeInterval = 60
let relaunchButtonTimeout: TimeInterval = 180
let oldProcessExitTimeout: TimeInterval = 120
let relaunchTimeout: TimeInterval = 120
let terminationTimeout: TimeInterval = 5
let forcedTerminationTimeout: TimeInterval = 5
let pollInterval: TimeInterval = 0.5
let launchSettleDelay: TimeInterval = 4
let activationSettleDelay: TimeInterval = 1
let relaunchSettleDelay: TimeInterval = 3

let bundleID = "com.shunnag.KaitoFinder"
setbuf(stdout, nil)

func usage(_ reason: String) -> Never {
    fputs("\(reason)\nUsage: drive_standard_update_dialog <path to KaitoFinder.app> [--expect-version <CFBundleShortVersionString>]\n", stderr)
    exit(64)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 4 else { usage("Wrong arguments.") }
if arguments.count == 4 {
    guard arguments[2] == "--expect-version", !arguments[3].isEmpty,
          !arguments[3].hasPrefix("--") else { usage("Expected --expect-version and a version string.") }
}
guard arguments[1].hasSuffix(".app") else { usage("The path must end in .app.") }
let inputURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let appURL = inputURL.resolvingSymlinksInPath()
let appPath = appURL.path
let expectedVersion = arguments.count == 4 ? arguments[3] : nil
guard ![inputURL.path, appPath].contains(where: { $0 == "/Applications" || $0.hasPrefix("/Applications/") }) else {
    usage("Use a disposable copy outside /Applications; this tool replaces the app in place.")
}
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: appPath, isDirectory: &isDirectory), isDirectory.boolValue,
      FileManager.default.fileExists(atPath: appPath + "/Contents/Info.plist") else {
    usage("The app bundle is missing: \(appPath)")
}
guard AXIsProcessTrusted() else {
    fputs("Accessibility permission is required. Run this tool in the GUI session (use gui-run from ssh).\n", stderr)
    exit(1)
}

struct AppVersion {
    let version: String
    let build: String
    let buildNumber: Int
}

func readVersion() throws -> AppVersion {
    // Bundle のキャッシュを使わず、置き換え前後の Info.plist を毎回ディスクから読む。
    let data = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
    guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
          plist["CFBundleIdentifier"] as? String == bundleID,
          let version = plist["CFBundleShortVersionString"] as? String, !version.isEmpty,
          let build = plist["CFBundleVersion"] as? String, let buildNumber = Int(build) else {
        throw NSError(domain: "StandardUpdateDialogDriver", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Expected a KaitoFinder Info.plist with a short version and an integer build number."
        ])
    }
    return AppVersion(version: version, build: build, buildNumber: buildNumber)
}

let oldVersion: AppVersion
do {
    oldVersion = try readVersion()
} catch {
    fputs("Cannot read the original version: \(error.localizedDescription)\n", stderr)
    exit(2)
}

func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func title(_ element: AXUIElement) -> String { (attr(element, kAXTitleAttribute) as? String) ?? "" }
func role(_ element: AXUIElement) -> String { (attr(element, kAXRoleAttribute) as? String) ?? "" }

func buttons(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    if depth > 8 { return [] }
    var result: [AXUIElement] = role(element) == kAXButtonRole as String ? [element] : []
    for child in children(element) { result += buttons(in: child, depth: depth + 1) }
    return result
}

func hasInputPath(_ app: NSRunningApplication) -> Bool {
    app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == appPath
}

func oldProcessExited() -> Bool { NSRunningApplication(processIdentifier: oldPID)?.isTerminated ?? true }

func runningApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { hasInputPath($0) && !$0.isTerminated }
}

func wait(_ seconds: TimeInterval, _ body: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if body() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
    return body()
}

func windowDump(_ pid: pid_t) {
    let ax = AXUIElementCreateApplication(pid)
    let windows = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    print("pid:", pid, "open windows:", windows.count)
    for window in windows {
        print("window:", title(window), "buttons:", buttons(in: window).map(title))
    }
}

func terminateInstances() -> Bool {
    var instances = runningApps()
    for app in instances { _ = app.terminate() }
    if wait(terminationTimeout, { instances.allSatisfy(\.isTerminated) && runningApps().isEmpty }) { return true }
    // 終了待ちの間に再起動した同じパスのプロセスも回収する。
    let restarted = runningApps().filter { app in
        !instances.contains(where: { $0.processIdentifier == app.processIdentifier })
    }
    for app in restarted {
        _ = app.terminate()
        instances.append(app)
    }
    if !restarted.isEmpty { _ = wait(terminationTimeout, { restarted.allSatisfy(\.isTerminated) }) }
    for app in instances where !app.isTerminated { _ = app.forceTerminate() }
    return wait(forcedTerminationTimeout, { instances.allSatisfy(\.isTerminated) && runningApps().isEmpty })
}

enum FailureStage: Int32 {
    case launch = 3, menuBar, menuItem, installButton, relaunchButton, oldProcessExit
    case relaunch, updatedPlist, processIdentity, buildIncrease, expectedVersion, termination
}

func fail(_ stage: FailureStage, _ reason: String) -> Never {
    print("FAIL (\(stage.rawValue)): \(reason)")
    let instances = runningApps()
    if instances.isEmpty { print("No running instances at:", appPath) }
    for app in instances { windowDump(app.processIdentifier) }
    if !terminateInstances() { print("Could not terminate every instance at:", appPath) }
    exit(stage.rawValue)
}

func clickButton(_ pid: pid_t, matching words: [String]) -> String? {
    let ax = AXUIElementCreateApplication(pid)
    for window in (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        for button in buttons(in: window) {
            let buttonTitle = title(button)
            if words.contains(where: { buttonTitle.contains($0) }),
               AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                return buttonTitle
            }
        }
    }
    return nil
}

let config = NSWorkspace.OpenConfiguration()
config.createsNewApplicationInstance = true
config.activates = true
var launchError: Error?
NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
    launchError = error
}
guard wait(launchTimeout, { !runningApps().isEmpty || launchError != nil }), let app = runningApps().first else {
    fail(.launch, launchError.map { "Launch error: \($0.localizedDescription)" } ?? "Timed out waiting for launch.")
}
let oldPID = app.processIdentifier
print("launched pid", oldPID, "version", oldVersion.version, "build", oldVersion.build)
RunLoop.current.run(until: Date().addingTimeInterval(launchSettleDelay))
app.activate()
RunLoop.current.run(until: Date().addingTimeInterval(activationSettleDelay))

let ax = AXUIElementCreateApplication(oldPID)
guard let barValue = attr(ax, kAXMenuBarAttribute), CFGetTypeID(barValue) == AXUIElementGetTypeID() else {
    fail(.menuBar, "No menu bar.")
}
let bar = barValue as! AXUIElement
var pressed = false
outer: for top in children(bar) {
    for menu in children(top) {
        for item in children(menu) where title(item).contains("アップデートを確認") || title(item).contains("Check for Updates") {
            print("menu item:", title(item), "enabled:", attr(item, kAXEnabledAttribute) as? Bool ?? false)
            guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
                fail(.menuItem, "Could not press the update menu item.")
            }
            pressed = true
            break outer
        }
    }
}
guard pressed else { fail(.menuItem, "Update menu item not found.") }

var installTitle: String?
guard wait(installButtonTimeout, {
    installTitle = clickButton(oldPID, matching: ["アップデートをインストール", "Install Update"])
    return installTitle != nil
}), let pressedInstallTitle = installTitle else { fail(.installButton, "Timed out waiting for the install button.") }
print("pressed:", pressedInstallTitle)

var relaunchTitle: String?
guard wait(relaunchButtonTimeout, {
    relaunchTitle = clickButton(oldPID, matching: ["インストールして再起動", "Install and Relaunch"])
    return relaunchTitle != nil || oldProcessExited()
}) else {
    fail(.relaunchButton, "Timed out waiting for the install and relaunch button.")
}
print("pressed:", relaunchTitle ?? "(the original process exited during the press)")

guard wait(oldProcessExitTimeout, { oldProcessExited() }) else {
    fail(.oldProcessExit, "Timed out waiting for the old process to exit.")
}
print("old process exited")
var newApp: NSRunningApplication?
guard wait(relaunchTimeout, {
    newApp = runningApps().first { $0.processIdentifier != oldPID && $0.isFinishedLaunching }
    return newApp != nil
}), let relaunched = newApp else { fail(.relaunch, "Timed out waiting for relaunch at the input path with a new pid.") }
RunLoop.current.run(until: Date().addingTimeInterval(relaunchSettleDelay))
guard hasInputPath(relaunched), relaunched.processIdentifier != oldPID, !relaunched.isTerminated else {
    fail(.processIdentity, "The relaunched process must run from the input path with a different pid.")
}
let newVersion: AppVersion
do {
    newVersion = try readVersion()
} catch {
    fail(.updatedPlist, "Cannot read the updated version: \(error.localizedDescription)")
}
print("relaunched pid", relaunched.processIdentifier, "version", newVersion.version, "build", newVersion.build)
guard newVersion.buildNumber > oldVersion.buildNumber else {
    fail(.buildIncrease, "The build did not increase: \(oldVersion.build) -> \(newVersion.build).")
}
if let expectedVersion, newVersion.version != expectedVersion {
    fail(.expectedVersion, "Expected version \(expectedVersion), got \(newVersion.version).")
}
print("PASS \(oldVersion.version) (\(oldVersion.build)) -> \(newVersion.version) (\(newVersion.build))")
guard terminateInstances() else { fail(.termination, "The relaunched instance did not terminate.") }
