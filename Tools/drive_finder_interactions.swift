import AppKit
import Carbon
import ScreenCaptureKit

struct FinderInteractionKeyboardLayout {
    let data: CFData
    let identifier: String
    let keyboardType: UInt32

    static func current() throws -> Self {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            throw failure("Cannot read the current keyboard layout")
        }
        return try Self(inputSource: source, keyboardType: UInt32(LMGetKbdType()))
    }

    init(inputSource: TISInputSource, keyboardType: UInt32) throws {
        if let rawIdentifier = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID) {
            identifier = Unmanaged<CFString>.fromOpaque(rawIdentifier).takeUnretainedValue() as String
        } else {
            identifier = "unknown"
        }
        guard let rawData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            throw Self.failure("Keyboard layout \(identifier) has no Unicode key layout data")
        }
        data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        self.keyboardType = keyboardType
    }

    func keyCode(for character: String) throws -> CGKeyCode {
        guard ["[", "]"].contains(character) else {
            throw Self.failure("Only the characters [ and ] are allowed")
        }
        guard CFDataGetLength(data) > 0, let bytes = CFDataGetBytePtr(data) else {
            throw Self.failure("Keyboard layout \(identifier) has empty Unicode key layout data")
        }
        return try withExtendedLifetime(data) {
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            for key in UInt16(0)...UInt16(127) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 255)
                let status = UCKeyTranslate(layout, key, UInt16(kUCKeyActionDown), 0, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState,
                                            characters.count, &length, &characters)
                if status == noErr, String(utf16CodeUnits: characters, count: length) == character {
                    return key
                }
            }
            throw Self.failure("Keyboard layout \(identifier) (keyboard type \(keyboardType)) cannot type \(character) without modifiers")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "FinderInteractionKeyboardLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// Sends input only to the UUID-scoped test app's requested window.
// The standalone unit tests compile this file without its input-posting entry point.
#if !FINDER_INTERACTION_DRIVER_TESTS
@main
#endif
struct DriveFinderInteractions {
    struct Input: Decodable {
        let type: String
        let x: Double?
        let y: Double?
        let count: Int?
        let modifiers: UInt64?
        let key: UInt16?
        let character: String?

        func resolvedKeyCode(layout: FinderInteractionKeyboardLayout? = nil) throws -> CGKeyCode? {
            guard key != nil || character != nil else { return nil }
            guard ["keyDown", "keyUp"].contains(type), key == nil || character == nil else { throw failure("InvalidKey") }
            if let key {
                guard [36, 53, 125, 126].contains(key) else { throw failure("InvalidKey") }
                return key
            }
            guard let character, ["[", "]"].contains(character) else { throw failure("InvalidCharacter") }
            return try (layout ?? FinderInteractionKeyboardLayout.current()).keyCode(for: character)
        }
    }
    struct Request: Decodable {
        let pid: Int32
        let bundle: String
        let window: UInt32
        let events: [Input]
        let capture: String?
    }

    @MainActor static func main() async throws {
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
        // Read the layout after activation, and use one snapshot for key-down/up pairs.
        // Resolve before posting anything so an unsupported character cannot leave a key held down.
        let layout = try request.events.contains { $0.character != nil } ? FinderInteractionKeyboardLayout.current() : nil
        let keys = try request.events.map { try $0.resolvedKeyCode(layout: layout) }
        let source = CGEventSource(stateID: .hidSystemState)
        for (input, key) in zip(request.events, keys) {
            guard application.isActive else { throw failure("TestAppLostFocus") }
            let event: CGEvent?
            if let key {
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
