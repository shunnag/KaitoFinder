import Darwin
import Foundation
import GyoshukuKit
import KaitoKit

nonisolated enum ExtractionPath {
    enum NameSyntax: Sendable, Equatable {
        case portable, posix

        init(_ format: KaitoKit.ArchiveFormat) { self = format == .tar ? .posix : .portable }
        init(_ format: GyoshukuKit.ArchiveFormat) { self = format.allowsColonsAndBackslashes ? .posix : .portable }
    }

    static func components(_ name: String, syntax: NameSyntax) throws -> [String] {
        guard !name.utf8.contains(0) else { throw ExtractionFailure.refused(String(localized: "パスにNULがあります。")) }
        // UTF-8 の区切り byte で分割する。結合文字を / と一書記素にしない。
        var bytes = Array(name.utf8.drop(while: { $0 == 47 }))
        if syntax == .portable, bytes.count >= 2, isLetter(bytes[0]), bytes[1] == 58 {
            bytes.removeFirst(2)
        }
        let raw = bytes.split(whereSeparator: { $0 == 47 || (syntax == .portable && $0 == 92) })
            .map { String(decoding: $0, as: UTF8.self) }
        guard !raw.contains("..") else { throw ExtractionFailure.refused(String(localized: "パスに..成分があります。")) }
        // \\ を特別に扱う driver にも、親へ戻る一歩を渡さない。
        if syntax == .posix, raw.contains(where: containsBackslashParent) {
            throw ExtractionFailure.refused(String(localized: "パスに..成分があります。"))
        }
        let components = raw.filter { $0 != "." }
        guard !components.isEmpty else { throw ExtractionFailure.refused(String(localized: "パスに有効な名前がありません。")) }
        return components
    }

    static func containsBackslashParent(_ component: String) -> Bool {
        component.utf8.split(separator: 92).contains { $0.elementsEqual([46, 46]) }
    }

    static func isInside(_ candidate: URL, root: URL) -> Bool {
        guard candidate.isFileURL, root.isFileURL,
              let resolvedRoot = resolvedPath(root.path),
              let resolvedCandidate = resolvedPath(candidate.path) else { return false }
        let prefix = resolvedRoot == "/" ? "/" : resolvedRoot + "/"
        return resolvedCandidate != resolvedRoot && resolvedCandidate.utf8.starts(with: prefix.utf8)
    }

    /// Foundation の resolvingSymlinksInPath は葉が未作成だと中間リンクを
    /// 解決しない場合がある。各成分を順に解決し、.. はリンク解決の後で処理する。
    /// 実際の書き込みでは別途 descriptor と NOFOLLOW を使い、検査だけを信用しない。
    static func resolvedPath(_ path: String, requireExistingParents: Bool = false) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        var pending = path.utf8.split(separator: 47).map { String(decoding: $0, as: UTF8.self) }.reversed().map { $0 }
        var resolved: [String] = []
        var links = 0
        while let component = pending.popLast() {
            if component == "." { continue }
            if component == ".." {
                if requireExistingParents {
                    // 未作成 a/.. の a が後続 entry でリンクになると意味が変わる。
                    var info = stat()
                    guard lstat("/" + resolved.joined(separator: "/"), &info) == 0,
                          info.st_mode & S_IFMT == S_IFDIR else { return nil }
                }
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            var info = stat()
            if lstat(candidate, &info) != 0 {
                guard errno == ENOENT else { return nil }
                resolved.append(component)
                continue
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                links += 1
                guard links <= 40 else { return nil }
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let count = bytes.withUnsafeMutableBytes { readlink(candidate, $0.baseAddress!, $0.count) }
                guard count > 0, count < bytes.count,
                      let target = String(bytes: bytes.prefix(count), encoding: .utf8) else { return nil }
                if target.hasPrefix("/") { resolved.removeAll() }
                pending.append(contentsOf: target.utf8.split(separator: 47)
                    .map { String(decoding: $0, as: UTF8.self) }.reversed())
            } else {
                guard pending.isEmpty || info.st_mode & S_IFMT == S_IFDIR else { return nil }
                resolved.append(component)
            }
        }
        return "/" + resolved.joined(separator: "/")
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }
}
