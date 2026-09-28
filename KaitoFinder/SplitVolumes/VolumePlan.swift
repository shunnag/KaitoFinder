import Foundation
import KaitoKit

// SplitVolumes/ の型名の接頭辞は層を表す。
// - `VolumePublish*`: 公開エンジンの内部（staging・journal・transaction・回復・fd 相対の I/O）。
// - `Volume*`: エンジンが呼び出し側に見せる値と入口（VolumePlan・VolumeSetPublication・VolumeSplitter など）。
// - `ArchiveVolume*`: 文書から見た巻セットの入力・メタデータ・layout（ArchiveVolumeInput・ArchiveVolumeMetadata など）。
// - `ArchiveSplit*`: 文書側の分割保存の pipeline・結果・失敗（ArchiveSplitSavePipeline・ArchiveSplitWorkProducer など）。
// Persistence/ の RecoverableWorkIndex・ArchiveVolumeMetadataStore は、ここの fd/NOFOLLOW の部品（VolumePublishDirectory・VolumePublishFS）を使う。

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
