import Darwin
import Foundation
import Synchronization

nonisolated struct VolumeExclusiveRename: Sendable {
    private static let cache = Mutex<[String: Bool]>([:])
    let usesFallback: Bool
    let verifiesPaths: Bool

    init(usesFallback: Bool, verifiesPaths: Bool = true) { self.usesFallback = usesFallback; self.verifiesPaths = verifiesPaths }

    init(parent: VolumePublishDirectory, staging: VolumePublishDirectory, volume: VolumePublishFS.VolumeInfo) throws {
        verifiesPaths = true
        usesFallback = try Self.cache.withLock { cache in
            if let value = cache[volume.cacheIdentity + ":" + volume.fileSystem] { return value }
            let from = "probe-" + UUID().uuidString, to = "probe-" + UUID().uuidString
            let file = try staging.openFile(from, flags: O_WRONLY | O_CREAT | O_EXCL)
            var owned = stat()
            guard fstat(file, &owned) == 0 else { close(file); throw VolumePublishError.system(errno) }
            close(file)
            defer {
                for name in [from, to] {
                    if let current = try? staging.info(name), VolumePublishFS.sameFile(owned, current) {
                        _ = unlinkat(staging.fd, name, 0)
                    }
                }
            }
            let result = renameatx_np(staging.fd, from, staging.fd, to, UInt32(RENAME_EXCL))
            let fallback: Bool
            if result == 0 { fallback = false }
            else if errno == ENOTSUP || errno == EOPNOTSUPP { fallback = true }
            else { throw VolumePublishError.system(errno) }
            cache[volume.cacheIdentity + ":" + volume.fileSystem] = fallback
            return fallback
        }
    }

    func move(_ name: String, from: VolumePublishDirectory, to: VolumePublishDirectory, as newName: String? = nil, verifyPaths: Bool? = nil) throws {
        let destination = newName ?? name
        if verifyPaths ?? verifiesPaths { try from.verifyPath(); try to.verifyPath() }
        try VolumePublishFS.checkName(name)
        try to.requireAbsent(destination)
        let result: Int32
        if usesFallback {
            // FAT/exFAT: fstatat(ENOENT) と renameat の間には外部プロセスとの TOCTOU が残る。
            // flock / coordinator は協調する writer を直列化するが、非協調 writer は防げない。
            result = renameat(from.fd, name, to.fd, destination)
        } else {
            result = renameatx_np(from.fd, name, to.fd, destination, UInt32(RENAME_EXCL))
        }
        guard result == 0 else {
            if errno == EEXIST { throw VolumePublishError.nameOccupied(destination) }
            throw VolumePublishError.system(errno)
        }
        // FAT は kernel が AppleDouble を一緒に動かすこともある。残っていれば best effort。
        let sidecar = "._" + name, destinationSidecar = "._" + destination
        if (try? VolumePublishFS.usesAppleDouble(from)) == true,
           (try? from.info(sidecar)) != nil, (try? to.info(destinationSidecar)) == nil {
            if usesFallback { _ = renameat(from.fd, sidecar, to.fd, destinationSidecar) }
            else { _ = renameatx_np(from.fd, sidecar, to.fd, destinationSidecar, UInt32(RENAME_EXCL)) }
        }
        try from.sync()
        try to.sync()
    }
}
