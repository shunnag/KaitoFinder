import AppKit
import ApplicationServices

// Invoked only by the UI verification driver, under its existing accessibility
// permission. Never prompts for permission or selects a user's running app.
let arguments = CommandLine.arguments
guard (4...5).contains(arguments.count), let pid = Int32(arguments[1]), !arguments[3].isEmpty,
      arguments[2].hasPrefix("com.shunnag.KaitoFinder.UIIntegrationVerification."),
      let app = NSRunningApplication(processIdentifier: pid),
      app.bundleIdentifier == arguments[2], !app.isTerminated,
      AXIsProcessTrusted() else {
    fputs("The isolated verification app or existing accessibility permission is unavailable.\n", stderr)
    exit(1)
}
let request = arguments.count == 5
    ? (try JSONSerialization.jsonObject(with: Data(arguments[4].utf8)) as? [String: Any] ?? [:]) : [:]

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

let application = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(application, 1)
_ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
let deadline = Date().addingTimeInterval(5)
var observedTitles = Set<String>()
while Date() < deadline {
    let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    var queue = windows, visited: [AXUIElement] = [], buttons: [AXUIElement] = []
    while !queue.isEmpty, visited.count < 2_000, Date() < deadline {
        let element = queue.removeFirst()
        guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
        visited.append(element)
        if (attribute(element, kAXRoleAttribute) as? String) == kAXButtonRole {
            let title = attribute(element, kAXTitleAttribute) as? String ?? ""
            observedTitles.insert(title)
            if title == arguments[3], (attribute(element, kAXEnabledAttribute) as? Bool) == true {
                buttons.append(element)
            }
        }
        queue += attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        if let value = attribute(element, kAXDefaultButtonAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
            queue.append(value as! AXUIElement)
        }
    }
    // The dedicated test opens one temporary save panel at a time.
    if buttons.count == 1 {
        if let expectedName = request["expectedName"] as? String {
            let fields = visited.filter {
                (attribute($0, kAXRoleAttribute) as? String) == kAXTextFieldRole
                    && (attribute($0, kAXValueAttribute) as? String) == expectedName
            }
            guard fields.count == 1 else {
                let values = visited.filter { (attribute($0, kAXRoleAttribute) as? String) == kAXTextFieldRole }
                    .compactMap { attribute($0, kAXValueAttribute) as? String }
                fputs("The native filename field does not uniquely match \(expectedName); observed: \(values).\n", stderr)
                exit(1)
            }
            if let enteredName = request["enteredName"] as? String {
                guard AXUIElementSetAttributeValue(fields[0], kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success,
                      AXUIElementSetAttributeValue(fields[0], kAXValueAttribute as CFString, enteredName as CFString) == .success else {
                    fputs("Cannot edit the isolated verification app's filename field.\n", stderr)
                    exit(1)
                }
                guard (attribute(fields[0], kAXValueAttribute) as? String) == enteredName else {
                    fputs("The native filename field did not retain the entered name.\n", stderr)
                    exit(1)
                }
            }
        }
        if request["editOnly"] as? Bool == true {
            guard request["expectedName"] is String,
                  request["enteredName"] is String || request["selectedFormat"] is String else { exit(1) }
            if let from = request["initialFormat"] as? String, let to = request["selectedFormat"] as? String {
                let popups = visited.filter {
                    (attribute($0, kAXRoleAttribute) as? String) == kAXPopUpButtonRole
                        && (attribute($0, kAXIdentifierAttribute) as? String) == "ArchiveSaveFormat"
                        && ((attribute($0, kAXValueAttribute) as? String) == from
                            || (attribute($0, kAXTitleAttribute) as? String) == from)
                }
                guard popups.count == 1,
                      AXUIElementPerformAction(popups[0], kAXPressAction as CFString) == .success else {
                    fputs("Cannot open the isolated format popup for \(from).\n", stderr)
                    exit(1)
                }
                let menuDeadline = Date().addingTimeInterval(3)
                var selected = false
                while Date() < menuDeadline, !selected {
                    var pending = attribute(popups[0], kAXChildrenAttribute) as? [AXUIElement] ?? []
                    var count = 0
                    while !pending.isEmpty, count < 100 {
                        count += 1
                        let item = pending.removeFirst()
                        if (attribute(item, kAXRoleAttribute) as? String) == kAXMenuItemRole,
                           (attribute(item, kAXTitleAttribute) as? String) == to {
                            selected = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                            break
                        }
                        pending += attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
                    }
                    if !selected { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
                }
                guard selected else {
                    fputs("Cannot select \(to) in the isolated format popup.\n", stderr)
                    exit(1)
                }
            }
            print("Edited the isolated verification app's filename field.")
            exit(0)
        }
        let result = AXUIElementPerformAction(buttons[0], kAXPressAction as CFString)
        // The native overwrite sheet can replace the AX button while its action
        // is returning. In that case require the expected sheet below as proof.
        guard result == .success || request["confirmationText"] is String else {
            fputs("Cannot press the verification Save button: \(result.rawValue)\n", stderr)
            exit(1)
        }
        print("Pressed the isolated verification app's default Save button.")
        if let confirmationText = request["confirmationText"] as? String {
            let confirmationDeadline = Date().addingTimeInterval(5)
            var confirmed = false
            var observed: [String] = []
            while Date() < confirmationDeadline, !confirmed {
                var descendants = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
                var seen: [AXUIElement] = []
                while !descendants.isEmpty, seen.count < 500 {
                    let element = descendants.removeFirst()
                    guard !seen.contains(where: { CFEqual($0, element) }) else { continue }
                    seen.append(element)
                    let role = attribute(element, kAXRoleAttribute) as? String ?? ""
                    if [kAXWindowRole, kAXSheetRole, kAXStaticTextRole, kAXButtonRole].contains(role) {
                        let entry = "\(role): \(attribute(element, kAXTitleAttribute) as? String ?? "") \(attribute(element, kAXValueAttribute) as? String ?? "")"
                        if !observed.contains(entry) { observed.append(entry) }
                    }
                    if role == kAXSheetRole {
                        var children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
                        var texts: [String] = []
                        var replacements: [AXUIElement] = []
                        var count = 0
                        while !children.isEmpty, count < 100 {
                            count += 1
                            let child = children.removeFirst()
                            if (attribute(child, kAXRoleAttribute) as? String) == kAXStaticTextRole,
                               let text = attribute(child, kAXValueAttribute) as? String { texts.append(text) }
                            // The nested native alert need not expose AXDefaultButton.
                            // Verification accepts Japanese and English system
                            // prompts; require the expected filename in this sheet.
                            if (attribute(child, kAXRoleAttribute) as? String) == kAXButtonRole,
                               (attribute(child, kAXEnabledAttribute) as? Bool) == true,
                               let title = attribute(child, kAXTitleAttribute) as? String,
                               ["Replace", "置き換え"].contains(title) {
                                replacements.append(child)
                            }
                            children += attribute(child, kAXChildrenAttribute) as? [AXUIElement] ?? []
                        }
                        if texts.contains(where: { $0.contains(confirmationText) }), replacements.count == 1 {
                            guard AXUIElementPerformAction(replacements[0], kAXPressAction as CFString) == .success else {
                                fputs("Cannot confirm the verification overwrite sheet.\n", stderr)
                                exit(1)
                            }
                            print("Confirmed the native sheet for the expected verification filename.")
                            confirmed = true
                            break
                        }
                    }
                    descendants += attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
                }
                if !confirmed { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            }
            guard confirmed else {
                fputs("The expected native overwrite confirmation was not shown: \(observed).\n", stderr)
                exit(1)
            }
        }
        exit(0)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
fputs("A unique enabled Save button was not found in the verification app; button titles: \(observedTitles.sorted()).\n", stderr)
exit(1)
