import Darwin
import Foundation

/// 名前と同じ親の兄弟だけで判定し、内容や symlink の参照先は読まない。
nonisolated enum ArchiveSplitVolume {
    static func isSplitVolumeMember(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard let dot = name.lastIndex(of: ".") else { return false }
        let suffix = name[name.index(after: dot)...], stem = String(name[..<dot])
        let parent = url.deletingLastPathComponent()
        func exists(_ extensionName: String) -> Bool {
            let sibling = parent.appendingPathComponent(stem + "." + extensionName, isDirectory: false)
            var info = stat()
            return lstat(sibling.path, &info) == 0
        }
        if digits(suffix, minimumCount: 3) {
            let padding = String(repeating: "0", count: suffix.utf8.count - 1)
            // 整数へ変換せず、桁あふれする連番も同じ規則で扱う。
            if suffix.drop(while: { $0 == "0" }) == "1" {
                return exists(padding + "2") || exists(padding + "0")
            }
            return exists("001") || exists(padding + "1")
        }
        let lower = suffix.lowercased()
        if lower.hasPrefix("zx"), digits(lower.dropFirst(2), minimumCount: 2) { return true }
        if lower.hasPrefix("z"), digits(lower.dropFirst(), minimumCount: 2) { return true }
        if lower == "zip" || lower == "zipx" {
            return ["z01", "Z01", "zx01", "ZX01"].contains(where: exists)
        }
        return false
    }

    private static func digits(_ text: Substring, minimumCount: Int) -> Bool {
        text.utf8.count >= minimumCount && text.utf8.allSatisfy { (48...57).contains($0) }
    }
}
