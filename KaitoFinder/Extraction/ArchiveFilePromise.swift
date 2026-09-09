import AppKit
import Synchronization
import UniformTypeIdentifiers

/// AppKit の weak delegate を registry が保持する。書き込み側は値と actor 参照だけを使う。
@MainActor final class ArchiveFilePromise: NSObject, NSFilePromiseProviderDelegate {
    nonisolated let payload: ArchiveEntryPayload
    nonisolated let session: ArchiveSession
    nonisolated let progress: Progress
    nonisolated private let finished: @Sendable () -> Void
    nonisolated private let state = Mutex(false)
    nonisolated var isWriting: Bool { state.withLock { $0 } }
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.shunnag.KaitoFinder.FilePromise"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(payload: ArchiveEntryPayload, session: ArchiveSession,
         progress: Progress = Progress(totalUnitCount: 0), finished: @escaping @Sendable () -> Void = {}) {
        self.payload = payload
        self.session = session
        self.progress = progress
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
            throw ExtractionFailure.refused("取り出す項目の型情報を取得できません: \(type.identifier)")
        }
        return NSFilePromiseProvider(fileType: type.identifier, delegate: self)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (try? ExtractionPath.components(payload.path).last) ?? "item"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        state.withLock { $0 = true }
        // AppKit が渡す completion は非 Sendable。専用の一回限りの箱へ移す。
        let completion = PromiseCompletion(completionHandler)
        let payload = payload, session = session, progress = progress, finished = finished
        Task.detached {
            var failure: (any Error)?
            do {
                let result = try await ExtractionService.extract([payload], from: session, to: url,
                    progress: progress, promisedItem: payload)
                try ArchiveCopyOut.check(result)
            } catch { failure = error }
            completion.call(failure)
            self.state.withLock { $0 = false }
            finished()
        }
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
    private var sweepTask: Task<Void, Never>?
    let gracePeriod: TimeInterval = 60
    var count: Int { records.count }
    var sessionCount: Int { sessions.count }

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

    func register(payload: ArchiveEntryPayload, session: ArchiveSession, owner: UUID? = nil, now: Date = Date()) throws
        -> (id: UUID, provider: NSFilePromiseProvider) {
        sweep(now: now)
        let id = UUID()
        let delegate = ArchiveFilePromise(payload: payload, session: session) { [weak self] in
            Task { @MainActor in self?.remove(id) }
        }
        let provider = try delegate.makeProvider()
        records[id] = Record(provider: provider, delegate: delegate, owner: owner, deadline: now.addingTimeInterval(gracePeriod))
        return (id, provider)
    }

    func beganPending(sessionID: Int, owner: UUID) {
        began(sessionID: sessionID, promises: records.compactMap { id, record in
            record.owner == owner && record.sessionID == nil ? id : nil
        })
    }

    func began(sessionID: Int, promises: [UUID]) {
        for id in promises where records[id] != nil {
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
        let expired = records.compactMap { id, record in
            !record.delegate.isWriting && record.deadline.map { $0 <= now } == true ? id : nil
        }
        for id in expired { remove(id) }
    }

    private func remove(_ id: UUID) {
        guard let record = records.removeValue(forKey: id), let sessionID = record.sessionID else { return }
        sessions[sessionID]?.remove(id)
        if sessions[sessionID]?.isEmpty == true { sessions.removeValue(forKey: sessionID) }
    }
}
