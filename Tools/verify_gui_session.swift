import CoreGraphics
import Foundation

// Read session state only. Do not unlock the screen, change idle settings,
// request capture permissions, or dismiss another application's windows.
guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
      session[kCGSessionOnConsoleKey as String] as? Bool == true else {
    print("UI verification requires the logged-in console session.")
    exit(1)
}
guard session["CGSSessionScreenIsLocked"] as? Bool != true else {
    print("UI verification is incomplete: macOS is locked. Unlock it and rerun the verification.")
    exit(1)
}
print("GUI session is unlocked.")
