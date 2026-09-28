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
        let leaf = (try? ExtractionPath.components(payload.path, syntax: .init(session.format)).last) ?? ""
        let candidate = payload.isDirectory ? UTType.folder :
            (UTType(filenameExtension: (leaf as NSString).pathExtension) ?? .data)
        return Self.validatedType(candidate)
    }

    func makeProvider() throws -> NSFilePromiseProvider {
        _ = try ExtractionPath.components(payload.path, syntax: .init(session.format))
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
        (try? ExtractionPath.components(payload.path, syntax: .init(session.format)).last) ?? String(localized: "項目")
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
