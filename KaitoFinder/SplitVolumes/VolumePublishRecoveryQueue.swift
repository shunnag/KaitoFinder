import Foundation
import Synchronization

/// Mount I/O never occupies a Swift cooperative-pool thread. Only pending notifications share a job.
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

    func recover(stagings: [URL], index: RecoverableWorkIndex,
                 metadataStore: ArchiveVolumeMetadataStore = .shared) async -> [VolumePublishRecovery.Result] {
        await withCheckedContinuation { continuation in
            queue.async {
                let recovery = VolumePublishRecovery(index: index, metadataStore: metadataStore)
                continuation.resume(returning: stagings.map { recovery.recover(staging: $0) })
            }
        }
    }

    private func drain() {
        while let next = state.withLock({ state -> (Key, Job)? in
            guard let key = state.order.first else { state.running = false; return nil }
            state.order.removeFirst()
            return (key, state.jobs.removeValue(forKey: key)!)
        }) {
            // Removing before perform lets a trigger during the running job queue one more pass.
            perform(next.1.index, next.0.mount)
            for completion in next.1.completions { completion() }
        }
    }
}
