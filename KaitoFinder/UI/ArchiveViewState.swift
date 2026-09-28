import Foundation

nonisolated struct ArchiveViewState: Sendable {
    var selectedPaths: Set<String> {
        // 編集後など、パスで選び直す状態には以前のレコード番号を引き継がない。
        didSet { selectedEntryIndices = nil; selectedPendingIDs = nil }
    }
    var expandedPaths: Set<String>
    var topPath: String?
    var selectedEntryIndices: Set<Int>? = nil
    var selectedPendingIDs: Set<UUID>? = nil
    var generation: UInt64? = nil
    var scrollX: CGFloat = 0
    var collapsedPaths: Set<String> = []

    @MainActor func resolve(in root: EntryNode, currentGeneration: UInt64? = nil)
        -> (selected: [EntryNode], expanded: [EntryNode], collapsed: [EntryNode], top: EntryNode?) {
        let indices = currentGeneration != nil && generation == currentGeneration ? selectedEntryIndices : nil
        let pendingIDs = currentGeneration != nil && generation == currentGeneration ? selectedPendingIDs : nil
        var candidates = selectedPaths.flatMap { root.nodes(at: $0) }
        if let indices { candidates += indices.compactMap { root.node(forEntryIndex: $0) } }
        if let pendingIDs { candidates += pendingIDs.compactMap { root.pendingNodes[$0] } }
        var seen: Set<ObjectIdentifier> = []
        let selected = candidates.filter { node in
            guard seen.insert(ObjectIdentifier(node)).inserted else { return false }
            if let id = node.entry?.pendingID, let pendingIDs { return pendingIDs.contains(id) }
            if let entry = node.entry, entry.pendingID == nil, let indices { return indices.contains(entry.index) }
            return selectedPaths.contains(node.path)
        }.sorted { $0.treeOrder < $1.treeOrder }
        let expanded = expandedPaths.flatMap { root.nodes(at: $0).filter(\.isDirectory) }.sorted { $0.treeOrder < $1.treeOrder }
        let collapsed = collapsedPaths.flatMap { root.nodes(at: $0).filter(\.isDirectory) }.sorted { $0.treeOrder < $1.treeOrder }
        let top = topPath.flatMap { root.nodes(at: $0).last }
        return (selected, expanded, collapsed, top)
    }
}
