import Foundation
import GyoshukuKit
import KaitoKit

/// 表示用の名前とは別に、展開時に必要となる元のエントリを保持する。
// 構築中だけ変更し、公開後は全スレッドから読み取り専用で使う。
nonisolated final class EntryNode: NSObject, @unchecked Sendable {
    private(set) weak var parent: EntryNode?
    private(set) var archiveEntries: [ArchiveEntry] = []
    private(set) var directoryNodes: [EntryNode] = []
    private(set) var pendingNodes: [UUID: EntryNode] = [:]
    private(set) var nodeCount = 0
    private(set) var visibleNodeCount = 0
    private(set) var visibleSize: UInt64?
    private(set) var editOccupancy: ArchivePathOccupancy.Overlay?
    private(set) var treeOrder = 0
    private var entriesAreOrdered = true
    let name: String
    private(set) var path: String = ""
    let isDirectory: Bool
    private(set) var entry: ArchiveEntry?
    private(set) var children: [EntryNode] = []
    // 表示では併合する directory entry も、展開時の重複検査では失わない。
    private(set) var representedEntries: [ArchiveEntry]
    private var directories: [String: EntryNode] = [:]
    private(set) var size: UInt64?
    private(set) var compressedSize: UInt64?

    var isVirtual: Bool { isDirectory && entry == nil }
    private(set) var isHidden = false

    nonisolated static func isHiddenName(_ name: String) -> Bool {
        let leaf = ArchivePath.components(name).last ?? ""
        // AppleDouble (._*) もドットで始まる名前として含める。
        return leaf.utf8.first == 46 || leaf == "__MACOSX"
    }

    private init(name: String, isDirectory: Bool, entry: ArchiveEntry? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.entry = entry
        representedEntries = entry.map { [$0] } ?? []
        size = entry?.uncompressedSize
        compressedSize = entry?.compressedSize
    }

    @concurrent static func build(from entries: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat = .zip,
                                  indexingEdits: Bool = true) async -> EntryNode {
        tree(from: entries, format: format, indexingEdits: indexingEdits)
    }

    @concurrent static func buildRenameOccupancy(from entries: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat) async
        -> ArchivePathOccupancy.Overlay? {
        ArchiveReservationDiagnostics.record(.renameIndex)
        let result = renameOccupancy(from: entries, format: format, checksCancellation: true)
        ArchiveReservationDiagnostics.record(.renameIndexBuilt)
        return result
    }

    static func renameOccupancy(from entries: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat,
                                checksCancellation: Bool = false) -> ArchivePathOccupancy.Overlay? {
        var occupancy = ArchivePathOccupancy()
        for (offset, entry) in entries.enumerated() {
            if checksCancellation, offset % 256 == 0, Task.isCancelled { return nil }
            let directory = entry.kind == .directory
            guard let key = ArchiveNameIndex.cleanKey(entry, format: format) else { return nil }
            occupancy.insert(key, directory: directory)
        }
        return .init(occupancy)
    }

    static func tree(from entries: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat = .zip,
                     indexingEdits: Bool = false) -> EntryNode {
        #if DEBUG
        let span = ArchiveStageDiagnostics.begin(.treeBuild)
        defer { span?.end() }
        #endif
        ArchiveReservationDiagnostics.record(.tree)
        let root = EntryNode(name: "", isDirectory: true)
        root.archiveEntries = entries
        root.entriesAreOrdered = zip(entries, entries.dropFirst()).allSatisfy { $0.index < $1.index }
        var nodes = [root]
        for entry in entries {
            // tar の先頭の ./ だけを表示上取り除く。.. や途中の . は解決しない。
            let components = entry.pathComponents.drop(while: { $0 == "." })
            guard let leaf = components.last else {
                root.representedEntries.append(entry)
                continue
            }
            var parent = root
            for name in components.dropLast() {
                parent = parent.directory(named: name, nodes: &nodes)
            }
            if entry.kind == .directory {
                let directory = parent.directory(named: leaf, nodes: &nodes)
                directory.entry = entry
                directory.representedEntries.append(entry)
            } else {
                // 同名ファイルや、ファイルとフォルダの衝突も消さずに表示する。
                let node = EntryNode(name: leaf, isDirectory: false, entry: entry)
                node.parent = parent
                node.path = parent.path.isEmpty ? leaf : parent.path + "/" + leaf
                node.isHidden = parent.isHidden || Self.isHiddenComponent(leaf)
                parent.children.append(node)
                nodes.append(node)
            }
        }
        // 子から親へ集計し、ディレクトリ自体の記録サイズは加算しない。
        for node in nodes.reversed() where node.isDirectory {
            node.size = sum(node.children.lazy.map(\.size))
            node.compressedSize = sum(node.children.lazy.map(\.compressedSize))
        }
        root.editOccupancy = indexingEdits ? renameOccupancy(from: entries, format: format) : nil
        root.directoryNodes = nodes.filter { $0 !== root && $0.isDirectory }
        root.nodeCount = nodes.count - 1
        root.visibleNodeCount = nodes.reduce(0) { $0 + ($1 !== root && !$1.isHidden ? 1 : 0) }
        root.visibleSize = sum(nodes.lazy.filter { !$0.isDirectory && !$0.isHidden }.map(\.size))
        var order = 0, pending = [root]
        while let node = pending.popLast() {
            node.treeOrder = order
            order += 1
            if let id = node.entry?.pendingID { root.pendingNodes[id] = node }
            pending.append(contentsOf: node.children.reversed())
        }
        return root
    }

    func nodes(at path: String) -> [EntryNode] {
        let parts = ArchivePath.components(path)
        guard let leaf = parts.last else { return [self] }
        var parent = self
        for part in parts.dropLast() {
            guard let child = parent.directories[part] else { return [] }
            parent = child
        }
        return parent.children.filter { $0.name == leaf }
    }

    func node(forEntryIndex index: Int) -> EntryNode? {
        var low = 0, high = archiveEntries.count
        while low < high {
            let middle = (low + high) / 2
            if archiveEntries[middle].index < index { low = middle + 1 } else { high = middle }
        }
        let entry: ArchiveEntry
        if entriesAreOrdered {
            guard low < archiveEntries.count, archiveEntries[low].index == index else { return nil }
            entry = archiveEntries[low]
        } else {
            guard let found = archiveEntries.first(where: { $0.index == index }) else { return nil }
            entry = found
        }
        let path = entry.pathComponents.drop(while: { $0 == "." }).joined(separator: "/")
        return nodes(at: path).first { $0.entry?.index == index }
    }

    private func directory(named name: String, nodes: inout [EntryNode]) -> EntryNode {
        if let existing = directories[name] { return existing }
        let node = EntryNode(name: name, isDirectory: true)
        node.parent = self
        node.path = path.isEmpty ? name : path + "/" + name
        node.isHidden = isHidden || Self.isHiddenComponent(name)
        directories[name] = node
        children.append(node)
        nodes.append(node)
        return node
    }

    private static func isHiddenComponent(_ name: String) -> Bool { name.utf8.first == 46 || name == "__MACOSX" }

    private static func sum<Values: Sequence>(_ values: Values) -> UInt64? where Values.Element == UInt64? {
        var total: UInt64 = 0
        for value in values {
            guard let value else { return nil }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }
}

/// 表示する子だけを選ぶ。元の node と children は削除・改名・取り出しで共有する。
nonisolated struct EntryTreeFilter: Sendable {
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
        #if DEBUG
        if Thread.isMainThread { ArchiveTestCounters.mainThreadFilters.get()?.increment() }
        #endif
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
