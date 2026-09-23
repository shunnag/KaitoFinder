import CryptoKit
import Darwin
import Foundation

nonisolated enum VolumeSplitter {
    struct Attributes: Sendable {
        let mode: mode_t
        let xattrs: [String: Data]

        init(directory: VolumePublishDirectory, name: String) throws {
            let fd = try directory.openFile(name)
            defer { close(fd) }
            try self.init(fd: fd)
        }

        init(fd: Int32) throws {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw VolumePublishError.system(errno) }
            mode = info.st_mode & 0o7777
            // fd は O_NOFOLLOW で開いたもの。fd API の options は 0（NOFOLLOW は EINVAL）。
            let size = flistxattr(fd, nil, 0, 0)
            guard size >= 0 else { throw VolumePublishError.system(errno) }
            var names = [CChar](repeating: 0, count: size)
            let actual = names.withUnsafeMutableBufferPointer { flistxattr(fd, $0.baseAddress, size, 0) }
            guard actual >= 0, actual <= size else { throw VolumePublishError.system(errno) }
            var values: [String: Data] = [:]
            for bytes in names.prefix(actual).split(separator: 0) {
                let key = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let length = fgetxattr(fd, key, nil, 0, 0, 0)
                guard length >= 0 else { throw VolumePublishError.system(errno) }
                var data = Data(count: length)
                let read = data.withUnsafeMutableBytes { fgetxattr(fd, key, $0.baseAddress, $0.count, 0, 0) }
                guard read == length else { throw VolumePublishError.system(read < 0 ? errno : EIO) }
                values[key] = data
            }
            xattrs = values
        }

        func apply(to fd: Int32, quarantine: Data?, avoidsAppleDouble: Bool = false) throws {
            var values = xattrs
            values.removeValue(forKey: ArchiveVolumeMetadata.layoutKey)
            values.removeValue(forKey: ArchiveVolumeMetadata.setKey)
            values.removeValue(forKey: "com.apple.quarantine")
            values["com.apple.quarantine"] = quarantine
            if avoidsAppleDouble { values.removeAll() }
            if quarantine == nil, !avoidsAppleDouble {
                let result = fremovexattr(fd, "com.apple.quarantine", 0)
                if result != 0, errno != ENOATTR { throw VolumePublishError.system(errno) }
            }
            for (key, data) in values {
                let result = data.withUnsafeBytes { fsetxattr(fd, key, $0.baseAddress, $0.count, 0, 0) }
                guard result == 0 else { throw VolumePublishError.system(errno) }
            }
            guard fchmod(fd, mode) == 0 else { throw VolumePublishError.system(errno) }
        }
    }

    /// 末尾から切り出し、巻を同期してから W を縮める。追加領域は約一巻に抑える。
    static func split(workURL: URL, into newDirectory: VolumePublishDirectory, plan: VolumePlan,
                      oldLayout: ArchiveVolumeLayout?, avoidsAppleDouble: Bool = false,
                      additionalQuarantine: Data? = nil, checkCancellation: () throws -> Void = {}) throws
        -> [VolumePublishJournalRecord.NewVolume] {
        let work = try VolumePublishDirectory(workURL.deletingLastPathComponent())
        guard work.url.lastPathComponent == "work",
              work.url.deletingLastPathComponent() == newDirectory.url.deletingLastPathComponent(),
              newDirectory.url.lastPathComponent == "new" else { throw VolumePublishError.unsafePath(workURL.path) }
        let fd = try work.openFile(workURL.lastPathComponent, flags: O_RDWR)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0, info.st_nlink == 1,
              UInt64(info.st_size) == plan.totalLength else { throw VolumePublishError.setChanged }
        var attributes: [Attributes] = []
        if let oldLayout {
            let parent = try VolumePublishDirectory(oldLayout.gateURL.deletingLastPathComponent())
            attributes = try oldLayout.volumes.map { try Attributes(directory: parent, name: $0.url.lastPathComponent) }
        } else {
            attributes = [try Attributes(directory: work, name: workURL.lastPathComponent)]
        }
        let quarantine = attributes.lazy.compactMap { $0.xattrs["com.apple.quarantine"] }.first ?? additionalQuarantine
        var records: [VolumePublishJournalRecord.NewVolume] = []
        for index in plan.volumes.indices.reversed() {
            try checkCancellation()
            let volume = plan.volumes[index]
            let output = try newDirectory.openFile(volume.name, flags: O_WRONLY | O_CREAT | O_EXCL)
            do {
                var hash = SHA256(), copied: UInt64 = 0
                while copied < volume.length {
                    try checkCancellation()
                    let data = try VolumePublishFS.read(fd, length: Int(min(1024 * 1024, volume.length - copied)),
                                                        offset: volume.offset + copied)
                    try VolumePublishFS.write(output, data: data, offset: copied)
                    hash.update(data: data)
                    copied += UInt64(data.count)
                }
                try attributes[index < attributes.count ? index : 0].apply(to: output, quarantine: quarantine,
                                                                        avoidsAppleDouble: avoidsAppleDouble)
                try VolumePublishFS.sync(output)
                records.append(.init(name: volume.name, length: volume.length,
                                     sha256: hash.finalize().map { String(format: "%02x", $0) }.joined()))
            } catch { close(output); throw error }
            close(output)
            guard let current = try work.info(workURL.lastPathComponent), current.st_ino == info.st_ino,
                  current.st_dev == info.st_dev else { throw VolumePublishError.setChanged }
            guard ftruncate(fd, off_t(volume.offset)) == 0 else { throw VolumePublishError.system(errno) }
            try VolumePublishFS.sync(fd)
        }
        try newDirectory.sync()
        return records.reversed()
    }
}
