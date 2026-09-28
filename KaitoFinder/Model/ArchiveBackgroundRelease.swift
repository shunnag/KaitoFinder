import Foundation
import Synchronization

nonisolated enum ArchiveBackgroundRelease {
    // 最後の参照を先に actor から外し、解放 Task との競争で main に破棄を戻さない。
    static func release<Value: Sendable>(_ value: inout Value?) {
        let retired = Mutex(value)
        value = nil
        Task.detached { retired.withLock { $0 = nil } }
    }
}
