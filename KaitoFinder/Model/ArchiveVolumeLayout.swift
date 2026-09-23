import Foundation
import KaitoKit

/// reader が組み立てた順序と命名規則を保ち、後の保存で使う巻サイズを推定する。
nonisolated struct ArchiveVolumeLayout: Sendable, Equatable {
    struct Volume: Sendable, Equatable {
        let url: URL
        let length: UInt64
    }

    enum Schedule: Sendable, Equatable {
        case uniform(size: UInt64)
        case uneven([UInt64])
    }

    let scheme: ArchiveVolumeSet.Scheme
    let volumes: [Volume]
    let openedVolumeIndex: Int
    let schedule: Schedule
    /// The intended schedule survives a short last volume, including a one-volume set.
    var savedSchedule: VolumePlan.Schedule? = nil

    init(volumeSet: ArchiveVolumeSet) {
        self.init(scheme: volumeSet.scheme,
                  volumes: volumeSet.volumes.map { Volume(url: $0.url, length: $0.length) },
                  openedVolumeIndex: volumeSet.openedVolumeIndex)
    }

    init(scheme: ArchiveVolumeSet.Scheme, volumes: [Volume], openedVolumeIndex: Int) {
        precondition(!volumes.isEmpty && volumes.indices.contains(openedVolumeIndex))
        self.scheme = scheme
        self.volumes = volumes
        self.openedVolumeIndex = openedVolumeIndex
        let lengths = volumes.map(\.length)
        let size = lengths[0], last = lengths[lengths.count - 1]
        if last > 0, last <= size, lengths.dropLast().allSatisfy({ $0 == size }) {
            schedule = .uniform(size: size)
        } else {
            schedule = .uneven(lengths)
        }
    }

    var gateURL: URL {
        switch scheme {
        case .numbered: volumes[0].url
        case .zipSpanned: volumes[volumes.count - 1].url
        }
    }

    func fileName(forVolumeAt index: Int, count: Int) -> String {
        precondition(index >= 0 && count > 0)
        // ZIP の既存の番号付き巻は、巻ごとに異なる大文字・小文字も維持する。
        if case .zipSpanned = scheme, index != count - 1, index < volumes.count - 1 {
            return volumes[index].url.lastPathComponent
        }
        return scheme.fileName(forVolumeAt: index, count: count)
    }

    var nextVolumeName: String {
        switch scheme {
        case .numbered: fileName(forVolumeAt: volumes.count, count: volumes.count + 1)
        case .zipSpanned: fileName(forVolumeAt: volumes.count - 1, count: volumes.count + 1)
        }
    }

    var nextVolumeURL: URL { gateURL.deletingLastPathComponent().appendingPathComponent(nextVolumeName) }

    func publicationLayout() throws -> Self {
        let parent = try VolumePublishFS.canonicalParent(of: gateURL)
        var result = Self(scheme: scheme, volumes: volumes.map {
            Volume(url: parent.appendingPathComponent($0.url.lastPathComponent), length: $0.length)
        }, openedVolumeIndex: openedVolumeIndex)
        result.savedSchedule = savedSchedule
        return result
    }
}
