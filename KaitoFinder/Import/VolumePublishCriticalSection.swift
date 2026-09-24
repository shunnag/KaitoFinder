import Foundation
import Synchronization

nonisolated final class VolumePublishCriticalSection: Sendable {
    static let shared = VolumePublishCriticalSection()
    private struct State {
        var count = 0
        var terminating = false
        var observers: [UUID: @Sendable () -> Void] = [:]
    }
    private let state = Mutex(State())
    var count: Int { state.withLock { $0.count } }

    func observeZero(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        state.withLock { $0.observers[id] = observer }
        return id
    }
    func removeObserver(_ id: UUID) { _ = state.withLock { $0.observers.removeValue(forKey: id) } }

    /// The final quit decision and entry share this mutex, including the no-work terminateNow path.
    func closeIfIdle() -> Bool {
        state.withLock { state in
            guard state.count == 0 else { return false }
            state.terminating = true
            return true
        }
    }
    func enter(checkCancellation: () throws -> Void = {}) throws -> Lease {
        try state.withLock { state in
            guard !state.terminating else { throw CancellationError() }
            state.count += 1
        }
        let lease = Lease(counter: self)
        try checkCancellation()
        return lease
    }
    private func leave() {
        let observers = state.withLock { state -> [@Sendable () -> Void] in
            precondition(state.count > 0)
            state.count -= 1
            return state.count == 0 ? Array(state.observers.values) : []
        }
        for observer in observers { observer() }
    }

    nonisolated final class Lease: @unchecked Sendable {
        private let counter: VolumePublishCriticalSection
        private let activity: NSObjectProtocol
        init(counter: VolumePublishCriticalSection) {
            self.counter = counter
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled,
                .suddenTerminationDisabled, .automaticTerminationDisabled], reason: "Publishing split archive volumes")
        }
        deinit { ProcessInfo.processInfo.endActivity(activity); counter.leave() }
    }
}

/// accessor を保持する間だけ書き込み意図が有効。取得待ちは臨界区間の外で打ち切れる。
nonisolated final class VolumePublishCoordination: @unchecked Sendable {
    typealias Request = @Sendable (NSFileCoordinator, [NSFileAccessIntent], OperationQueue,
                                   @escaping @Sendable ((any Error)?) -> Void) -> Void
    private struct State { var expired = false; var error: (any Error)? }
    private let state = Mutex(State())
    private let acquired = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let coordinator: NSFileCoordinator
    private let queue = OperationQueue()
    private let request: Request?

    init(gate: URL, presenter: (any NSFilePresenter)?, request: Request? = nil) {
        coordinator = NSFileCoordinator(filePresenter: presenter)
        self.request = request
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    func withAccess<T>(gate: URL, additional: [URL] = [], timeout: TimeInterval, body: () throws -> T) throws -> T {
        // Foundation は writing option を一つだけ許す。入口全体の置き換えとして取得する。
        let intents = Set([gate] + additional).map { NSFileAccessIntent.writingIntent(with: $0, options: .forReplacing) }
        let accessor: @Sendable ((any Error)?) -> Void = { [self] error in
            let expired = state.withLock { value in value.error = error; return value.expired }
            acquired.signal()
            if !expired, error == nil { release.wait() }
        }
        if let request { request(coordinator, intents, queue, accessor) }
        else { coordinator.coordinate(with: intents, queue: queue, byAccessor: accessor) }
        guard acquired.wait(timeout: .now() + timeout) == .success else {
            state.withLock { $0.expired = true }
            release.signal()
            coordinator.cancel()
            throw VolumePublishError.coordinationTimedOut
        }
        defer { release.signal() }
        if let error = state.withLock({ $0.error }) { throw error }
        return try body()
    }
}
