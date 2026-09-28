import Foundation
import Synchronization

/// 止まった syscall は取り消せない。待ち時間に上限を設け、終わっていない worker は最大 4 つまで持つ。
/// 同じ root を再び調べるときは止まっている worker を使い回す。不完全な走査を、索引の項目を刈り込む根拠にしない。
nonisolated enum VolumePublishMountProbe {
    private struct Key: Hashable { let root: URL; let valueType: ObjectIdentifier }
    private final class Request: Sendable {
        let result = Mutex<Result<any Sendable, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
    }
    private static let pending = Mutex<[Key: Request]>([:])

    static func run<Value: Sendable>(root: URL, timeout: TimeInterval = 1,
                    probe: @escaping @Sendable () throws -> Value) throws -> Value {
        let key = Key(root: root, valueType: ObjectIdentifier(Value.self))
        let (request, start) = try pending.withLock { state in
            if let existing = state[key] { return (existing, false) }
            guard state.count < 4 else { throw VolumePublishError.system(ETIMEDOUT) }
            let request = Request()
            state[key] = request
            return (request, true)
        }
        if start {
            Thread.detachNewThread {
                let result: Result<any Sendable, any Error> = Result { try probe() }
                request.result.withLock { $0 = result }
                request.finished.signal()
                _ = pending.withLock { $0.removeValue(forKey: key) }
            }
        }
        if request.result.withLock({ $0 == nil }) { _ = request.finished.wait(timeout: .now() + timeout) }
        guard let result = request.result.withLock({ $0 }) else { throw VolumePublishError.system(ETIMEDOUT) }
        // 型は要求の鍵の一部。読み取りだけの別種の probe が結果を共有することはない。
        guard let value = try result.get() as? Value else { throw VolumePublishError.validationFailed }
        return value
    }
}
