import Foundation
import KaitoKit
import Synchronization

// 最大4並列。同じ solid group は直列に流し、worker の reader と復号状態を引き継ぐ。
nonisolated final class ArchivePromiseExtractionQueue: Sendable {
    struct Job: Sendable {
        let payload: ArchiveEntryPayload
        let session: ArchiveSession
        let url: URL
        let progress: Progress
        let didWrite: (@Sendable (Int) -> Void)?
        let completion: @Sendable ((any Error)?) -> Void
    }
    private let scheduler = Scheduler()
#if DEBUG
    let readerReopenCount = Mutex(0)
    let activeCount = Mutex(0)
    let maximumActiveCount = Mutex(0)
    let processedIndices = Mutex<[Int]>([])
#endif

    func enqueue(_ job: Job) {
        Task { await scheduler.enqueue(job, queue: self) }
    }

    private actor Scheduler {
        private enum Resource: Hashable {
            case solid(ObjectIdentifier, Int)
            case progress(ObjectIdentifier)
        }
        private struct ScheduledJob {
            let job: Job
            let resources: Set<Resource>
            let order: Int
            let sequence: Int
        }
        private struct Slot {
            let worker = Worker()
            var resources = Set<Resource>()
            var solidGroups = Set<Resource>()
            var busy = false
        }
        private var slots = (0..<4).map { _ in Slot() }
        private var incoming: [Job] = []
        private var pending: [ScheduledJob] = []
        private var sequence = 0
        private var scheduling = false

        func enqueue(_ job: Job, queue: ArchivePromiseExtractionQueue) {
            incoming.append(job)
            startScheduling(queue, coalescing: true)
        }

        private func startScheduling(_ queue: ArchivePromiseExtractionQueue, coalescing: Bool = false) {
            guard !scheduling else { return }
            scheduling = true
            Task {
                // AppKit の行ごとの callback をまとめ、到着済みの行をアーカイブ順に流す。
                if coalescing { try? await Task.sleep(for: .milliseconds(10)) }
                await schedule(queue)
            }
        }

        private func schedule(_ queue: ArchivePromiseExtractionQueue) async {
            while !incoming.isEmpty {
                let jobs = incoming
                incoming.removeAll(keepingCapacity: true)
                for job in jobs {
                    let entries: [ArchiveEntry]
                    if job.session.usesPendingReading || job.payload.revision != nil {
                        entries = (try? job.session.pendingReadSnapshot?.resolve(job.payload)) ?? []
                    } else {
                        let snapshot = await job.session.snapshot()
                        entries = (try? job.payload.resolve(in: snapshot.entries, generation: snapshot.generation, syntax: .init(job.session.format))) ?? []
                    }
                    // 分類後も、実行直前の resolve で世代・暗号・原本の同一性を再検証する。
                    var resources = Set(entries.filter { $0.solidGroup >= 0 }.map {
                        Resource.solid(ObjectIdentifier(job.session), $0.solidGroup)
                    })
                    // 同じ provider の再要求は進捗を共有するため、独立した行とは区別する。
                    resources.insert(.progress(ObjectIdentifier(job.progress)))
                    pending.append(.init(job: job, resources: resources,
                        order: entries.map(\.index).min() ?? job.payload.entryIndex ?? Int.max, sequence: sequence))
                    sequence += 1
                }
            }
            pending.sort { $0.order == $1.order ? $0.sequence < $1.sequence : $0.order < $1.order }
            while slots.contains(where: { !$0.busy }) {
                let occupied = slots.filter(\.busy).reduce(into: Set<Resource>()) { $0.formUnion($1.resources) }
                var assignment: (job: Int, slot: Int)?
                for next in pending.indices where pending[next].resources.isDisjoint(with: occupied) {
                    let matching = slots.indices.filter { !slots[$0].solidGroups.isDisjoint(with: pending[next].resources) }
                    // 遅れて届く同じ group も元の reader へ戻し、新しい group は空き worker へ分散する。
                    let candidates = matching.isEmpty ? slots.indices.sorted {
                        slots[$0].solidGroups.count < slots[$1].solidGroups.count
                    } : matching
                    if let slot = candidates.first(where: { !slots[$0].busy }) {
                        assignment = (next, slot)
                        break
                    }
                }
                guard let (next, slot) = assignment else { break }
                let scheduled = pending.remove(at: next), job = scheduled.job
                slots[slot].busy = true
                slots[slot].resources = scheduled.resources
                slots[slot].solidGroups.formUnion(scheduled.resources.filter {
                    if case .solid = $0 { return true }
                    return false
                })
                let worker = slots[slot].worker
                Task.detached {
#if DEBUG
                    let active = queue.activeCount.withLock { $0 += 1; return $0 }
                    queue.maximumActiveCount.withLock { $0 = max($0, active) }
#endif
                    var failure: (any Error)?
                    do { try await worker.extract(job, queue: queue) }
                    catch { failure = error }
#if DEBUG
                    queue.activeCount.withLock { $0 -= 1 }
#endif
                    job.completion(failure)
                    await self.finished(slot, queue: queue)
                }
            }
            scheduling = false
        }

        private func finished(_ slot: Int, queue: ArchivePromiseExtractionQueue) {
            slots[slot].busy = false
            startScheduling(queue)
        }
    }

    private actor Worker {
        private var reader: ArchiveReader?
        private var session: ArchiveSession?
        private var revision: ArchiveSession.ReadRevision?

        func extract(_ job: Job, queue: ArchivePromiseExtractionQueue) async throws {
            try ArchiveImportPlan.checkCancellation(job.progress)
            let result: ExtractionResult
            if job.session.usesPendingReading || job.payload.revision != nil {
                result = try await ExtractionService.extract([job.payload], from: job.session, to: job.url,
                    progress: job.progress, promisedItem: job.payload, didWrite: job.didWrite)
            } else {
                let snapshot = try await job.session.resolveForPromiseExtraction([job.payload],
                    reusing: session === job.session ? revision : nil, progress: job.progress)
                if let replacement = snapshot.reader {
                    reader = replacement
                    session = job.session
                    revision = snapshot.revision
#if DEBUG
                    queue.readerReopenCount.withLock { $0 += 1 }
#endif
                }
                job.progress.beginFileCopy(to: job.url)
#if DEBUG
                queue.processedIndices.withLock { $0 += snapshot.selection.entries.map(\.index) }
#endif
                result = try ExtractionService.extractResolved(snapshot.selection.entries, reader: reader!, to: job.url,
                    quarantine: snapshot.quarantine, progress: job.progress, promisedItem: job.payload, didWrite: job.didWrite,
                    powerPolicy: job.session.writerOptions(job.session.passwordFormat ?? .zip).powerPolicy)
            }
            try ArchiveCopyOut.check(result)
        }
    }
}
