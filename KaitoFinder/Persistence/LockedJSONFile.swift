import Darwin
import Foundation
import Synchronization

/// JSON 配列を一つの file に持つ台帳。読み書きは `withExclusiveAccess` の中で行い、
/// Mutex がプロセス内、flock が別プロセスとの更新競合を防ぐ。壊れた台帳の扱いは `corruptPolicy` で決める。
nonisolated struct LockedJSONFile<Entry: Codable>: Sendable {
    enum CorruptLedgerPolicy: Sendable {
        case resetToEmpty, fail
    }

    let fileURL: URL
    let corruptPolicy: CorruptLedgerPolicy

    func withExclusiveAccess<T>(mutex: borrowing Mutex<Void>, _ body: () throws -> T) throws -> T {
        try mutex.withLock { _ in
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // atomic 保存で台帳の inode は変わるため、ロックは別の固定ファイルに持つ。
            let descriptor = open(fileURL.appendingPathExtension("lock").path,
                                  O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ExtractionFailure.system(errno) }
            defer { close(descriptor) }
            while flock(descriptor, LOCK_EX) != 0 {
                if errno != EINTR { throw ExtractionFailure.system(errno) }
            }
            defer { _ = flock(descriptor, LOCK_UN) }
            return try body()
        }
    }

    func read() throws -> [Entry] {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch CocoaError.fileReadNoSuchFile { return [] }
        switch corruptPolicy {
        case .resetToEmpty:
            // 壊れた台帳は信用せず、次の保存で空の状態から作り直す。
            return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
        case .fail:
            return try JSONDecoder().decode([Entry].self, from: data)
        }
    }

    func save(_ entries: [Entry]) throws {
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }
}
