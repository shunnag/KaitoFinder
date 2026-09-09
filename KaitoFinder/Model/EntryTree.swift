import Foundation
import KaitoKit

/// 表示用の名前とは別に、展開時に必要となる元のエントリを保持する。
final class EntryNode: NSObject {
    let name: String
    let isDirectory: Bool
    private(set) var entry: ArchiveEntry?
    private(set) var children: [EntryNode] = []
    // 表示では併合する directory entry も、展開時の重複検査では失わない。
    private(set) var representedEntries: [ArchiveEntry]
    private var directories: [String: EntryNode] = [:]
    private(set) var size: UInt64?
    private(set) var compressedSize: UInt64?

    var isVirtual: Bool { isDirectory && entry == nil }

    private init(name: String, isDirectory: Bool, entry: ArchiveEntry? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.entry = entry
        representedEntries = entry.map { [$0] } ?? []
        size = entry?.uncompressedSize
        compressedSize = entry?.compressedSize
    }

    static func tree(from entries: [ArchiveEntry]) -> EntryNode {
        let root = EntryNode(name: "", isDirectory: true)
        var nodes = [root]
        for entry in entries {
            // tar の先頭の ./ だけを表示上取り除く。.. や途中の . は解決しない。
            let components = Array(entry.pathComponents.drop(while: { $0 == "." }))
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
                parent.children.append(node)
                nodes.append(node)
            }
        }
        // 子から親へ集計し、ディレクトリ自体の記録サイズは加算しない。
        for node in nodes.reversed() where node.isDirectory {
            node.size = sum(node.children.map(\.size))
            node.compressedSize = sum(node.children.map(\.compressedSize))
        }
        return root
    }

    private func directory(named name: String, nodes: inout [EntryNode]) -> EntryNode {
        if let existing = directories[name] { return existing }
        let node = EntryNode(name: name, isDirectory: true)
        directories[name] = node
        children.append(node)
        nodes.append(node)
        return node
    }

    private static func sum(_ values: [UInt64?]) -> UInt64? {
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
