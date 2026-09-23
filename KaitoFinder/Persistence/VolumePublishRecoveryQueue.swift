import Foundation
import Synchronization

/// Mount I/O never occupies a Swift cooperative-pool thread. Repeated notifications share one job.
nonisolated final class VolumePublishRecoveryQueue: Sendable {
    static let shared = VolumePublishRecoveryQueue()
    private struct Key: Hashable { let index: URL; let mount: URL? }
    private struct Job {
        let index: RecoverableWorkIndex
        var completions: [@Sendable () -> Void]
    }
    private struct State {
        var running = false
        var order: [Key] = []
        var jobs: [Key: Job] = [:]
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "com.shunnag.KaitoFinder.volume-recovery", qos: .utility)
    private let perform: @Sendable (RecoverableWorkIndex, URL?) -> Void

    init(perform: @escaping @Sendable (RecoverableWorkIndex, URL?) -> Void = { index, mount in
        _ = VolumePublishRecovery(index: index).recoverAll(mountedVolume: mount)
    }) { self.perform = perform }

    func schedule(index: RecoverableWorkIndex, mountedVolume: URL? = nil, completion: @escaping @Sendable () -> Void = {}) {
        let key = Key(index: index.fileURL, mount: mountedVolume)
        let start = state.withLock { state in
            if state.jobs[key] == nil {
                state.jobs[key] = Job(index: index, completions: [])
                state.order.append(key)
            }
            state.jobs[key]!.completions.append(completion)
            guard !state.running else { return false }
            state.running = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    func recover(index: RecoverableWorkIndex) async {
        await withCheckedContinuation { continuation in
            schedule(index: index) { continuation.resume() }
        }
    }

    private func drain() {
        while let next = state.withLock({ state -> (Key, RecoverableWorkIndex)? in
            guard let key = state.order.first else { state.running = false; return nil }
            return (key, state.jobs[key]!.index)
        }) {
            perform(next.1, next.0.mount)
            let completions = state.withLock { state in
                state.order.removeFirst()
                return state.jobs.removeValue(forKey: next.0)!.completions
            }
            for completion in completions { completion() }
        }
    }
}
