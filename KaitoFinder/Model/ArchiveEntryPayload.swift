import Foundation
import KaitoKit

/// index は同一世代内の位置だけを表す。仮想フォルダには index がない。
nonisolated struct ArchiveEntryPayload: Sendable, Hashable {
    enum Origin: Sendable, Hashable {
        case base(index: Int, expectedName: String, baseGeneration: UInt64)
        case pending(UUID)
    }
    let archiveURL: URL
    let generation: UInt64
    let revision: UInt64?
    let origin: Origin?
    let entryIndex: Int?
    let path: String
    let isDirectory: Bool

    @MainActor init(node: EntryNode, archiveURL: URL, generation: UInt64) {
        self.init(archiveURL: archiveURL, generation: generation, entryIndex: node.entry?.index,
                  path: node.entry?.name ?? node.path, isDirectory: node.isDirectory)
    }

    // 画面の「すべて展開」と一括展開で、仮想フォルダを含む同じ選択を作る。
    @MainActor static func payloads(for nodes: [EntryNode], archiveURL: URL, generation: UInt64) -> [ArchiveEntryPayload] {
        nodes.map { ArchiveEntryPayload(node: $0, archiveURL: archiveURL, generation: generation) }
    }

    @MainActor init(node: EntryNode, session: ArchiveSession, generation: UInt64) {
        if session.usesPendingReading {
            let snapshot = session.pendingReadSnapshot
            let anchor = node.entry ?? ExtractionSelection(nodes: [node]).entries.first
            self.init(archiveURL: session.sourceURL, generation: generation, entryIndex: node.entry?.index,
                      path: node.entry?.name ?? node.path, isDirectory: node.isDirectory,
                      revision: snapshot?.revision, origin: anchor.flatMap { snapshot?.origin(for: $0) })
        } else { self.init(node: node, archiveURL: session.sourceURL, generation: generation) }
    }

    @MainActor static func payloads(for nodes: [EntryNode], session: ArchiveSession, generation: UInt64) -> [Self] {
        nodes.map { Self(node: $0, session: session, generation: generation) }
    }

    init(archiveURL: URL, generation: UInt64, entryIndex: Int?, path: String, isDirectory: Bool,
         revision: UInt64? = nil, origin: Origin? = nil) {
        self.archiveURL = archiveURL
        self.generation = generation
        self.revision = revision
        self.origin = origin
        self.entryIndex = entryIndex
        self.path = path
        self.isDirectory = isDirectory
    }

    func resolve(in entries: [ArchiveEntry], generation current: UInt64,
                 subtrees: SubtreeIndex? = nil) throws -> [ArchiveEntry] {
        // 保存前モードは専用の origin 照合を通す。名前で別の entry を探さない。
        guard revision == nil, origin == nil else { throw Self.staleSelection }
        let components = try ExtractionPath.components(path)
        if isDirectory {
            let subtree = (subtrees ?? SubtreeIndex(entries: entries)).subtree(for: components)
            guard !subtree.isEmpty else { throw ExtractionFailure.refused(String(localized: "選択したフォルダが見つかりません: \(path)。")) }
            return subtree
        }
        if generation == current, let index = entryIndex,
           entries.indices.contains(index), entries[index].name == path, entries[index].kind != .directory {
            return [entries[index]]
        }
        let matches = entries.filter { $0.name == path && $0.kind != .directory }
        guard matches.count == 1 else {
            throw ExtractionFailure.refused(String(localized: "選択した項目が見つからないか、同名の項目があります: \(path)。"))
        }
        return matches
    }

    static var staleSelection: ExtractionFailure {
        .refused(String(localized: "選択した項目が変更されています。アーカイブを開き直してください。"))
    }

    // 複数フォルダの解決でパスの分解と全件走査を繰り返さない。
    nonisolated struct SubtreeIndex: Sendable {
        private struct Node: Sendable {
            var children: [String: Int] = [:]
            var entryOffsets: [Int] = []
        }

        private let entries: [ArchiveEntry]
        private var nodes = [Node()]

        init(entries: [ArchiveEntry], components: ((ArchiveEntry) -> [String])? = nil) {
            self.entries = entries
            for (offset, entry) in entries.enumerated() {
                // 不正な子パスも選択に含め、展開層で失敗として報告する。黙って除外しない。
                let parts = components?(entry) ?? ((try? ExtractionPath.components(entry.name)) ??
                    Array(entry.pathComponents.drop(while: { $0 == "." })))
                var node = 0
                // 同じパスのファイルは、そのフォルダ自身として選択しない。
                for part in parts.dropLast(entry.kind == .directory ? 0 : 1) {
                    if let child = nodes[node].children[part] {
                        node = child
                    } else {
                        let child = nodes.count
                        nodes[node].children[part] = child
                        nodes.append(Node())
                        node = child
                    }
                    nodes[node].entryOffsets.append(offset)
                }
            }
        }

        func subtree(for components: [String]) -> [ArchiveEntry] {
            var node = 0
            for component in components {
                guard let child = nodes[node].children[component] else { return [] }
                node = child
            }
            return nodes[node].entryOffsets.map { entries[$0] }
        }
    }
}
