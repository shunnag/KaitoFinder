import AppKit

/// Finder の関連付けを増やさず、アプリ内では分割巻を文書として開く。
final class ArchiveDocumentController: NSDocumentController {
    var volumeRecoveryIndex = RecoverableWorkIndex.shared
    var volumeMetadataStore = ArchiveVolumeMetadataStore.shared
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
        do {
            if let recovery = try ArchiveVolumeOpenRecovery.discover(url, index: volumeRecoveryIndex, metadataStore: volumeMetadataStore) {
                completionHandler(nil, false, ArchiveVolumeOpenError(recovery: recovery))
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
