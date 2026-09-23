import Darwin
import Foundation
import Synchronization

/// 発見の手がかりだけを保存する。未マウント・ENOENT・st_dev の変化では項目を落とさない。
nonisolated final class RecoverableWorkIndex: Sendable {
    struct Entry: Codable, Sendable, Equatable {
        var stagingPath: String
        let volumeUUID: String
        let registeredAt: Date
        var relativeStagingPath: String? = nil
        var gateName: String? = nil
        var cleanupAuthorized: Bool? = nil
        var parentInode: UInt64? = nil
        var nonLocalVolume: Bool? = nil
        var stagingLockName: String? = nil

        func matches(_ staging: URL, volumeUUID: String, root: URL) -> Bool {
            self.volumeUUID == volumeUUID && (stagingPath == staging.path
                || (relativeStagingPath != nil && relativeStagingPath == VolumePublishFS.relativePath(staging, on: root)))
        }

        func resolved(on root: URL, uuid: String) -> URL? {
            guard VolumePublishFS.knownUUID(uuid), uuid == volumeUUID, let relativeStagingPath, !relativeStagingPath.hasPrefix("/"),
                  relativeStagingPath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ VolumePublishFS.isName(String($0)) }) else { return nil }
            return root.appendingPathComponent(relativeStagingPath, isDirectory: true)
        }
    }
    static let shared = RecoverableWorkIndex(fileURL: VolumePublishFS.support.appendingPathComponent("volume-publish-index.json"))
    private static let mutex = Mutex(())
    let fileURL: URL
    var setLocksURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("set-locks", isDirectory: true) }
    var stagingLocksURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("staging-locks", isDirectory: true) }
    init(fileURL: URL) { self.fileURL = fileURL }

    func entries() throws -> [Entry] { try access { try read($0) } }
    func register(_ staging: URL, volumeUUID: String, gateName: String? = nil, nonLocalVolume: Bool? = nil,
                  stagingLockName: String? = nil, volumeRoot: URL? = nil) throws {
        let parent = try VolumePublishDirectory(staging.deletingLastPathComponent())
        var parentInfo = stat()
        guard fstat(parent.fd, &parentInfo) == 0 else { throw VolumePublishError.system(errno) }
        let root = try volumeRoot ?? VolumePublishFS.volumeRoot(parent)
        let relative = VolumePublishFS.relativePath(staging, on: root)
        try access { directory in
            var entries = try read(directory)
            if !entries.contains(where: { $0.stagingPath == staging.path }) {
                entries.append(Entry(stagingPath: staging.path, volumeUUID: volumeUUID, registeredAt: Date(),
                                     relativeStagingPath: relative, gateName: gateName, parentInode: parentInfo.st_ino,
                                     nonLocalVolume: nonLocalVolume, stagingLockName: stagingLockName))
            }
            try save(entries, in: directory)
        }
    }
    func authorizeCleanup(_ staging: URL) throws {
        try access { directory in
            var entries = try read(directory)
            for i in entries.indices where entries[i].stagingPath == staging.path { entries[i].cleanupAuthorized = true }
            try save(entries, in: directory)
        }
    }
    func rebase(_ entry: Entry, to staging: URL) throws {
        try access { directory in
            var entries = try read(directory)
            for i in entries.indices where entries[i] == entry { entries[i].stagingPath = staging.path }
            try save(entries, in: directory)
        }
    }
    func removeCompleted(_ staging: URL) throws {
        try access { directory in
            var entries = try read(directory)
            entries.removeAll { $0.stagingPath == staging.path }
            try save(entries, in: directory)
        }
    }

    private func access<T>(_ body: (VolumePublishDirectory) throws -> T) throws -> T {
        try Self.mutex.withLock { _ in
            let directory = try VolumePublishFS.supportDirectory(fileURL.deletingLastPathComponent())
            let fd = try directory.openFile(fileURL.lastPathComponent + ".lock", flags: O_RDWR | O_CREAT)
            defer { close(fd) }
            while flock(fd, LOCK_EX) != 0 {
                if errno != EINTR { throw VolumePublishError.system(errno) }
            }
            return try body(directory)
        }
    }
    private func read(_ directory: VolumePublishDirectory) throws -> [Entry] {
        guard let info = try directory.info(fileURL.lastPathComponent) else { return [] }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw VolumePublishError.unsafePath(fileURL.path)
        }
        let fd = try directory.openFile(fileURL.lastPathComponent)
        defer { close(fd) }
        let bytes = info.st_size < 16 * 1024 * 1024 ? try VolumePublishFS.read(fd, length: Int(info.st_size), offset: 0) : nil
        if let bytes, let entries = try? JSONDecoder().decode([Entry].self, from: bytes),
           entries.allSatisfy({ $0.stagingPath.hasPrefix("/") && URL(fileURLWithPath: $0.stagingPath).lastPathComponent
                .hasPrefix(VolumePublishFS.stagingPrefix) }) { return entries }
        // 壊れた原本を必ず保存してから新しい索引を始める。失敗したら呼び出し側へ返す。
        let backup = fileURL.lastPathComponent + ".corrupt-" + String(Int(Date().timeIntervalSince1970)) + "-" + UUID().uuidString
        guard renameatx_np(directory.fd, fileURL.lastPathComponent, directory.fd, backup, UInt32(RENAME_EXCL)) == 0 else {
            throw VolumePublishError.system(errno)
        }
        try directory.sync()
        try save([], in: directory)
        return []
    }
    private func save(_ entries: [Entry], in directory: VolumePublishDirectory) throws {
        let data = try JSONEncoder().encode(entries)
        let temporary = ".volume-index-" + UUID().uuidString
        let fd = try directory.openFile(temporary, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer {
            var owned = stat()
            if fstat(fd, &owned) == 0, let current = try? directory.info(temporary),
               VolumePublishFS.sameFile(owned, current),
               (try? VolumePublishFS.hash(directory, temporary)) == VolumePublishFS.digest(data) {
                _ = unlinkat(directory.fd, temporary, 0)
            }
            close(fd)
        }
        try VolumePublishFS.write(fd, data: data, offset: 0)
        try VolumePublishFS.sync(fd, full: true)
        guard renameat(directory.fd, temporary, directory.fd, fileURL.lastPathComponent) == 0 else {
            throw VolumePublishError.system(errno)
        }
        try directory.sync()
    }
}
