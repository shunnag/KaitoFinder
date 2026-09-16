import AppKit
import GyoshukuKit
import KaitoKit
import Synchronization

@MainActor final class ArchiveDocument: NSDocument {
    // NSDocument の読み込みは非隔離なので、actor 参照の受け渡しだけをロックする。
    nonisolated private enum Contents: Sendable {
        case empty, locked(URL), open(ArchiveSession), closed
    }
    nonisolated private let contentsStorage = Mutex<Contents>(.empty)
    // セッションが文書を保持せずに、通知で更新した設定だけを worker から読めるようにする。
    nonisolated private final class PreferencesSnapshot: Sendable {
        let value: Mutex<ArchivePreferences>
        init(_ preferences: ArchivePreferences) { value = Mutex(preferences) }
    }
    nonisolated private let preferencesSnapshot: PreferencesSnapshot
    private let preferencesStore: ArchivePreferencesStore
    nonisolated private var sessionWriterOptions: @Sendable (GyoshukuKit.ArchiveFormat) -> WriterOptions {
        { [preferencesSnapshot] format in preferencesSnapshot.value.withLock { $0.writerOptions(for: format) } }
    }
    nonisolated private var sessionImportOptions: @Sendable () -> ArchiveImportPlan.Options {
        { [preferencesSnapshot] in preferencesSnapshot.value.withLock { $0.importOptions } }
    }
    var session: ArchiveSession? {
        contentsStorage.withLock { if case .open(let session) = $0 { session } else { nil } }
    }
    var lockedURL: URL? {
        contentsStorage.withLock { if case .locked(let url) = $0 { url } else { nil } }
    }
    var isPasswordLocked: Bool { lockedURL != nil }
    private(set) var sessionCleanup: Task<Void, Never>?
    var generation: UInt64 { session?.generation ?? 0 }
    private var loadingTask: Task<Void, Never>?
    private var materialization: ArchiveMaterializationController?
    private(set) var materializationCleanup: Task<Void, Never>?
    private(set) var archiveUndoStack: ArchiveUndoStack
    let passwordVault: ArchivePasswordVault
    private var rememberedPayloadPassword: String?
    private var mutationTask: Task<Void, Never>?
    private var mutationProgress: Progress?
    private var cancelMutation: (() -> Void)?
    private(set) var undoTask: Task<Void, Never>?
    private(set) var undoCleanup: Task<Void, Never>?
    private(set) var undoFailure: (any Error)?
    private var closed = false
    private var switchingBackingFile = false
    private var repairingUndoRegistration = false
    private var undoActions: [UUID: UndoAction] = [:]

    private final class UndoAction {
        let id: UUID
        let name: String
        init(id: UUID, name: String) { self.id = id; self.name = name }
    }

    override convenience init() { self.init(undoStack: ArchiveUndoStack()) }

    convenience init(passwordVault: ArchivePasswordVault) {
        self.init(undoStack: ArchiveUndoStack(), passwordVault: passwordVault)
    }

    init(undoStack: ArchiveUndoStack, passwordVault: ArchivePasswordVault = .shared,
         preferencesStore: ArchivePreferencesStore = .shared) {
        archiveUndoStack = undoStack
        self.passwordVault = passwordVault
        self.preferencesStore = preferencesStore
        preferencesSnapshot = PreferencesSnapshot(preferencesStore.preferences)
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)),
                                               name: ArchivePreferencesStore.didChange, object: preferencesStore)
        hasUndoManager = true
        let manager = ArchiveUndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = 10
        undoManager = manager
    }

    @objc private func preferencesDidChange(_ notification: Notification) {
        let preferences = preferencesStore.preferences
        preferencesSnapshot.value.withLock { $0 = preferences }
    }

    var canUndoNextMutation: Bool {
        guard let sourceURL = session?.sourceURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let size = attributes[.size] as? NSNumber else {
            return archiveUndoStack.canUndoNextMutation
        }
        return archiveUndoStack.canUndoNextMutation(archiveSize: size.uint64Value)
    }

    var hasWorkInFlight: Bool {
        mutationTask != nil || undoTask != nil || switchingBackingFile
            || windowControllers.contains { ($0 as? ArchiveWindowController)?.hasWorkInFlight == true }
    }

    var needsTerminationCleanup: Bool { hasWorkInFlight || !archiveUndoStack.slots.isEmpty }

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
        // 実測(2026-09-15): 並行読み込みを許すと AppKit が @MainActor の initializer を
        // "NSDocumentController Opening" queue で呼び、EXC_BREAKPOINT で落ちる。
        // read(from:ofType:) は非隔離のままでよいが、文書の生成は main actor で行う。
        false
    }

    nonisolated override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        []
    }

    nonisolated override func read(from url: URL, ofType typeName: String) throws {
        // super は NSFileWrapper 経由で全体を読み込むため呼ばない。
        let contents: Contents
        do { contents = .open(try ArchiveSession(url: url, writerOptions: sessionWriterOptions, importOptions: sessionImportOptions)) }
        catch KaitoError.passwordRequired {
            // AppKit の並行 read では UI を出せない。URL だけを渡し、window 側で解除する。
            contents = .locked(url)
        } catch let error as CancellationError { throw error }
        catch {
            throw NSError(domain: "com.shunnag.KaitoFinder.document", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "アーカイブを開けませんでした"),
                NSLocalizedFailureReasonErrorKey: ArchiveAlertText.informativeText(ArchiveErrorText.describe(error)),
                NSUnderlyingErrorKey: error as NSError
            ])
        }
        let installed = contentsStorage.withLock { state in
            if case .closed = state { return false }
            state = contents
            return true
        }
        if !installed, case .open(let session) = contents { Task { await session.close() } }
    }

    func unlockUsingRememberedPassword() async throws -> Bool {
        guard let url = lockedURL else { return false }
        let key = ArchivePasswordVault.Key.file(url)
        guard let password = await passwordVault.password(for: key) else { return false }
        do {
            try await unlock(password: password)
            return true
        } catch {
            guard ArchivePasswordChallenge(error) != nil else { throw error }
            await passwordVault.remove(for: key, matching: password)
            return false
        }
    }

    func unlock(password: String, remember: Bool = false, vaultGeneration: UInt64? = nil) async throws {
        guard !closed, let url = lockedURL else { throw CancellationError() }
        let opened = try await Self.openArchive(url, password: password, writerOptions: sessionWriterOptions,
                                                importOptions: sessionImportOptions)
        guard !closed, !Task.isCancelled, lockedURL == url else {
            await opened.close()
            throw CancellationError()
        }
        contentsStorage.withLock { $0 = .open(opened) }
        if remember {
            await passwordVault.save(password, for: .file(url), generation: vaultGeneration)
        }
        await displayAfterMutation()
    }

    func password(for session: ArchiveSession, challenge: ArchivePasswordChallenge,
                  request: () async throws -> ArchivePasswordResponse) async throws -> String {
        try checkPasswordRequest(session, generation: session.generation)
        let expectedGeneration = session.generation
        let key = ArchivePasswordVault.Key.file(session.sourceURL)
        if challenge == .incorrect, let previous = rememberedPayloadPassword {
            await passwordVault.remove(for: key, matching: previous)
            rememberedPayloadPassword = nil
        }
        if challenge == .required, let stored = await passwordVault.password(for: key) {
            try checkPasswordRequest(session, generation: expectedGeneration)
            rememberedPayloadPassword = stored
            return stored
        }
        let vaultGeneration = await passwordVault.generation()
        let response = try await request()
        try checkPasswordRequest(session, generation: expectedGeneration)
        if response.remember {
            let snapshot = await session.snapshot()
            let verified = try await Self.verifyRememberedPassword(response.password, url: session.sourceURL,
                                                                   entries: snapshot.entries)
            // session の prompt には採用通知がない。別 reader で CRC / HMAC まで確かめ、
            // 検証できない候補は保存せず、元の読み出し側に可否の判断を返す。
            _ = try await session.extractionReader()
            try checkPasswordRequest(session, generation: expectedGeneration)
            if verified, await passwordVault.save(response.password, for: key, generation: vaultGeneration) {
                try checkPasswordRequest(session, generation: expectedGeneration)
                rememberedPayloadPassword = response.password
            }
        }
        return response.password
    }

    private func checkPasswordRequest(_ session: ArchiveSession, generation: UInt64) throws {
        try Task.checkCancellation()
        guard !closed, self.session === session else { throw CancellationError() }
        guard session.generation == generation else {
            throw ExtractionFailure.refused(String(localized: "アーカイブが変更されています。開き直してください。"))
        }
    }

    @concurrent private static func verifyRememberedPassword(_ password: String, url: URL,
                                                             entries: [ArchiveEntry]) async throws -> Bool {
        do {
            try Task.checkCancellation()
            let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
            guard reader.entries == entries, entries.contains(where: \.isEncrypted) else { return false }
            for entry in entries where entry.isEncrypted {
                try ExtractionService.consume(reader.stream(entry), checkCancellation: { try Task.checkCancellation() }) { _ in }
            }
            return true
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    @concurrent private static func openArchive(
        _ url: URL, password: String?,
        writerOptions: @escaping @Sendable (GyoshukuKit.ArchiveFormat) -> WriterOptions,
        importOptions: @escaping @Sendable () -> ArchiveImportPlan.Options,
        checksCancellation: Bool = true
    ) async throws -> ArchiveSession {
        if checksCancellation { try Task.checkCancellation() }
        return try ArchiveSession(url: url, password: password, writerOptions: writerOptions, importOptions: importOptions)
    }

    override func makeWindowControllers() {
        let controller = ArchiveWindowController(preferencesStore: preferencesStore)
        addWindowController(controller)
        guard let session else {
            if isPasswordLocked { controller.displayLocked() }
            return
        }
        loadingTask = Task { [weak self, weak controller] in
            let snapshot = await session.snapshot()
            guard !Task.isCancelled, let self else { return }
            controller?.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation,
                                materializationController: self.materializationController())
        }
    }

    func append(urls: [URL], to folder: String, progress: Progress,
                willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveImportResult {
        try await mutate(progress: progress, actionName: "追加", willPublish: willPublish,
                         published: { !$0.addedPaths.isEmpty }) { session, publish in
            try await session.append(urls: urls, to: folder, progress: progress, willPublish: publish)
        }
    }

    func remove(_ nodes: [EntryNode], progress: Progress,
                willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveEditResult {
        try await edit(removing: nodes.map(ArchiveEditSelection.init), progress: progress, willPublish: willPublish)
    }

    func createFolder(in folder: String, baseName: String = String(localized: "名称未設定フォルダ"), progress: Progress,
                      willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveImportResult {
        try await mutate(progress: progress, actionName: "新規フォルダ", willPublish: willPublish,
                         published: { !$0.addedPaths.isEmpty }) { session, publish in
            try await session.createFolder(in: folder, baseName: baseName, progress: progress, willPublish: publish)
        }
    }

    func rename(_ node: EntryNode, to name: String, progress: Progress,
                willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveEditResult {
        try await edit(renaming: [ArchiveEditRename(selection: ArchiveEditSelection(node), name: name)],
                       progress: progress, willPublish: willPublish)
    }

    func move(_ nodes: [EntryNode], to folder: String, progress: Progress,
              willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveEditResult {
        try await edit(moving: nodes.map { ArchiveEditMove(selection: ArchiveEditSelection($0), folder: folder) },
                       progress: progress, willPublish: willPublish)
    }

    func edit(removing: [ArchiveEditSelection] = [], renaming: [ArchiveEditRename] = [],
              moving: [ArchiveEditMove] = [], progress: Progress,
              willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveEditResult {
        let name = !moving.isEmpty && removing.isEmpty && renaming.isEmpty ? "移動"
            : (renaming.isEmpty ? "削除" : (removing.isEmpty ? "名称変更" : "削除・名称変更"))
        return try await mutate(progress: progress, actionName: name, willPublish: willPublish,
                                published: { $0.published }) { session, publish in
            try await session.edit(removing: removing, renaming: renaming, moving: moving, progress: progress, willPublish: publish)
        }
    }

    // メニューと XCTest が共有する入口。パスワードだけの変更も通常編集と同じ公開・Undo 境界を使う。
    func updatePassword(_ action: ArchivePasswordAction, settings: ArchiveEncryptionSettings,
                        progress: Progress = Progress(),
                        willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchivePasswordEditResult {
        let result = try await mutate(progress: progress, actionName: action.actionName, willPublish: willPublish,
                                     published: { _ in true }) { session, publish in
            try await session.updatePassword(action, settings: settings, progress: progress, willPublish: publish)
        }
        // 以前に記憶した鍵を次回の open に使わせない。新しい鍵の永続化は明示的な記憶操作だけ。
        if let session, let stored = await passwordVault.password(for: .file(session.sourceURL)) {
            await passwordVault.remove(for: .file(session.sourceURL), matching: stored)
        }
        rememberedPayloadPassword = nil
        return result
    }

    // 操作の種類によらず、公開の成否・取消し・close 待機を同じ規則で扱う。
    private func mutate<Result: Sendable>(
        progress: Progress, actionName: String, willPublish: (@Sendable () throws -> Void)?,
        published: @escaping @Sendable (Result) -> Bool,
        operation: @escaping @Sendable (ArchiveSession, @escaping @Sendable () throws -> Void) async throws -> Result
    ) async throws -> Result {
        guard !closed, let session else { throw ExtractionFailure.refused(String(localized: "アーカイブが閉じられています。")) }
        guard mutationTask == nil, undoTask == nil, !switchingBackingFile else {
            throw ExtractionFailure.refused(String(localized: "アーカイブを変更しています。"))
        }
        let previousGeneration = session.generation
        let stack = archiveUndoStack
        let pending = Mutex<ArchiveUndoStack.Slot?>(nil)
        let task = Task {
            do {
                let encryption = await session.encryptionSettings()
                let result = try await operation(session, {
                    // updater が書き換えるのは作業コピー。退避するのは公開直前の原本だけ。
                    let slot = try stack.capture(session.sourceURL, encryption: encryption)
                    pending.withLock { $0 = slot }
                    try willPublish?()
                })
                await stack.finishMutation(pending.withLock { $0 }, published: published(result))
                return result
            } catch {
                await stack.finishMutation(pending.withLock { $0 }, published: false)
                throw error
            }
        }
        mutationTask = Task { _ = await task.result }
        mutationProgress = progress
        cancelMutation = { task.cancel() }
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        defer {
            mutationTask = nil
            mutationProgress = nil
            cancelMutation = nil
            (undoManager as? ArchiveUndoManager)?.isSuspended = closed
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                progress.cancel()
                task.cancel()
            }
            if !closed, published(result) { synchronizeUndoActions(registering: actionName) }
            if session.generation != previousGeneration { await displayAfterMutation() }
            return result
        } catch {
            if session.generation != previousGeneration { await displayAfterMutation() }
            throw error
        }
    }

    private func synchronizeUndoActions(registering name: String? = nil) {
        let slots = archiveUndoStack.slots
        let retained = Set(slots.map(\.id))
        for (id, action) in undoActions where !retained.contains(id) {
            undoManager?.removeAllActions(withTarget: action)
            undoActions.removeValue(forKey: id)
        }
        if let name {
            for slot in slots where undoActions[slot.id] == nil {
                let action = UndoAction(id: slot.id, name: name)
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
        undoManager.setActionName(action.name)
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
            if session.generation != previousGeneration {
                if let stored = await self.passwordVault.password(for: .file(session.sourceURL)) {
                    let current = await session.password
                    if current != stored { await self.passwordVault.remove(for: .file(session.sourceURL), matching: stored) }
                }
                self.rememberedPayloadPassword = nil
                await self.displayAfterMutation()
            }
        }
    }

    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = undoManager?.undoMenuItemTitle ?? String(localized: "取り消す")
            return undoManager?.canUndo == true
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = undoManager?.redoMenuItemTitle ?? String(localized: "やり直す")
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

    func switchBackingFile(to url: URL, password: String? = nil) async throws {
        guard !closed, let oldSession = session else { throw CancellationError() }
        guard mutationTask == nil, undoTask == nil, !switchingBackingFile else {
            throw ExtractionFailure.refused(String(localized: "アーカイブを変更しています。"))
        }
        switchingBackingFile = true
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        defer {
            switchingBackingFile = false
            (undoManager as? ArchiveUndoManager)?.isSuspended = closed
        }
        // 新しい reader・capabilities・identity が揃うまでは文書の参照先を変えない。
        // 作成 transaction の公開後は、遅れて届いた取消しで成功を隠さない。
        let opened = try await Self.openArchive(url, password: password, writerOptions: sessionWriterOptions,
                                                importOptions: sessionImportOptions, checksCancellation: false)
        guard !closed, session === oldSession else {
            await opened.close()
            throw CancellationError()
        }
        let format: GyoshukuKit.ArchiveFormat
        switch opened.capabilities.mode {
        case .inPlace: format = .zip
        case .rewrite(let outputFormat): format = outputFormat
        case nil:
            await opened.close()
            throw ExtractionFailure.refused(String(localized: "対応していないフォーマットです。"))
        }
        loadingTask?.cancel()
        loadingTask = nil
        for controller in windowControllers.compactMap({ $0 as? ArchiveWindowController }) {
            controller.prepareForBackingFileSwitch()
        }
        disposeMaterialization()
        rememberedPayloadPassword = nil
        let nextUndoStack = archiveUndoStack.emptyCopy()
        disposeUndoStack()
        archiveUndoStack = nextUndoStack
        undoFailure = nil
        contentsStorage.withLock { $0 = .open(opened) }
        fileURL = url
        fileType = ArchiveSavePanelController.contentType(for: format).identifier
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        let previous = sessionCleanup
        let hasPromises = FilePromiseRegistry.shared.hasPromises(for: oldSession)
        let cleanup = Task { [weak self] in
            await previous?.value
            let promiseWait = Task { await FilePromiseRegistry.shared.waitUntilNoPromises(for: oldSession) }
            // 文書の close はこの cleanup を待つため、終了時には保持期間を待たずに解放する。
            let closeMonitor = Task { [weak self] in
                while self?.closed == false {
                    do { try await Task.sleep(for: .milliseconds(50)) }
                    catch { return }
                }
                promiseWait.cancel()
            }
            await promiseWait.value
            closeMonitor.cancel()
            await oldSession.close()
        }
        sessionCleanup = cleanup
        // 受信側は別名で保存が終わってから要求できる。promise がある時の後始末は待たない。
        if !hasPromises { await cleanup.value }
        await undoCleanup?.value
        guard !closed, session === opened else { return }
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

    /// 進行中の仕事を取り消し、後始末と一時コピー・undo スロットの破棄を待つ。
    /// 文書は閉じず、状態復元を含む通常の終了処理は AppKit に任せる。
    func prepareForTermination() async {
        let controllers = windowControllers.compactMap { $0 as? ArchiveWindowController }
        // 完了時に controller が nil に戻すので、取消し前に Task を保持する。
        let extractions = controllers.compactMap(\.extractionTask)
        mutationProgress?.cancel()
        cancelMutation?()
        undoTask?.cancel()
        for controller in controllers { controller.cancelExtraction() }

        await mutationTask?.value
        await undoTask?.value
        // 別名で保存・変換・パスワード変更と switchingBackingFile は extractionTask 内で完了する。
        for extraction in extractions { await extraction.value }
        disposeUndoStack()
        await undoCleanup?.value
        disposeMaterialization()
        await materializationCleanup?.value
    }

    override func close() {
        closed = true
        NotificationCenter.default.removeObserver(self, name: ArchivePreferencesStore.didChange, object: preferencesStore)
        rememberedPayloadPassword = nil
        disposeMaterialization()
        disposeUndoStack()
        for controller in windowControllers.compactMap({ $0 as? ArchiveWindowController }) {
            controller.cancelExtraction()
        }
        loadingTask?.cancel()
        loadingTask = nil
        let session = contentsStorage.withLock { state -> ArchiveSession? in
            let session: ArchiveSession?
            if case .open(let opened) = state { session = opened } else { session = nil }
            state = .closed
            return session
        }
        let previous = sessionCleanup
        sessionCleanup = Task {
            await previous?.value
            await session?.close()
        }
        super.close()
    }

    private func disposeUndoStack() {
        undoManager?.removeAllActions()
        undoActions.removeAll()
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        mutationProgress?.cancel()
        cancelMutation?()
        undoTask?.cancel()
        let mutation = mutationTask
        let undo = undoTask
        let previous = undoCleanup
        let stack = archiveUndoStack
        undoCleanup = Task {
            // 公開・置換の後始末を待ち、動作中のスロットを削除しない。
            await previous?.value
            await mutation?.value
            await undo?.value
            await stack.dispose()
        }
    }
}
