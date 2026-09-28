import AppKit
import GyoshukuKit
import KaitoKit
import Synchronization

@MainActor final class ArchiveDocument: NSDocument {
    // NSDocument の読み込みは非隔離なので、actor 参照の受け渡しだけをロックする。
    nonisolated private let contentsStorage = Mutex<Contents>(.empty)

    // makeDocument の同期呼び出し内だけで渡し、revert や直接の read には渡さない。
    nonisolated static let preopenedArchive = TaskLocal<Result<PreopenedArchive, NSError>?>(wrappedValue: nil)

    nonisolated let preferencesSnapshot: PreferencesSnapshot
    nonisolated let saveBehavior: ArchivePreferences.SaveBehavior
    nonisolated let volumeMetadataStore: ArchiveVolumeMetadataStore
    nonisolated let volumeRecoveryIndex: RecoverableWorkIndex
    nonisolated private let splitPublicationActive = Mutex(false)
    /// 分割アーカイブの保存に関わる文書側の状態。差し替え口と、直前の保存の結果・通知・同意を持つ。
    private var splitSave = SplitSaveState()
    var splitSaveHooks: ArchiveSplitSaveHooks { get { splitSave.hooks } set { splitSave.hooks = newValue } }
    var splitScheduleChooser: ((ArchiveVolumeLayout, Bool) async throws -> ArchiveSplitScheduleChoice)? {
        get { splitSave.scheduleChooser } set { splitSave.scheduleChooser = newValue }
    }
    var splitMutationConfirmation: ((NSAlert) async throws -> NSApplication.ModalResponse)? {
        get { splitSave.mutationConfirmation } set { splitSave.mutationConfirmation = newValue }
    }
    var splitHazardConsent: ((String) async throws -> Bool)? { get { splitSave.hazardConsent } set { splitSave.hazardConsent = newValue } }
    private(set) var splitSchedule: VolumePlan.Schedule? { get { splitSave.schedule } set { splitSave.schedule = newValue } }
    private(set) var splitSaveNotice: String? { get { splitSave.notice } set { splitSave.notice = newValue } }
    private(set) var splitSaveFailure: ArchiveSplitSaveFailure? { get { splitSave.failure } set { splitSave.failure = newValue } }
    private(set) var splitSaveResult: PublishedVolumeSet? { get { splitSave.result } set { splitSave.result = newValue } }
    let pendingEditor: ArchivePendingEditor?
    /// 進行中の保存前モードの保存（別名保存と戻し込みを含む）。finishDeferredSave がまとめて解放する。
    private var deferredSave: DeferredSaveOperation?
    var deferredSaveTask: Task<Void, Error>? { deferredSave?.task }
    var deferredSaveSheet: ExtractionProgressSheet? { deferredSave?.sheet }
    var isDeferredSaveRunning: Bool { deferredSave != nil }
    private(set) var stagingCleanup: Task<Void, Never>?
    private var reservationInFlight = false
    private var externalChangeAlert: NSAlert?
    private var waitingToClose = false
    var pendingChanges: ArchivePendingChanges { pendingEditor?.changes ?? .init() }
    // 保存の公開境界をローカル試験で止める。通常の UI は使わない。
    var deferredWillPublish: (@Sendable () throws -> Void)?
    var deferredWillReload: (@Sendable () throws -> Void)?
    private(set) var deferredReloadFailure: String?
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
    private var deferredPreparationID: UUID?
    #if DEBUG
    nonisolated static let preparationFailureForTesting = TaskLocal<(any Error)?>(wrappedValue: nil)
    var presentedErrorObserverForTesting: ((any Error) -> Void)?

    func waitForDeferredPreparationForTesting() async {
        while let task = loadingTask {
            await task.value
            if loadingTask == task { return }
        }
    }
    #endif
    private var materialization: ArchiveMaterializationController?
    private(set) var materializationCleanup: Task<Void, Never>?
    private(set) var archiveUndoStack: ArchiveUndoStack
    let passwordVault: ArchivePasswordVault
    private var rememberedPayloadPassword: String?
    private var mutationTask: Task<Void, Never>?
    private var mutationProgress: Progress?
    private var cancelMutation: (() -> Void)?
    private(set) var undoTask: Task<Void, Never>?
    private var pendingUndoRefresh: UUID?
    private(set) var undoCleanup: Task<Void, Never>?
    private(set) var undoFailure: (any Error)?
    private var closed = false
    private var switchingBackingFile = false
    private var repairingUndoRegistration = false
    private var undoActions: [UUID: UndoAction] = [:]

    private final class UndoAction {
        let id: UUID
        let name: String
        var pending: ArchivePendingChanges?
        init(id: UUID, name: String, pending: ArchivePendingChanges? = nil) {
            self.id = id; self.name = name; self.pending = pending
        }
    }

    /// 一回の保存前モードの保存に属する作業。戻し込みは task だけを持ち、他は経路によって無い。
    private struct DeferredSaveOperation {
        let task: Task<Void, Error>
        var progress: Progress?
        var cancellation: ArchiveProgressCancellation?
        var sheet: ExtractionProgressSheet?
        var publication: ArchiveSavePublication?
        var creation: ArchiveCreationController?
    }

    /// 分割保存の文書側の状態。差し替え口（hooks と三つの確認）は文書の寿命の間保つ。
    /// 同意・確認の抑止・巻サイズの選択・直前の結果は同じ書庫と場所に対するものなので、別名保存で書庫が変わると消す。
    private struct SplitSaveState {
        var hooks = ArchiveSplitSaveHooks()
        var scheduleChooser: ((ArchiveVolumeLayout, Bool) async throws -> ArchiveSplitScheduleChoice)?
        var mutationConfirmation: ((NSAlert) async throws -> NSApplication.ModalResponse)?
        var hazardConsent: ((String) async throws -> Bool)?
        var suppressesMutationConfirmation = false
        var hazardConsents: Set<ArchiveSplitHazardLocation> = []
        var schedule: VolumePlan.Schedule?
        var notice: String?
        var failure: ArchiveSplitSaveFailure?
        var result: PublishedVolumeSet?

        /// 直前の保存の結果と通知を消す。次の保存が新しい値を置く。
        mutating func clearOutcome() { failure = nil; result = nil; notice = nil }

        /// 別名保存で書庫と場所が変わった。確認・同意・巻サイズの選択・直前の結果はその書庫のものなので最初からにする。
        mutating func resetForNewArchive() {
            hazardConsents.removeAll()
            suppressesMutationConfirmation = false
            schedule = nil
            clearOutcome()
        }
    }

    override convenience init() { self.init(undoStack: ArchiveUndoStack()) }

    convenience init(passwordVault: ArchivePasswordVault) {
        self.init(undoStack: ArchiveUndoStack(), passwordVault: passwordVault)
    }

    init(undoStack: ArchiveUndoStack, passwordVault: ArchivePasswordVault = .shared,
         preferencesStore: ArchivePreferencesStore = .shared,
         volumeMetadataStore: ArchiveVolumeMetadataStore = .shared, volumeRecoveryIndex: RecoverableWorkIndex = .shared) {
        archiveUndoStack = undoStack
        self.passwordVault = passwordVault
        self.preferencesStore = preferencesStore
        self.volumeMetadataStore = volumeMetadataStore
        self.volumeRecoveryIndex = volumeRecoveryIndex
        let preferences = preferencesStore.preferences
        preferencesSnapshot = PreferencesSnapshot(preferences)
        saveBehavior = preferences.saveBehavior
        pendingEditor = preferences.saveBehavior == .onSave ? ArchivePendingEditor() : nil
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)),
                                               name: ArchivePreferencesStore.didChange, object: preferencesStore)
        hasUndoManager = true
        let manager = ArchiveUndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = ArchiveUndoStack.maximumSupportedCount
        undoManager = manager
    }

    @objc private func preferencesDidChange(_ notification: Notification) {
        let preferences = preferencesStore.preferences
        preferencesSnapshot.value.withLock { $0 = preferences }
    }

    var canUndoNextMutation: Bool {
        if saveBehavior == .onSave { return true }
        guard session?.volumeLayout == nil, let sourceURL = session?.sourceURL else { return false }
        archiveUndoStack.resolveCloneSupport(for: sourceURL)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sourceURL.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return archiveUndoStack.canUndoNextMutation(archiveSize: size.uint64Value)
    }

    var hasWorkInFlight: Bool {
        deferredSaveTask != nil || reservationInFlight || mutationTask != nil || undoTask != nil || switchingBackingFile
            || windowControllers.contains { ($0 as? ArchiveWindowController)?.hasWorkInFlight == true }
    }

    var needsTerminationCleanup: Bool { hasWorkInFlight || !archiveUndoStack.slots.isEmpty || pendingEditor?.staging != nil || stagingCleanup != nil }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        // 即時モードは公開済み。保存前モードだけ AppKit の変更数を使う。
        if saveBehavior == .onSave {
            super.updateChangeCount(change)
            refreshPendingNotices()
        }
    }

    private func refreshPendingNotices() {
        for controller in windowControllers.compactMap({ $0 as? ArchiveWindowController }) {
            controller.refreshCapabilityNotice(session: session)
        }
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
        if let recovery = try ArchiveVolumeOpenRecovery.discover(url, index: volumeRecoveryIndex, metadataStore: volumeMetadataStore) {
            throw ArchiveVolumeOpenError(recovery: recovery).presentedError
        }
        // 失敗も read から返し、AppKit のエラー整形を保つ。
        let preopened = try Self.preopenedArchive.get()?.get()
        // super は NSFileWrapper 経由で全体を読み込むため呼ばない。
        let contents: Contents
        do {
            if let adopted = preopened?.adopt(into: self, from: url) { contents = adopted }
            else {
                contents = .open(try ArchiveSession(url: url, allowsSplitSave: saveBehavior == .onSave, allowsImmediateSplitSave: saveBehavior == .immediate,
                    volumeMetadataStore: volumeMetadataStore, writerOptions: sessionWriterOptions, importOptions: sessionImportOptions))
            }
        }
        catch KaitoError.passwordRequired {
            // AppKit の並行 read では UI を出せない。URL だけを渡し、window 側で解除する。
            contents = .locked(url)
        } catch let error as CancellationError { throw error }
        catch { throw Self.openingError(error) }
        if saveBehavior == .onSave, case .open(let session) = contents { session.setPendingReadSnapshot(nil) }
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
                                                importOptions: sessionImportOptions, allowsSplitSave: saveBehavior == .onSave, allowsImmediateSplitSave: saveBehavior == .immediate,
                                                volumeMetadataStore: volumeMetadataStore)
        guard !closed, !Task.isCancelled, lockedURL == url else {
            await opened.close()
            throw CancellationError()
        }
        if saveBehavior == .onSave { opened.setPendingReadSnapshot(nil) }
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
        // A closed session must reject even a correct candidate before installing a callback.
        _ = try await session.extractionReader()
        try checkPasswordRequest(session, generation: expectedGeneration)
        session.setPasswordAcceptance(nil)
        if response.remember {
            session.setPasswordAcceptance { [weak self, weak session] accepted, generation in
                guard let self, let session, accepted == response.password, generation == expectedGeneration else { return }
                do { try self.checkPasswordRequest(session, generation: expectedGeneration) }
                catch { return }
                if await self.passwordVault.save(accepted, for: key, generation: vaultGeneration) {
                    do { try self.checkPasswordRequest(session, generation: expectedGeneration) }
                    catch { return }
                    self.rememberedPayloadPassword = accepted
                }
            }
        }
        return response.password
    }

    /// 記憶した鍵を vault と文書の両方から忘れる。session がなくても文書側の記憶は消す。
    private func forgetRememberedPassword(for session: ArchiveSession?) async {
        if let session, let stored = await passwordVault.password(for: .file(session.sourceURL)) {
            await passwordVault.remove(for: .file(session.sourceURL), matching: stored)
        }
        rememberedPayloadPassword = nil
    }

    private func checkPasswordRequest(_ session: ArchiveSession, generation: UInt64) throws {
        try Task.checkCancellation()
        guard !closed, self.session === session else { throw CancellationError() }
        guard session.generation == generation else {
            throw ExtractionFailure.refused(String(localized: "アーカイブが変更されています。開き直してください。"))
        }
    }

    override func makeWindowControllers() {
        let controller = ArchiveWindowController(preferencesStore: preferencesStore)
        addWindowController(controller)
        guard let session else {
            if isPasswordLocked { controller.displayLocked() }
            return
        }
        let loadingToken = controller.beginListLoading()
        loadingTask = Task { [weak self, weak controller] in
            defer { controller?.finishListLoading(loadingToken) }
            let snapshot = await session.snapshot()
            guard !Task.isCancelled, let self, !self.closed, self.session === session else { return }
            if self.saveBehavior == .onSave {
                do {
                    var baseTree: EntryNode?
                    let revision = self.pendingChanges.revision
                    if self.pendingChanges.isEmpty {
                        let configuration = controller?.filterConfiguration
                        let tree = await EntryNode.build(from: snapshot.entries, format: session.reservationFormat, indexingEdits: false)
                        var filters: [EntryTreeFilter.Configuration: EntryTreeFilter] = [:]
                        if let configuration, !configuration.query.isEmpty {
                            filters = await Self.prepareFilters(tree, configurations: [configuration])
                        }
                        guard !Task.isCancelled, !self.closed, self.session === session,
                              session.generation == snapshot.generation,
                              controller?.isCurrentListLoading(loadingToken) == true else { return }
                        if self.pendingChanges.isEmpty, self.pendingChanges.revision == revision {
                            // 変更のない一覧を先に公開し、編集用の全件検査は表示後に進める。
                            session.setPendingReadSnapshot(try .init(deferredBase: snapshot.entries, generation: snapshot.generation,
                                changes: self.pendingChanges, staging: nil, nameSyntax: .init(session.reservationFormat)))
                            controller?.display(tree, session: session, generation: snapshot.generation,
                                                materializationController: self.materializationController(),
                                                preparedFilter: controller.flatMap { filters[$0.filterConfiguration] })
                            baseTree = tree
                        }
                    }
                    await session.prepareDeferredEditing()
                    guard !Task.isCancelled, !self.closed, self.session === session,
                          session.generation == snapshot.generation else { return }
                    if let editor = self.pendingEditor {
                        try await self.installEditor(editor, base: snapshot.entries, generation: snapshot.generation, session: session)
                    }
                    guard !Task.isCancelled, !self.closed, self.session === session else { return }
                    if let baseTree, let editor = self.pendingEditor {
                        let prepared = try await editor.prepare(generation: snapshot.generation, baseTree: baseTree)
                        guard !Task.isCancelled, !self.closed, self.session === session,
                              session.generation == snapshot.generation, editor.changes.revision == prepared.revision else { return }
                        session.setPendingReadSnapshot(prepared.reading)
                    } else { try await self.displayPending() }
                } catch {
                    controller?.finishListLoading(loadingToken)
                    if !self.closed, !(error is CancellationError) { self.presentError(error) }
                }
            } else {
                let configuration = controller?.filterConfiguration
                let tree = await EntryNode.build(from: snapshot.entries, format: session.reservationFormat, indexingEdits: false)
                var filters: [EntryTreeFilter.Configuration: EntryTreeFilter] = [:]
                if let configuration, !configuration.query.isEmpty {
                    filters = await Self.prepareFilters(tree, configurations: [configuration])
                }
                guard !Task.isCancelled, !self.closed, self.session === session,
                      session.generation == snapshot.generation,
                      controller?.isCurrentListLoading(loadingToken) == true else { return }
                controller?.display(tree, session: session, generation: snapshot.generation,
                                    materializationController: self.materializationController(),
                                    preparedFilter: controller.flatMap { filters[$0.filterConfiguration] }, indexingRenames: true)
            }
        }
    }

    func append(urls: [URL], to folder: String, progress: Progress,
                resolveConflict: ArchiveImportConflict.Resolver? = nil,
                willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveImportResult {
        if saveBehavior == .onSave || isImmediateSplitMutation {
            return try await reserveAppend(urls: urls, folder: folder, progress: progress, resolver: resolveConflict, willPublish: willPublish)
        }
        return try await mutate(progress: progress, actionName: "追加", willPublish: willPublish,
                         published: { !$0.addedPaths.isEmpty }) { session, publish in
            try await session.append(urls: urls, to: folder, progress: progress,
                                     resolveConflict: resolveConflict, willPublish: publish)
        }
    }

    func remove(_ nodes: [EntryNode], progress: Progress,
                willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveEditResult {
        try await edit(removing: nodes.map(ArchiveEditSelection.init), progress: progress, willPublish: willPublish)
    }

    func createFolder(in folder: String, baseName: String = String(localized: "名称未設定フォルダ"), progress: Progress,
                      willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveImportResult {
        if saveBehavior == .onSave || isImmediateSplitMutation {
            return try await reserveFolder(in: folder, baseName: baseName, progress: progress, willPublish: willPublish)
        }
        return try await mutate(progress: progress, actionName: "新規フォルダ", willPublish: willPublish,
                         published: { !$0.addedPaths.isEmpty }) { session, publish in
            try await session.createFolder(in: folder, baseName: baseName, progress: progress, willPublish: publish)
        }
    }

    func rename(_ node: EntryNode, to name: String, progress: Progress,
                willPublish: (@Sendable () throws -> Void)? = nil, validated: ArchiveValidatedRename? = nil) async throws -> ArchiveEditResult {
        if saveBehavior == .onSave, let validated {
            return try await reserve(name: "名称変更", progress: progress, willPublish: willPublish) { editor, state, session in
                guard validated.generation == state.reading.generation, validated.revision == editor.changes.revision,
                      validated.session == ObjectIdentifier(session) else { throw ArchiveEditError.staleSelection }
                return await ArchiveReservationComputation.applyValidated(validated.plan, state: state, changes: editor.changes,
                    base: editor.base, generation: state.reading.generation)
            }
        }
        return try await edit(renaming: [ArchiveEditRename(selection: ArchiveEditSelection(node), name: name)],
                       progress: progress, willPublish: willPublish)
    }

    func move(_ nodes: [EntryNode], to folder: String, progress: Progress,
              resolveConflict: ArchiveImportConflict.Resolver? = nil,
              willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveEditResult {
        let selections = nodes.map(ArchiveEditSelection.init)
        if saveBehavior == .onSave || isImmediateSplitMutation {
            return try await reserveMove(selections, to: folder, progress: progress, resolver: resolveConflict, willPublish: willPublish)
        }
        return try await mutate(progress: progress, actionName: "移動", willPublish: willPublish,
                                published: { $0.published }) { session, publish in
            try await session.move(selections, to: folder, progress: progress,
                                   resolveConflict: resolveConflict, willPublish: publish)
        }
    }

    func edit(removing: [ArchiveEditSelection] = [], renaming: [ArchiveEditRename] = [],
              moving: [ArchiveEditMove] = [], progress: Progress,
              willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveEditResult {
        let name = !moving.isEmpty && removing.isEmpty && renaming.isEmpty ? "移動"
            : (renaming.isEmpty ? "削除" : (removing.isEmpty ? "名称変更" : "削除・名称変更"))
        if saveBehavior == .onSave || isImmediateSplitMutation {
            return try await reserveEdit(removing: removing, renaming: renaming, moving: moving, progress: progress, name: name, willPublish: willPublish)
        }
        return try await mutate(progress: progress, actionName: name, willPublish: willPublish,
                                published: { $0.published }) { session, publish in
            try await session.edit(removing: removing, renaming: renaming, moving: moving, progress: progress, willPublish: publish)
        }
    }

    // メニューと XCTest が共有する入口。パスワードだけの変更も通常編集と同じ公開・Undo 境界を使う。
    func updatePassword(_ action: ArchivePasswordAction, settings: ArchiveEncryptionSettings,
                        progress: Progress = Progress(),
                        willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchivePasswordEditResult {
        if saveBehavior == .onSave || isImmediateSplitMutation { return try await reservePassword(action, settings: settings, progress: progress, willPublish: willPublish) }
        let result = try await mutate(progress: progress, actionName: action.actionName, willPublish: willPublish,
                                     published: { _ in true }) { session, publish in
            try await session.updatePassword(action, settings: settings, progress: progress, willPublish: publish)
        }
        // 以前に記憶した鍵を次回の open に使わせない。新しい鍵の永続化は明示的な記憶操作だけ。
        await forgetRememberedPassword(for: session)
        return result
    }

    // 操作の種類によらず、公開の成否・取消し・close 待機を同じ規則で扱う。
    private func mutate<Result: Sendable>(
        progress: Progress, actionName: String, willPublish: (@Sendable () throws -> Void)?,
        published: @escaping @Sendable (Result) -> Bool,
        operation: @escaping @MainActor (ArchiveSession, @escaping @Sendable () throws -> Void) async throws -> Result
    ) async throws -> Result {
        guard !closed, let session else { throw ExtractionFailure.refused(String(localized: "アーカイブが閉じられています。")) }
        guard mutationTask == nil, undoTask == nil, !switchingBackingFile else {
            throw ExtractionFailure.refused(String(localized: "アーカイブを変更しています。"))
        }
        let isSplit = session.volumeLayout != nil
        let previousGeneration = session.generation
        let stack = archiveUndoStack
        let pending = Mutex<ArchiveUndoStack.Slot?>(nil)
        let publication = ArchiveSavePublication()
        defer { publication.finish() }
        let task = Task {
            try await ArchiveSavePublication.current.withValue(publication) {
                do {
                    let encryption = await session.encryptionSettings()
                    let result = try await operation(session, {
                        // updater が書き換えるのは作業コピー。退避するのは公開直前の原本だけ。
                        let slot = try isSplit ? nil : stack.capture(session.sourceURL, encryption: encryption, verification: session.entryVerification)
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
        }
        let cancellation = publication.watchCancellation(progress: progress) { task.cancel() }
        defer { cancellation.invalidate() }
        mutationTask = Task { _ = await task.result }
        mutationProgress = progress
        cancelMutation = { publication.cancelBeforePublication(progress: progress) { task.cancel() } }
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        defer {
            mutationTask = nil
            mutationProgress = nil
            cancelMutation = nil
            (undoManager as? ArchiveUndoManager)?.isSuspended = closed || session.requiresSplitRecovery
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                publication.cancelBeforePublication(progress: progress) { task.cancel() }
            }
            if !closed, published(result) {
                if isSplit { clearUndoHistory() }
                else { synchronizeUndoActions(registering: actionName) }
            }
            if session.generation != previousGeneration { await displayAfterMutation() }
            return result
        } catch {
            if session.generation != previousGeneration { await displayAfterMutation() }
            throw error
        }
    }

    /// NSUndoManager の履歴と、その handler が保持する予約値の両方を捨てる。
    private func clearUndoHistory() {
        undoManager?.removeAllActions()
        undoActions.removeAll()
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
        if action.pending != nil {
            // UndoManager は target を保持しない。予約値は handler が保持し、履歴破棄と同時に解放する。
            undoManager.registerUndo(withTarget: self) { [action] document in document.restore(action) }
        } else {
            undoManager.registerUndo(withTarget: action) { [weak self] action in self?.restore(action) }
        }
        undoManager.setActionName(action.name)
        if grouping { undoManager.endUndoGrouping() }
    }

    private func restore(_ action: UndoAction) {
        if action.pending != nil, pendingEditor != nil { restorePendingChanges(action) }
        else { restoreArchiveSlot(action) }
    }

    /// 保存前モードの取消し。予約値を editor に戻し、逆操作として今の予約値を同じ action に持たせる。
    private func restorePendingChanges(_ action: UndoAction) {
        guard let pending = action.pending, let editor = pendingEditor else { return }
        guard !closed, !isDeferredSaveRunning, !reservationInFlight, let session, !session.requiresSplitRecovery else { return }
        do {
            guard editor.baseGeneration == session.generation else { throw ArchiveEditError.staleSelection }
            try pending.validate(base: editor.base, generation: session.generation)
            let previous = editor.changes
            editor.replace(pending)
            session.setPendingReadSnapshot(try .init(deferredBase: editor.base, generation: session.generation,
                changes: editor.changes, staging: editor.staging, nameSyntax: .init(session.reservationFormat)))
            action.pending = previous
            registerUndo(action)
            let revision = editor.changes.revision, previousRefresh = undoTask, refreshID = UUID()
            pendingUndoRefresh = refreshID
            undoFailure = nil
            undoTask = Task { [weak self] in
                await previousRefresh?.value
                guard let self else { return }
                defer { if pendingUndoRefresh == refreshID { undoTask = nil; pendingUndoRefresh = nil } }
                guard editor.changes.revision == revision else { return }
                do { try await displayPending() }
                catch { if editor.changes.revision == revision { undoFailure = error } }
            }
        } catch { undoFailure = error }
    }

    /// 即時モードの取消し。clone した原本を session に戻させ、置換前に失敗したときは NSUndoManager の位置だけを戻す。
    private func restoreArchiveSlot(_ action: UndoAction) {
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

    // メニューの selector を分離し、保存の実処理は close/quit と同じ NSDocument の経路に戻す。
    @objc func saveArchiveDocument(_ sender: Any?) {
        guard canSavePendingChanges else { return }
        save(sender)
    }

    private var canSavePendingChanges: Bool {
        saveBehavior == .onSave && isDocumentEdited && !hasWorkInFlight && !closed && session?.requiresSplitRecovery != true
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(saveArchiveDocument(_:)), #selector(NSDocument.save(_:)), #selector(NSDocument.revertToSaved(_:)):
            return canSavePendingChanges
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
        guard !closed, let session else { return }
        let loading = beginListLoading()
        var handedOff = false
        defer { if !handedOff { finishListLoading(loading) } }
        disposeMaterialization()
        try await session.reloadAfterMutation()
        handedOff = await displayAfterMutation(loading: loading)
    }

    /// 旧 session の後始末が、文書の close を見に行く間隔。
    private static let closeMonitorInterval: Duration = .milliseconds(50)

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
                                                importOptions: sessionImportOptions, checksCancellation: false, allowsSplitSave: saveBehavior == .onSave, allowsImmediateSplitSave: saveBehavior == .immediate,
                                                volumeMetadataStore: volumeMetadataStore)
        guard !closed, session === oldSession else {
            await opened.close()
            throw CancellationError()
        }
        guard let format = opened.capabilities.mode?.outputFormat else {
            await opened.close()
            throw ExtractionFailure.refused(String(localized: "対応していないフォーマットです。"))
        }
        let newModificationDate = try Self.modificationDate(atPath: url.path)
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
        if saveBehavior == .onSave { disposePending() }
        if saveBehavior == .onSave { opened.setPendingReadSnapshot(nil) }
        // 確認も同意もこの書庫と場所に対するもの。別名保存は同意の範囲を新しく始める。
        splitSave.resetForNewArchive()
        contentsStorage.withLock { $0 = .open(opened) }
        fileURL = url
        fileModificationDate = newModificationDate
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
                    do { try await Task.sleep(for: Self.closeMonitorInterval) }
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

    private typealias ListLoading = [(controller: ArchiveWindowController, token: UUID)]

    private func beginListLoading() -> ListLoading {
        windowControllers.compactMap { controller in
            guard let controller = controller as? ArchiveWindowController else { return nil }
            return (controller, controller.beginListLoading())
        }
    }

    private func finishListLoading(_ loading: ListLoading) {
        for (controller, token) in loading { controller.finishListLoading(token) }
    }

    @discardableResult private func displayAfterMutation(loading existingLoading: ListLoading? = nil) async -> Bool {
        guard !closed, let session else { return false }
        let loading = existingLoading ?? beginListLoading()
        var handedOff = false
        defer { if !handedOff { finishListLoading(loading) } }
        disposeMaterialization()
        let snapshot = await session.snapshot()
        guard !session.isInvalidated else { return false }
        if saveBehavior == .onSave {
            handedOff = await displayDeferred(snapshot, session: session, loading: loading)
            return handedOff
        }
        await displayImmediate(snapshot, session: session, loading: loading)
        return false
    }

    /// 即時モードの表示。一覧と検索を組み立て、その loading をまだ待っている窓だけに表示する。
    private func displayImmediate(_ snapshot: (entries: [ArchiveEntry], generation: UInt64),
                                  session: ArchiveSession, loading: ListLoading) async {
        let configurations = Set(loading.map { $0.controller.filterConfiguration }.filter { !$0.query.isEmpty })
        let tree = await EntryNode.build(from: snapshot.entries, format: session.reservationFormat, indexingEdits: false)
        let filters = await Self.prepareFilters(tree, configurations: configurations)
        guard !closed, self.session === session, session.generation == snapshot.generation else { return }
        for (controller, token) in loading where controller.isCurrentListLoading(token) {
            controller.display(tree, session: session, generation: snapshot.generation,
                               materializationController: materializationController(),
                               preparedFilter: filters[controller.filterConfiguration], indexingRenames: true)
        }
    }

    /// 保存前モードの表示。予約が空なら公開後の一覧を先に表示し、編集の準備は背景の Task に渡す
    /// （true を返し、loading の終了もその Task が担う）。予約がある間は予約を重ねた一覧を表示して false を返す。
    private func displayDeferred(_ snapshot: (entries: [ArchiveEntry], generation: UInt64),
                                 session: ArchiveSession, loading: ListLoading) async -> Bool {
        do {
            if let editor = pendingEditor, editor.changes.isEmpty {
                let revision = editor.changes.revision
                let configurations = Set(loading.map { $0.controller.filterConfiguration })
                // 公開後の一覧は取消しに左右されず、編集の準備だけを背景へ渡す。
                let tree = await EntryNode.build(from: snapshot.entries, format: session.reservationFormat, indexingEdits: false)
                let filters = await Self.prepareFilters(tree, configurations: configurations)
                guard !closed, self.session === session, session.generation == snapshot.generation,
                      pendingEditor === editor, editor.changes.isEmpty, editor.changes.revision == revision else { return false }
                session.setPendingReadSnapshot(try .init(deferredBase: snapshot.entries, generation: snapshot.generation,
                                                        changes: editor.changes, staging: nil, nameSyntax: .init(session.reservationFormat)))
                for (controller, token) in loading where controller.isCurrentListLoading(token) {
                    controller.display(tree, session: session, generation: snapshot.generation,
                        materializationController: materializationController(), preparedFilter: filters[controller.filterConfiguration], loadingToken: token)
                }
                let previous = loadingTask
                previous?.cancel()
                let preparationID = UUID()
                deferredPreparationID = preparationID
                loadingTask = Task {
                    defer { finishListLoading(loading) }
                    @MainActor func isCurrent() -> Bool {
                        !closed && self.session === session && session.generation == snapshot.generation
                            && pendingEditor === editor && editor.changes.revision == revision
                            && deferredPreparationID == preparationID
                    }
                    do {
                        await previous?.value
                        guard !Task.isCancelled, isCurrent() else { return }
                        await session.prepareDeferredEditing()
                        guard !Task.isCancelled, isCurrent() else { return }
                        #if DEBUG
                        if let error = Self.preparationFailureForTesting.get() { throw error }
                        #endif
                        try await installEditor(editor, base: snapshot.entries, generation: snapshot.generation, session: session, checksCancellation: true)
                        guard !Task.isCancelled, isCurrent() else { return }
                        let prepared = try await editor.prepare(generation: snapshot.generation, filters: configurations,
                                                                baseTree: tree, checksCancellation: true)
                        guard !Task.isCancelled, isCurrent() else { return }
                        session.setPendingReadSnapshot(prepared.reading)
                    } catch {
                        finishListLoading(loading)
                        if isCurrent(), !(error is CancellationError) { presentPreparationError(error) }
                    }
                }
                return true
            }
            await session.prepareDeferredEditing()
            guard !closed, self.session === session, session.generation == snapshot.generation else { return false }
            if let editor = pendingEditor {
                try await installEditor(editor, base: snapshot.entries, generation: snapshot.generation, session: session, checksCancellation: false)
            }
            guard !closed, self.session === session, session.generation == snapshot.generation else { return false }
            try await displayPending(checksCancellation: false)
        } catch {
            finishListLoading(loading)
            if !closed { presentPreparationError(error) }
        }
        return false
    }

    @concurrent private static func prepareFilters(_ tree: EntryNode, configurations: Set<EntryTreeFilter.Configuration>) async
        -> [EntryTreeFilter.Configuration: EntryTreeFilter] {
        Dictionary(uniqueKeysWithValues: configurations.map {
            ($0, EntryTreeFilter(root: tree, query: $0.query, showsHiddenFiles: $0.showsHiddenFiles))
        })
    }

    private func presentPreparationError(_ error: any Error) {
        #if DEBUG
        if let observer = presentedErrorObserverForTesting { observer(error); return }
        #endif
        presentError(error)
    }

    /// 公開待ちの文書があっても、全ての文書へ先に取消しを届ける。
    func cancelForTermination() {
        loadingTask?.cancel()
        if let saving = deferredSave {
            if let publication = saving.publication, let progress = saving.progress {
                publication.cancelBeforePublication(progress: progress) {
                    saving.creation?.savePanel?.cancel()
                    saving.task.cancel()
                }
            } else {
                saving.progress?.cancel()
                saving.creation?.savePanel?.cancel()
                saving.task.cancel()
            }
        }
        pendingEditor?.cancelStaging()
        let controllers = windowControllers.compactMap { $0 as? ArchiveWindowController }
        if mutationProgress?.isCancellable == true { mutationProgress?.cancel() }
        cancelMutation?()
        undoTask?.cancel()
        for controller in controllers {
            controller.cancelListWork()
            controller.cancelExtraction()
        }
    }

    /// 文書は閉じず、状態復元を含む通常の終了処理は AppKit に任せる。
    func prepareForTermination() async {
        let extractions = windowControllers.compactMap { ($0 as? ArchiveWindowController)?.extractionTask }
        cancelForTermination()
        _ = await deferredSaveTask?.result
        await mutationTask?.value
        await undoTask?.value
        // 別名で保存・変換・パスワード変更と switchingBackingFile は extractionTask 内で完了する。
        for extraction in extractions { await extraction.value }
        disposeUndoStack()
        await undoCleanup?.value
        disposeMaterialization()
        await materializationCleanup?.value
        if saveBehavior == .onSave { disposePending() }
        await stagingCleanup?.value
    }

    override func close() {
        guard !closed else { return }
        if let deferredSaveTask {
            guard !waitingToClose else { return }
            waitingToClose = true
            Task { _ = await deferredSaveTask.result; waitingToClose = false; close() }
            return
        }
        closed = true
        pendingEditor?.cancelStaging()
        disposePending()
        NotificationCenter.default.removeObserver(self, name: ArchivePreferencesStore.didChange, object: preferencesStore)
        rememberedPayloadPassword = nil
        disposeMaterialization()
        disposeUndoStack()
        for controller in windowControllers.compactMap({ $0 as? ArchiveWindowController }) {
            controller.cancelListWork()
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
        let staging = stagingCleanup, undo = undoCleanup, materialized = materializationCleanup, reader = sessionCleanup
        if saveBehavior == .onSave {
            DocumentCleanupRegistry.shared.track(Task {
                await staging?.value
                await undo?.value
                await materialized?.value
                await reader?.value
            })
        }
        super.close()
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        guard saveBehavior == .onSave else {
            super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
            return
        }
        let token = changeCountToken(for: .saveOperation)
        if let deferredSaveTask {
            Task { switch await deferredSaveTask.result {
                case .success: completionHandler(nil)
                case .failure(let error): completionHandler(Self.deferredSaveError(error))
                } }
            return
        }
        guard !closed, !reservationInFlight, undoTask == nil, !switchingBackingFile,
              let session, url == (fileURL ?? session.sourceURL), saveOperation == .saveOperation else {
            completionHandler(ArchiveEditError.staleSelection)
            return
        }
        let progress = Progress(), publication = ArchiveSavePublication()
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        let sheet = ExtractionProgressSheet(progress: progress, title: String(localized: "保存"), detail: displayName)
        if let window = windowControllers.first?.window { sheet.begin(on: window) }
        let task = Task {
            do {
                try await savePendingDocument(token: token, progress: progress, publication: publication, sheet: sheet)
                finishDeferredSave(sheet: sheet)
                if let reason = deferredReloadFailure {
                    for controller in windowControllers.compactMap({ $0 as? ArchiveWindowController }) {
                        controller.reportDeferredReloadFailure(reason)
                    }
                }
                completionHandler(nil)
            } catch {
                sheet.finish()
                if let failure = error as? ArchiveSplitSaveFailure {
                    recordSplitSaveFailure(failure)
                    refreshPendingNotices()
                    if failure.kind == .tooManyVolumes, let layout = session.volumeLayout {
                        // The attempted publication is finished. Remember a new size for the next Save;
                        // never begin a second publisher within one save operation.
                        do { splitSchedule = try await chooseSplitSchedule(layout, tooMany: true) }
                        catch {
                            finishDeferredSave(sheet: sheet)
                            completionHandler(Self.deferredSaveError(error)); throw error
                        }
                    }
                }
                finishDeferredSave(sheet: sheet)
                completionHandler(Self.deferredSaveError(error))
                throw error
            }
        }
        deferredSave = DeferredSaveOperation(task: task, progress: progress,
            cancellation: publication.watchCancellation(progress: progress) { task.cancel() },
            sheet: sheet, publication: publication)
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        guard saveBehavior == .onSave else {
            let loading = beginListLoading()
            do { try super.revert(toContentsOf: url, ofType: typeName) }
            catch { finishListLoading(loading); throw error }
            loadingTask?.cancel()
            loadingTask = Task { _ = await displayAfterMutation(loading: loading) }
            return
        }
        guard !hasWorkInFlight, !closed, url == (fileURL ?? session?.sourceURL) else { throw ArchiveEditError.staleSelection }
        // NSDocument の入口は同期。main actor の Task なら quit の modal run loop でも進む。
        let task = beginDeferredRevert()
        Task { do { try await task.value } catch { if !closed { presentError(error) } } }
    }

    nonisolated override func presentedItemDidMove(to newURL: URL) {
        guard !splitPublicationActive.withLock({ $0 }) else { return }
        super.presentedItemDidMove(to: newURL)
        Task { @MainActor [weak self] in
            guard let self, !closed, !isDeferredSaveRunning, !reservationInFlight else { return }
            do { try await synchronizeDeferredLocation() }
            catch { checkDeferredIdentityWhenKey() }
        }
    }

    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        guard saveBehavior == .onSave, let deferredSaveTask else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        Task { @MainActor in
            _ = await deferredSaveTask.result
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
        }
    }

    private func disposeUndoStack() {
        clearUndoHistory()
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        if mutationProgress?.isCancellable == true { mutationProgress?.cancel() }
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

extension ArchiveDocument {
    var isImmediateSplitMutation: Bool { saveBehavior == .immediate && session?.volumeLayout != nil }

    private func reserve<Result: ArchiveMutationResult>(name: String, progress: Progress,
        willPublish: (@Sendable () throws -> Void)? = nil,
        operation: @escaping @MainActor (ArchivePendingEditor, ArchiveReservationState, ArchiveSession) async throws -> (ArchivePendingChanges, Result)
    ) async throws -> Result {
        if isImmediateSplitMutation {
            return try await mutate(progress: progress, actionName: name, willPublish: willPublish,
                                    published: { $0.didPublishMutation }) { _, publish in
                try await self.performReservation(name: name, progress: progress, willPublish: publish, operation: operation)
            }
        }
        return try await performReservation(name: name, progress: progress, willPublish: willPublish, operation: operation)
    }

    private func performReservation<Result: ArchiveMutationResult>(name: String, progress: Progress,
        willPublish: (@Sendable () throws -> Void)?,
        operation: (ArchivePendingEditor, ArchiveReservationState, ArchiveSession) async throws -> (ArchivePendingChanges, Result)
    ) async throws -> Result {
        // UI は無効化する。既に送られたプログラム上の要求は保存後の新しい予約として扱う。
        if let saving = deferredSaveTask { try await saving.value }
        if saveBehavior == .onSave {
            while let refresh = undoTask { await refresh.value }
            await loadingTask?.value
        }
        try ArchiveImportPlan.checkCancellation(progress)
        guard !closed, let session else { throw CancellationError() }
        let immediate = isImmediateSplitMutation
        guard !isDeferredSaveRunning, !reservationInFlight, undoTask == nil, !switchingBackingFile else {
            throw ExtractionFailure.refused(String(localized: "アーカイブを変更しています。"))
        }
        reservationInFlight = true
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        defer {
            reservationInFlight = false
            (undoManager as? ArchiveUndoManager)?.isSuspended = closed || isDeferredSaveRunning
        }
        try await verifyReservationIdentity()
        guard !closed, self.session === session else { throw CancellationError() }
        let snapshot = try await session.deferredSnapshot(progress: progress)
        guard !closed, self.session === session else { throw CancellationError() }
        if immediate { try await confirmSplitMutation(progress: progress) }
        let temporaryStaging = immediate ? try StagingRegistry.temporary(beside: session.sourceURL) : nil
        defer { temporaryStaging?.remove() }
        let editor = pendingEditor ?? ArchivePendingEditor(registry: temporaryStaging?.registry ?? .shared)
        try await installEditor(editor, base: snapshot.entries, generation: snapshot.generation, session: session)
        let previous = editor.changes
        let stagingCheckpoint = editor.stagingCheckpoint
        var state: ArchiveReservationState? = try await editor.prepare(generation: snapshot.generation)
        defer { ArchiveBackgroundRelease.release(&state) }
        guard !closed, self.session === session, session.generation == snapshot.generation,
              editor.baseSession == ObjectIdentifier(session), editor.changes.revision == previous.revision else { throw ArchiveEditError.staleSelection }
        if !immediate { session.setPendingReadSnapshot(state!.reading) }
        do {
            var (next, initialResult) = try await operation(editor, state!, session)
            var result = initialResult
            try ArchiveImportPlan.checkCancellation(progress)
            guard !closed, self.session === session, generation == snapshot.generation,
                  editor.baseSession == ObjectIdentifier(session), editor.changes.revision == previous.revision else { throw ArchiveEditError.staleSelection }
            next.revision = previous.revision &+ 1
            var prepared: ArchiveReservationState? = try await ArchiveReservationState.build(base: editor.base, generation: snapshot.generation,
                changes: next, validation: editor.validation!, staging: editor.staging, validates: true,
                previous: previous, reusing: state,
                filters: Set(windowControllers.compactMap { ($0 as? ArchiveWindowController)?.filterConfiguration }))
            defer { ArchiveBackgroundRelease.release(&prepared) }
            try ArchiveImportPlan.checkCancellation(progress)
            try await verifyReservationIdentity()
            guard !closed, self.session === session, generation == snapshot.generation,
                  editor.baseSession == ObjectIdentifier(session), editor.changes.revision == previous.revision else { throw ArchiveEditError.staleSelection }
            if prepared!.changesDiffer {
                if immediate {
                    let publication = ArchiveSavePublication.current.get() ?? ArchiveSavePublication()
                    defer { if ArchiveSavePublication.current.get() == nil { publication.finish() } }
                    let saved = try await publishSplitChanges(next, base: snapshot.entries, generation: snapshot.generation,
                        progress: progress, publication: publication, willPublish: willPublish)
                    result.reloadFailure = saved.reloadFailure
                    fileModificationDate = saved.modificationDate
                } else {
                    editor.replace(next, prepared: prepared)
                    // groupsByEvent=false なので即時モードと同じ grouping 入口を通す。
                    registerUndo(UndoAction(id: UUID(), name: name, pending: previous))
                    displayPending(prepared!)
                }
            }
            if immediate, let staging = editor.reset() { await staging.removeWhenUnused() }
            return result
        } catch {
            if immediate, let staging = editor.reset() { await staging.removeWhenUnused() }
            if let failure = error as? ArchiveSplitSaveFailure {
                recordSplitSaveFailure(failure)
                if immediate, failure.requiresReopen || failure.kind == .rolledBack {
                    await archiveUndoStack.finishMutation(nil, published: true)
                    clearUndoHistory()
                }
            }
            await editor.discardStaging(after: stagingCheckpoint)
            throw error
        }
    }

    private func reserveAppend(urls: [URL], folder: String, progress: Progress,
                               resolver: ArchiveImportConflict.Resolver?, willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveImportResult {
        try await reserve(name: "追加", progress: progress, willPublish: willPublish) { [self] editor, state, session in
            var options = preferencesStore.preferences.importOptions
            options.excludesStagingFiles = true
            let plan = try await ArchiveReservationComputation.importPlan(urls: urls, folder: folder, state: state,
                archive: session.sourceURL, progress: progress, options: options, resolver: resolver)
            guard plan.failures.isEmpty, !plan.items.isEmpty else {
                return (editor.changes, ArchiveImportResult(addedPaths: [], failures: plan.failures))
            }
            guard !closed, self.session === session else { throw CancellationError() }
            let additions = try await editor.stage(plan.items, sourceStamps: plan.sourceStamps, progress: progress)
            let next = await ArchiveReservationComputation.append(plan, additions: additions, state: state,
                changes: editor.changes, base: editor.base, generation: state.reading.generation)
            return (next, ArchiveImportResult(addedPaths: plan.items.map(\.path), failures: []))
        }
    }

    private func reserveFolder(in folder: String, baseName: String, progress: Progress, willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveImportResult {
        try await reserve(name: "新規フォルダ", progress: progress, willPublish: willPublish) { editor, state, _ in
            try await ArchiveReservationComputation.folder(in: folder, baseName: baseName, state: state, changes: editor.changes)
        }
    }

    private func reserveEdit(removing: [ArchiveEditSelection], renaming: [ArchiveEditRename], moving: [ArchiveEditMove],
                             progress: Progress, name: String, willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveEditResult {
        try await reserve(name: name, progress: progress, willPublish: willPublish) { editor, state, _ in
            try await ArchiveReservationComputation.edit(removing: removing, renaming: renaming, moving: moving,
                state: state, changes: editor.changes, base: editor.base, generation: state.reading.generation)
        }
    }

    private func reserveMove(_ selections: [ArchiveEditSelection], to folder: String, progress: Progress,
                             resolver: ArchiveImportConflict.Resolver?, willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveEditResult {
        guard let resolver else {
            return try await reserveEdit(removing: [], renaming: [], moving: selections.map { .init(selection: $0, folder: folder) },
                                         progress: progress, name: "移動", willPublish: willPublish)
        }
        return try await reserve(name: "移動", progress: progress, willPublish: willPublish) { editor, state, session in
            try await ArchiveReservationComputation.move(selections, folder: folder, state: state, changes: editor.changes,
                base: editor.base, archive: session.sourceURL, generation: state.reading.generation, progress: progress, resolver: resolver)
        }
    }

    func deferredEncryptionSettings() async -> ArchiveEncryptionSettings {
        if let output = pendingChanges.outputEncryption { return output }
        return await session?.encryptionSettings() ?? .init()
    }

    private func reservePassword(_ action: ArchivePasswordAction, settings: ArchiveEncryptionSettings,
                                 progress: Progress, willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchivePasswordEditResult {
        try await reserve(name: action.actionName, progress: progress, willPublish: willPublish) { [self] editor, _, session in
            guard session.passwordFormat != nil else { throw ArchiveEditError.staleSelection }
            try await session.validateDeferredPassword(progress: progress)
            let current = await deferredEncryptionSettings()
            let encrypted = current.password != nil || (editor.changes.outputEncryption == nil && session.hasEncryptedEntries)
            guard action == .set ? !encrypted : encrypted else { throw ArchiveEditError.staleSelection }
            if action != .remove, settings.password?.isEmpty != false {
                throw ExtractionFailure.refused(String(localized: "パスワードを入力してください。"))
            }
            let output = action == .remove ? ArchiveEncryptionSettings() : settings
            var next = editor.changes
            next.outputEncryption = output == (await session.encryptionSettings()) ? nil : output
            return (next, ArchivePasswordEditResult())
        }
    }

    func projectedEntries() async throws -> [ArchiveEntry] {
        if saveBehavior == .onSave {
            while let refresh = undoTask { await refresh.value }
            await loadingTask?.value
        }
        guard let session else { return [] }
        let snapshot = await session.snapshot()
        guard let editor = pendingEditor else { return snapshot.entries }
        await session.prepareDeferredEditing()
        guard !closed, self.session === session else { throw CancellationError() }
        try await installEditor(editor, base: snapshot.entries, generation: snapshot.generation, session: session)
        let prepared = try await editor.prepare(generation: snapshot.generation)
        guard self.session === session, editor.baseSession == ObjectIdentifier(session), session.generation == snapshot.generation else { throw ArchiveEditError.staleSelection }
        session.setPendingReadSnapshot(prepared.reading)
        return prepared.projection.entries
    }

    /// 予約用 editor に現在の一覧を据え、その検証結果を session の名前索引へ引き継ぐ。
    private func installEditor(_ editor: ArchivePendingEditor, base: [ArchiveEntry], generation: UInt64,
                               session: ArchiveSession, checksCancellation: Bool = true) async throws {
        let format = session.reservationFormat
        try await editor.install(base: base, generation: generation, format: format, sessionID: ObjectIdentifier(session),
                                 checksCancellation: checksCancellation, index: session.nameIndex(generation: generation, format: format))
        session.adoptNameIndex(validation: editor.validation, generation: generation)
    }

    private func displayPending(checksCancellation: Bool = true) async throws {
        guard !closed, let editor = pendingEditor, let session else { return }
        guard editor.baseSession == ObjectIdentifier(session) else { throw ArchiveEditError.staleSelection }
        let prepared = try await editor.prepare(generation: session.generation,
            filters: Set(windowControllers.compactMap { ($0 as? ArchiveWindowController)?.filterConfiguration }),
            checksCancellation: checksCancellation)
        guard !closed, self.session === session, editor.baseSession == ObjectIdentifier(session),
              editor.changes.revision == prepared.revision else { return }
        displayPending(prepared)
    }

    private func displayPending(_ prepared: ArchiveReservationState) {
        guard !closed, let session else { return }
        session.setPendingReadSnapshot(prepared.reading)
        disposeMaterialization()
        for controller in windowControllers.compactMap({ $0 as? ArchiveWindowController }) {
            controller.display(prepared.tree, session: session, generation: session.generation,
                               materializationController: materializationController(), preparedFilter: prepared.filters[controller.filterConfiguration])
        }
    }

    private func verifyReservationIdentity() async throws {
        guard let session else { throw CancellationError() }
        do { try await synchronizeDeferredLocation(); try await session.verifyDeferredIdentity() }
        catch {
            if session.isInvalidated || session.requiresSplitRecovery { throw error }
            if !isImmediateSplitMutation, windowControllers.first?.window != nil {
                await presentExternalChange()
                throw CancellationError()
            }
            throw ArchiveEditError.archiveChanged
        }
    }

    func checkDeferredIdentityWhenKey() {
        guard saveBehavior == .onSave, !closed, !isDeferredSaveRunning, !reservationInFlight,
              session?.isInvalidated == false, session?.requiresSplitRecovery == false else { return }
        Task { [weak self] in
            guard let self, let session else { return }
            do { try await synchronizeDeferredLocation(); try await session.verifyDeferredIdentity() }
            catch {
                guard !isDeferredSaveRunning, !reservationInFlight, !closed,
                      !session.isInvalidated, !session.requiresSplitRecovery,
                      !ExtractionProgressSheet.hasPendingSheet(on: windowControllers.first?.window),
                      windowControllers.first?.window?.attachedSheet == nil else { return }
                await presentExternalChange()
            }
        }
    }

    private func presentExternalChange() async {
        guard !closed, externalChangeAlert == nil, let window = windowControllers.first?.window else { return }
        let controller = window.windowController as? ArchiveWindowController
        controller?.editProgressSheet?.finish()
        deferredSaveSheet?.finish()
        if let progressSheet = window.attachedSheet {
            window.endSheet(progressSheet)
            progressSheet.orderOut(nil)
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "アーカイブが別のアプリで変更されました")
        alert.addButton(withTitle: String(localized: "キャンセル"))
        alert.addButton(withTitle: String(localized: "変更を破棄して読み直す"))
        externalChangeAlert = alert
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        externalChangeAlert = nil
        if response == .alertSecondButtonReturn {
            do { try await revertPending() }
            catch { if !closed { presentError(error) } }
        }
    }

    private func disposePending() {
        if saveBehavior == .onSave { session?.setPendingReadSnapshot(nil) }
        let stagingWrite = pendingEditor?.stagingTask
        guard let lease = pendingEditor?.reset() else { return }
        let previous = stagingCleanup
        let task = Task {
            await previous?.value
            _ = await stagingWrite?.result
            await Self.removeStaging(lease)
        }
        stagingCleanup = task
        DocumentCleanupRegistry.shared.track(task)
    }

    @concurrent private static func removeStaging(_ lease: StagingRegistry.Lease) async { await lease.removeWhenUnused() }
}

extension ArchiveDocument {
    private func withSplitPrompt<Value>(_ body: (NSWindow?) async throws -> Value) async rethrows -> Value {
        let controller = windowControllers.compactMap { $0 as? ArchiveWindowController }.first
        let sheet = deferredSaveSheet ?? controller?.editProgressSheet
        sheet?.finish()
        defer {
            if let sheet, let window = controller?.window, !sheet.progress.isCancelled, !closed { sheet.begin(on: window) }
        }
        return try await body(controller?.window)
    }

    private func recordSplitSaveFailure(_ failure: ArchiveSplitSaveFailure) {
        splitSaveFailure = failure
        if failure.kind == .rolledBack, let restored = failure.restoredIdentity {
            fileModificationDate = restored.modificationDate
        }
    }

    private func confirmSplitMutation(progress: Progress) async throws {
        // isImmediateSplitMutation が真なら session はある。
        guard !canUndoNextMutation, isImmediateSplitMutation, let session else { return }
        guard session.capabilities.canEdit else { throw session.capabilities.editRefusal }
        guard !splitSave.suppressesMutationConfirmation else { return }
        let alert = ArchiveSplitSaveSheet.mutationAlert(schedule: session.volumeLayout?.immediateSchedule)
        let response = try await withSplitPrompt { window in
            if let splitMutationConfirmation { return try await splitMutationConfirmation(alert) }
            return try await ArchiveSplitSaveSheet.present(alert, on: window)
        }
        try ArchiveImportPlan.checkCancellation(progress)
        guard response == .alertFirstButtonReturn else { throw CancellationError() }
        splitSave.suppressesMutationConfirmation = alert.suppressionButton?.state == .on
    }

    func consentToSplitHazard(_ location: ArchiveSplitHazardLocation) async throws -> Bool {
        if splitSave.hazardConsents.contains(location) { return true }
        let consent = try await withSplitPrompt { window in
            if let splitHazardConsent { return try await splitHazardConsent(location.hazard) }
            return try await ArchiveSplitSaveSheet.consent(on: window)
        }
        if consent { splitSave.hazardConsents.insert(location) }
        return consent
    }

    private func chooseSplitSchedule(_ layout: ArchiveVolumeLayout, tooMany: Bool) async throws -> VolumePlan.Schedule {
        let choice: ArchiveSplitScheduleChoice
        if let splitScheduleChooser { choice = try await splitScheduleChooser(layout, tooMany) }
        else { choice = try await ArchiveSplitSaveSheet(tooManyVolumes: tooMany).choose(on: windowControllers.first?.window) }
        return try choice.schedule(for: layout)
    }

    /// 非 APFS の ZIP 更新が必要とし得る空き容量の倍率: 連結した作業コピー 1 つと、再構築の複製 2 つ。
    private static let zipRewriteSpaceFactor: UInt64 = 3

    private func prepareSplitSave(layout: ArchiveVolumeLayout, pending: ArchivePendingChanges,
                                  progress: Progress) async throws -> (VolumePlan.Schedule, UInt64, Bool) {
        let parent = try VolumePublishFS.canonicalParent(of: layout.gateURL)
        let info = try await Self.splitVolumeInfo(parent, operations: splitSaveHooks.operations)
        var estimate = layout.volumes.reduce(UInt64(0)) { $0 + $1.length }
        for entry in pending.additions {
            let next = estimate.addingReportingOverflow(entry.sourceStamp.size + 1024)
            guard !next.overflow else { throw VolumePublishError.invalidPlan }
            estimate = next.partialValue
        }
        estimate = max(1, estimate)
        try VolumeSetPublication.checkWorkLength(estimate, fileSystem: info.fileSystem)
        if splitSchedule == nil {
            if let saved = layout.savedSchedule { splitSchedule = saved }
            else if case .uniform(let size) = layout.schedule { splitSchedule = .uniform(size: size) }
            else { splitSchedule = try await chooseSplitSchedule(layout, tooMany: false) }
        }
        while true {
            do { _ = try VolumePlan(totalLength: estimate, schedule: splitSchedule!, scheme: layout.scheme); break }
            catch let error as VolumePublishError {
                guard case .tooManyVolumes = error else { throw error }
                if isImmediateSplitMutation { throw ArchiveSplitSaveFailure.map(error, staging: nil, context: .immediateReplacement) }
                splitSchedule = try await chooseSplitSchedule(layout, tooMany: true)
            }
        }
        var consent = false
        if let location = ArchiveSplitHazardLocation(parent: parent, info: info) {
            consent = try await consentToSplitHazard(location)
            guard consent else { throw CancellationError() }
        }
        // 非 APFS では ZIP updater の再構築に、連結した作業コピーとさらに 2 つの複製が要り得る。
        if session?.format == .zip, info.fileSystem != "apfs" {
            let needed = estimate.multipliedReportingOverflow(by: Self.zipRewriteSpaceFactor)
            let required = needed.partialValue.addingReportingOverflow(VolumePublishFS.margin)
            guard !needed.overflow, !required.overflow, info.available >= required.partialValue else {
                throw VolumePublishError.insufficientSpace(required: needed.overflow || required.overflow ? .max : required.partialValue, available: info.available)
            }
        }
        try ArchiveImportPlan.checkCancellation(progress)
        return (splitSchedule!, estimate, consent)
    }

    @concurrent private static func splitVolumeInfo(_ parent: URL, operations: VolumePublishOperations) async throws -> VolumePublishFS.VolumeInfo {
        try operations.volumeInfo(VolumePublishDirectory(parent))
    }

    func splitArchiveNotice(bundle: Bundle = .main) -> String? {
        guard saveBehavior == .onSave, let layout = session?.volumeLayout, case .numbered = layout.scheme else { return nil }
        let schedule = splitSchedule ?? layout.savedSchedule
        let size: UInt64?
        if case .uniform(let value) = schedule { size = value }
        else if schedule == nil, case .uniform(let value) = layout.schedule { size = value }
        else { size = nil }
        if let size {
            let count = layout.volumes.count
            let text = ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .binary)
            return String(localized: "分割アーカイブ（\(count)個・各\(text)）。保存すると同じ巻サイズで分割し直します。", bundle: bundle)
        }
        if schedule == .single { return String(localized: "保存すると1つのファイルにします。", bundle: bundle) }
        if case .explicit = schedule { return String(localized: "保存すると元の巻サイズを再現します。", bundle: bundle) }
        return String(localized: "巻サイズが揃っていません。保存時に選びます。", bundle: bundle)
    }

    private func finishDeferredSave(sheet: ExtractionProgressSheet? = nil) {
        sheet?.finish()
        deferredSave?.cancellation?.invalidate()
        deferredSave?.publication?.finish()
        deferredSave = nil
        (undoManager as? ArchiveUndoManager)?.isSuspended = closed || session?.requiresSplitRecovery == true
    }

    private func publishSplitChanges(_ pending: ArchivePendingChanges, base: [ArchiveEntry], generation baseGeneration: UInt64,
                                     progress: Progress, publication: ArchiveSavePublication,
                                     sheet: ExtractionProgressSheet? = nil,
                                     willPublish: (@Sendable () throws -> Void)?) async throws -> ArchiveSplitSaveResult {
        guard let session, let layout = session.volumeLayout else { throw ArchiveEditError.staleSelection }
        splitSave.clearOutcome()
        let (schedule, estimatedLength, consent) = try await prepareSplitSave(layout: layout, pending: pending, progress: progress)
        try await session.verifyDeferredIdentity()
        let expected = await session.sourceIdentity
        let publicationLayout = try layout.publicationLayout()
        var target = VolumeSetTarget(parent: publicationLayout.gateURL.deletingLastPathComponent(), layout: publicationLayout, expected: expected,
            schedule: schedule, allowHazardousVolume: consent, filePresenter: self)
        target.oldVolumeDisposal = isImmediateSplitMutation ? .remove : .trash
        if let window = windowControllers.first?.window { sheet?.begin(on: window) }
        // KaitoKit standardizes layout URLs (e.g. /private/var -> /var). Keep the
        // document's original gate spelling so later saves do not look like moves.
        let documentGate = fileURL ?? session.sourceURL
        splitPublicationActive.withLock { $0 = true }
        defer {
            if fileURL != documentGate { fileURL = documentGate }
            splitPublicationActive.withLock { $0 = false }
        }
        let result = try await session.savePendingSplit(pending, baseGeneration: baseGeneration, target: target,
            estimatedLength: estimatedLength, progress: progress, publication: publication, index: volumeRecoveryIndex,
            hooks: splitSaveHooks, willPublish: willPublish, willReload: deferredWillReload)
        splitSaveResult = result.published
        if result.recompressedZIP {
            splitSaveNotice = String(localized: "このZIPはそのまま更新できないため、アーカイブ全体を再圧縮しました。")
        }
        if let warning = result.published.warning {
            splitSaveNotice = (splitSaveNotice.map { $0 + "\n" } ?? "") + warning
        }
        if pending.outputEncryption != nil { await forgetRememberedPassword(for: session) }
        refreshPendingNotices()
        return result
    }

    private func savePendingDocument(token: Any, progress: Progress, publication: ArchiveSavePublication,
                                     sheet: ExtractionProgressSheet) async throws {
        await loadingTask?.value
        try ArchiveImportPlan.checkCancellation(progress)
        guard let session, let editor = pendingEditor else { throw CancellationError() }
        try await synchronizeDeferredLocation()
        deferredReloadFailure = nil
        splitSave.clearOutcome()
        var committedDate: Date?
        let snapshot = await session.snapshot()
        try await installEditor(editor, base: snapshot.entries, generation: snapshot.generation, session: session)
        let pending = editor.changes
        if try await pending.requiresReplay(base: snapshot.entries, generation: snapshot.generation) {
            // AppKit の外部変更シートを Save anyway で越えても、この照合は省かない。
            do { try await session.verifyDeferredIdentity() }
            catch {
                if session.isInvalidated || session.requiresSplitRecovery { throw error }
                throw Self.deferredExternalChangeError
            }
            if session.volumeLayout != nil {
                let result = try await publishSplitChanges(pending, base: snapshot.entries, generation: snapshot.generation,
                    progress: progress, publication: publication, sheet: sheet, willPublish: deferredWillPublish)
                committedDate = result.modificationDate
                deferredReloadFailure = result.reloadFailure
            } else {
                if let window = windowControllers.first?.window { sheet.begin(on: window) }
                let result = try await session.savePending(pending, baseGeneration: snapshot.generation,
                    progress: progress, publication: publication, willPublish: deferredWillPublish, willReload: deferredWillReload)
                deferredReloadFailure = result.reloadFailure
            }
            if pending.outputEncryption != nil { await forgetRememberedPassword(for: session) }
        }
        let modificationDate = try committedDate ?? Self.modificationDate(atPath: session.sourceURL.path)
        // 予約入口は保存中閉じている。AppKit に後着した変更数は token で保持する。
        disposePending()
        clearUndoHistory()
        await stagingCleanup?.value
        await displayAfterMutation()
        updateChangeCount(withToken: token, for: .saveOperation)
        fileModificationDate = modificationDate
        refreshPendingNotices()
    }

    /// 公開後に fileModificationDate へ据える値。AppKit の外部変更検出と揃えるため、公開直後の mtime を読む。
    private static func modificationDate(atPath path: String) throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private static func deferredSaveError(_ error: any Error) -> NSError {
        if error is CancellationError { return CocoaError(.userCancelled) as NSError }
        if let failure = error as? ArchiveSplitSaveFailure { return failure as NSError }
        return NSError(domain: KaitoFinderErrorDomain.deferred, code: 2, userInfo: [
            NSLocalizedDescriptionKey: ArchiveErrorText.describe(error), NSUnderlyingErrorKey: error as NSError
        ])
    }

    private static var deferredExternalChangeError: NSError {
        NSError(domain: KaitoFinderErrorDomain.deferred, code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "アーカイブが別のアプリで変更されました")
        ])
    }

    // XCTest と標準 Revert の共通処理。外部変更がなければ reader・世代を維持する。
    func revertPending() async throws {
        if let deferredSaveTask { try await deferredSaveTask.value; return }
        try await beginDeferredRevert().value
    }

    private func beginDeferredRevert() -> Task<Void, Error> {
        let token = changeCountToken(for: .saveOperation)
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        let task = Task {
            defer { finishDeferredSave() }
            try await performDeferredRevert(token: token)
        }
        deferredSave = DeferredSaveOperation(task: task)
        return task
    }

    func synchronizeDeferredLocation() async throws {
        guard let session, let url = fileURL,
              url.standardizedFileURL.resolvingSymlinksInPath() != session.sourceURL.standardizedFileURL.resolvingSymlinksInPath() else { return }
        try await session.followDeferredMove(to: url)
        disposeMaterialization()
    }

    private func performDeferredRevert(token: Any) async throws {
        await loadingTask?.value
        try Task.checkCancellation()
        guard let session, pendingEditor != nil, !closed else { throw CancellationError() }
        let loading = beginListLoading()
        var handedOff = false
        defer { if !handedOff { finishListLoading(loading) } }
        try await synchronizeDeferredLocation()
        var changed = false
        do { try await session.verifyDeferredIdentity() }
        catch { changed = true }
        if changed { try await session.reloadAfterMutation() }
        let modificationDate = try Self.modificationDate(atPath: session.sourceURL.path)
        disposePending()
        clearUndoHistory()
        await stagingCleanup?.value
        updateChangeCount(withToken: token, for: .saveOperation)
        handedOff = await displayAfterMutation(loading: loading)
        fileModificationDate = modificationDate
    }

    func adoptSplitCreationNotice(_ creator: ArchiveCreationController) {
        splitSaveNotice = creator.createdSplitNotice
        refreshPendingNotices()
    }

    func configureSplitCreation(_ creator: ArchiveCreationController) {
        creator.splitSaveHooks = splitSaveHooks
        creator.volumeRecoveryIndex = volumeRecoveryIndex
        creator.volumeMetadataStore = volumeMetadataStore
        creator.splitHazardConsent = { [weak self] location in
            guard let self else { throw CancellationError() }
            return try await self.consentToSplitHazard(location)
        }
    }

    func savePendingAs(using creator: ArchiveCreationController, on window: NSWindow?, progress: Progress) async throws {
        guard !closed, !isDeferredSaveRunning, !reservationInFlight, let session, let editor = pendingEditor else {
            throw ArchiveEditError.staleSelection
        }
        configureSplitCreation(creator)
        let token = changeCountToken(for: .saveOperation), publication = ArchiveSavePublication()
        (undoManager as? ArchiveUndoManager)?.isSuspended = true
        let task = Task {
            defer { finishDeferredSave() }
            await loadingTask?.value
            try ArchiveImportPlan.checkCancellation(progress)
            do { try await synchronizeDeferredLocation(); try await session.verifyDeferredIdentity() }
            catch {
                if session.isInvalidated || session.requiresSplitRecovery { throw error }
                throw Self.deferredExternalChangeError
            }
            var existing = try await ArchiveCreationController.existingArchive(from: session, progress: progress)
            try await installEditor(editor, base: existing.entries, generation: generation, session: session)
            existing.pending = try await ArchiveSaveReplayPlan.build(base: existing.entries, generation: generation,
                pending: editor.changes, format: session.reservationFormat, progress: progress)
            existing.publication = publication
            existing.encryption = await deferredEncryptionSettings()
            guard let destination = try await creator.create(sources: [], existing: existing, on: window, progress: progress,
                                                            willPublish: deferredWillPublish) else { return }
            let modificationDate = try Self.modificationDate(atPath: destination.path)
            // switchBackingFile の display が新しい世代へ旧予約を重ねないよう、切り替え時にだけ外す。
            try await switchBackingFile(to: destination, password: creator.createdEncryption.password)
            adoptSplitCreationNotice(creator)
            disposePending()
            clearUndoHistory()
            await stagingCleanup?.value
            await displayAfterMutation()
            updateChangeCount(withToken: token, for: .saveOperation)
            fileModificationDate = modificationDate
            refreshPendingNotices()
        }
        deferredSave = DeferredSaveOperation(task: task, progress: progress,
            cancellation: publication.watchCancellation(progress: progress) { task.cancel() },
            publication: publication, creation: creator)
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            publication.cancelBeforePublication(progress: progress) { task.cancel() }
        }
    }
}
