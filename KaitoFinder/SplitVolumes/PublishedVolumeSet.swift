import Foundation

nonisolated enum VolumeDisposal: Sendable, Equatable {
    case trashed(URL)
    case removed
    case kept(URL)
    case none
}

nonisolated struct PublishedVolumeSet: Sendable {
    let gateURL: URL
    let layout: ArchiveVolumeLayout
    let identity: ArchiveSetIdentity
    let oldVolumesDisposal: VolumeDisposal
    let usedExclusiveRenameFallback: Bool
    var outcome: VolumePublishOutcome = .committed(cleanupFailed: nil)
    var metadataWarning: String? = nil
    var warning: String? {
        if let metadataWarning { return metadataWarning }
        if case .committed(let warning) = outcome, warning != nil {
            return String(localized: "変更は保存されましたが、作業フォルダの後片付けが残っています。")
        }
        return nil
    }
}

nonisolated enum VolumePublishOutcome: Sendable, Equatable {
    case committed(cleanupFailed: String?)
}
