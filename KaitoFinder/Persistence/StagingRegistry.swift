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
    let root: URL
    private let fileURL: URL
    private struct Entry: Codable {
        let path: String
        let device: Int64
        let inode: UInt64
    }

    init(root: URL) {
        self.root = root
        fileURL = root.deletingLastPathComponent().appendingPathComponent("staging.json")
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
        func remove() { registry.remove(directory) }

        func acquireRead() throws -> ReadLease {
            try reads.withLock {
                guard !$0.retiring else { throw ArchiveEntryPayload.staleSelection }
                $0.count += 1
            }
            return ReadLease(owner: self)
        }

        func removeWhenUnused() async {
            await withCheckedContinuation { continuation in
                let ready = reads.withLock {
                    $0.retiring = true
                    if $0.count == 0 { return true }
                    $0.waiters.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
            remove()
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
                let descriptor = open(directory.appendingPathComponent(".KaitoFinder-owner.lock").path,
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

    private func remove(_ directory: URL) {
        do {
            try exclusive {
                var entries = try read()
                do { try Self.removeSnapshot(directory) }
                catch CocoaError.fileNoSuchFile { }
                entries.removeAll { $0.path == directory.path }
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
        try exclusive {
            var retained: [Entry] = [], recovered: [URL] = []
            for entry in try read() {
                let directory = URL(fileURLWithPath: entry.path)
                guard directory.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
                      UUID(uuidString: directory.lastPathComponent) != nil else { retained.append(entry); continue }
                var info = stat()
                guard lstat(directory.path, &info) == 0 else {
                    if errno != ENOENT { retained.append(entry) }
                    continue
                }
                guard info.st_mode & S_IFMT == S_IFDIR, Int64(info.st_dev) == entry.device,
                      info.st_ino == entry.inode else { retained.append(entry); continue }
                let descriptor = open(directory.appendingPathComponent(".KaitoFinder-owner.lock").path,
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
                do { recovered.append(try trash(directory)) }
                catch { retained.append(entry) }
            }
            try save(retained)
            return recovered
        }
    }

    static func copySnapshot(from source: URL, to target: URL, isDirectory: Bool,
                             progress: Progress = Progress(), allowsClone: Bool = true,
                             didCopy: (@Sendable (Int) -> Void)? = nil) throws {
        try ArchiveImportPlan.checkCancellation(progress)
        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
        var complete = false
        defer { if !complete { try? removeSnapshot(target) } }
        if isDirectory {
            // 子は planner の列挙単位で確保する。ACL・flags は即時追加と同様に格納しない。
            guard mkdir(target.path, 0o700) == 0 else { throw ExtractionFailure.system(errno) }
        } else if info.st_mode & S_IFMT == S_IFLNK {
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            guard symlink(destination, target.path) == 0 else { throw ExtractionFailure.system(errno) }
        } else {
            // schg を複製すると一般ユーザでは解除できない。flag 付き入力は本文だけを運ぶ。
            let cloned = allowsClone && info.st_flags == 0 && clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0
            if !cloned {
                let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard input >= 0 else { throw ExtractionFailure.system(errno) }
                defer { close(input) }
                let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard output >= 0 else { throw ExtractionFailure.system(errno) }
                defer { close(output) }
                var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                while true {
                    try ArchiveImportPlan.checkCancellation(progress)
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else { throw ExtractionFailure.system(errno) }
                    if count == 0 { break }
                    try buffer.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < count {
                            try ArchiveImportPlan.checkCancellation(progress)
                            let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                            if written < 0, errno == EINTR { continue }
                            guard written > 0 else { throw ExtractionFailure.system(written == 0 ? EIO : errno) }
                            offset += written
                        }
                    }
                    didCopy?(count)
                }
            }
        }
        try clearRemovalRestrictions(target)
        try copyExtendedAttributes(from: source, to: target, progress: progress)
        // 所有者は sourceStamp に記録する。実ファイルの所有者や ACL を持ち出さない。
        guard lchmod(target.path, info.st_mode & 0o7777) == 0 else { throw ExtractionFailure.system(errno) }
        var times = [info.st_atimespec, info.st_mtimespec]
        guard utimensat(AT_FDCWD, target.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw ExtractionFailure.system(errno) }
        try ArchiveImportPlan.checkCancellation(progress)
        complete = true
    }

    static func copyExtendedAttributes(from source: URL, to target: URL, progress: Progress,
        setValue: (URL, String, Data) throws -> Void = { url, name, data in
            let status = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            guard status == 0 else { throw ExtractionFailure.system(errno) }
        }) throws {
        let size = listxattr(source.path, nil, 0, XATTR_NOFOLLOW)
        if size < 0, errno == ENOTSUP || errno == EPERM { return }
        guard size >= 0 else { throw ExtractionFailure.system(errno) }
        var names = [CChar](repeating: 0, count: size)
        let count = names.withUnsafeMutableBufferPointer { listxattr(source.path, $0.baseAddress, $0.count, XATTR_NOFOLLOW) }
        guard count >= 0 else { throw ExtractionFailure.system(errno) }
        for bytes in names.prefix(count).split(separator: 0) {
            try ArchiveImportPlan.checkCancellation(progress)
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            do {
                let size = getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { throw ExtractionFailure.system(errno) }
                var data = Data(count: size)
                let count = data.withUnsafeMutableBytes { getxattr(source.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
                guard count >= 0 else { throw ExtractionFailure.system(errno) }
                try setValue(target, name, Data(data.prefix(count)))
            } catch ExtractionFailure.system(let code) where name != ExtractionQuarantine.name
                && [EPERM, EACCES, ENOTSUP, ENOATTR].contains(code) {
                // file provider の保護属性などは即時 writer も格納しない。本文の予約は続ける。
                continue
            }
        }
    }

    static func clearRemovalRestrictions(_ url: URL) throws {
        guard lchflags(url.path, 0) == 0 else { throw ExtractionFailure.system(errno) }
        guard let empty = acl_init(0) else { throw ExtractionFailure.system(errno) }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_link_np(url.path, ACL_TYPE_EXTENDED, empty) != 0, errno != ENOTSUP {
            throw ExtractionFailure.system(errno)
        }
    }

    static func removeSnapshot(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch {
            var info = stat()
            if lstat(url.path, &info) != 0, errno == ENOENT { return }
            // 旧版で作られた退避物も回収する。symlink の宛先には触れない。
            func clear(_ item: URL) throws {
                var info = stat()
                guard lstat(item.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
                try clearRemovalRestrictions(item)
                if info.st_mode & S_IFMT == S_IFDIR {
                    guard chmod(item.path, (info.st_mode & 0o777) | 0o700) == 0 else { throw ExtractionFailure.system(errno) }
                    for child in try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) { try clear(child) }
                }
            }
            try clear(url)
            try FileManager.default.removeItem(at: url)
        }
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

/// AppKit の終了レビューは文書を documents から除いた後に applicationShouldTerminate を呼ぶ。
@MainActor final class DocumentCleanupRegistry {
    static let shared = DocumentCleanupRegistry()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    var hasPendingCleanup: Bool { !tasks.isEmpty }

    func track(_ task: Task<Void, Never>) {
        let id = UUID()
        tasks[id] = task
        Task { await task.value; tasks.removeValue(forKey: id) }
    }

    func waitUntilEmpty() async {
        while let task = tasks.values.first { await task.value; await Task.yield() }
    }
}
