import Foundation

/// / の直後に結合文字があっても、ファイルシステムと同じ位置でパスを分ける。
nonisolated enum ArchivePath {
    static func components(_ path: String, omittingEmptySubsequences: Bool = true) -> [String] {
        path.utf8.split(separator: 47, omittingEmptySubsequences: omittingEmptySubsequences)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func isDescendant(_ path: String, of parent: String) -> Bool {
        path.precomposedStringWithCanonicalMapping.utf8
            .starts(with: (parent + "/").precomposedStringWithCanonicalMapping.utf8)
    }

    static func replacingPrefix(of path: String, from source: String, to destination: String) -> String? {
        let path = path.precomposedStringWithCanonicalMapping
        let source = source.precomposedStringWithCanonicalMapping
        if path == source { return destination }
        guard path.utf8.starts(with: (source + "/").utf8) else { return nil }
        return destination + String(decoding: path.utf8.dropFirst(source.utf8.count), as: UTF8.self)
    }
}
