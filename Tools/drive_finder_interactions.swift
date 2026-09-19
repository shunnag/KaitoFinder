import AppKit
import ScreenCaptureKit

// Sends input only to the UUID-scoped test app's requested window.
@main @MainActor private struct DriveFinderInteractions {
    struct Input: Decodable {
        let type: String
        let x: Double?
        let y: Double?
        let count: Int?
        let modifiers: UInt64?
        let key: UInt16?
    }
    struct Request: Decodable {
        let pid: Int32
        let bundle: String
        let window: UInt32
        let events: [Input]
        let capture: String?
    }

    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 2 else { throw failure("ExpectedRequest") }
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: path))
        let prefix = "com.shunnag.KaitoFinder.FinderInteractionVerification."
        guard request.bundle.hasPrefix(prefix), UUID(uuidString: String(request.bundle.dropFirst(prefix.count))) != nil,
              let application = NSRunningApplication(processIdentifier: request.pid),
              application.bundleIdentifier == request.bundle,
              CGPreflightPostEventAccess(), let screen = NSScreen.screens.first,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["CGSSessionScreenIsLocked"] as? Bool != true else { throw failure("ExpectedUnlockedTestApp") }
        application.activate(options: [.activateAllWindows])
        var targetBounds: CGRect?
        for _ in 0..<100 {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
            if application.isActive, let target = windows.first(where: {
                ($0[kCGWindowNumber as String] as? UInt32) == request.window
                    && ($0[kCGWindowOwnerPID as String] as? Int32) == request.pid
            }), let rawBounds = target[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: rawBounds) {
                targetBounds = bounds
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let bounds = targetBounds else { throw failure("ExpectedTestWindow") }
        let source = CGEventSource(stateID: .hidSystemState)
        for input in request.events {
            guard application.isActive else { throw failure("TestAppLostFocus") }
            let event: CGEvent?
            if let key = input.key {
                guard [36, 53, 125, 126].contains(key), ["keyDown", "keyUp"].contains(input.type) else { throw failure("InvalidKey") }
                event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: input.type == "keyDown")
            } else {
                let types: [String: CGEventType] = ["down": .leftMouseDown, "up": .leftMouseUp, "drag": .leftMouseDragged]
                guard let type = types[input.type], let x = input.x, let y = input.y else { throw failure("InvalidMouseEvent") }
                let point = CGPoint(x: x, y: screen.frame.maxY - y)
                guard bounds.contains(point) else { throw failure("InputOutsideTestWindow") }
                event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(input.count ?? 1))
            }
            guard let event else { throw failure("EventCreationFailed") }
            event.flags = CGEventFlags(rawValue: input.modifiers ?? 0)
            event.post(tap: .cghidEventTap)
            try await Task.sleep(for: .milliseconds(25))
        }
        if let name = request.capture {
            guard name.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil,
                  CGPreflightScreenCaptureAccess() else { throw failure("InvalidCapture") }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == request.window && $0.owningApplication?.processID == request.pid }) else {
                throw failure("TestWindowClosed")
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(ceil(window.frame.width * 2))
            configuration.height = Int(ceil(window.frame.height * 2))
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true
            let bitmap = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
            guard let png = NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]) else { throw failure("CaptureFailed") }
            let directory = path.deletingLastPathComponent().appendingPathComponent("captures", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    static func failure(_ reason: String) -> NSError { NSError(domain: reason, code: 1) }
}
