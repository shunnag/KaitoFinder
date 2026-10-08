import CoreGraphics
import Foundation

// この実行ファイルも Xcode 27 で作って運ぶ。runtime job は swift を実行しない。
let session = CGSessionCopyCurrentDictionary() as? [String: Any]
let onConsole = session?[kCGSessionOnConsoleKey as String] as? Bool
let locked = session?["CGSSessionScreenIsLocked"] as? Bool
print("kCGSSessionOnConsoleKey=\(onConsole.map(String.init) ?? "unavailable")")
print("CGSSessionScreenIsLocked=\(locked.map(String.init) ?? "unavailable")")
guard onConsole == true, locked != true else {
    fputs("error: app-hosted tests require an unlocked console session\n", stderr)
    exit(1)
}
