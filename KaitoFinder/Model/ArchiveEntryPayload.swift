import Foundation
import KaitoKit

/// index は同一世代内の位置だけを表す。仮想フォルダには index がない。
nonisolated struct ArchiveEntryPayload: Sendable, Hashable {
    let archiveURL: URL
    let generation: UInt64
    let entryIndex: Int?
    let path: String
    let isDirectory: Bool

    @MainActor init(node: EntryNode, archiveURL: URL, generation: UInt64) {
        self.init(archiveURL: archiveURL, generation: generation, entryIndex: node.entry?.index,
                  path: node.entry?.name ?? node.path, isDirectory: node.isDirectory)
    }

    init(archiveURL: URL, generation: UInt64, entryIndex: Int?, path: String, isDirectory: Bool) {
        self.archiveURL = archiveURL
        self.generation = generation
        self.entryIndex = entryIndex
        self.path = path
        self.isDirectory = isDirectory
    }

    func resolve(in entries: [ArchiveEntry], generation current: UInt64) throws -> [ArchiveEntry] {
        let components = try ExtractionPath.components(path)
        if isDirectory {
            let subtree = entries.filter {
                // 不正な子パスも選択に含め、展開層で失敗として報告する。黙って除外しない。
                let parts = (try? ExtractionPath.components($0.name)) ??
                    Array($0.pathComponents.drop(while: { $0 == "." }))
                return parts.starts(with: components) && (parts.count > components.count || $0.kind == .directory)
            }
            guard !subtree.isEmpty else { throw ExtractionFailure.refused("選択したフォルダが見つかりません: \(path)") }
            return subtree
        }
        if generation == current, let index = entryIndex,
           entries.indices.contains(index), entries[index].name == path, entries[index].kind != .directory {
            return [entries[index]]
        }
        let matches = entries.filter { $0.name == path && $0.kind != .directory }
        guard matches.count == 1 else {
            throw ExtractionFailure.refused("選択した項目が見つからないか、同名の項目があります: \(path)")
        }
        return matches
    }
}
