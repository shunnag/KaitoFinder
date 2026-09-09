import Foundation
import QuickLookUI

/// URL の照会には副作用を持たせない。先読みの照会でも抽出は始まらない。
final class ArchivePreviewItem: NSObject, QLPreviewItem {
    let payload: ArchiveEntryPayload
    let capability: EntryReadCapability
    let requiresProgress: Bool
    private(set) var previewItemURL: URL?
    var previewItemTitle: String? { payload.path }

    init(payload: ArchiveEntryPayload, capability: EntryReadCapability, requiresProgress: Bool) {
        self.payload = payload
        self.capability = capability
        self.requiresProgress = requiresProgress
    }

    func publish(_ url: URL) { previewItemURL = url }
}
