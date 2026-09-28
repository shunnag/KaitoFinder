import Foundation
import QuickLookUI
import Synchronization

/// URL の照会には副作用を持たせない。先読みの照会でも抽出は始まらない。
// 実測: アプリが前面にあると QuickLookUI は NSOperationQueue から項目を読む。
// MainActor 隔離の @objc getter はそこでクラッシュするため、非隔離とロックで保護する。
nonisolated final class ArchivePreviewItem: NSObject, QLPreviewItem, Sendable {
    let payload: ArchiveEntryPayload
    let capability: EntryReadCapability
    let requiresProgress: Bool
    private let urlStorage = Mutex<URL?>(nil)
    var previewItemURL: URL? { urlStorage.withLock { $0 } }
    var previewItemTitle: String? { payload.path }

    init(payload: ArchiveEntryPayload, capability: EntryReadCapability, requiresProgress: Bool) {
        self.payload = payload
        self.capability = capability
        self.requiresProgress = requiresProgress
    }

    func publish(_ url: URL) { urlStorage.withLock { $0 = url } }
}
