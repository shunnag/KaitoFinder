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
        guard fstat(file, &value) == 0, value.isRegularFile else {
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
    static let stagingPrefix = WorkAreaName.volume
    /// 空き容量の検査で要求量に足す余裕。台帳の上限（maximumLedgerBytes）とは別物。
    static let margin: UInt64 = 16 * 1024 * 1024
    /// 全文 hash と巻のコピーで一度に読む長さ。
    static let hashChunkSize: UInt64 = 1 << 20
    /// Application Support の JSON 台帳（volume-publish-index / volume-metadata）を読み書きする上限。
    static let maximumLedgerBytes = 16 << 20
    /// FAT 系。inode と 2 秒単位の mtime を信用せず、旧巻の全文 hash を必要とする。
    static let fatFamily: Set<String> = ["msdos", "exfat", "fat", "fat32"]
    /// 4 GiB のファイル上限を持つ FAT。exFAT は含めない。
    static let fat32Family: Set<String> = ["msdos", "fat", "fat32"]
    /// volume capability を読めないとき、xattr を AppleDouble（._*）で運ぶとみなすファイルシステム。
    static let appleDoubleFallbackFileSystems: Set<String> = ["msdos", "exfat", "smbfs", "afpfs", "webdav"]
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KaitoFinder", isDirectory: true)

    static func isName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }
    static func checkName(_ name: String) throws {
        guard isName(name) else { throw VolumePublishError.unsafePath(name) }
    }

    /// 公開の名前空間を決める前に、ディレクトリの別名（macOS の /var や /tmp を含む）を解決する。
    /// 巻そのものは解決せず、以後の I/O はすべて NOFOLLOW のまま。
    static func canonicalParent(of member: URL) throws -> URL {
        guard let path = realpath(member.deletingLastPathComponent().path, nil) else { throw VolumePublishError.system(errno) }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
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

    /// 64 桁の小文字 16 進。journal・xattr・台帳に書く digest の書式はすべてこれ。
    static func hex(_ digest: some Sequence<UInt8>) -> String { digest.map { String(format: "%02x", $0) }.joined() }
    static func isSHA256Hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hash(_ directory: VolumePublishDirectory, _ name: String,
                     checkCancellation: () throws -> Void = {}) throws -> String {
        let fd = try directory.openFile(name)
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_size >= 0 else { throw VolumePublishError.system(errno) }
        var hash = SHA256(), offset: UInt64 = 0
        while offset < UInt64(before.st_size) {
            try checkCancellation()
            let data = try read(fd, length: Int(min(hashChunkSize, UInt64(before.st_size) - offset)), offset: offset)
            hash.update(data: data)
            offset += UInt64(data.count)
        }
        guard fstat(fd, &after) == 0, sameFile(before, after),
              let path = try directory.info(name), sameFile(after, path) else { throw VolumePublishError.setChanged }
        return hex(hash.finalize())
    }

    static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.isRegularFile && rhs.isRegularFile && VolumeFileStamp(lhs) == VolumeFileStamp(rhs)
    }

    struct VolumeInfo: Sendable {
        let uuid: String
        let cacheIdentity: String
        let fileSystem: String
        let available: UInt64
        let hazard: String?
        var isLocal: Bool { hazard != "non-local" }
        var needsOldHashes: Bool { VolumePublishFS.fatFamily.contains(fileSystem) }
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
        if fatFamily.contains(kind) { hazard = kind }
        else if resources.volumeIsLocal == false || value.f_flags & UInt32(MNT_LOCAL) == 0 { hazard = "non-local" }
        else if cloud || resources.isUbiquitousItem == true { hazard = "file-provider" }
        else { hazard = nil }
        let (bytes, overflow) = UInt64(value.f_bavail).multipliedReportingOverflow(by: UInt64(value.f_bsize))
        let uuid = volumeUUID(parent) ?? resources.volumeUUIDString ?? "unknown-volume"
        return VolumeInfo(uuid: uuid, cacheIdentity: uuid + ":" + String(directoryInfo.st_dev), fileSystem: kind,
                          available: overflow ? .max : bytes, hazard: hazard)
    }

    /// volume の capability を使う。既知の AppleDouble のファイルシステムは、capability を読めないときの代わりにだけ使う。
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
        return appleDoubleFallbackFileSystems.contains(kind)
    }

    /// Foundation はシステムの root と Data の mount の両方に volume group の UUID を返すことがある。
    /// 両者を複製された volume と取り違えないよう、実際のファイルシステムの UUID を読む。
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
    struct MountScan: Sendable, ExpressibleByArrayLiteral {
        struct Failure: Sendable { let root: URL; let reason: String }
        var volumes: [MountedVolume] = []
        var failures: [Failure] = []
        var isComplete: Bool { failures.isEmpty }
        init(arrayLiteral elements: MountedVolume...) { volumes = elements }
    }
    private static let mountMutex = Mutex(())
    static func shouldProbeMount(flags: UInt32, extendedFlags: UInt32, kind: String, includeNonLocal: Bool,
                                 fileSystems: Set<String> = []) -> Bool {
        let kind = kind.lowercased()
        guard !["autofs", "devfs", "nullfs", "devicefs", "fskit"].contains(kind),
              includeNonLocal || flags & UInt32(MNT_LOCAL) != 0 else { return false }
        // FAT/exFAT も FSKit を使う。索引に記録した種類は、将来のデータ用ファイルシステムのモジュールでも通す。
        return extendedFlags & UInt32(MNT_EXT_FSKIT) == 0 || fileSystems.contains(kind)
            || ["msdos", "exfat", "fat", "fat32", "apfs", "hfs"].contains(kind)
    }
    static func mountedVolumes(includeNonLocal: Bool = false, fileSystems: Set<String> = []) throws -> MountScan {
        let roots: [URL] = try mountMutex.withLock { _ in
            var mounts: UnsafeMutablePointer<statfs>?
            let count = getmntinfo(&mounts, MNT_NOWAIT)
            guard count > 0, let mounts else { throw VolumePublishError.system(errno) }
            return (0..<Int(count)).compactMap { index in
                let kind = withUnsafePointer(to: &mounts[index].f_fstypename) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) }
                }
                guard shouldProbeMount(flags: mounts[index].f_flags, extendedFlags: mounts[index].f_flags_ext,
                                       kind: kind, includeNonLocal: includeNonLocal, fileSystems: fileSystems) else { return nil }
                return withUnsafePointer(to: &mounts[index].f_mntonname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                        URL(fileURLWithPath: String(cString: $0), isDirectory: true)
                    }
                }
            }
        }
        return probeMounts(roots) { root in
            let directory = try VolumePublishDirectory(root)
            guard let uuid = volumeUUID(directory) ?? (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString),
                  knownUUID(uuid) else { return nil }
            return MountedVolume(root: root, uuid: uuid)
        }
    }

    static func probeMounts(_ roots: [URL], timeout: TimeInterval = 1,
                            probe: @escaping @Sendable (URL) throws -> MountedVolume?) -> MountScan {
        var scan: MountScan = []
        for root in roots {
            do {
                if let volume = try VolumePublishMountProbe.run(root: root, timeout: timeout, probe: { try probe(root) }) {
                    scan.volumes.append(volume)
                }
            } catch {
                scan.failures.append(.init(root: root, reason: String(describing: error)))
            }
        }
        return scan
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
