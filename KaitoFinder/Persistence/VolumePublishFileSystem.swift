import CryptoKit
import Darwin
import Foundation
import Synchronization

/// 変更は保持した directory fd に対して行う。パスの各成分でも symlink を辿らない。
nonisolated final class VolumePublishDirectory: Sendable {
    let url: URL
    let fd: Int32

    init(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw VolumePublishError.unsafePath(url.path) }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw VolumePublishError.system(errno) }
        do {
            // standardizedFileURL は既存の /private/tmp を symlink の /tmp に戻すことがある。
            // NOFOLLOW の検査には渡された絶対パスの成分をそのまま使う。
            for component in url.pathComponents.dropFirst() {
                guard VolumePublishFS.isName(component) else { throw VolumePublishError.unsafePath(component) }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw VolumePublishError.system(errno) }
                close(current)
                current = next
            }
        } catch { close(current); throw error }
        self.url = URL(fileURLWithPath: url.path, isDirectory: true)
        fd = current
    }

    private init(url: URL, fd: Int32) { self.url = url; self.fd = fd }
    deinit { close(fd) }

    func directory(_ name: String, create: Bool = false) throws -> VolumePublishDirectory {
        try VolumePublishFS.checkName(name)
        if create, mkdirat(fd, name, 0o700) != 0 { throw VolumePublishError.system(errno) }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else { throw VolumePublishError.system(errno) }
        return VolumePublishDirectory(url: url.appendingPathComponent(name, isDirectory: true), fd: child)
    }

    func info(_ name: String) throws -> stat? {
        try VolumePublishFS.checkName(name)
        var value = stat()
        if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
        guard errno == ENOENT else { throw VolumePublishError.system(errno) }
        return nil
    }

    func requireAbsent(_ name: String) throws {
        if try info(name) != nil { throw VolumePublishError.nameOccupied(name) }
    }

    func openFile(_ name: String, flags: Int32 = O_RDONLY, mode: mode_t = 0o600) throws -> Int32 {
        try VolumePublishFS.checkName(name)
        let file = openat(fd, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode)
        guard file >= 0 else { throw VolumePublishError.system(errno) }
        var value = stat()
        guard fstat(file, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            close(file)
            throw VolumePublishError.unsafePath(name)
        }
        return file
    }

    func names(checkCancellation: () throws -> Void = {}) throws -> [String] {
        // dup は directory offset を共有するので、独立した fd を開く。
        let descriptor = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw VolumePublishError.system(errno) }
        guard let stream = fdopendir(descriptor) else { close(descriptor); throw VolumePublishError.system(errno) }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            try checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw VolumePublishError.system(errno) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
    }

    func verifyPath() throws {
        let current = try VolumePublishDirectory(url)
        var lhs = stat(), rhs = stat()
        guard fstat(fd, &lhs) == 0, fstat(current.fd, &rhs) == 0,
              lhs.st_ino == rhs.st_ino, lhs.st_dev == rhs.st_dev else { throw VolumePublishError.setChanged }
    }

    func sync(full: Bool = false) throws { try VolumePublishFS.sync(fd, full: full) }
}

nonisolated enum VolumePublishFS {
    static let stagingPrefix = ".KaitoFinder-vol-"
    static let margin: UInt64 = 16 * 1024 * 1024
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KaitoFinder", isDirectory: true)

    static func isName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }
    static func checkName(_ name: String) throws {
        guard isName(name) else { throw VolumePublishError.unsafePath(name) }
    }

    static func sync(_ fd: Int32, full: Bool = false) throws {
        if full, fcntl(fd, F_FULLFSYNC) == 0 { return }
        while fsync(fd) != 0 {
            if errno != EINTR { throw VolumePublishError.system(errno) }
        }
    }

    static func write(_ fd: Int32, data: Data, offset: UInt64) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = pwrite(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written,
                                   off_t(offset) + off_t(written))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw VolumePublishError.system(count < 0 ? errno : EIO) }
                written += count
            }
        }
    }

    static func read(_ fd: Int32, length: Int, offset: UInt64) throws -> Data {
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { buffer in
            var readCount = 0
            while readCount < length {
                let count = pread(fd, buffer.baseAddress!.advanced(by: readCount), length - readCount,
                                  off_t(offset) + off_t(readCount))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw VolumePublishError.system(count < 0 ? errno : EIO) }
                readCount += count
            }
        }
        return data
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func hash(_ directory: VolumePublishDirectory, _ name: String,
                     checkCancellation: () throws -> Void = {}) throws -> String {
        let fd = try directory.openFile(name)
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_size >= 0 else { throw VolumePublishError.system(errno) }
        var hash = SHA256(), offset: UInt64 = 0
        while offset < UInt64(before.st_size) {
            try checkCancellation()
            let data = try read(fd, length: Int(min(1024 * 1024, UInt64(before.st_size) - offset)), offset: offset)
            hash.update(data: data)
            offset += UInt64(data.count)
        }
        guard fstat(fd, &after) == 0, sameFile(before, after),
              let path = try directory.info(name), sameFile(after, path) else { throw VolumePublishError.setChanged }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_mode & S_IFMT == S_IFREG && rhs.st_mode & S_IFMT == S_IFREG
            && lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    struct VolumeInfo: Sendable {
        let uuid: String
        let cacheIdentity: String
        let fileSystem: String
        let available: UInt64
        let hazard: String?
        var isLocal: Bool { hazard != "non-local" }
        var needsOldHashes: Bool { ["msdos", "exfat", "fat", "fat32"].contains(fileSystem) }
    }

    static func volumeInfo(_ parent: VolumePublishDirectory) throws -> VolumeInfo {
        var value = statfs()
        guard fstatfs(parent.fd, &value) == 0 else { throw VolumePublishError.system(errno) }
        let kind = withUnsafePointer(to: &value.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0).lowercased() }
        }
        try parent.verifyPath()
        let resources = try parent.url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsLocalKey, .isUbiquitousItemKey])
        var directoryInfo = stat()
        guard fstat(parent.fd, &directoryInfo) == 0 else { throw VolumePublishError.system(errno) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cloud = [home + "/Library/Mobile Documents", home + "/Library/CloudStorage"].contains {
            parent.url.path == $0 || parent.url.path.hasPrefix($0 + "/")
        }
        let hazard: String?
        if ["msdos", "exfat", "fat", "fat32"].contains(kind) { hazard = kind }
        else if resources.volumeIsLocal == false || value.f_flags & UInt32(MNT_LOCAL) == 0 { hazard = "non-local" }
        else if cloud || resources.isUbiquitousItem == true { hazard = "file-provider" }
        else { hazard = nil }
        let (bytes, overflow) = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_bsize))
        let uuid = volumeUUID(parent) ?? resources.volumeUUIDString ?? "unknown-volume"
        return VolumeInfo(uuid: uuid, cacheIdentity: uuid + ":" + String(directoryInfo.st_dev), fileSystem: kind,
                          available: overflow ? .max : bytes, hazard: hazard)
    }

    /// Use the volume interface capability; only known AppleDouble file systems are a fallback.
    static func usesAppleDouble(_ directory: VolumePublishDirectory) throws -> Bool {
        var fileSystem = statfs()
        guard fstatfs(directory.fd, &fileSystem) == 0 else { throw VolumePublishError.system(errno) }
        let kind = withUnsafePointer(to: &fileSystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0).lowercased() }
        }
        if ["apfs", "hfs"].contains(kind) { return false }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_CAPABILITIES)
        struct Buffer { var length: UInt32 = 0; var value = vol_capabilities_attr_t() }
        var buffer = Buffer()
        if fgetattrlist(directory.fd, &attributes, &buffer, MemoryLayout<Buffer>.size, 0) == 0,
           buffer.value.valid.1 & UInt32(VOL_CAP_INT_EXTENDED_ATTR) != 0 {
            return buffer.value.capabilities.1 & UInt32(VOL_CAP_INT_EXTENDED_ATTR) == 0
        }
        return ["msdos", "exfat", "smbfs", "afpfs", "webdav"].contains(kind)
    }

    /// Foundation can return a volume-group UUID for both the system root and Data mount.
    /// Read the actual filesystem UUID so those are not mistaken for cloned volumes.
    private static func volumeUUID(_ directory: VolumePublishDirectory) -> String? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        struct Buffer { var length: UInt32 = 0; var uuid = UUID().uuid }
        var buffer = Buffer()
        guard fgetattrlist(directory.fd, &attributes, &buffer, MemoryLayout<Buffer>.size, 0) == 0,
              buffer.length == MemoryLayout<Buffer>.size else { return nil }
        let uuid = UUID(uuid: buffer.uuid).uuidString
        return uuid == "00000000-0000-0000-0000-000000000000" ? nil : uuid
    }

    struct MountedVolume: Sendable { let root: URL; let uuid: String }
    private static let mountMutex = Mutex(())
    static func shouldProbeMount(flags: UInt32, extendedFlags: UInt32, kind: String, includeNonLocal: Bool) -> Bool {
        includeNonLocal || (flags & UInt32(MNT_LOCAL) != 0 && extendedFlags & UInt32(MNT_EXT_FSKIT) == 0
            && !["autofs", "devfs", "nullfs", "devicefs", "fskit"].contains(kind.lowercased()))
    }
    static func mountedVolumes(includeNonLocal: Bool = false) throws -> [MountedVolume] {
        let roots: [URL] = try mountMutex.withLock { _ in
            var mounts: UnsafeMutablePointer<statfs>?
            let count = getmntinfo(&mounts, MNT_NOWAIT)
            guard count > 0, let mounts else { throw VolumePublishError.system(errno) }
            return (0..<Int(count)).compactMap { index in
                let kind = withUnsafePointer(to: &mounts[index].f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
                }
                guard shouldProbeMount(flags: mounts[index].f_flags, extendedFlags: mounts[index].f_flags_ext,
                                       kind: kind, includeNonLocal: includeNonLocal) else { return nil }
                return withUnsafePointer(to: &mounts[index].f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                        URL(fileURLWithPath: String(cString: $0), isDirectory: true)
                    }
                }
            }
        }
        return try roots.compactMap { root in
            try VolumePublishMountProbe.run(root: root) {
                let directory = try VolumePublishDirectory(root)
                guard let uuid = volumeUUID(directory) ?? (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString),
                      knownUUID(uuid) else { return nil }
                return MountedVolume(root: root, uuid: uuid)
            }
        }
    }
    static func knownUUID(_ uuid: String) -> Bool { !uuid.isEmpty && uuid.lowercased() != "unknown-volume" }

    static func relativePath(_ url: URL, on root: URL) -> String? {
        let prefix = root.path == "/" ? "/" : root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : nil
    }

    static func volumeRoot(_ directory: VolumePublishDirectory) throws -> URL {
        var value = statfs()
        guard fstatfs(directory.fd, &value) == 0 else { throw VolumePublishError.system(errno) }
        let path = withUnsafePointer(to: &value.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        // APFS firmlink で見えているパスには、その名前空間の volume URL を使う。
        let root = URL(fileURLWithPath: path, isDirectory: true)
        if directory.url.path == path || directory.url.path.hasPrefix(path + "/") || path == "/" { return root }
        return try directory.url.resourceValues(forKeys: [.volumeURLKey]).volume ?? root
    }

    /// app support のみ。作成後にも各成分を NOFOLLOW で開き直す。
    static func supportDirectory(_ url: URL) throws -> VolumePublishDirectory {
        // createDirectory が既存 symlink を通らないよう、既存の先祖から一段ずつ作る。
        var ancestor = url, missing: [String] = []
        while true {
            var info = stat()
            if lstat(ancestor.path, &info) == 0 { break }
            guard errno == ENOENT, ancestor.path != "/" else { throw VolumePublishError.system(errno) }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var directory = try VolumePublishDirectory(ancestor)
        for name in missing.reversed() {
            if mkdirat(directory.fd, name, 0o700) != 0, errno != EEXIST { throw VolumePublishError.system(errno) }
            directory = try directory.directory(name)
        }
        return directory
    }
}

/// A stuck syscall cannot be cancelled. Bound the wait and retain at most four outstanding workers;
/// repeat sweeps reuse a stuck root's worker. An incomplete scan must never authorize pruning.
nonisolated enum VolumePublishMountProbe {
    private final class Request: Sendable {
        let result = Mutex<Result<VolumePublishFS.MountedVolume?, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
    }
    private static let pending = Mutex<[URL: Request]>([:])

    static func run(root: URL, timeout: TimeInterval = 1,
                    probe: @escaping @Sendable () throws -> VolumePublishFS.MountedVolume?) throws -> VolumePublishFS.MountedVolume? {
        let (request, start) = try pending.withLock { state in
            if let existing = state[root] { return (existing, false) }
            guard state.count < 4 else { throw VolumePublishError.system(ETIMEDOUT) }
            let request = Request()
            state[root] = request
            return (request, true)
        }
        if start {
            Thread.detachNewThread {
                let result = Result { try probe() }
                request.result.withLock { $0 = result }
                request.finished.signal()
                _ = pending.withLock { $0.removeValue(forKey: root) }
            }
        }
        if let result = request.result.withLock({ $0 }) { return try result.get() }
        _ = request.finished.wait(timeout: .now() + timeout)
        guard let result = request.result.withLock({ $0 }) else { throw VolumePublishError.system(ETIMEDOUT) }
        return try result.get()
    }
}

nonisolated final class VolumePublishLock: Sendable {
    private let descriptor: Mutex<Int32>
    init(directory: VolumePublishDirectory, name: String) throws {
        let fd = try directory.openFile(name, flags: O_RDWR | O_CREAT)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno; close(fd)
            if error == EWOULDBLOCK { throw VolumePublishError.ownerAlive }
            throw VolumePublishError.system(error)
        }
        descriptor = Mutex(fd)
    }
    func release() { descriptor.withLock { if $0 >= 0 { close($0); $0 = -1 } } }
    deinit { release() }

    /// Local support lock survives journal closure, path rebasing, and the entire S1 window.
    static func stagingLock(_ name: String, directory: URL) throws -> VolumePublishLock {
        guard let base = VolumePublishRemoval.stagingName(name) else { throw VolumePublishError.unsafePath(name) }
        return try VolumePublishLock(directory: VolumePublishFS.supportDirectory(directory), name: base + ".lock")
    }

    static func setLock(volumeUUID: String, gateInode: UInt64?, parent: URL, gate: String,
                        directory: URL) throws -> VolumePublishLock {
        // gate inode は世代ごとに変わる。現在の親と名前で全世代・gate 不在時も競合させる。
        let parentDirectory = try VolumePublishDirectory(parent)
        var info = stat()
        guard fstat(parentDirectory.fd, &info) == 0 else { throw VolumePublishError.system(errno) }
        let key = volumeUUID + ":" + String(info.st_ino) + ":" + gate.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        return try VolumePublishLock(directory: VolumePublishFS.supportDirectory(directory),
                                     name: VolumePublishFS.digest(Data(key.utf8)) + ".lock")
    }
}

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
