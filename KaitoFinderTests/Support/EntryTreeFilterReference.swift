import Foundation
@testable import KaitoFinder

// S33 の走査と Foundation の照合を同値性の基準として固定する。
nonisolated struct EntryTreeFilterReference: Sendable {
    struct Configuration: Sendable, Hashable {
        let query: String
        let showsHiddenFiles: Bool
    }
    private var visible: Set<ObjectIdentifier> = []
    private let unfiltered: Bool
    private let showsHiddenFiles: Bool
    private(set) var totalCount = 0
    private(set) var totalSize: UInt64?
    private(set) var matchingCount = 0

    init(root: EntryNode, query: String, showsHiddenFiles: Bool = false) {
        unfiltered = query.isEmpty
        self.showsHiddenFiles = showsHiddenFiles
        totalSize = showsHiddenFiles ? root.size : root.visibleSize
        if unfiltered {
            totalCount = showsHiddenFiles ? root.nodeCount : root.visibleNodeCount
            matchingCount = totalCount
            return
        }
        var pending = [(root, false)]
        var visited: [EntryNode] = []
        while let (node, matchedAncestor) = pending.popLast() {
            guard showsHiddenFiles || !node.isHidden else { continue }
            // 日本語の書庫では半角カナや全角数字が混在するため、文字幅も明示的に同一視する。
            let matches = query.isEmpty || matchedAncestor || node.name.range(of: query,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
            if matches { visible.insert(ObjectIdentifier(node)) }
            visited.append(node)
            pending.append(contentsOf: node.children.map { ($0, matches && node.isDirectory) })
        }
        // 子から祖先へ辿り、名前に一致しない親も開けるように残す。
        for node in visited.reversed() where node.children.contains(where: contains) {
            visible.insert(ObjectIdentifier(node))
        }
        // 選択変更のたびに全項目を数え直さない。root 自身は表示上の件数に含めない。
        totalCount = visited.count - 1
        matchingCount = visible.count - (contains(root) ? 1 : 0)
    }

    func contains(_ node: EntryNode) -> Bool {
        unfiltered ? (showsHiddenFiles || !node.isHidden) : visible.contains(ObjectIdentifier(node))
    }

    func children(of node: EntryNode) -> [EntryNode] {
        // 部分木を複製して縮めると、編集時に隠れた子孫が脱落する。完全な node の参照を返す。
        node.children.filter(contains)
    }
}
