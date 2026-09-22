import AppKit
import UniformTypeIdentifiers

/// 動的な UTI になる分割巻も、通常のアーカイブと同じパネルで選べるようにする。
final class ArchiveOpenPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    private static var retentionKey: UInt8 = 0
    private let archiveTypes: [UTType]

    init(archiveTypes: [UTType]) {
        self.archiveTypes = archiveTypes
        super.init()
    }

    static func install(on panel: NSOpenPanel, bundle: Bundle = .main) {
        let delegate = ArchiveOpenPanelDelegate(archiveTypes: ArchiveBatchExtractionController.archiveContentTypes(bundle: bundle))
        panel.allowedContentTypes = []
        panel.delegate = delegate
        // panel.delegate は weak。静的 factory で作る一括展開パネルにも寿命を合わせる。
        objc_setAssociatedObject(panel, &retentionKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func acceptsArchive(_ url: URL, archiveTypes: [UTType]) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == false else { return false }
        if ArchiveSplitVolume.isOpenableName(url.lastPathComponent) { return true }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return archiveTypes.contains { type.conforms(to: $0) }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return true }
        return Self.acceptsArchive(url, archiveTypes: archiveTypes)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard Self.acceptsArchive(url, archiveTypes: archiveTypes) else {
            // システムの標準エラーを使い、独自の表示文言は増やさない。
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path])
        }
    }
}
