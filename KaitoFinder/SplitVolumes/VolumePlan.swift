import Foundation
import KaitoKit

nonisolated enum VolumePublishError: Error, Equatable {
    case invalidPlan
    case unsupportedScheme
    case tooManyVolumes(required: UInt64)
    case hazardousVolume(String)
    case insufficientSpace(required: UInt64, available: UInt64)
    case nameOccupied(String)
    case unresolvedPublication(URL)
    case setChanged
    case unsafePath(String)
    case system(Int32)
    case journalUnreadable
    case journalTooLarge
    case ownerAlive
    case coordinationTimedOut
    case validationFailed
    case rollbackIncomplete(URL)
    case alreadyUsed
    case fat32WorkFileTooLarge(length: UInt64)
    case contentMismatch(String)
    case publishedReaderFailed(staging: URL, diagnostic: String)
    case stagedReaderFailed(String)
    case publishedVerificationPending(staging: URL, diagnostic: String)
    case rolledBack(underlying: String, cleanupFailed: String?, disposal: VolumeDisposal)
}

/// 不揃いな予定表の選択は呼び出し側の仕事。推測して自動採用しない。
nonisolated struct VolumePlan: Sendable, Equatable {
    enum Schedule: Codable, Sendable, Equatable {
        case uniform(size: UInt64)
        case explicit([UInt64])
        case single
    }

    struct Volume: Sendable, Equatable {
        let name: String
        let length: UInt64
        let offset: UInt64
    }

    let scheme: ArchiveVolumeSet.Scheme
    let volumes: [Volume]
    let totalLength: UInt64
    var gateName: String { volumes[0].name }
    var nextVolumeName: String { scheme.fileName(forVolumeAt: volumes.count, count: volumes.count + 1) }
    var largestVolume: UInt64 { volumes.map(\.length).max() ?? 0 }

    init(totalLength: UInt64, schedule: Schedule, scheme: ArchiveVolumeSet.Scheme,
         layout: ArchiveVolumeLayout? = nil) throws {
        guard case .numbered(let stem, let width) = scheme else { throw VolumePublishError.unsupportedScheme }
        guard VolumePublishFS.isName(stem), width >= 3, width <= 255, stem.utf8.count + 1 + width <= 255, totalLength > 0,
              totalLength <= UInt64(Int64.max), layout == nil || layout?.scheme == scheme else {
            throw VolumePublishError.invalidPlan
        }
        let prefix: [UInt64], repeating: UInt64
        switch schedule {
        case .single: prefix = []; repeating = UInt64(Int64.max)
        case .uniform(let size): prefix = []; repeating = size
        case .explicit(let lengths):
            guard !lengths.isEmpty, lengths.allSatisfy({ $0 > 0 }) else { throw VolumePublishError.invalidPlan }
            prefix = Array(lengths.dropLast())
            repeating = max(lengths.last!, lengths.dropLast().last ?? lengths.last!)
        }
        guard repeating > 0 else { throw VolumePublishError.invalidPlan }
        var remaining = totalLength, count: UInt64 = 0
        for length in prefix where remaining > 0 {
            remaining -= min(remaining, length)
            count += 1
        }
        if remaining > 0 { count += (remaining - 1) / repeating + 1 }
        guard count <= UInt64(ReadLimits().maxVolumeCount) else {
            throw VolumePublishError.tooManyVolumes(required: count)
        }
        var result: [Volume] = [], offset: UInt64 = 0
        for index in 0..<Int(count) {
            let length = min(totalLength - offset, index < prefix.count ? prefix[index] : repeating)
            let name = layout?.fileName(forVolumeAt: index, count: Int(count))
                ?? scheme.fileName(forVolumeAt: index, count: Int(count))
            guard VolumePublishFS.isName(name) else { throw VolumePublishError.invalidPlan }
            result.append(Volume(name: name, length: length, offset: offset))
            offset += length
        }
        self.scheme = scheme
        self.volumes = result
        self.totalLength = totalLength
    }
}

nonisolated enum VolumePublishStep: Sendable, Hashable {
    case registered, stagingCreated, journalCreated
    case s5, s6, s7, s8, s9, s10, s11
    case committed, oldDisposed, stagingRemoved, indexRemoved
    case retiredVolume(Int)
    case placedVolume(Int)
}

/// 障害注入専用。捕捉時は rollback せず fd を閉じ、実際のクラッシュと同じ残骸を作る。
nonisolated struct SimulatedCrash: Error, Sendable {}

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

nonisolated extension VolumePublishError: LocalizedError {
    var errorDescription: String? { message() }

    func message(bundle: Bundle = .main) -> String {
        switch self {
        case .fat32WorkFileTooLarge:
            return String(localized: "このアーカイブの作業ファイルはFAT32の上限を超えます。APFSまたはexFATのディスクに保存してください。", bundle: bundle)
        case .insufficientSpace:
            return String(localized: "保存先の空き容量が足りません。空き容量を増やすか、別の場所に保存してください。", bundle: bundle)
        case .nameOccupied:
            return String(localized: "同じ名前の分割ファイルが既にあります。", bundle: bundle)
        case .setChanged:
            return String(localized: "アーカイブが別のアプリで変更されました", bundle: bundle)
        case .unsupportedScheme:
            return String(localized: "ZIP本来の分割アーカイブは変更できません。", bundle: bundle)
        case .tooManyVolumes:
            return String(localized: "分割数が上限（128）を超えるため保存できません。巻サイズを大きくしてください。", bundle: bundle)
        case .ownerAlive, .alreadyUsed:
            return String(localized: "別の保存または回復処理中です。しばらくしてからもう一度保存してください。", bundle: bundle)
        case .coordinationTimedOut:
            return String(localized: "保存のためのファイル調整が時間切れになりました。原本は変更されていません。もう一度保存してください。", bundle: bundle)
        case .rolledBack:
            return String(localized: "保存できなかったため、元の分割アーカイブに戻しました。未保存の変更は保持されています。もう一度保存してください。", bundle: bundle)
        case .rollbackIncomplete, .unresolvedPublication, .publishedReaderFailed, .publishedVerificationPending:
            return String(localized: "分割アーカイブの保存を完了できませんでした。回復するまで編集できません。アーカイブを開き直してください。", bundle: bundle)
        case .journalUnreadable, .journalTooLarge:
            return String(localized: "分割アーカイブの保存が中断されています", bundle: bundle) + "\n"
                + String(localized: "中断した保存を完了して開く", bundle: bundle)
        case .validationFailed, .contentMismatch, .stagedReaderFailed:
            return String(localized: "アーカイブの原本を確認できません。", bundle: bundle) + "\n"
                + String(localized: "保存できませんでした。設定、保存先のアクセス権と空き容量を確認して、もう一度試してください。", bundle: bundle)
        case .invalidPlan, .unsafePath, .system, .hazardousVolume:
            return String(localized: "保存できませんでした。設定、保存先のアクセス権と空き容量を確認して、もう一度試してください。", bundle: bundle)
        }
    }
}
