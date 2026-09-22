import Darwin
import Foundation
import KaitoKit

/// 名前と同じ親の兄弟だけで判定し、内容や symlink の参照先は読まない。
nonisolated enum ArchiveSplitVolume {
    /// 通常の .zip / .zipx は宣言型に任せ、番号付きの巻だけを名前で受け入れる。
    static func isOpenableName(_ name: String) -> Bool {
        guard let parsed = ArchiveVolumeSet.parse(fileName: name) else { return false }
        return parsed.index >= 0
    }

    /// 途中の巻を単独で開かず、文書・履歴・一括展開で同じ入口を使う。
    static func gateURL(for url: URL) -> URL {
        guard url.isFileURL, let parsed = ArchiveVolumeSet.parse(fileName: url.lastPathComponent) else { return url }
        let names: [String]
        switch parsed.scheme {
        case .numbered(let stem, _):
            guard parsed.index > 0 else { return url }
            // 見えている桁幅を優先し、.1000 など桁が増えた名前は .001 も探す。
            names = [parsed.scheme.fileName(forVolumeAt: 0, count: 1), stem + ".001"]
        case .zipSpanned(let stem, _, let lastExtension):
            guard parsed.index >= 0 else { return url }
            let alternate = lastExtension == lastExtension.lowercased()
                ? lastExtension.uppercased() : lastExtension.lowercased()
            names = [stem + "." + lastExtension, stem + "." + alternate]
        }
        let parent = url.deletingLastPathComponent()
        for name in names {
            let gate = parent.appendingPathComponent(name, isDirectory: false)
            var info = stat()
            // 切れた symlink も入口として扱い、読み込み時に通常のエラーを返す。
            if lstat(gate.path, &info) == 0 { return gate }
        }
        return url
    }

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
