import Darwin
import Foundation
import Synchronization

/// 作成前に記録し、defer が実行されなかった作業領域だけを次回起動時に回収する。
nonisolated final class PendingWorkRegistry: Sendable {
    private static let current = Mutex<PendingWorkRegistry?>(nil)
    static var shared: PendingWorkRegistry {
        get { current.withLock { $0 ?? defaultRegistry } }
        set { current.withLock { $0 = newValue } }
    }

    private static let defaultRegistry = PendingWorkRegistry(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KaitoFinder", isDirectory: true)
        .appendingPathComponent("pending-work.json"))

    private struct Entry: Codable {
        let path: String
        var device: Int64?
        var inode: UInt64?
        var processID: Int32?
    }

    // 同じ台帳を開く別インスタンスも、読み込みから atomic 保存まで直列化する。
    // Mutex はプロセス内、flock は別のアプリプロセスとの更新競合を防ぐ。
    private static let lock = Mutex(())
    private let fileURL: URL

    init(fileURL: URL) { self.fileURL = fileURL }

    func register(_ directory: URL) throws {
        try withExclusiveAccess {
            var entries = try read()
            if !entries.contains(where: { $0.path == directory.path }) {
                entries.append(Entry(path: directory.path, processID: getpid()))
            }
            try save(entries)
        }
    }

    func recordIdentity(_ directory: URL) throws {
        try withExclusiveAccess {
            var info = stat()
            guard lstat(directory.path, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR))
            }
            var entries = try read()
            if let index = entries.firstIndex(where: { $0.path == directory.path }) {
                entries[index].device = Int64(info.st_dev)
                entries[index].inode = info.st_ino
            }
            try save(entries)
        }
    }

    func unregister(_ directory: URL) {
        try? withExclusiveAccess {
            var entries = try read()
            entries.removeAll { $0.path == directory.path }
            try save(entries)
        }
    }

    func sweep() throws -> [URL] {
        try withExclusiveAccess {
            let entries = try read()
            var removed: [URL] = []
            var retained: [Entry] = []
            for entry in entries {
                // 起動時の utility Task より先に新しい作業が登録されることがある。
                // 他の起動中インスタンスも含め、所有プロセスが生きている領域は回収しない。
                // mkdir 前の登録も残し、以後の recordIdentity が台帳から脱落しないようにする。
                if let pid = entry.processID, pid > 0, kill(pid, 0) == 0 || errno == EPERM {
                    retained.append(entry)
                    continue
                }
                let directory = URL(fileURLWithPath: entry.path)
                let name = directory.lastPathComponent
                guard name.hasPrefix(".KaitoFinder-add-") || name.hasPrefix(".KaitoFinder-new-") else { continue }
                var info = stat()
                guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                      entry.device == nil || entry.device == Int64(info.st_dev),
                      entry.inode == nil || entry.inode == info.st_ino else { continue }
                // removeItem は子孫の symlink も辿らず、リンク自身だけを削除する。
                try FileManager.default.removeItem(at: directory)
                removed.append(directory)
            }
            try save(retained)
            return removed
        }
    }

    @discardableResult func startLaunchSweep() -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            do { _ = try self.sweep() }
            catch { NSLog("台帳の回収に失敗しました: %@", String(describing: error)) }
        }
    }

    private func read() throws -> [Entry] {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        // 壊れた台帳は信用せず、次の保存で空の状態から作り直す。
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func withExclusiveAccess<T>(_ body: () throws -> T) throws -> T {
        try Self.lock.withLock { _ in
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // atomic 保存で台帳の inode は変わるため、ロックは別の固定ファイルに持つ。
            let descriptor = open(fileURL.appendingPathExtension("lock").path,
                                  O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { close(descriptor) }
            while flock(descriptor, LOCK_EX) != 0 {
                if errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            return try body()
        }
    }

    private func save(_ entries: [Entry]) throws {
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }
}
