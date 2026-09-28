import Darwin
import Foundation
import Synchronization

/// 未保存の入力は一時領域ではなく Application Support に置く。所有権は PID ではなく flock で示す。
nonisolated final class StagingRegistry: Sendable {
    private static let current = Mutex<StagingRegistry?>(nil)
    static var shared: StagingRegistry {
        get { current.withLock { $0 ?? defaultRegistry } }
        set { current.withLock { $0 = newValue } }
    }
    private static let defaultRegistry = StagingRegistry(root: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KaitoFinder/Staging", isDirectory: true))
    private static let lock = Mutex(())
    /// 退避物の複製で一度に読み書きする長さ。
    static let copyBufferSize = 256 << 10
    let root: URL
    private let fileURL: URL
    private struct Entry: Codable {
        let path: String
        let device: Int64
        let inode: UInt64
        var discardable: Bool? = nil
    }

    init(root: URL, fileURL: URL? = nil) {
        self.root = root
        self.fileURL = fileURL ?? root.deletingLastPathComponent().appendingPathComponent("staging.json")
    }

    struct Temporary: Sendable {
        let registry: StagingRegistry
        let pendingWork: PendingWorkRegistry
        func remove() { pendingWork.removeAndUnregister(registry.root) }
    }

    static func temporary(beside archive: URL, pendingWork: PendingWorkRegistry = .shared) throws -> Temporary {
        let directory = archive.deletingLastPathComponent()
            .appendingPathComponent(WorkAreaName.staging + UUID().uuidString, isDirectory: true)
        try pendingWork.register(directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            try pendingWork.recordIdentity(directory)
        } catch {
            pendingWork.removeAndUnregister(directory)
            throw error
        }
        // 即時編集の入力と台帳は保存先にまとめ、終了時は親ごと回収する。
        return Temporary(registry: StagingRegistry(root: directory, fileURL: directory.appendingPathComponent("staging.json")),
                         pendingWork: pendingWork)
    }

    nonisolated final class Lease: Sendable {
        let directory: URL
        private let descriptor: Int32
        private let registry: StagingRegistry
        private struct Reads {
            var count = 0
            var retiring = false
            var waiters: [CheckedContinuation<Void, Never>] = []
        }
        private let reads = Mutex(Reads())
        init(directory: URL, descriptor: Int32, registry: StagingRegistry) {
            self.directory = directory
            self.descriptor = descriptor
            self.registry = registry
        }
        deinit { close(descriptor) }
        func remove() {
            guard let tombstone = registry.retire(directory) else { return }
            Task.detached { self.registry.deleteRetired(tombstone) }
        }

        func acquireRead() throws -> ReadLease {
            try reads.withLock {
                guard !$0.retiring else { throw ArchiveEntryPayload.staleSelection }
                $0.count += 1
            }
            return ReadLease(owner: self)
        }

        @concurrent func removeWhenUnused() async {
            await withCheckedContinuation { continuation in
                let ready = reads.withLock {
                    $0.retiring = true
                    if $0.count == 0 { return true }
                    $0.waiters.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
            if let tombstone = registry.retire(directory) { registry.deleteRetired(tombstone) }
        }

        fileprivate func releaseRead() {
            let waiters = reads.withLock { state in
                state.count -= 1
                guard state.count == 0 else { return [CheckedContinuation<Void, Never>]() }
                let waiters = state.waiters
                state.waiters.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    nonisolated final class ReadLease: Sendable {
        private let owner: Lease
        fileprivate init(owner: Lease) { self.owner = owner }
        deinit { owner.releaseRead() }
    }

    func create(id: UUID) throws -> Lease {
        try exclusive {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            do {
                let descriptor = open(directory.appendingPathComponent(WorkAreaName.ownerLock).path,
                                      O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw ExtractionFailure.system(errno) }
                let lease = Lease(directory: directory, descriptor: descriptor, registry: self)
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw ExtractionFailure.system(errno) }
                var info = stat()
                guard lstat(directory.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
                var entries = try read()
                entries.append(Entry(path: directory.path, device: Int64(info.st_dev), inode: info.st_ino))
                try save(entries)
                return lease
            } catch {
                try? Self.removeSnapshot(directory)
                throw error
            }
        }
    }

    private func retire(_ directory: URL) -> URL? {
        do {
            return try exclusive {
                var entries = try read()
                guard let record = entries.first(where: { $0.path == directory.path }) else { return nil }
                var info = stat()
                if lstat(directory.path, &info) != 0 {
                    guard errno == ENOENT else { throw ExtractionFailure.system(errno) }
                    entries.removeAll { $0.path == directory.path }
                    try save(entries)
                    return nil
                }
                guard Int64(info.st_dev) == record.device, info.st_ino == record.inode,
                      info.isDirectory else { throw ExtractionFailure.system(ESTALE) }
                let tombstone = root.appendingPathComponent(WorkAreaName.deleted + UUID().uuidString, isDirectory: true)
                // rename の前に記録し、途中終了でも削除許可済みの領域だけを回収する。
                entries.append(Entry(path: tombstone.path, device: record.device, inode: record.inode, discardable: true))
                try save(entries)
                guard rename(directory.path, tombstone.path) == 0 else { throw ExtractionFailure.system(errno) }
                entries.removeAll { $0.path == directory.path }
                try save(entries)
                return tombstone
            }
        } catch {
            NSLog("保存前の退避領域を削除できません: %@", String(describing: error))
            return nil
        }
    }

    private func deleteRetired(_ directory: URL) {
        do {
            try Self.removeSnapshot(directory)
            try exclusive {
                var entries = try read()
                entries.removeAll { $0.path == directory.path && $0.discardable == true }
                try save(entries)
            }
        } catch { NSLog("保存前の退避領域を削除できません: %@", String(describing: error)) }
    }

    /// 唯一のコピーかもしれないため、孤立した入力は削除しない。テストでは移動先を注入する。
    func sweep(trash: @Sendable (URL) throws -> URL = { directory in
        var result: NSURL?
        try FileManager.default.trashItem(at: directory, resultingItemURL: &result)
        return result as URL? ?? directory
    }) throws -> [URL] {
        let result = try exclusive {
            var retained: [Entry] = [], recovered: [URL] = [], discarded: [URL] = []
            for entry in try read() {
                let directory = URL(fileURLWithPath: entry.path)
                guard directory.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                      UUID(uuidString: directory.lastPathComponent) != nil ||
                        (entry.discardable == true && directory.lastPathComponent.hasPrefix(WorkAreaName.deleted) &&
                         UUID(uuidString: String(directory.lastPathComponent.dropFirst(WorkAreaName.deleted.count))) != nil)
                else { retained.append(entry); continue }
                var info = stat()
                guard lstat(directory.path, &info) == 0 else {
                    if errno != ENOENT { retained.append(entry) }
                    continue
                }
                guard info.isDirectory, Int64(info.st_dev) == entry.device,
                      info.st_ino == entry.inode else { retained.append(entry); continue }
                let descriptor = open(directory.appendingPathComponent(WorkAreaName.ownerLock).path,
                                      O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                if descriptor < 0 {
                    // 台帳と inode が一致する退避領域で、所有者の lock だけがなければ孤立している。
                    guard errno == ENOENT else { retained.append(entry); continue }
                } else {
                    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                        close(descriptor); retained.append(entry); continue
                    }
                }
                defer { if descriptor >= 0 { close(descriptor) } }
                if entry.discardable == true { retained.append(entry); discarded.append(directory) }
                else {
                    do { recovered.append(try trash(directory)) }
                    catch { retained.append(entry) }
                }
            }
            try save(retained)
            return (recovered, discarded)
        }
        for directory in result.1 { deleteRetired(directory) }
        return result.0
    }

    private func exclusive<T>(_ body: () throws -> T) throws -> T {
        try Self.lock.withLock { _ in
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(fileURL.appendingPathExtension("lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ExtractionFailure.system(errno) }
            defer { close(descriptor) }
            while flock(descriptor, LOCK_EX) != 0 {
                if errno != EINTR { throw ExtractionFailure.system(errno) }
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            return try body()
        }
    }

    private func read() throws -> [Entry] {
        do { return try JSONDecoder().decode([Entry].self, from: Data(contentsOf: fileURL)) }
        catch CocoaError.fileReadNoSuchFile { return [] }
    }
    private func save(_ entries: [Entry]) throws {
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }
}
