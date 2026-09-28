import AppKit

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
