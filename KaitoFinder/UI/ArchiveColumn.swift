import AppKit

enum ArchiveColumn: String, CaseIterable {
    case name, size, compressedSize, date, kind, method, encrypted
    case ratio, crc32, permissions, archiveOrder

    var hiddenByDefault: Bool { [.ratio, .crc32, .permissions, .archiveOrder].contains(self) }
    var isNumeric: Bool { [.size, .compressedSize, .ratio, .crc32, .archiveOrder].contains(self) }
    var usesMonospacedDigits: Bool { [.crc32, .permissions, .archiveOrder].contains(self) }

    var width: CGFloat {
        switch self {
        case .name: 300
        case .size, .compressedSize: 110
        case .date: 180
        case .kind: 140
        case .method: 100
        case .encrypted: 80
        case .ratio: 100
        case .crc32: 110
        case .permissions: 130
        case .archiveOrder: 110
        }
    }

    func title(bundle: Bundle) -> String {
        switch self {
        case .name: String(localized: "名前", bundle: bundle)
        case .size: String(localized: "サイズ", bundle: bundle)
        case .compressedSize: String(localized: "圧縮サイズ", bundle: bundle)
        case .date: String(localized: "変更日", bundle: bundle)
        case .kind: String(localized: "種類", bundle: bundle)
        case .method: String(localized: "圧縮方式", bundle: bundle)
        case .encrypted: String(localized: "暗号化", bundle: bundle)
        case .ratio: String(localized: "圧縮率", bundle: bundle)
        case .crc32: String(localized: "CRC-32", bundle: bundle)
        case .permissions: String(localized: "アクセス権", bundle: bundle)
        case .archiveOrder: String(localized: "格納順", bundle: bundle)
        }
    }

    static func populate(_ menu: NSMenu, bundle: Bundle, table: NSOutlineView?, target: AnyObject, action: Selector) {
        menu.removeAllItems()
        let columns = table?.tableColumns.compactMap { Self(rawValue: $0.identifier.rawValue) } ?? allCases
        for column in columns where column != .name {
            let item = menu.addItem(withTitle: column.title(bundle: bundle), action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = column.rawValue
            let visible = table?.tableColumn(withIdentifier: .init(column.rawValue)).map { !$0.isHidden } ?? false
            item.state = visible ? .on : .off
            item.isEnabled = table != nil
        }
    }
}

enum ArchiveEntryDisplay {
    static func ratio(_ node: EntryNode) -> Double? {
        guard let size = node.size, let compressed = node.compressedSize else { return nil }
        // 空ファイルには削減できるバイトがない。圧縮ヘッダによる負の率は保持する。
        return size == 0 ? 0 : 1 - Double(compressed) / Double(size)
    }

    static func archiveOrder(_ node: EntryNode) -> Int? {
        guard let index = node.entry?.index, index >= 0, index < Int.max else { return nil }
        return index + 1
    }

    static func permissions(_ node: EntryNode) -> String {
        guard let mode = node.entry?.posixPermissions else { return "—" }
        var text: String
        switch node.entry?.kind {
        case .directory: text = "d"
        case .symlink: text = "l"
        case .file, .hardlink: text = "-"
        default: text = "?"
        }
        for (shift, special, lower, upper): (UInt16, UInt16, String, String) in
            [(6, 0o4000, "s", "S"), (3, 0o2000, "s", "S"), (0, 0o1000, "t", "T")] {
            text += mode & (4 << shift) != 0 ? "r" : "-"
            text += mode & (2 << shift) != 0 ? "w" : "-"
            let executable = mode & (1 << shift) != 0
            text += mode & special != 0 ? (executable ? lower : upper) : (executable ? "x" : "-")
        }
        return text
    }
}
