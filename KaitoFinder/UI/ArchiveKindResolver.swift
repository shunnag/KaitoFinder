import AppKit
import UniformTypeIdentifiers

final class ArchiveKindResolver {
    struct Kind {
        let type: UTType
        let description: String
        let isImage: Bool

        init(type: UTType, description: String) {
            self.type = type
            self.description = description
            isImage = type.conforms(to: .image)
        }
    }

    private struct Key: Hashable {
        let extensionName: String
        let isExecutable: Bool
        let isDirectory: Bool
        let isSymbolicLink: Bool
        let isHardLink: Bool
    }

    private let bundle: Bundle
    private var kinds: [Key: Kind] = [:]
    private var nodeKinds: [EntryNode: Kind] = [:]
    private var icons: [UTType: NSImage] = [:]
    #if DEBUG
    private(set) var resolutionCount = 0
    #endif

    init(bundle: Bundle = .main) { self.bundle = bundle }

    // 木を差し替えたら、表示済みノードの参照を解放する。
    func resetNodes() { nodeKinds.removeAll(keepingCapacity: true) }

    func kind(for node: EntryNode) -> Kind {
        if let kind = nodeKinds[node] { return kind }
        let key = Key(extensionName: (node.name as NSString).pathExtension.lowercased(),
                      isExecutable: node.entry?.kind == .file && (node.entry?.posixPermissions ?? 0) & 0o111 != 0,
                      isDirectory: node.isDirectory, isSymbolicLink: node.entry?.kind == .symlink,
                      isHardLink: node.entry?.kind == .hardlink)
        let kind: Kind
        if let cached = kinds[key] { kind = cached }
        else {
            kind = resolve(key)
            kinds[key] = kind
        }
        nodeKinds[node] = kind
        return kind
    }

    func icon(for node: EntryNode) -> NSImage {
        let type = kind(for: node).type
        if let icon = icons[type] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        icons[type] = icon
        return icon
    }

    private func resolve(_ key: Key) -> Kind {
        #if DEBUG
        resolutionCount += 1
        #endif
        let document = String(localized: "書類", bundle: bundle)
        if key.isSymbolicLink {
            return Kind(type: .symbolicLink, description: UTType.symbolicLink.localizedDescription ?? document)
        }
        // 既定の .data では .app や .rtfd を解決できない。動的な仮の package 型は使わない。
        let type = key.extensionName.isEmpty ? nil : UTType(filenameExtension: key.extensionName,
            conformingTo: key.isDirectory ? .package : .data)
        if key.isDirectory {
            if let type, !type.isDynamic, type.conforms(to: .package) {
                return Kind(type: type, description: type.localizedDescription ?? document)
            }
            return Kind(type: .folder, description: String(localized: "フォルダ", bundle: bundle))
        }
        if key.isHardLink {
            return Kind(type: type ?? .data, description: String(localized: "ハードリンク", bundle: bundle))
        }
        if key.extensionName.isEmpty {
            if key.isExecutable {
                return Kind(type: .unixExecutable, description: UTType.unixExecutable.localizedDescription ?? document)
            }
            return Kind(type: .data, description: document)
        }
        return Kind(type: type ?? .data, description: (type ?? .data).localizedDescription ?? document)
    }
}
