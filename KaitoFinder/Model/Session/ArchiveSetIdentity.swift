import Darwin
import Foundation
import KaitoKit

/// パスと記述子の照合には Foundation の resource cache や volume lookup を介さない。
nonisolated struct ArchiveFileIdentity: Sendable, Equatable, CustomStringConvertible {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let mode: UInt16
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    static func capture(url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
        return try Self(info)
    }

    static func capture(descriptor: Int32) throws -> Self {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw ExtractionFailure.system(errno) }
        return try Self(info)
    }

    private init(_ info: stat) throws {
        guard info.isRegularFile, info.st_size >= 0 else { throw ExtractionFailure.system(EINVAL) }
        device = UInt64(UInt32(bitPattern: info.st_dev)); inode = info.st_ino
        size = UInt64(info.st_size); mode = info.st_mode
        modificationSeconds = Int64(info.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }

    func contentEquals(_ other: Self) -> Bool {
        device == other.device && inode == other.inode && size == other.size
            && modificationSeconds == other.modificationSeconds && modificationNanoseconds == other.modificationNanoseconds
    }

    var description: String {
        "dev=\(device),ino=\(inode),size=\(size),mode=\(mode),mtime=\(modificationSeconds).\(modificationNanoseconds)"
    }
}

/// 全巻の同一性と、連結される続きの巻がないことをひとまとまりで照合する。
nonisolated struct ArchiveSetIdentity: Sendable, Equatable {
    struct Volume: Codable, Sendable, Equatable {
        let fileName: String
        let volumeUUID: String
        let inode: UInt64
        let size: UInt64
        let mode: UInt16
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64

        func contentEquals(_ other: Self) -> Bool {
            fileName == other.fileName && volumeUUID == other.volumeUUID && inode == other.inode
                && size == other.size && modificationSeconds == other.modificationSeconds
                && modificationNanoseconds == other.modificationNanoseconds
        }
    }

    let volumes: [Volume]
    let nextVolumeName: String?

    /// Foundation の Date は 2001 年基準なので、その基準で組み立てて epoch 変換の丸めを一回減らす。
    var modificationDate: Date {
        let gate = volumes[0]
        return Date(timeIntervalSinceReferenceDate: Double(gate.modificationSeconds) - 978_307_200
                    + Double(gate.modificationNanoseconds) / 1_000_000_000)
    }

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

    static func capture(descriptor: Int32, url: URL) throws -> Self {
        Self(file: try ArchiveFileIdentity.capture(descriptor: descriptor), url: url)
    }

    init(file: ArchiveFileIdentity, url: URL) {
        self.init(volumes: [Volume(fileName: url.lastPathComponent,
            volumeUUID: Self.volumeUUID(for: url, device: file.device), inode: file.inode, size: file.size, mode: file.mode,
            modificationSeconds: file.modificationSeconds, modificationNanoseconds: file.modificationNanoseconds)], nextVolumeName: nil)
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
        return zip(volumes, other.volumes).allSatisfy { $0.contentEquals($1) }
    }

    // NSDocument が追跡した単一ファイルの移動だけに用いる。別 inode への置換は許さない。
    func contentEqualsAfterMove(_ other: Self) -> Bool {
        guard nextVolumeName == nil, other.nextVolumeName == nil,
              volumes.count == 1, other.volumes.count == 1 else { return false }
        let lhs = volumes[0], rhs = other.volumes[0]
        return lhs.volumeUUID == rhs.volumeUUID && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modificationSeconds == rhs.modificationSeconds
            && lhs.modificationNanoseconds == rhs.modificationNanoseconds
    }

    private static func captureVolume(_ url: URL) throws -> Volume {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.isRegularFile else { throw refusal }
        // lastuseddate や Finder タグは内容を変えずに ctime を更新するので比較に含めない。
        return Volume(fileName: url.lastPathComponent,
                      volumeUUID: volumeUUID(for: url, device: UInt64(UInt32(bitPattern: info.st_dev))),
                      inode: info.st_ino, size: UInt64(info.st_size), mode: info.st_mode,
                      modificationSeconds: Int64(info.st_mtimespec.tv_sec),
                      modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    private static func volumeUUID(for url: URL, device: UInt64) -> String {
        // 親の UUID を使えば、再マウントで st_dev が変わっても同じボリュームとして扱える。
        (try? URL(fileURLWithPath: url.deletingLastPathComponent().path, isDirectory: true)
            .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            ?? String(device)
    }

    private static var refusal: ExtractionFailure {
        .refused(String(localized: "アーカイブの原本を確認できません。"))
    }
}

nonisolated struct ArchiveEntryVerification: Sendable {
    let identity: ArchiveSetIdentity
    // nil は、入力を全検証した公開処理が出力全体を保証するときだけ使う。
    let indices: Set<Int>?

    func matches(_ current: ArchiveSetIdentity) -> Bool {
        identity.contentEquals(current) || identity.contentEqualsAfterMove(current)
    }
}
