import AppKit
import KaitoKit

/// Finder の関連付けを増やさず、アプリ内では分割巻を文書として開く。
final class ArchiveDocumentController: NSDocumentController {
    var volumeRecoveryIndex = RecoverableWorkIndex.shared
    var volumeMetadataStore = ArchiveVolumeMetadataStore.shared
    var volumeRecoveryError: (ArchiveVolumeOpenRecovery) -> NSError = { ArchiveVolumeOpenError(recovery: $0).presentedError }
    nonisolated static let splitVolumeType = "com.shunnag.KaitoFinder.split-volume"

    override func typeForContents(of url: URL) throws -> String {
        let type = try super.typeForContents(of: url)
        if documentClass(forType: type) == nil, ArchiveSplitVolume.isOpenableName(url.lastPathComponent) {
            return Self.splitVolumeType
        }
        return type
    }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        // Lookup must precede discovery, even while this document's publisher has hidden the gate.
        let gate = ArchiveSplitVolume.gateURL(for: url)
        let canonicalParent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let parsed = ArchiveVolumeSet.parse(fileName: url.lastPathComponent)
        if let existing = document(for: gate) ?? documents.first(where: { document in
            guard let source = document.fileURL,
                  source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == canonicalParent,
                  let parsed, case .numbered(let stem, _) = parsed.scheme,
                  let sourcePart = ArchiveVolumeSet.parse(fileName: source.lastPathComponent),
                  case .numbered(let sourceStem, _) = sourcePart.scheme else { return false }
            return stem == sourceStem && parsed.scheme == sourcePart.scheme
        }) {
            if displayDocument {
                if existing.windowControllers.isEmpty { existing.makeWindowControllers() }
                existing.showWindows()
            }
            if let url = existing.fileURL { noteNewRecentDocumentURL(url) }
            completionHandler(existing, true, nil)
            return
        }
        do {
            if let recovery = try ArchiveVolumeOpenRecovery.discover(url, index: volumeRecoveryIndex, metadataStore: volumeMetadataStore) {
                completionHandler(nil, false, volumeRecoveryError(recovery))
                return
            }
        } catch { completionHandler(nil, false, error); return }
        // 重複文書の照合と最近使った項目への登録より先に入口へ揃える。
        super.openDocument(withContentsOf: ArchiveSplitVolume.gateURL(for: url), display: displayDocument,
                           completionHandler: completionHandler)
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        ArchiveOpenPanelDelegate.install(on: openPanel)
        super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
    }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        ArchiveOpenPanelDelegate.install(on: openPanel)
        return super.runModalOpenPanel(openPanel, forTypes: nil)
    }
}
