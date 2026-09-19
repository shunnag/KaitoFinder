import AppKit
import ScreenCaptureKit

// Captures only the UUID-scoped verification app's requested window.
@main @MainActor private struct CapturePreviewSidebar {
    private struct Request: Decodable {
        let pid: Int32
        let bundle: String
        let window: UInt32
        let name: String
        let drag: [[Double]]?
    }

    static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 2 else { throw NSError(domain: "ExpectedRequestFile", code: 1) }
        let path = URL(fileURLWithPath: CommandLine.arguments[1])
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: path))
        let prefix = "com.shunnag.KaitoFinder.PreviewVerification."
        guard request.bundle.hasPrefix(prefix), UUID(uuidString: String(request.bundle.dropFirst(prefix.count))) != nil,
              request.name.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil,
              let application = NSRunningApplication(processIdentifier: request.pid),
              application.bundleIdentifier == request.bundle else { throw NSError(domain: "ExpectedIsolatedPreviewApp", code: 2) }
        guard CGPreflightScreenCaptureAccess() else { throw NSError(domain: "ScreenRecordingPermissionRequired", code: 3) }
        application.activate(options: [.activateAllWindows])
        try await Task.sleep(for: .milliseconds(300))
        if let drag = request.drag {
            guard drag.count == 2, drag.allSatisfy({ $0.count == 2 }), application.isActive,
                  CGPreflightPostEventAccess(),
                  let screen = NSScreen.screens.first else { throw NSError(domain: "InvalidPreviewDrag", code: 6) }
            let start = CGPoint(x: drag[0][0], y: screen.frame.maxY - drag[0][1])
            let end = CGPoint(x: drag[1][0], y: screen.frame.maxY - drag[1][1])
            let shared = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let target = shared.windows.first(where: { $0.windowID == request.window && $0.owningApplication?.processID == request.pid }),
                  target.frame.contains(start), target.frame.contains(end) else { throw NSError(domain: "DragOutsidePreviewWindow", code: 8) }
            let source = CGEventSource(stateID: .hidSystemState)
            for step in 0...10 {
                let point = CGPoint(x: start.x + (end.x - start.x) * Double(step) / 10, y: start.y)
                let type: CGEventType = step == 0 ? .leftMouseDown : step == 10 ? .leftMouseUp : .leftMouseDragged
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                    throw NSError(domain: "PreviewDragEventFailed", code: 7)
                }
                event.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(30))
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.windowID == request.window && $0.owningApplication?.processID == request.pid
                && $0.owningApplication?.bundleIdentifier == request.bundle
        }) else { throw NSError(domain: "ExpectedIsolatedPreviewWindow", code: 4) }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(ceil(window.frame.width * 2))
        configuration.height = Int(ceil(window.frame.height * 2))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        let bitmap = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PreviewCaptureFailed", code: 5)
        }
        let directory = path.deletingLastPathComponent().appendingPathComponent("captures", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(request.name + ".png"))
        print("Captured verification window: \(request.name)")
    }
}
