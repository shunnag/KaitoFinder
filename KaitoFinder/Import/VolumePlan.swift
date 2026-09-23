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
    enum Schedule: Sendable, Equatable {
        case uniform(size: UInt64)
        case explicit([UInt64])
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
}

nonisolated enum VolumePublishOutcome: Sendable, Equatable {
    case committed(cleanupFailed: String?)
}
