import AppKit
import Synchronization

final class ArchiveDocument: NSDocument {
    // NSDocument の読み込みは非隔離なので、actor 参照の受け渡しだけをロックする。
    nonisolated private let sessionStorage = Mutex<ArchiveSession?>(nil)
    var session: ArchiveSession? { sessionStorage.withLock { $0 } }
    var generation: UInt64 { session?.generation ?? 0 }
    private var loadingTask: Task<Void, Never>?
    private var materialization: ArchiveMaterializationController?
    private(set) var materializationCleanup: Task<Void, Never>?
    let archiveUndoStack: ArchiveUndoStack
    private var appendTask: Task<ArchiveImportResult, any Error>?
    private var appendProgress: Progress?
    private(set) var undoTask: Task<Void, Never>?
    private(set) var undoCleanup: Task<Void, Never>?
    private(set) var undoFailure: (any Error)?
    private var closed = false
    private var repairingUndoRegistration = false
    private var undoActions: [UUID: UndoAction] = [:]

    private final class UndoAction {
        let id: UUID
        init(id: UUID) { self.id = id }
    }

    override convenience init() { self.init(undoStack: ArchiveUndoStack()) }

    init(undoStack: ArchiveUndoStack) {
        archiveUndoStack = undoStack
        super.init()
        hasUndoManager = true
        let manager = ArchiveUndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 10
        undoManager = manager
    }

    var canUndoNextMutation: Bool { archiveUndoStack.canUndoNextMutation }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        // 書き換えは即ディスクへ公開済み。保存不能な文書に未保存状態を作らない。
    }

    func materializationController(
        temporaryDirectory: ExtractionTemporaryDirectory = ExtractionTemporaryDirectory()
    ) -> ArchiveMaterializationController? {
        guard let session else { return nil }
        if let materialization { return materialization }
        let controller = ArchiveMaterializationController(session: session, temporaryDirectory: temporaryDirectory)
        materialization = controller
        return controller
    }

    private func disposeMaterialization() {
        guard let materialization else { return }
        let previous = materializationCleanup
        let current = materialization.close()
        materializationCleanup = Task {
            await previous?.value
            await current.value
        }
        self.materialization = nil
    }

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
            guard !Task.isCancelled, let self else { return }
            controller?.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation,
                                materializationController: self.materializationController())
        }
    }

    func append(urls: [URL], to folder: String, progress: Progress,
                willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveImportResult {
        guard !closed, let session else { throw ExtractionFailure.refused("書庫が閉じられています") }
        guard appendTask == nil, undoTask == nil else { throw ExtractionFailure.refused("書庫を変更しています") }
        let previousGeneration = session.generation
        let stack = archiveUndoStack
        let pending = Mutex<ArchiveUndoStack.Slot?>(nil)
        let task = Task {
            do {
                let result = try await session.append(urls: urls, to: folder, progress: progress, willPublish: {
                    // updater が書き換えるのは作業コピー。退避するのは公開直前の原本だけ。
                    let slot = try stack.capture(session.sourceURL)
                    pending.withLock { $0 = slot }
                    try willPublish?()
                })
                await stack.finishMutation(pending.withLock { $0 }, published: !result.addedPaths.isEmpty)
                return result
            } catch {
                await stack.finishMutation(pending.withLock { $0 }, published: false)
                throw error
            }
        }
        appendTask = task
        appendProgress = progress
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        defer {
            appendTask = nil
            appendProgress = nil
            (undoManager as? ArchiveUndoManager)?.isSuspended = closed
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                progress.cancel()
                task.cancel()
            }
            if !closed, !result.addedPaths.isEmpty { synchronizeUndoActions(registerNew: true) }
            if session.generation != previousGeneration { await displayAfterMutation() }
            return result
        } catch {
            if session.generation != previousGeneration { await displayAfterMutation() }
            throw error
        }
    }

    private func synchronizeUndoActions(registerNew: Bool = false) {
        let slots = archiveUndoStack.slots
        let retained = Set(slots.map(\.id))
        for (id, action) in undoActions where !retained.contains(id) {
            undoManager?.removeAllActions(withTarget: action)
            undoActions.removeValue(forKey: id)
        }
        if registerNew {
            for slot in slots where undoActions[slot.id] == nil {
                let action = UndoAction(id: slot.id)
                undoActions[slot.id] = action
                registerUndo(action)
            }
        }
    }

    private func registerUndo(_ action: UndoAction) {
        guard let undoManager else { return }
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: action) { [weak self] action in self?.restore(action) }
        undoManager.setActionName("追加")
        if grouping { undoManager.endUndoGrouping() }
    }

    private func restore(_ action: UndoAction) {
        guard !closed, let session, let manager = undoManager as? ArchiveUndoManager else { return }
        // isUndoing / isRedoing が立っている同期呼び出し中に逆操作を登録する必要がある。
        registerUndo(action)
        if repairingUndoRegistration { return }
        let wasUndo = manager.isUndoing
        let previousGeneration = session.generation
        manager.isSuspended = true
        undoFailure = nil
        undoTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.undoTask = nil
                manager.isSuspended = self.closed
            }
            do {
                try await session.restoreUndoSlot(action.id, from: self.archiveUndoStack)
            } catch {
                self.undoFailure = error
                if !self.closed, session.generation == previousGeneration {
                    // 置換前の失敗なら byte は不変。進んだ NSUndoManager の位置だけを戻す。
                    self.repairingUndoRegistration = true
                    manager.isSuspended = false
                    if wasUndo { manager.redo() } else { manager.undo() }
                    manager.isSuspended = true
                    self.repairingUndoRegistration = false
                }
                if !self.closed, !self.windowControllers.isEmpty { self.presentError(error) }
            }
            if !self.closed { self.synchronizeUndoActions() }
            if session.generation != previousGeneration { await self.displayAfterMutation() }
        }
    }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = undoManager?.undoMenuItemTitle ?? "取り消す"
            return undoManager?.canUndo == true
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = undoManager?.redoMenuItemTitle ?? "やり直す"
            return undoManager?.canRedo == true
        default: return super.validateUserInterfaceItem(item)
        }
    }

    func reloadAfterMutation() async throws {
        guard let session else { return }
        disposeMaterialization()
        try await session.reloadAfterMutation()
        await displayAfterMutation()
    }

    private func displayAfterMutation() async {
        guard let session else { return }
        disposeMaterialization()
        let snapshot = await session.snapshot()
        for controller in windowControllers.compactMap({ $0 as? ArchiveWindowController }) {
            controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation,
                               materializationController: materializationController())
        }
    }

    override func close() {
        closed = true
        disposeMaterialization()
        disposeUndoStack()
        for controller in windowControllers.compactMap({ $0 as? ArchiveWindowController }) {
            controller.cancelExtraction()
        }
        loadingTask?.cancel()
        loadingTask = nil
        sessionStorage.withLock { $0 = nil }
        super.close()
    }

    private func disposeUndoStack() {
        undoManager?.removeAllActions()
        undoActions.removeAll()
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        appendProgress?.cancel()
        appendTask?.cancel()
        undoTask?.cancel()
        let append = appendTask
        let undo = undoTask
        let previous = undoCleanup
        let stack = archiveUndoStack
        undoCleanup = Task {
            // 公開・置換の後始末を待ち、動作中のスロットを削除しない。
            await previous?.value
            _ = await append?.result
            await undo?.value
            await stack.dispose()
        }
    }
}
