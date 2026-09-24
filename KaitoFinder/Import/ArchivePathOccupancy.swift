import Foundation

/// 比較用のパスを数える。元レコードの同名・正準等価も、片方の削除で空きにしない。
/// 成分ごとの木にし、深いパスでもすべての接頭辞文字列を複製しない。
nonisolated struct ArchivePathOccupancy: Sendable {
    private struct Node: Sendable {
        var children: [String: Int] = [:]
        var entries = 0
        var files = 0
        var total = 0
    }
    private var nodes = [Node()]
    private var unused: [Int] = []

    mutating func insert(_ path: String, directory: Bool) {
        adjust(path, directory: directory, by: 1)
    }

    private mutating func adjust(_ path: String, directory: Bool, by amount: Int) {
        var branch = [0]
        for part in ArchivePath.components(path, omittingEmptySubsequences: false) {
            let parent = branch.last!, component = String(part)
            let child: Int
            if let existing = nodes[parent].children[component] { child = existing }
            else {
                if let available = unused.popLast() { child = available }
                else { child = nodes.count; nodes.append(Node()) }
                nodes[parent].children[component] = child
            }
            branch.append(child)
        }
        for node in branch { nodes[node].total += amount }
        nodes[branch.last!].entries += amount
        if !directory { nodes[branch.last!].files += amount }
    }

    mutating func remove(_ path: String, directory: Bool) {
        let parts = ArchivePath.components(path, omittingEmptySubsequences: false)
        var branch = [0]
        for part in parts {
            guard let child = nodes[branch.last!].children[String(part)] else {
                assertionFailure("未登録のパスを解除しました")
                return
            }
            branch.append(child)
        }
        let leaf = branch.last!
        assert(nodes[leaf].entries > 0)
        nodes[leaf].entries -= 1
        if !directory { nodes[leaf].files -= 1 }
        for node in branch { nodes[node].total -= 1 }
        // 改名を繰り返しても、使わなくなった枝は次の予約で再利用できる。
        for depth in stride(from: parts.count, through: 1, by: -1) {
            let child = branch[depth]
            guard nodes[child].total == 0 else { break }
            nodes[branch[depth - 1]].children.removeValue(forKey: String(parts[depth - 1]))
            nodes[child] = Node()
            unused.append(child)
        }
    }

    func containsSubtree(at path: String) -> Bool {
        var node = 0
        for part in ArchivePath.components(path, omittingEmptySubsequences: false) {
            guard let child = nodes[node].children[String(part)] else { return false }
            node = child
        }
        return nodes[node].total > 0
    }

    func collides(_ path: String, directory: Bool) -> Bool {
        var node = 0
        // 空成分も残し、/ と結合文字を別々に扱う。
        for part in ArchivePath.components(path, omittingEmptySubsequences: false) {
            if nodes[node].files > 0 { return true }
            guard let child = nodes[node].children[String(part)] else { return false }
            node = child
        }
        return nodes[node].entries > 0 || (!directory && nodes[node].total > nodes[node].entries)
    }

    // 基底の配列を COW で複製せず、触れた枝の差分だけを数える。
    struct Overlay: Sendable {
        let base: ArchivePathOccupancy
        private var delta = ArchivePathOccupancy()

        init(_ base: ArchivePathOccupancy) { self.base = base }
        mutating func insert(_ path: String, directory: Bool) { delta.adjust(path, directory: directory, by: 1) }
        mutating func remove(_ path: String, directory: Bool) { delta.adjust(path, directory: directory, by: -1) }

        private func counts(_ path: String) -> (entries: Int, files: Int, total: Int, ancestorFile: Bool) {
            var original: Int? = 0, changed: Int? = 0, ancestorFile = false
            for part in ArchivePath.components(path, omittingEmptySubsequences: false) {
                if (original.map { base.nodes[$0].files } ?? 0) + (changed.map { delta.nodes[$0].files } ?? 0) > 0 {
                    ancestorFile = true
                }
                original = original.flatMap { base.nodes[$0].children[part] }
                changed = changed.flatMap { delta.nodes[$0].children[part] }
            }
            let a = original.map { base.nodes[$0] } ?? Node(), b = changed.map { delta.nodes[$0] } ?? Node()
            return (a.entries + b.entries, a.files + b.files, a.total + b.total, ancestorFile)
        }

        func containsSubtree(at path: String) -> Bool { counts(path).total > 0 }
        func selectionCount(at path: String) -> Int { let count = counts(path); return count.total - count.files }
        func isFolder(_ path: String) -> Bool {
            let count = counts(path)
            return count.total > 0 && count.files == 0 && !count.ancestorFile
        }
        func firstFileAncestor(_ path: String) -> String? {
            let parts = ArchivePath.components(path)
            for depth in 1...max(1, parts.count) {
                let ancestor = parts.prefix(depth).joined(separator: "/")
                if counts(ancestor).files > 0 { return ancestor }
            }
            return nil
        }
        func collides(_ path: String, directory: Bool) -> Bool {
            let count = counts(path)
            return count.ancestorFile || count.entries > 0 || (!directory && count.total > count.entries)
        }
    }
}
