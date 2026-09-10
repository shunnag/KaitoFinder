import Darwin
import Foundation
import KaitoKit

nonisolated struct ArchiveImportPlan: Sendable {
    struct Item: Sendable {
        let url: URL
        let path: String
        let isDirectory: Bool
    }
    struct Failure: Sendable {
        let name: String
        let reason: String
    }
    var items: [Item] = []
    var failures: [Failure] = []

    static func path(_ raw: String) throws -> String {
        let parts = raw.utf8.split(separator: 47, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\\") || $0.contains("\0") }),
              !(parts.first?.contains(":") ?? false) else {
            throw ExtractionFailure.refused("安全でない追加先パスです: \(raw)")
        }
        return raw.precomposedStringWithCanonicalMapping
    }

    static func build(urls: [URL], folder: String, existing: [ArchiveEntry], progress: Progress) throws -> Self {
        let target = folder.isEmpty ? "" : try path(folder)
        var occupied = Set<String>(), files = Set<String>()
        for entry in existing {
            let raw = entry.pathComponents.drop(while: { $0 == "." }).joined(separator: "/")
            guard let key = try? path(raw) else { continue }
            occupied.insert(key)
            if entry.kind != .directory { files.insert(key) }
            var parts = key.split(separator: "/")
            while parts.count > 1 { parts.removeLast(); occupied.insert(parts.joined(separator: "/")) }
        }
        if !target.isEmpty {
            let parts = target.split(separator: "/")
            let ancestors = (1...parts.count).map { parts.prefix($0).joined(separator: "/") }
            guard occupied.contains(target), !ancestors.contains(where: files.contains) else {
                throw ExtractionFailure.refused("追加先フォルダが見つからないか、ファイルと衝突しています: \(target)")
            }
        }
        var plan = Self()
        for url in urls {
            try checkCancellation(progress)
            do {
                guard url.isFileURL else { throw ExtractionFailure.refused("追加元は file URL が必要です") }
                let leaf = try path(url.lastPathComponent)
                let rootPath = target.isEmpty ? leaf : target + "/" + leaf
                // 仮想フォルダとの衝突も拒否する。フォルダの暗黙の併合は行わない。
                guard !occupied.contains(rootPath) else {
                    throw ExtractionFailure.refused("同じ名前の項目が既にあります: \(rootPath)")
                }
                var pending = [(url, rootPath)], batch: [Item] = [], names = Set<String>()
                while let (source, name) = pending.popLast() {
                    try checkCancellation(progress)
                    let key = try path(name)
                    guard names.insert(key).inserted, !occupied.contains(key) else {
                        throw ExtractionFailure.refused("同じ名前の項目が既にあります: \(key)")
                    }
                    var info = stat()
                    guard lstat(source.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
                    let kind = info.st_mode & S_IFMT
                    guard kind == S_IFREG || kind == S_IFDIR || kind == S_IFLNK else {
                        throw ExtractionFailure.refused("この種類のファイルは追加できません: \(source.lastPathComponent)")
                    }
                    batch.append(Item(url: source, path: key, isDirectory: kind == S_IFDIR))
                    // リンクを再帰しない。writer が lstat でリンク自体を保存する。
                    if kind == S_IFDIR {
                        let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                            .sorted { $0.lastPathComponent < $1.lastPathComponent }
                        pending.append(contentsOf: children.reversed().map { ($0, key + "/" + $0.lastPathComponent) })
                    }
                }
                occupied.formUnion(names)
                plan.items.append(contentsOf: batch)
            } catch is CancellationError { throw CancellationError() }
            catch { plan.failures.append(Failure(name: url.lastPathComponent, reason: String(describing: error))) }
        }
        // 衝突などの事前検査は全項目を報告するが、一つでも失敗なら原本を一切変えない。
        return plan
    }

    static func checkCancellation(_ progress: Progress) throws {
        if progress.isCancelled || Task.isCancelled { throw CancellationError() }
    }
}
