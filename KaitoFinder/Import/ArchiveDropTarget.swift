import Foundation

/// 行の解釈と可否は AppKit のドラッグセッションなしで検証できる。
nonisolated enum ArchiveDropTarget {
    struct Row: Sendable {
        let path: String
        let isDirectory: Bool
        @MainActor init(_ node: EntryNode) { path = node.path; isDirectory = node.isDirectory }
        init(path: String, isDirectory: Bool) { self.path = path; self.isDirectory = isDirectory }
    }
    static func folder(for row: Row?) -> String {
        guard let row else { return "" }
        return row.isDirectory ? row.path : row.path.split(separator: "/").dropLast().joined(separator: "/")
    }
    @MainActor static func node(for row: EntryNode?, in root: EntryNode) -> EntryNode? {
        let path = folder(for: row.map(Row.init))
        guard !path.isEmpty else { return nil }
        var current = root
        for component in path.split(separator: "/") {
            guard let child = current.children.first(where: { $0.isDirectory && $0.name == component }) else { return nil }
            current = child
        }
        return current
    }
    static func accepts(capabilities: ArchiveCapabilities, offersCopy: Bool, hasFiles: Bool, busy: Bool) -> Bool {
        capabilities.canAppend && offersCopy && hasFiles && !busy
    }
}

nonisolated struct ArchiveViewState: Sendable {
    var selectedPaths: Set<String>
    var expandedPaths: Set<String>
    var topPath: String?

    @MainActor func resolve(in root: EntryNode) -> (selected: [EntryNode], expanded: [EntryNode], top: EntryNode?) {
        var pending = [root]
        var selected: [EntryNode] = [], expanded: [EntryNode] = []
        var top: EntryNode?
        while let node = pending.popLast() {
            if selectedPaths.contains(node.path) { selected.append(node) }
            if expandedPaths.contains(node.path), node.isDirectory { expanded.append(node) }
            if topPath == node.path { top = node }
            pending.append(contentsOf: node.children.reversed())
        }
        return (selected, expanded, top)
    }
}
