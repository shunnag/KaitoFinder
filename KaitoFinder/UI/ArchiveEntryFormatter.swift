import AppKit

/// 一覧の各列に表示する文字列を作る。書式オブジェクトは一覧の生存期間で共有する。
final class ArchiveEntryFormatter {
    private let bundle: Bundle
    private let kindResolver: ArchiveKindResolver
    private let ratioFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(bundle: Bundle, kindResolver: ArchiveKindResolver) {
        self.bundle = bundle
        self.kindResolver = kindResolver
    }

    func text(for node: EntryNode, column: ArchiveColumn) -> String {
        switch column {
        case .name: node.name
        case .size: formattedSize(node.size)
        case .compressedSize: formattedSize(node.compressedSize)
        case .date: node.entry?.modificationDate.map { dateFormatter.string(from: $0) } ?? "—"
        case .kind: kindResolver.kind(for: node).description
        case .ratio: ArchiveEntryDisplay.ratio(node).flatMap { ratioFormatter.string(from: NSNumber(value: $0)) } ?? "—"
        case .crc32: node.entry?.crc32.map { String(format: "%08X", $0) } ?? "—"
        case .permissions: ArchiveEntryDisplay.permissions(node)
        case .archiveOrder: ArchiveEntryDisplay.archiveOrder(node).map(String.init) ?? "—"
        case .method: node.entry?.methodDescription ?? "—"
        case .encrypted:
            if let entry = node.entry {
                entry.isEncrypted ? String(localized: "はい", bundle: bundle) : String(localized: "いいえ", bundle: bundle)
            } else { "—" }
        }
    }

    private func formattedSize(_ size: UInt64?) -> String {
        guard let size, let signed = Int64(exactly: size) else { return "—" }
        return byteFormatter.string(fromByteCount: signed)
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
