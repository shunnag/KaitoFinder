import AppKit
import Synchronization

final class ArchiveDocument: NSDocument {
    // NSDocument の読み込みは非隔離なので、actor 参照の受け渡しだけをロックする。
    nonisolated private let sessionStorage = Mutex<ArchiveSession?>(nil)
    var session: ArchiveSession? { sessionStorage.withLock { $0 } }
    private var loadingTask: Task<Void, Never>?

    nonisolated override class var autosavesInPlace: Bool { false }
    nonisolated override class var preservesVersions: Bool { false }
    nonisolated override var isEntireFileLoaded: Bool { false }

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
            let entries = await session.entries()
            guard !Task.isCancelled, self != nil else { return }
            controller?.display(EntryNode.tree(from: entries))
        }
    }

    override func close() {
        loadingTask?.cancel()
        loadingTask = nil
        sessionStorage.withLock { $0 = nil }
        super.close()
    }
}
