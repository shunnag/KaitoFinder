import AppKit
import Synchronization

final class ArchiveDocument: NSDocument {
    // NSDocument の読み込みは非隔離なので、actor 参照の受け渡しだけをロックする。
    nonisolated private let sessionStorage = Mutex<ArchiveSession?>(nil)
    var session: ArchiveSession? { sessionStorage.withLock { $0 } }
    var generation: UInt64 { session?.generation ?? 0 }
    private var loadingTask: Task<Void, Never>?

    nonisolated override class var autosavesInPlace: Bool { false }
    nonisolated override class var preservesVersions: Bool { false }
    nonisolated override var isEntireFileLoaded: Bool { false }

    nonisolated override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        // read は非隔離で sessionStorage だけを更新する。AppKit の並行読み込みを許可する。
        true
    }

    nonisolated override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        []
    }

    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        // super は NSFileWrapper 経由で全体を読み込むため呼ばない。
        let session = try ArchiveSession(url: url)
        sessionStorage.withLock { $0 = session }
    }

    override func makeWindowControllers() {
        let controller = ArchiveWindowController()
        addWindowController(controller)
        guard let session else { return }
        loadingTask = Task { [weak self, weak controller] in
            let snapshot = await session.snapshot()
            guard !Task.isCancelled, self != nil else { return }
            controller?.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
        }
    }

    func reloadAfterMutation() async throws {
        guard let session else { return }
        try await session.reloadAfterMutation()
        let snapshot = await session.snapshot()
        for controller in windowControllers.compactMap({ $0 as? ArchiveWindowController }) {
            controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
        }
    }

    override func close() {
        for controller in windowControllers.compactMap({ $0 as? ArchiveWindowController }) {
            controller.cancelExtraction()
        }
        loadingTask?.cancel()
        loadingTask = nil
        sessionStorage.withLock { $0 = nil }
        super.close()
    }
}
