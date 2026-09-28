import Foundation
import Synchronization

/// A stuck syscall cannot be cancelled. Bound the wait and retain at most four outstanding workers;
/// repeat sweeps reuse a stuck root's worker. An incomplete scan must never authorize pruning.
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
        // The type is part of the request key; distinct read-only probe kinds cannot share a result.
        guard let value = try result.get() as? Value else { throw VolumePublishError.validationFailed }
        return value
    }
}
