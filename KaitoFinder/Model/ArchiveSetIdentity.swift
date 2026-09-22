import Darwin
import Foundation
import KaitoKit

/// 全巻の同一性と、連結される続きの巻がないことをひとまとまりで照合する。
nonisolated struct ArchiveSetIdentity: Sendable, Equatable {
    struct Volume: Sendable, Equatable {
        let fileName: String
        let volumeUUID: String
        let inode: UInt64
        let size: UInt64
        let mode: UInt16
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    let volumes: [Volume]
    let nextVolumeName: String?

    private init(volumes: [Volume], nextVolumeName: String?) {
        self.volumes = volumes
        self.nextVolumeName = nextVolumeName
    }

    init(volumeSet: ArchiveVolumeSet) {
        volumes = volumeSet.volumes.map { volume in
            Volume(fileName: volume.url.lastPathComponent,
                   volumeUUID: Self.volumeUUID(for: volume.url, device: volume.device),
                   inode: volume.inode, size: volume.length, mode: volume.mode,
                   modificationSeconds: volume.modificationSeconds,
                   modificationNanoseconds: volume.modificationNanoseconds)
        }
        nextVolumeName = ArchiveVolumeLayout(volumeSet: volumeSet).nextVolumeName
    }

    static func capture(url: URL) throws -> Self {
        Self(volumes: [try captureVolume(url)], nextVolumeName: nil)
    }

    static func capture(layout: ArchiveVolumeLayout) throws -> Self {
        let volumes = try layout.volumes.map { try captureVolume($0.url) }
        var info = stat()
        // 切れた symlink も存在扱い。ENOENT 以外は不在を証明できない。
        guard lstat(layout.nextVolumeURL.path, &info) != 0, errno == ENOENT else { throw refusal }
        return Self(volumes: volumes, nextVolumeName: layout.nextVolumeName)
    }

    static func capture(url: URL, layout: ArchiveVolumeLayout?) throws -> Self {
        if let layout { return try capture(layout: layout) }
        return try capture(url: url)
    }

    func contentEquals(_ other: Self) -> Bool {
        guard nextVolumeName == other.nextVolumeName, volumes.count == other.volumes.count else { return false }
        return zip(volumes, other.volumes).allSatisfy { lhs, rhs in
            lhs.fileName == rhs.fileName && lhs.volumeUUID == rhs.volumeUUID && lhs.inode == rhs.inode
                && lhs.size == rhs.size && lhs.modificationSeconds == rhs.modificationSeconds
                && lhs.modificationNanoseconds == rhs.modificationNanoseconds
        }
    }

    private static func captureVolume(_ url: URL) throws -> Volume {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw refusal }
        // lastuseddate や Finder タグは内容を変えずに ctime を更新するので比較に含めない。
        return Volume(fileName: url.lastPathComponent,
                      volumeUUID: volumeUUID(for: url, device: UInt64(UInt32(bitPattern: info.st_dev))),
                      inode: info.st_ino, size: UInt64(info.st_size), mode: info.st_mode,
                      modificationSeconds: Int64(info.st_mtimespec.tv_sec),
                      modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    private static func volumeUUID(for url: URL, device: UInt64) -> String {
        // 親の UUID を使えば、再マウントで st_dev が変わっても同じボリュームとして扱える。
        (try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            ?? String(device)
    }

    private static var refusal: ExtractionFailure {
        .refused(String(localized: "アーカイブの原本を確認できません。"))
    }
}
