import AppKit
import KaitoKit
import Synchronization
import UniformTypeIdentifiers

/// AppKit の weak delegate を registry が保持する。書き込み側は値と actor 参照だけを使う。
@MainActor final class ArchiveFilePromise: NSObject, NSFilePromiseProviderDelegate {
    nonisolated let payload: ArchiveEntryPayload
    nonisolated let session: ArchiveSession
    nonisolated let progress: Progress
    nonisolated let didWrite: (@Sendable (Int) -> Void)?
    nonisolated private let finished: @Sendable () -> Void
    nonisolated private let activeWrites = Mutex(0)
    nonisolated private let extractionQueue = Mutex<ArchivePromiseExtractionQueue?>(nil)
    nonisolated private var promiseQueue: ArchivePromiseExtractionQueue {
        extractionQueue.withLock { queue in
            if let queue { return queue }
            let created = ArchivePromiseExtractionQueue()
            queue = created
            return created
        }
    }
#if DEBUG
    var debugExtractionQueue: ArchivePromiseExtractionQueue { promiseQueue }
#endif
    func useExtractionQueue(_ queue: ArchivePromiseExtractionQueue) { extractionQueue.withLock { $0 = queue } }
    nonisolated var isWriting: Bool { activeWrites.withLock { $0 > 0 } }
    nonisolated private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.shunnag.KaitoFinder.FilePromise"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(payload: ArchiveEntryPayload, session: ArchiveSession,
         progress: Progress = Progress(totalUnitCount: 0), didWrite: (@Sendable (Int) -> Void)? = nil,
         finished: @escaping @Sendable () -> Void = {}) {
        self.payload = payload
        self.session = session
        self.progress = progress
        self.didWrite = didWrite
        self.finished = finished
    }

    static func validatedType(_ candidate: UTType) -> UTType {
        // 組込み folder/data は定義が確定している。拡張子由来の型だけを照会する。
        if candidate == .folder || candidate == .data { return candidate }
        return candidate.conforms(to: .data) || candidate.conforms(to: .directory) ? candidate : .data
    }

    var promisedType: UTType {
        let leaf = (try? ExtractionPath.components(payload.path).last) ?? ""
        let candidate = payload.isDirectory ? UTType.folder :
            (UTType(filenameExtension: (leaf as NSString).pathExtension) ?? .data)
        return Self.validatedType(candidate)
    }

    func makeProvider() throws -> NSFilePromiseProvider {
        _ = try ExtractionPath.components(payload.path)
        let type = promisedType
        // 型サービスが利用できない場合も、AppKit の例外へ渡す前に Swift のエラーにする。
        guard type == .data || type.conforms(to: .data) || type.conforms(to: .directory) else {
            throw ExtractionFailure.refused(String(localized: "展開する項目の型情報を取得できません: \(type.identifier)。"))
        }
        return NSFilePromiseProvider(fileType: type.identifier, delegate: self)
    }

    // 同一プロセスで受信すると、受信側の OperationQueue からこの二つの delegate メソッドが
    // 呼ばれることを実測。main actor に隔離すると @objc thunk の動的隔離検査で trap する。
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (try? ExtractionPath.components(payload.path).last) ?? String(localized: "項目")
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        // OperationQueue は Task の完了を待たない。同じ provider の重なった要求も数える。
        activeWrites.withLock { $0 += 1 }
        // AppKit が渡す completion は非 Sendable。専用の一回限りの箱へ移す。
        let completion = PromiseCompletion(completionHandler)
        let job = ArchivePromiseExtractionQueue.Job(payload: payload, session: session, url: url,
            progress: progress, didWrite: didWrite) { failure in
                completion.call(failure)
                self.activeWrites.withLock { $0 -= 1 }
                self.finished()
            }
        promiseQueue.enqueue(job)
    }
}

/// AppKit の非隔離 callback を一度だけ呼ぶための同期境界。callback 自体はロック外で実行する。
nonisolated private final class PromiseCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?
    init(_ handler: @escaping (Error?) -> Void) { self.handler = handler }
    func call(_ error: (any Error)?) {
        let callback = lock.withLock {
            let callback = handler
            handler = nil
            return callback
        }
        callback?(error)
    }
}

@MainActor final class FilePromiseRegistry {
    static let shared = FilePromiseRegistry(automaticallySweeps: true)
    private struct Record {
        let provider: NSFilePromiseProvider
        let delegate: ArchiveFilePromise
        let owner: UUID?
        var sessionID: Int?
        var deadline: Date?
    }
    private var records: [UUID: Record] = [:]
    private var sessions: [Int: Set<UUID>] = [:]
    private var extractionQueues: [Int: ArchivePromiseExtractionQueue] = [:]
    private var sweepTask: Task<Void, Never>?
    let gracePeriod: TimeInterval = 60
    var count: Int { records.count }
    var sessionCount: Int { sessions.count }
    var hasActiveWrites: Bool { records.values.contains { $0.delegate.isWriting } }
#if DEBUG
    private(set) var sweepCount = 0
    private(set) var sweepWritingCheckCount = 0
#endif

    init(automaticallySweeps: Bool = false) {
        if automaticallySweeps {
            sweepTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard let self else { return }
                    self.sweep()
                }
            }
        }
    }

    deinit { sweepTask?.cancel() }

    func register(payload: ArchiveEntryPayload, session: ArchiveSession, owner: UUID? = nil, now: Date = Date(),
                  didWrite: (@Sendable (Int) -> Void)? = nil) throws
        -> (id: UUID, provider: NSFilePromiseProvider) {
        let id = UUID()
        let delegate = ArchiveFilePromise(payload: payload, session: session, didWrite: didWrite) { [weak self] in
            Task { @MainActor in self?.finishedWriting(id) }
        }
        let provider = try delegate.makeProvider()
        records[id] = Record(provider: provider, delegate: delegate, owner: owner, deadline: now.addingTimeInterval(gracePeriod))
        return (id, provider)
    }

    func beganPending(sessionID: Int, owner: UUID) {
        // 行ごとの register では走査せず、ドラッグ開始時に一度だけ期限切れを回収する。
        sweep()
        began(sessionID: sessionID, promises: records.compactMap { id, record in
            record.owner == owner && record.sessionID == nil ? id : nil
        })
    }

    func began(sessionID: Int, promises: [UUID]) {
        guard promises.contains(where: { records[$0] != nil }) else { return }
        let queue = extractionQueues[sessionID] ?? ArchivePromiseExtractionQueue()
        extractionQueues[sessionID] = queue
        for id in promises where records[id] != nil {
            records[id]?.delegate.useExtractionQueue(queue)
            records[id]?.sessionID = sessionID
            records[id]?.deadline = nil
            sessions[sessionID, default: []].insert(id)
        }
    }

    func ended(sessionID: Int, now: Date = Date()) {
        for id in sessions[sessionID] ?? [] {
            records[id]?.deadline = now.addingTimeInterval(gracePeriod)
        }
    }

    func sweep(now: Date = Date()) {
#if DEBUG
        sweepCount += 1
#endif
        let expired = records.compactMap { id, record -> UUID? in
            guard let deadline = record.deadline, deadline <= now else { return nil }
#if DEBUG
            sweepWritingCheckCount += 1
#endif
            return record.delegate.isWriting ? nil : id
        }
        for id in expired { remove(id) }
    }

    func hasPromises(for session: ArchiveSession) -> Bool {
        records.values.contains { $0.delegate.session === session }
    }

    func cancelActiveWrites() {
        for record in records.values where record.delegate.isWriting {
            record.delegate.progress.cancel()
        }
    }

    func waitUntilNoActiveWrites() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while hasActiveWrites, ContinuousClock.now < deadline, !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        }
    }

    func waitUntilNoPromises(for session: ArchiveSession) async {
        let deadline = ContinuousClock.now + .seconds(gracePeriod + 15)
        while hasPromises(for: session) {
            sweep()
            guard hasPromises(for: session), ContinuousClock.now < deadline, !Task.isCancelled else { return }
            // 自動 sweep がない registry でも期限を回収し、完了 callback の除去も待つ。
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        }
    }

    private func remove(_ id: UUID) {
        guard let record = records.removeValue(forKey: id), let sessionID = record.sessionID else { return }
        sessions[sessionID]?.remove(id)
        if sessions[sessionID]?.isEmpty == true {
            sessions.removeValue(forKey: sessionID)
            extractionQueues.removeValue(forKey: sessionID)
        }
    }

    private func finishedWriting(_ id: UUID) {
        // 完了通知を待つ間に次の要求が始まった場合も、実行中の delegate を保持する。
        guard let record = records[id], !record.delegate.isWriting else { return }
        remove(id)
    }
}

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
                        entries = (try? job.payload.resolve(in: snapshot.entries, generation: snapshot.generation)) ?? []
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
                    reusing: session === job.session ? revision : nil)
                if let replacement = snapshot.reader {
                    reader = replacement
                    session = job.session
                    revision = snapshot.revision
#if DEBUG
                    queue.readerReopenCount.withLock { $0 += 1 }
#endif
                }
                job.progress.kind = .file
                job.progress.setUserInfoObject(Progress.FileOperationKind.copying, forKey: .fileOperationKindKey)
                job.progress.setUserInfoObject(job.url, forKey: .fileURLKey)
#if DEBUG
                queue.processedIndices.withLock { $0 += snapshot.selection.entries.map(\.index) }
#endif
                result = try ExtractionService.extractResolved(snapshot.selection.entries, reader: reader!, to: job.url,
                    quarantine: snapshot.quarantine, progress: job.progress, promisedItem: job.payload, didWrite: job.didWrite)
            }
            try ArchiveCopyOut.check(result)
        }
    }
}
