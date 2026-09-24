import Foundation

enum ArchiveEntrySort {
    private enum Value {
        case unsigned(UInt64?), integer(Int?), decimal(Double?), text(String)

        func compare(to other: Value) -> ComparisonResult {
            switch (self, other) {
            case let (.unsigned(lhs), .unsigned(rhs)): compareOptional(lhs, rhs)
            case let (.integer(lhs), .integer(rhs)): compareOptional(lhs, rhs)
            case let (.decimal(lhs), .decimal(rhs)): compareOptional(lhs, rhs)
            case let (.text(lhs), .text(rhs)): lhs == rhs ? .orderedSame : lhs.localizedStandardCompare(rhs)
            default: .orderedSame
            }
        }
    }

    static func sorted(_ nodes: [EntryNode], descriptors: [NSSortDescriptor], foldersOnTop: Bool,
                       kindResolver: ArchiveKindResolver) -> [EntryNode] {
        guard nodes.count > 1 else { return nodes }
        let criteria = descriptors.map { (key: $0.key ?? "name", ascending: $0.ascending) }
        // ソートに使わない列は計算しない。比較中に AppKit や Launch Services へ問い合わせない。
        let decorated = nodes.map { node in
            (node: node, name: node.name, directory: node.isDirectory,
             values: criteria.map { value(for: node, key: $0.key, kindResolver: kindResolver) })
        }
        return decorated.sorted { lhs, rhs in
            if foldersOnTop, lhs.directory != rhs.directory { return lhs.directory }
            for (index, criterion) in criteria.enumerated() {
                let result = lhs.values[index].compare(to: rhs.values[index])
                if result != .orderedSame {
                    return criterion.ascending ? result == .orderedAscending : result == .orderedDescending
                }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.map(\.node)
    }

    private static func value(for node: EntryNode, key: String, kindResolver: ArchiveKindResolver) -> Value {
        switch ArchiveColumn(rawValue: key) {
        case .name: .text(node.name)
        case .size: .unsigned(node.size)
        case .compressedSize: .unsigned(node.compressedSize)
        case .date: .decimal(node.entry?.modificationDate?.timeIntervalSinceReferenceDate)
        case .encrypted: .integer(node.entry.map { $0.isEncrypted ? 1 : 0 })
        case .kind: .text(kindResolver.kind(for: node).description)
        case .method: .text(node.entry?.methodDescription ?? "—")
        case .ratio: .decimal(ArchiveEntryDisplay.ratio(node))
        case .crc32: .unsigned(node.entry?.crc32.map(UInt64.init))
        case .permissions: .unsigned(node.entry?.posixPermissions.map { UInt64($0 & 0o7777) })
        case .archiveOrder: .integer(ArchiveEntryDisplay.archiveOrder(node))
        case nil: .text("")
        }
    }

    private static func compareOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedAscending
        case (_, nil): .orderedDescending
        case let (lhs?, rhs?): lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
    }
}
