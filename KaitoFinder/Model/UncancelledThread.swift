import Foundation
import Synchronization

/// DispatchQueue.sync は同じ thread で実行しうる。別 thread で Task の取消状態を切り離す。
nonisolated enum UncancelledThread {
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let result = Mutex<Result<T, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let value = Result { try body() }
            result.withLock { $0 = value }
            finished.signal()
        }
        finished.wait()
        return try result.withLock { $0! }.get()
    }
}
