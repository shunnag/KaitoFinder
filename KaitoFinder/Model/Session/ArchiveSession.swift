import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization

/// スレッドセーフではない reader を所有し、値型の一覧だけを外へ渡す。
actor ArchiveSession {
    #if DEBUG
    nonisolated static let nameIndexChangeForTesting = TaskLocal<(@Sendable (ArchiveNameIndexChange) -> ArchiveNameIndexChange)?>(wrappedValue: nil)
    nonisolated static let readerAdoptionObserverForTesting = TaskLocal<(@Sendable (ArchiveReaderAdoption) -> Void)?>(wrappedValue: nil)
    nonisolated static let willAdoptReaderForTesting = TaskLocal<(@Sendable (ArchiveVerifiedOutput) -> Void)?>(wrappedValue: nil)
    private var promiseSourceForTesting: (any ByteSource)?
    func setPromiseSourceForTesting(_ source: any ByteSource) { promiseSourceForTesting = source }
    #endif

    typealias PasswordPrompt = @MainActor @Sendable (ArchivePasswordChallenge) async throws -> String
    nonisolated private let nameIndexCache = ArchiveNameIndexCache()
    private var reader: ArchiveReader?
    private(set) var password: String?
    private let allowsSplitSave: Bool
    private let allowsImmediateSplitSave: Bool
    private let volumeMetadataStore: ArchiveVolumeMetadataStore
    nonisolated private let splitRecoveryReason = Mutex<String?>(nil)
    nonisolated var requiresSplitRecovery: Bool { splitRecoveryReason.withLock { $0 != nil } }
    private var closed = false
    private var invalidated = false
    nonisolated private let invalidationStorage = Mutex(false)
    nonisolated var isInvalidated: Bool { invalidationStorage.withLock { $0 } }
    private var deferredUpdaterGeneration: UInt64?
    nonisolated private let pendingReading = Mutex<(enabled: Bool, snapshot: ArchivePendingReadSnapshot?)>((false, nil))
    nonisolated var usesPendingReading: Bool { pendingReading.withLock { $0.enabled } }
    nonisolated var pendingReadSnapshot: ArchivePendingReadSnapshot? { pendingReading.withLock { $0.snapshot } }
    nonisolated func setPendingReadSnapshot(_ snapshot: ArchivePendingReadSnapshot?) {
        var previous = pendingReading.withLock { state in
            let previous = state.snapshot
            state = (true, snapshot)
            return previous
        }
        ArchiveBackgroundRelease.release(&previous)
    }
    private var verifiedEntries: Set<Int> = []
    nonisolated private let verificationStorage = Mutex<ArchiveEntryVerification?>(nil)
    nonisolated var entryVerification: ArchiveEntryVerification? { verificationStorage.withLock { $0 } }

    private func rememberVerification() {
        verificationStorage.withLock { $0 = .init(identity: sourceIdentity, indices: verifiedEntries) }
    }

    private func mergeVerification(_ indices: Set<Int>) {
        if !indices.isEmpty {
            // 同期参照の Set を先に離し、行ごとの検証で全件の COW コピーを繰り返さない。
            verificationStorage.withLock { $0 = nil }
            verifiedEntries.formUnion(indices)
        }
        rememberVerification()
    }

    private func clearVerification() {
        verifiedEntries.removeAll()
        verificationStorage.withLock { $0 = nil }
    }
    private var passwordRevision: UInt64 = 0
    // UI の接続だけは同期的に済ませ、display 直後の読み出しとの競合を避ける。
    nonisolated private let promptStorage = Mutex<PasswordPrompt?>(nil)
    typealias PasswordAcceptance = @MainActor @Sendable (String, UInt64) async -> Void
    nonisolated private let passwordAcceptance = Mutex<PasswordAcceptance?>(nil)
    nonisolated private let capabilitiesObserver = Mutex<(@MainActor @Sendable () -> Void)?>(nil)
    nonisolated private let capabilitiesStorage: Mutex<ArchiveCapabilities>
    nonisolated var capabilities: ArchiveCapabilities { capabilitiesStorage.withLock { $0 } }
    nonisolated private let generationStorage = Mutex<UInt64>(0)
    nonisolated var generation: UInt64 { generationStorage.withLock { $0 } }
    nonisolated private let sourceURLStorage: Mutex<URL>
    nonisolated var sourceURL: URL { sourceURLStorage.withLock { $0 } }
    nonisolated private let formatStorage: Mutex<KaitoKit.ArchiveFormat>
    nonisolated var format: KaitoKit.ArchiveFormat { formatStorage.withLock { $0 } }
    nonisolated private let encryptionStorage: Mutex<EncryptionState>
    private struct EncryptionState: Sendable {
        var hasEncryptedEntries: Bool
        var hasKnownPassword: Bool
    }
    nonisolated var hasEncryptedEntries: Bool { encryptionStorage.withLock { $0.hasEncryptedEntries } }
    nonisolated var hasKnownPassword: Bool { encryptionStorage.withLock { $0.hasKnownPassword } }
    nonisolated var passwordFormat: GyoshukuKit.ArchiveFormat? {
        switch format {
        case .zip: .zip
        case .sevenZip: .sevenZip
        default: nil
        }
    }
    private var encryptsSevenZipHeaders = false
    private(set) var sourceIdentity: ArchiveSetIdentity
    nonisolated private let volumeLayoutStorage: Mutex<ArchiveVolumeLayout?>
    nonisolated var volumeLayout: ArchiveVolumeLayout? { volumeLayoutStorage.withLock { $0 } }
    nonisolated let writerOptions: @Sendable (GyoshukuKit.ArchiveFormat) -> WriterOptions
    nonisolated private let importOptions: @Sendable () -> ArchiveImportPlan.Options
    private(set) var quarantine: Data?

    init(url: URL, password: String? = nil, allowsSplitSave: Bool = false, allowsImmediateSplitSave: Bool = false,
         volumeMetadataStore: ArchiveVolumeMetadataStore = .shared,
         writerOptions: @escaping @Sendable (GyoshukuKit.ArchiveFormat) -> WriterOptions = { _ in WriterOptions() },
         importOptions: @escaping @Sendable () -> ArchiveImportPlan.Options = { .init() }) throws {
        self.allowsSplitSave = allowsSplitSave
        self.allowsImmediateSplitSave = allowsImmediateSplitSave
        self.volumeMetadataStore = volumeMetadataStore
        sourceURLStorage = Mutex(url)
        self.password = password
        self.writerOptions = writerOptions
        self.importOptions = importOptions
        let original = try ArchiveSetIdentity.capture(url: url)
        let reader = try ArchiveReader.open(url: url, options: .kaitoFinder(password: password))
        let metadata = try ArchiveVolumeMetadata.inspect(url: url, volumeSet: reader.volumeSet, store: volumeMetadataStore)
        let layout = metadata.layout
        let identity = try Self.currentIdentity(url: url, layout: layout)
        // 後からパスを調べるだけでは、reader の組み立て中に差し替わった巻を採用してしまう。
        guard identity.volumes == (reader.volumeSet.map { ArchiveSetIdentity(volumeSet: $0) } ?? original).volumes else {
            throw ArchiveEditError.archiveChanged
        }
        sourceIdentity = identity
        volumeLayoutStorage = Mutex(layout)
        quarantine = try ExtractionQuarantine.firstValue(from: layout?.volumes.map(\.url) ?? [url]) {} ?? metadata.quarantine
        self.reader = reader
        formatStorage = Mutex(reader.format)
        // 開いたばかりの reader を渡し、編集可否のために書庫を開き直さない（actor 内で所有したまま読む）。
        capabilitiesStorage = Mutex(ArchiveCapabilities.inspect(reader: reader, url: url, password: password,
            splitLayout: layout, allowsSplitSave: allowsSplitSave, allowsImmediateSplitSave: allowsImmediateSplitSave, mixedVolumes: metadata.mixed))
        encryptionStorage = Mutex(EncryptionState(hasEncryptedEntries: reader.entries.contains(where: \.isEncrypted),
                                                  hasKnownPassword: password != nil))
        encryptsSevenZipHeaders = Self.hasEncryptedHeaders(url: url, format: reader.format, password: password)
        guard try Self.currentIdentity(url: url, layout: layout) == identity else { throw ArchiveEditError.archiveChanged }
    }

    func extractionReader() throws -> sending ArchiveReader {
        let reader = try requireCurrentReader()
        return try reader.reopen()
    }

    func extractionSnapshot(progress: Progress? = nil) async throws -> sending (reader: ArchiveReader, quarantine: Data?) {
        let entries = try requireCurrentReader().entries
        try await prepareEncryptedEntries(entries, generation: generation, progress: progress)
        return (try requireCurrentReader().reopen(), quarantine)
    }

    func preparedPassword(progress: Progress? = nil) async throws -> String? {
        let expectedGeneration = generation
        let entries = try requireCurrentReader().entries
        try await prepareEncryptedEntries(entries, generation: expectedGeneration, progress: progress)
        try checkReadRequest(generation: expectedGeneration)
        return password
    }

    private func requireCurrentReader() throws -> ArchiveReader {
        guard !closed, let reader else { throw CancellationError() }
        guard !invalidated else { throw ExtractionFailure.refused(String(localized: "変更後のアーカイブを読み直せませんでした。")) }
        // reopenは旧inodeを保持する。文書を開いてからの置換・削除を先に検出する。
        let current = try Self.currentIdentity(url: sourceURL, layout: volumeLayout)
        guard usesPendingReading ? current.contentEquals(sourceIdentity) : current == sourceIdentity else {
            clearVerification()
            throw ArchiveEditError.archiveChanged
        }
        return reader
    }

    private static func currentIdentity(url: URL, layout: ArchiveVolumeLayout?) throws -> ArchiveSetIdentity {
        guard let layout else { return try ArchiveSetIdentity.capture(url: url) }
        do { return try ArchiveSetIdentity.capture(layout: layout) }
        // 巻の削除や次の巻の出現も、開いているセットの外部変更として扱う。
        catch { throw ArchiveEditError.archiveChanged }
    }

    nonisolated func setPasswordPrompt(_ prompt: PasswordPrompt?) {
        promptStorage.withLock { $0 = prompt }
    }

    nonisolated func setPasswordAcceptance(_ accepted: PasswordAcceptance?) {
        passwordAcceptance.withLock { $0 = accepted }
    }

    nonisolated func setCapabilitiesObserver(_ observer: (@MainActor @Sendable () -> Void)?) {
        capabilitiesObserver.withLock { $0 = observer }
    }

    // entry ごとのエラーが文字列になる前に認証を完了する。出力はまだ作らないので、
    // 途中でパスワードを取り消しても、複数項目の一部だけを公開することがない。
    private func prepareEncryptedEntries(_ entries: [ArchiveEntry], generation expectedGeneration: UInt64,
                                         progress: Progress? = nil) async throws {
        let encrypted = entries.filter(\.isEncrypted)
        guard !encrypted.isEmpty else { return }
        while true {
            try checkReadRequest(generation: expectedGeneration)
            do {
                mergeVerification(try verify(encrypted.filter { !verifiedEntries.contains($0.index) },
                                             using: requireCurrentReader(), progress: progress))
                return
            } catch {
                guard var challenge = ArchivePasswordChallenge(error), let prompt = promptStorage.withLock({ $0 }) else {
                    throw error
                }
                let revision = passwordRevision
                while true {
                    let candidate = try await prompt(challenge)
                    try checkReadRequest(generation: expectedGeneration)
                    // 複数の file promise が同じシートを待っていた場合は、先に採用された値を使う。
                    if revision != passwordRevision { break }
                    do {
                        let replacement = try ArchiveReader.open(url: sourceURL, options: .kaitoFinder(password: candidate))
                        guard replacement.entries == (try requireCurrentReader().entries) else {
                            throw ExtractionFailure.refused(String(localized: "アーカイブが変更されています。開き直してください。"))
                        }
                        if let volumeSet = replacement.volumeSet,
                           ArchiveSetIdentity(volumeSet: volumeSet) != sourceIdentity {
                            throw ArchiveEditError.archiveChanged
                        }
                        let verified = try verify(encrypted, using: replacement, progress: progress)
                        try checkReadRequest(generation: expectedGeneration)
                        // 間違った候補は保持しない。採用は検証が最後まで成功した時だけ。
                        reader = replacement
                        password = candidate
                        passwordRevision &+= 1
                        verifiedEntries = verified
                        rememberVerification()
                        refreshCapabilities()
                        // Only the request's verified entries authorize persistence; no second archive pass.
                        let accepted = passwordAcceptance.withLock { callback in
                            let result = callback
                            callback = nil
                            return result
                        }
                        await accepted?(candidate, expectedGeneration)
                        try checkReadRequest(generation: expectedGeneration)
                        return
                    } catch {
                        guard let next = ArchivePasswordChallenge(error) else { throw error }
                        challenge = next
                    }
                }
            }
        }
    }

    private func checkReadRequest(generation expectedGeneration: UInt64) throws {
        try Task.checkCancellation()
        _ = try requireCurrentReader()
        guard generation == expectedGeneration else {
            throw ExtractionFailure.refused(String(localized: "アーカイブが変更されています。開き直してください。"))
        }
    }

    @discardableResult private func verify(_ entries: [ArchiveEntry], using reader: ArchiveReader,
                                           progress: Progress? = nil) throws -> Set<Int> {
        guard !entries.isEmpty else { return [] }
        let threads = writerOptions(passwordFormat ?? .zip).compressionThreads
            ?? ArchiveHardware.current.automaticCompressionThreads
        return try ArchivePasswordVerification.verify(entries, using: reader, workers: max(1, threads), progress: progress)
    }

    func close() {
        closed = true
        password = nil
        reader = nil
        clearVerification()
        promptStorage.withLock { $0 = nil }
        passwordAcceptance.withLock { $0 = nil }
        capabilitiesObserver.withLock { $0 = nil }
        passwordRevision &+= 1
        encryptionStorage.withLock { $0.hasKnownPassword = false }
    }

    // 確認 UI を待つ間は書かず、回答後に世代と原本を再検証する。公開と再読込は直列。
    nonisolated func nameIndex(generation: UInt64, format: GyoshukuKit.ArchiveFormat) -> ArchiveNameIndex? {
        nameIndexCache.index(generation: generation, format: format)
    }

    nonisolated func adoptNameIndex(_ index: ArchiveNameIndex) {
        nameIndexCache.adopt(index)
    }

    nonisolated func adoptNameIndex(validation: ArchiveReservationValidation?, generation: UInt64) {
        nameIndexCache.adopt(validation: validation, generation: generation)
    }

    func availableNameIndex() -> ArchiveNameIndex? {
        guard !closed, !invalidated else { return nil }
        return nameIndex(generation: generation, format: reservationFormat)
    }

    func currentNameIndex() -> ArchiveNameIndex? {
        #if DEBUG
        if ArchiveNameIndexCache.disabledForTesting.get() { return nil }
        #endif
        if let index = availableNameIndex() { return index }
        guard !closed, !invalidated, let reader else { return nil }
        let index = ArchiveStageDiagnostics.measure(.nameIndexBuild) {
            ArchiveNameIndex.build(entries: reader.entries, generation: generation, format: reservationFormat,
                                   provingRepresentability: false, checksCancellation: true)
        }
        if let index { adoptNameIndex(index) }
        return index
    }

    nonisolated func prepareNameIndex(generation: UInt64) async -> ArchiveNameIndex? {
        #if DEBUG
        if ArchiveNameIndexCache.disabledForTesting.get() { return nil }
        #endif
        if let index = nameIndex(generation: generation, format: reservationFormat) { return index }
        guard let input = await nameIndexInput(generation: generation) else { return nil }
        let index = await Self.buildNameIndex(entries: input.entries, generation: generation, format: input.format)
        if let index { adoptNameIndex(index) }
        return nameIndex(generation: generation, format: input.format)
    }

    private func nameIndexInput(generation: UInt64) -> (entries: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat)? {
        guard !closed, !invalidated, self.generation == generation, let reader else { return nil }
        return (reader.entries, reservationFormat)
    }

    @concurrent private static func buildNameIndex(entries: [ArchiveEntry], generation: UInt64,
                                                   format: GyoshukuKit.ArchiveFormat) async -> ArchiveNameIndex? {
        ArchiveReservationDiagnostics.record(.renameIndex)
        defer { ArchiveReservationDiagnostics.record(.renameIndexBuilt) }
        return ArchiveStageDiagnostics.measure(.nameIndexBuild) {
            ArchiveNameIndex.build(entries: entries, generation: generation, format: format,
                                   provingRepresentability: false, checksCancellation: true)
        }
    }

    private func validatePendingRepresentability(_ pending: ArchivePendingChanges, plan: ArchiveSaveReplayPlan,
                                                  base: [ArchiveEntry], generation: UInt64,
                                                  format: GyoshukuKit.ArchiveFormat) throws {
        guard format == reservationFormat, let index = nameIndex(generation: generation, format: format),
              index.entryCount == base.count, index.representable, !index.containsHardLinks else {
            try ArchiveSaveReplayPlan.validateRepresentability(plan.projected, format: format)
            return
        }
        try ArchiveStageDiagnostics.measure(.representabilityDifferential) {
            let removed = pending.removals.map(\.index).sorted()
            try ArchiveReservationValidation(base: base, format: format, index: index)
                .validate(pending, projected: plan.projected, position: { index in
                    if index >= base.count { return index - removed.count }
                    var lower = 0, upper = removed.count
                    while lower < upper {
                        let middle = (lower + upper) / 2
                        if removed[middle] < index { lower = middle + 1 } else { upper = middle }
                    }
                    return lower < removed.count && removed[lower] == index ? nil : index - lower
                })
        }
    }

    func append(urls: [URL], to folder: String, progress: Progress,
                resolveConflict: ArchiveImportConflict.Resolver? = nil,
                didProcess: (@Sendable (Int) throws -> Void)? = nil,
                willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveImportResult {
        let reader = try requireCurrentReader()
        guard capabilities.canEdit else { throw capabilities.editRefusal }
        try verifyBeforeEditing(progress: progress)
        let expectedGeneration = generation
        let occupancy = currentNameIndex()?.overlay
        let plan: ArchiveImportPlan
        if let resolveConflict {
            plan = try await ArchiveImportPlan.resolving(urls: urls, folder: folder, existing: reader.entries,
                archive: sourceURL, generation: expectedGeneration, progress: progress, options: importOptions(),
                format: reservationFormat, occupancy: occupancy, resolver: resolveConflict)
            _ = try requireCurrentReader()
            guard generation == expectedGeneration else { throw ArchiveEditError.staleSelection }
        } else {
            plan = try ArchiveStageDiagnostics.measure(.planBuild) {
                try ArchiveImportPlan.build(urls: urls, folder: folder, existing: reader.entries,
                                            progress: progress, options: importOptions(), format: reservationFormat, occupancy: occupancy)
            }
        }
        let (_, mode, options) = resolvedWriteMode()
        var (result, verified, publishedMode) = try publishVerified(mode: mode) { verifiedOutput in
            try ArchiveImportTransaction.run(plan: plan, archive: sourceURL, mode: mode,
                                             options: options, password: password, progress: progress,
                                             didProcess: didProcess, willPublish: willPublish, expectedIdentity: sourceIdentity, verifiedOutput: verifiedOutput,
                                             sessionReader: mode.reusesSessionReader ? try reader.reopen() : nil)
        }
        if !result.addedPaths.isEmpty {
            // 公開済みの書き込みと表示の失敗を区別し、旧 byte に戻ったとは報告しない。
            do { try reloadAfterMutation(verification: result.publishedIdentity.map { .init(identity: $0, indices: nil) }, adopting: consume verified, advancing: ArchiveNameIndexChange(removed: plan.replacingEntries, appended: plan.items.map { ($0.path, $0.isDirectory) }, mode: publishedMode)) }
            catch { result.reloadFailure = Self.reloadFailureMessage }
        }
        return result
    }

    func move(_ selections: [ArchiveEditSelection], to folder: String, progress: Progress,
              resolveConflict: ArchiveImportConflict.Resolver?,
              willPublish: (@Sendable () throws -> Void)? = nil) async throws -> ArchiveEditResult {
        guard let resolveConflict else {
            return try edit(moving: selections.map { .init(selection: $0, folder: folder) },
                            progress: progress, willPublish: willPublish)
        }
        let entries = try requireCurrentReader().entries, expectedGeneration = generation
        #if DEBUG
        var planning = ArchiveStageDiagnostics.begin(.planBuild)
        defer { planning?.end() }
        #endif
        let occupancy = currentNameIndex()?.overlay
        let target = folder.isEmpty ? "" : try ArchiveImportPlan.path(folder, format: reservationFormat)
        _ = try ArchiveImportPlan.build(urls: [], folder: target, existing: entries, progress: progress, format: reservationFormat, occupancy: occupancy)
        var moving: [ArchiveEditSelection] = [], candidates: [ArchiveConflictResolution.Candidate] = []
        for selection in selections {
            let source = try ArchiveImportPlan.path(selection.path, format: reservationFormat)
            if ArchivePath.components(source).dropLast().joined(separator: "/") == target { continue }
            if selection.isDirectory, target == source || ArchivePath.isDescendant(target, of: source) {
                throw ArchiveEditError.destinationInsideSource(source)
            }
            let leaf = ArchivePath.components(source).last!
            let destination = target.isEmpty ? leaf : target + "/" + leaf
            moving.append(selection)
            candidates.append(.init(path: destination, info: .archived(selection.entries, path: source,
                                                                         archive: sourceURL, generation: expectedGeneration)))
        }
        let groups = ArchiveConflictResolution.existingGroups(entries, folder: target, matching: Set(candidates.map(\.path)), occupancy: occupancy)
        #if DEBUG
        planning?.end()
        planning = nil
        #endif
        let resolution = try await ArchiveConflictResolution.resolve(candidates,
            existing: groups, archive: sourceURL,
            generation: expectedGeneration, progress: progress, resolver: resolveConflict)
        #if DEBUG
        planning = ArchiveStageDiagnostics.begin(.planBuild)
        #endif
        _ = try requireCurrentReader()
        guard generation == expectedGeneration else { throw ArchiveEditError.staleSelection }
        // 各 record の削除を指定し、同名の実体と仮想フォルダが混在する書庫も取りこぼさない。
        let removals = resolution.replaced.map {
            ArchiveEditSelection(path: $0.name, isDirectory: false, entries: [$0])
        }
        let moves = resolution.accepted.map { ArchiveEditMove(selection: moving[$0], folder: target) }
        #if DEBUG
        planning?.end()
        planning = nil
        #endif
        return try edit(removing: removals, moving: moves,
                        progress: progress, willPublish: willPublish)
    }

    func remove(_ selections: [ArchiveEditSelection], progress: Progress,
                willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveEditResult {
        try edit(removing: selections, progress: progress, willPublish: willPublish)
    }

    func createFolder(in folder: String, baseName: String = String(localized: "名称未設定フォルダ"), progress: Progress,
                      willOpenUpdater: (@Sendable () throws -> Void)? = nil,
                      willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveImportResult {
        let reader = try requireCurrentReader()
        guard capabilities.canEdit else { throw capabilities.editRefusal }
        try ArchiveImportPlan.checkCancellation(progress)
        try verifyBeforeEditing(progress: progress)
        // 名前決定も同じ actor 内で行い、連続した作成が同じ空き名を予約しないようにする。
        let plan = try ArchiveStageDiagnostics.measure(.planBuild) {
            try ArchiveNewFolderPlan.build(in: folder, baseName: baseName, existing: reader.entries, format: reservationFormat, occupancy: currentNameIndex()?.overlay)
        }
        let (_, mode, options) = resolvedWriteMode()
        var (result, verified, publishedMode) = try publishVerified(mode: mode) { verifiedOutput in
            try ArchiveImportTransaction.createFolder(plan: plan, archive: sourceURL, mode: mode,
                                                      options: options, password: password, progress: progress,
                                                      willOpenUpdater: willOpenUpdater, willPublish: willPublish, expectedIdentity: sourceIdentity, verifiedOutput: verifiedOutput,
                                                      sessionReader: mode.reusesSessionReader ? try reader.reopen() : nil)
        }
        do { try reloadAfterMutation(verification: result.publishedIdentity.map { .init(identity: $0, indices: nil) }, adopting: consume verified, advancing: ArchiveNameIndexChange(appended: [(plan.path, true)], mode: publishedMode)) }
        catch { result.reloadFailure = Self.reloadFailureMessage }
        return result
    }

    func rename(_ selection: ArchiveEditSelection, to name: String, progress: Progress,
                willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveEditResult {
        try edit(renaming: [ArchiveEditRename(selection: selection, name: name)],
                 progress: progress, willPublish: willPublish)
    }

    // 部分木の検証から公開後の再読込まで await を挟まず、一操作を一世代にまとめる。
    func edit(removing: [ArchiveEditSelection] = [], renaming: [ArchiveEditRename] = [],
              moving: [ArchiveEditMove] = [], progress: Progress,
              willOpenUpdater: (@Sendable () throws -> Void)? = nil,
              willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveEditResult {
        let reader = try requireCurrentReader()
        // canEdit は編集の共通門番。拒否理由も追加と揃える。
        guard capabilities.canEdit else { throw capabilities.editRefusal }
        try ArchiveImportPlan.checkCancellation(progress)
        try verifyBeforeEditing(progress: progress)
        let occupancy = (renaming.isEmpty && moving.isEmpty ? availableNameIndex() : currentNameIndex())?.overlay
        let plan = try ArchiveStageDiagnostics.measure(.planBuild) {
            try ArchiveEditPlan.build(removing: removing, renaming: renaming, moving: moving,
                                      existing: reader.entries, format: reservationFormat, occupancy: occupancy)
        }
        let (_, mode, options) = resolvedWriteMode()
        var (result, verified, publishedMode) = try publishVerified(mode: mode) { verifiedOutput in
            try ArchiveEditTransaction.run(plan: plan, archive: sourceURL, mode: mode,
                                           options: options, password: password, progress: progress,
                                           willOpenUpdater: willOpenUpdater, willPublish: willPublish, expectedIdentity: sourceIdentity, verifiedOutput: verifiedOutput,
                                           sessionReader: mode.reusesSessionReader ? try reader.reopen() : nil, occupancy: occupancy)
        }
        if result.published {
            do { try reloadAfterMutation(verification: result.publishedIdentity.map { .init(identity: $0, indices: nil) }, adopting: consume verified, advancing: ArchiveNameIndexChange(plan: plan, mode: publishedMode)) }
            catch { result.reloadFailure = Self.reloadFailureMessage }
        }
        return result
    }

    func prepareDeferredEditing() {
        guard format == .zip, volumeLayout == nil, deferredUpdaterGeneration != generation,
              capabilities.canEdit else { return }
        #if DEBUG
        let span = ArchiveStageDiagnostics.begin(.updaterPreparation)
        defer { span?.end() }
        #endif
        ArchiveReservationDiagnostics.record(.updaterPreparation)
        // 失敗は従来どおり編集入口で提示し、読める書庫の表示は妨げない。
        do {
            try verifyDeferredIdentity()
            _ = try ArchiveUpdater.open(url: sourceURL)
            try verifyDeferredIdentity()
            deferredUpdaterGeneration = generation
        } catch { }
    }

    // 保存前モードでも認証と外部変更の門番は session が所有する。
    func deferredSnapshot(progress: Progress? = nil) throws -> (entries: [ArchiveEntry], generation: UInt64) {
        try verifyDeferredIdentity()
        let reader = try requireCurrentReader()
        if allowsSplitSave || allowsImmediateSplitSave, volumeLayout != nil { refreshCapabilities() }
        guard capabilities.canEdit else { throw capabilities.editRefusal }
        try verifyBeforeEditing(progress: progress)
        if format == .zip, volumeLayout == nil, deferredUpdaterGeneration != generation {
            // probe は終端だけ。CD と local record の照合は open を一世代につき一度通す。
            ArchiveReservationDiagnostics.record(.deferredUpdaterOpen)
            try publishing { _ = try ArchiveUpdater.open(url: sourceURL) }
            deferredUpdaterGeneration = generation
        }
        return (reader.entries, generation)
    }

    func verifyDeferredIdentity() throws {
        if let reason = splitRecoveryReason.withLock({ $0 }) { throw ExtractionFailure.refused(reason) }
        guard !invalidated else { throw ExtractionFailure.refused(String(localized: "変更後のアーカイブを読み直せませんでした。")) }
        let current = try Self.currentIdentity(url: sourceURL, layout: volumeLayout)
        guard current.contentEquals(sourceIdentity) else {
            throw ArchiveEditError.archiveChanged
        }
        // 公開側には最新の mode を渡し、処理中の変更は従来どおり照合する。
        sourceIdentity = current
    }

    func followDeferredMove(to url: URL) throws {
        guard url != sourceURL else { return }
        guard (usesPendingReading || allowsImmediateSplitSave), !invalidated, !requiresSplitRecovery else { throw ArchiveEditError.archiveChanged }
        if let layout = volumeLayout {
            guard url.lastPathComponent == sourceURL.lastPathComponent else { throw ArchiveEditError.archiveChanged }
            var moved = ArchiveVolumeLayout(scheme: layout.scheme, volumes: layout.volumes.map {
                .init(url: url.deletingLastPathComponent().appendingPathComponent($0.url.lastPathComponent), length: $0.length)
            }, openedVolumeIndex: layout.openedVolumeIndex)
            moved.savedSchedule = layout.savedSchedule
            let current = try ArchiveSetIdentity.capture(layout: moved)
            // Names are unchanged by a containing-folder move; every member and the absent tail must agree.
            guard current.contentEquals(sourceIdentity) else { throw ArchiveEditError.archiveChanged }
            try reanchorSplitReader(at: url, layout: moved, identity: current)
            return
        }
        let current = try ArchiveSetIdentity.capture(url: url)
        guard current.contentEqualsAfterMove(sourceIdentity) else { throw ArchiveEditError.archiveChanged }
        sourceURLStorage.withLock { $0 = url }
        sourceIdentity = current
    }

    /// Neither a proved rollback nor a folder move changes entries or the pending plan's generation.
    private func reanchorSplitReader(at url: URL, layout: ArchiveVolumeLayout, identity: ArchiveSetIdentity) throws {
        let replacement = try ArchiveReader.open(url: url, options: .kaitoFinder(password: password))
        let assembled = try replacement.volumeSet.map { ArchiveSetIdentity(volumeSet: $0) } ?? ArchiveSetIdentity.capture(url: url)
        guard assembled.volumes == identity.volumes,
              try ArchiveSetIdentity.capture(layout: layout) == identity else { throw ArchiveEditError.archiveChanged }
        reader = replacement
        sourceURLStorage.withLock { $0 = url }
        sourceIdentity = identity
        volumeLayoutStorage.withLock { $0 = layout }
        refreshCapabilities()
    }

    func validateDeferredPassword(progress: Progress? = nil) throws {
        _ = try deferredSnapshot(progress: progress)
    }

    func savePending(_ pending: ArchivePendingChanges, baseGeneration: UInt64, progress: Progress,
                     publication: ArchiveSavePublication,
                     willPublish: (@Sendable () throws -> Void)? = nil,
                     willReload: (@Sendable () throws -> Void)? = nil) throws -> ArchivePasswordEditResult {
        guard volumeLayout == nil else { throw ArchiveEditError.splitArchive }
        let snapshot = try deferredSnapshot(progress: progress)
        guard snapshot.generation == baseGeneration else { throw ArchiveEditError.staleSelection }
        let plan = try ArchiveSaveReplayPlan(base: snapshot.entries, generation: baseGeneration, pending: pending,
                                            format: reservationFormat, progress: progress,
                                            baseOccupancy: availableNameIndex()?.occupancy)
        guard !plan.isEmpty else { return .init() }
        let resolved = resolvedWriteMode()
        var output = resolved.options
        var mode = resolved.mode
        if let encryption = plan.outputEncryption {
            guard let format = passwordFormat else { throw ArchiveEditError.staleSelection }
            output = encryption.applying(to: writerOptions(format), format: format)
            mode = resolved.base.resolved(with: output)
            if format == .sevenZip, case .update = mode, capabilities.sevenZipAssessment?.canReencrypt != true {
                mode = .rewrite(.sevenZip)
            }
        }
        let outputFormat = mode.outputFormat
        try validatePendingRepresentability(pending, plan: plan, base: snapshot.entries, generation: baseGeneration, format: outputFormat)
        let counted = plan.edits.removals.count + plan.edits.renames.count + plan.folders.count
        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: counted,
            additions: plan.additions.map { $0.sourceStamp.kind == .file ? $0.stagedStamp.size : 0 },
            itemCount: counted + plan.additions.count, carriedBytes: ArchiveWriteProgress.carriedBytes(plan.projected),
            changesExisting: !plan.edits.removals.isEmpty || !plan.edits.renames.isEmpty || plan.outputEncryption != nil))
        let zipEncryption: ArchiveOutputProjection.ExpectedZipEncryption? =
            outputFormat == .zip && plan.outputEncryption != nil ? .init(output) : nil
        let sevenZipEncryption: Bool? = outputFormat == .sevenZip && plan.outputEncryption != nil ? output.password != nil : nil
        let quarantine = try ExtractionQuarantine.firstValue(from: plan.additions.map(\.stagedURL)) {
            try ArchiveImportPlan.checkCancellation(progress)
        }
        let sourcePassword = password
        let (identity, verified, publishedMode) = try publishing {
            let verifiedOutput = ArchiveVerifiedOutputSink()
            func publish(_ mode: ArchiveCapabilities.Mode) throws -> ArchiveSetIdentity {
                return try ArchiveImportTransaction.publish(archive: sourceURL, mode: mode, options: output, password: password,
                    progress: progress, ledger: ledger, willPublish: {
                        try plan.validate()
                        try willPublish?()
                    }, expectedIdentity: sourceIdentity, verifiedOutput: verifiedOutput,
                    sessionReader: mode.reusesSessionReader ? try requireCurrentReader().reopen() : nil,
                    additionalQuarantine: quarantine,
                    publication: publication, deferredPlan: plan,
                    expectedOutput: .init(plan: plan, mode: mode, zipEncryption: zipEncryption, sevenZipEncryption: sevenZipEncryption)) { editor in
                        try plan.replay(on: editor, sourcePassword: sourcePassword, progress: progress,
                                        preservingOwnerIDs: output.preserveOwnerIDs && outputFormat.isTarFamily, ledger: ledger)
                    }
            }
            let identity: ArchiveSetIdentity
            do { identity = try publish(mode) }
            catch UpdaterError.nonRelocatableEntry where zipEncryption != nil {
                ledger.reset()
                identity = try publish(.rewrite(.zip))
            }
            return (identity, verifiedOutput.take(), verifiedOutput.publishedMode ?? .rewrite(outputFormat))
        }
        if let encryption = plan.outputEncryption {
            password = encryption.password
            passwordRevision &+= 1
            encryptsSevenZipHeaders = encryption.encryptsSevenZipHeaders
        }
        do { try reloadAfterMutation(willOpen: willReload, verification: .init(identity: identity, indices: nil), adopting: consume verified, advancing: .init(plan: plan, mode: publishedMode)); return .init() }
        catch { return .init(reloadFailure: Self.reloadFailureMessage) }
    }

    func savePendingSplit(_ pending: ArchivePendingChanges, baseGeneration: UInt64, target: VolumeSetTarget,
                          estimatedLength: UInt64, progress: Progress, publication: ArchiveSavePublication,
                          index: RecoverableWorkIndex, hooks: ArchiveSplitSaveHooks,
                          willPublish: (@Sendable () throws -> Void)?, willReload: (@Sendable () throws -> Void)?) throws -> ArchiveSplitSaveResult {
        let snapshot = try deferredSnapshot(progress: progress)
        guard capabilities.splitSave, target.filePresenter != nil,
              target.layout == (try volumeLayout?.publicationLayout()), target.expected == sourceIdentity,
              snapshot.generation == baseGeneration else { throw ArchiveEditError.staleSelection }
        let plan = try ArchiveSaveReplayPlan(base: snapshot.entries, generation: baseGeneration, pending: pending,
                                            format: reservationFormat, progress: progress,
                                            baseOccupancy: availableNameIndex()?.occupancy)
        let resolved = resolvedWriteMode()
        var output = resolved.options
        var mode = resolved.mode
        if let encryption = plan.outputEncryption {
            guard let format = passwordFormat else { throw ArchiveEditError.staleSelection }
            mode = format == .zip ? .inPlace : .rewrite(format)
            output = encryption.applying(to: writerOptions(format), format: format)
        }
        let format = mode.outputFormat
        try validatePendingRepresentability(pending, plan: plan, base: snapshot.entries, generation: baseGeneration, format: format)
        var target = target
        target.writesVolumeMetadata = true
        target.additionalQuarantine = try quarantine ?? ExtractionQuarantine.firstValue(from: plan.additions.map(\.stagedURL)) {
            try ArchiveImportPlan.checkCancellation(progress)
        }
        do {
            let result = try ArchiveSplitSavePipeline.run(target: target, estimatedLength: estimatedLength, plan: plan,
                password: output.password, zipEncryption: format == .zip && plan.outputEncryption != nil ? .init(output) : nil,
                progress: progress, publication: publication, index: index,
                metadataStore: volumeMetadataStore, hooks: hooks, willPublish: willPublish, keepsPendingChanges: allowsSplitSave) { split in
                    guard let input = split.input else { throw VolumePublishError.invalidPlan }
                    return try ArchiveSplitWorkProducer.produce(source: input, workURL: split.workURL, mode: mode,
                        password: password, options: output, plan: plan, progress: progress,
                        verifyAssembledInput: { try split.verifyAssembledInput($0, progress: progress) })
                }
            if let encryption = plan.outputEncryption {
                password = encryption.password; passwordRevision &+= 1
                encryptsSevenZipHeaders = encryption.encryptsSevenZipHeaders
            }
            let failure: String?
            do { try reloadAfterMutation(willOpen: willReload, verification: .init(identity: result.published.identity, indices: nil), advancing: .init(plan: plan, mode: result.mode)); failure = nil }
            catch { failure = Self.reloadFailureMessage }
            return ArchiveSplitSaveResult(published: result.published, reloadFailure: failure, recompressedZIP: result.recompressedZIP)
        } catch is CancellationError { throw CancellationError() }
        catch {
            var failure = (error as? ArchiveSplitSaveFailure) ?? ArchiveSplitSaveFailure.map(error, staging: nil)
            if failure.kind == .rolledBack, let layout = volumeLayout {
                do {
                    guard let identity = failure.restoredIdentity else { throw ArchiveEditError.archiveChanged }
                    try reanchorSplitReader(at: sourceURL, layout: layout, identity: identity)
                } catch {
                    failure = ArchiveSplitSaveFailure(kind: .held, staging: failure.staging, diagnostic: ArchiveErrorText.describe(error),
                                                      keepsPendingChanges: allowsSplitSave)
                }
            }
            if failure.requiresReopen {
                let reason = failure.errorDescription!
                splitRecoveryReason.withLock { $0 = reason }
                capabilitiesStorage.withLock { $0 = ArchiveCapabilities(refusal: .unavailable(reason)) }
                notifyCapabilitiesChanged()
            }
            throw failure
        }
    }

    /// capabilities の mode に現在の暗号化設定と writer の設定を重ね、実際に公開へ渡す mode を決める。
    /// base は、暗号化の変更で設定を差し替えてから解決し直す呼出側（保存前モードの保存）のために返す。
    private func resolvedWriteMode() -> (base: ArchiveCapabilities.Mode, mode: ArchiveCapabilities.Mode, options: WriterOptions) {
        let base = capabilities.mode!
        let options = options(for: base)
        return (base, base.resolved(with: options), options)
    }

    private func options(for mode: ArchiveCapabilities.Mode) -> WriterOptions {
        let format = mode.outputFormat
        return encryptionSettings().applying(to: writerOptions(format), format: format)
    }

    func encryptionSettings() -> ArchiveEncryptionSettings {
        ArchiveEncryptionSettings(password: hasEncryptedEntries || encryptsSevenZipHeaders ? password : nil,
                                  zipEncryption: ArchiveEncryptionSettings.zipMethod(in: reader?.entries ?? []),
                                  encryptsSevenZipHeaders: encryptsSevenZipHeaders)
    }

    private func verifyBeforeEditing(progress: Progress? = nil) throws {
        #if DEBUG
        let span = ArchiveStageDiagnostics.begin(.passwordVerification)
        defer { span?.end() }
        #endif
        let reader = try requireCurrentReader()
        let encrypted = reader.entries.filter(\.isEncrypted)
        if !encrypted.isEmpty, password == nil {
            throw ExtractionFailure.refused(ArchiveCapabilities(refusal: .encrypted).readOnlyReason!)
        }
        mergeVerification(try verify(encrypted.filter { !verifiedEntries.contains($0.index) }, using: reader, progress: progress))
    }

    func updatePassword(_ action: ArchivePasswordAction, settings: ArchiveEncryptionSettings,
                        progress: Progress, willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchivePasswordEditResult {
        let reader = try requireCurrentReader()
        guard let format = passwordFormat, capabilities.canEdit,
              action == .set ? !hasEncryptedEntries : hasEncryptedEntries && hasKnownPassword else {
            throw capabilities.editRefusal
        }
        try verifyBeforeEditing(progress: progress)
        if action != .remove, settings.password?.isEmpty != false {
            throw ExtractionFailure.refused(String(localized: "パスワードを入力してください。"))
        }
        let output = action == .remove ? ArchiveEncryptionSettings() : settings
        let options = output.applying(to: writerOptions(format), format: format)
        let sourcePassword = password
        var mode = capabilities.mode!.resolved(with: options)
        if format == .sevenZip, case .update = mode, capabilities.sevenZipAssessment?.canReencrypt != true {
            mode = .rewrite(.sevenZip)
        }
        let sevenZipEncryption: Bool? = format == .sevenZip ? options.password != nil : nil
        let zipEncryption: ArchiveOutputProjection.ExpectedZipEncryption? = format == .zip ? .init(options) : nil
        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 1, additions: [], itemCount: 1,
            carriedBytes: ArchiveWriteProgress.carriedBytes(reader.entries), changesExisting: true))
        let (identity, verified, publishedMode) = try publishing {
            let verifiedOutput = ArchiveVerifiedOutputSink()
            func publish(_ mode: ArchiveCapabilities.Mode) throws -> ArchiveSetIdentity {
                return try ArchiveImportTransaction.publish(archive: sourceURL, mode: mode, options: options, password: password,
                    progress: progress, ledger: ledger,
                    willPublish: willPublish, expectedIdentity: sourceIdentity, verifiedOutput: verifiedOutput,
                    expectedOutput: .init(projected: reader.entries, mode: mode, zipEncryption: zipEncryption, sevenZipEncryption: sevenZipEncryption)) { editor in
                        if mode == .inPlace {
                            guard let updater = editor as? ArchiveUpdater else { throw ArchiveEditError.staleSelection }
                            try updater.reencryptExistingEntries(currentPassword: sourcePassword)
                        } else if format == .sevenZip {
                            try (editor as? any ArchiveReencrypting)?.reencryptExistingEntries(currentPassword: sourcePassword)
                        }
                        ledger.didCount()
                    }
            }
            let identity: ArchiveSetIdentity
            do { identity = try publish(mode) }
            catch UpdaterError.nonRelocatableEntry where format == .zip {
                ledger.reset()
                identity = try publish(.rewrite(.zip))
            }
            return (identity, verifiedOutput.take(), verifiedOutput.publishedMode ?? .rewrite(format))
        }
        // 公開後にだけ新しい鍵を採用する。取消しや競合では旧鍵を維持する。
        password = output.password
        passwordRevision &+= 1
        encryptsSevenZipHeaders = output.encryptsSevenZipHeaders
        do { try reloadAfterMutation(verification: .init(identity: identity, indices: nil), adopting: consume verified, advancing: publishedMode == .inPlace ? .init(mode: publishedMode) : nil); return ArchivePasswordEditResult() }
        catch { return ArchivePasswordEditResult(reloadFailure: Self.reloadFailureMessage) }
    }

    // 公開時にだけ分かる拒否（G4 の中央ディレクトリ照合など）は、以後の編集を最初から断る。
    // 終端の門番を通った ZIP が照合で失敗した場合、毎回の作業コピーと失敗を繰り返さない。
    private func publishing<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch UpdaterError.invalidArchive(let reason) {
            let refusal = ArchiveCapabilities(refusal: .unavailable(reason))
            capabilitiesStorage.withLock { $0 = refusal }
            notifyCapabilitiesChanged()
            throw UpdaterError.invalidArchive(reason)
        } catch ArchiveEditError.splitArchive {
            throw splitArchiveRefusal()
        }
    }

    /// publishing の門番の中で検証済み出力の受け皿を用意し、結果と一緒に実際に公開された mode を返す。
    /// 公開側が mode を変えなかった（受け皿に記録しなかった）場合は、渡した mode をそのまま返す。
    private func publishVerified<T>(mode: ArchiveCapabilities.Mode,
                                    _ body: (ArchiveVerifiedOutputSink) throws -> T) throws -> (T, ArchiveVerifiedOutput?, ArchiveCapabilities.Mode) {
        try publishing {
            let verifiedOutput = ArchiveVerifiedOutputSink()
            let result = try body(verifiedOutput)
            return (result, verifiedOutput.take(), verifiedOutput.publishedMode ?? mode)
        }
    }

    private func splitArchiveRefusal() -> ExtractionFailure {
        let refusal = ArchiveCapabilities(refusal: ArchiveCapabilities.splitRefusal(for: sourceURL, scheme: volumeLayout?.scheme))
        capabilitiesStorage.withLock { $0 = refusal }
        notifyCapabilitiesChanged()
        return .refused(refusal.readOnlyReason!)
    }

    private func refreshCapabilities() {
        guard let reader else { return }
        if requiresSplitRecovery { return }
        let metadata = try? ArchiveVolumeMetadata.inspect(url: sourceURL, volumeSet: reader.volumeSet, store: volumeMetadataStore)
        let capabilities = ArchiveCapabilities.inspect(reader: reader, url: sourceURL, password: password,
            splitLayout: volumeLayout, allowsSplitSave: allowsSplitSave, allowsImmediateSplitSave: allowsImmediateSplitSave, mixedVolumes: metadata?.mixed ?? true)
        capabilitiesStorage.withLock { $0 = capabilities }
        encryptionStorage.withLock {
            $0 = EncryptionState(hasEncryptedEntries: reader.entries.contains(where: \.isEncrypted), hasKnownPassword: password != nil)
        }
        notifyCapabilitiesChanged()
    }

    /// capabilities の差し替えを UI へ知らせる。観測側は main actor で読み直すだけなので、actor の外で呼ぶ。
    private func notifyCapabilitiesChanged() {
        if let observer = capabilitiesObserver.withLock({ $0 }) { Task { @MainActor in observer() } }
    }

    // KaitoKit の公開 entry metadata は header の暗号化を含まない。
    // パスワードなしで一覧を読めるかを調べ、既存の名前の保護を編集でも維持する。
    private static func hasEncryptedHeaders(url: URL, format: KaitoKit.ArchiveFormat, password: String?, afterPublication: Bool = false) -> Bool {
        guard format == .sevenZip, password != nil else { return false }
        do {
            if afterPublication { _ = try ArchiveVerifiedOutput.openAfterPublication(url: url, options: .kaitoFinder()) }
            else { _ = try ArchiveReader.open(url: url, options: .kaitoFinder()) }
            return false
        }
        catch KaitoError.passwordRequired { return true }
        catch KaitoError.wrongPassword { return true }
        catch { return false }
    }

    // atomic replace 後はこの入口で reader と世代を一緒に更新する。
    // 検証した inode が今のパスと一致するときだけ、解析を引き継ぐ。
    func reloadAfterMutation(willOpen: (@Sendable () throws -> Void)? = nil,
                             verification: ArchiveEntryVerification? = nil, adopting output: consuming ArchiveVerifiedOutput? = nil,
                             advancing change: ArchiveNameIndexChange? = nil) throws {
        let previousEntries = reader?.entries
        var advanced = false
        defer { if !advanced { nameIndexCache.clear() } }
        #if DEBUG
        let span = ArchiveStageDiagnostics.begin(.reload)
        defer { span?.end() }
        #endif
        guard !closed else { throw CancellationError() }
        if let reason = splitRecoveryReason.withLock({ $0 }) { throw ExtractionFailure.refused(reason) }
        // 変更済みなら再オープンの失敗時も世代を進め、旧 reader への要求を拒否する。
        generationStorage.withLock { $0 += 1 }
        invalidated = true
        invalidationStorage.withLock { $0 = true }
        clearVerification()
        capabilitiesStorage.withLock { $0 = ArchiveCapabilities(refusal: .unavailable(String(localized: "変更後のアーカイブを読み直せませんでした。"))) }
        try willOpen?()
        let original = try ArchiveSetIdentity.capture(url: sourceURL)
        var output = consume output
        let adopted = adoptVerifiedReader(output, identity: original)
        // fallback の open より先に staging と eager なキャッシュを解放する。
        output = nil
        let replacement = try adopted ?? ArchiveStageDiagnostics.measure(.reloadOpen) {
            try ArchiveVerifiedOutput.openAfterPublication(url: sourceURL, options: .kaitoFinder(password: password))
        }
        let metadata = try ArchiveVolumeMetadata.inspect(url: sourceURL, volumeSet: replacement.volumeSet, store: volumeMetadataStore)
        let layout = metadata.layout
        let identity = try Self.currentIdentity(url: sourceURL, layout: layout)
        guard identity.volumes == (replacement.volumeSet.map { ArchiveSetIdentity(volumeSet: $0) } ?? original).volumes else {
            throw ArchiveEditError.archiveChanged
        }
        let updatedQuarantine = try ExtractionQuarantine.firstValue(from: layout?.volumes.map(\.url) ?? [sourceURL]) {} ?? metadata.quarantine
        let updatedCapabilities = ArchiveStageDiagnostics.measure(.capabilityProbe) {
            ArchiveCapabilities.inspect(reader: replacement, url: sourceURL, password: password,
                splitLayout: layout, allowsSplitSave: allowsSplitSave, allowsImmediateSplitSave: allowsImmediateSplitSave, mixedVolumes: metadata.mixed)
        }
        guard try Self.currentIdentity(url: sourceURL, layout: layout) == identity else { throw ArchiveEditError.archiveChanged }
        reader = replacement
        quarantine = updatedQuarantine
        sourceIdentity = identity
        volumeLayoutStorage.withLock { $0 = layout }
        formatStorage.withLock { $0 = replacement.format }
        capabilitiesStorage.withLock { $0 = updatedCapabilities }
        encryptionStorage.withLock {
            $0 = EncryptionState(hasEncryptedEntries: replacement.entries.contains(where: \.isEncrypted), hasKnownPassword: password != nil)
        }
        encryptsSevenZipHeaders = Self.hasEncryptedHeaders(url: sourceURL, format: replacement.format, password: password, afterPublication: true)
        if let verification, password != nil, verification.matches(identity) {
            // 自前の公開は CRC/HMAC 検証済みの本文を保持するか、既知の鍵で新規作成する。
            // 公開した inode・長さ・mtime が一致する場合だけ、新しい index に検証結果を継ぐ。
            verifiedEntries = Set(replacement.entries.filter {
                $0.isEncrypted && (verification.indices?.contains($0.index) ?? true)
            }.map(\.index))
            rememberVerification()
        }
        deferredUpdaterGeneration = adopted != nil && replacement.format == .zip && layout == nil ? generation : nil
        if var change, let previousEntries,
           let index = nameIndex(generation: generation &- 1, format: reservationFormat) {
            #if DEBUG
            change = Self.nameIndexChangeForTesting.get()?(change) ?? change
            #endif
            if let next = index.advancing(change, previous: previousEntries, entries: replacement.entries,
                                          generation: generation, format: reservationFormat) {
                adoptNameIndex(next)
                advanced = true
            }
        }
        if !advanced { nameIndexCache.clear() }
        invalidated = false
        invalidationStorage.withLock { $0 = false }
    }

    private func adoptVerifiedReader(_ output: ArchiveVerifiedOutput?, identity: ArchiveSetIdentity) -> ArchiveReader? {
        func fallback(_ reason: ArchiveReaderAdoption.Reason) -> ArchiveReader? {
            #if DEBUG
            Self.readerAdoptionObserverForTesting.get()?(.fallback(reason))
            #endif
            return nil
        }
        guard let output else { return fallback(.noOutput) }
        #if DEBUG
        Self.willAdoptReaderForTesting.get()?(output)
        #endif
        guard output.hint == sourceURL.standardizedFileURL else { return fallback(.hint) }
        guard identity.contentEqualsAfterMove(output.identity) else { return fallback(.identity) }
        guard output.source.isUnchanged() else { return fallback(.descriptor) }
        guard !ArchiveSplitVolume.isSplitVolumeMember(sourceURL) else { return fallback(.splitSibling) }
        guard output.verificationPassword == nil || output.verificationPassword == password else { return fallback(.password) }
        guard let verified = output.reader, [.zip, .tar, .sevenZip, .lha].contains(verified.format) else { return fallback(.format) }
        do {
            verified.password = password
            let replacement = try ArchiveStageDiagnostics.measure(.readerAdoption) { try verified.reopen() }
            output.reader = nil
            #if DEBUG
            Self.readerAdoptionObserverForTesting.get()?(.adopted)
            #endif
            return replacement
        } catch { return fallback(.reopenFailed) }
    }

    // ReaderOptions や下位エラーの説明を公開結果へ持ち込まず、秘密を含まない文言に限定する。
    nonisolated static var reloadFailureMessage: String {
        String(localized: "変更は保存されましたが、アーカイブを読み直せませんでした。アーカイブを開き直してください。")
    }

    // append と同じ actor で置換と fresh open を連続させ、旧 inode の reader を渡さない。
    func restoreUndoSlot(_ id: UUID, from stack: ArchiveUndoStack) throws {
        if volumeLayout != nil || ArchiveSplitVolume.isSplitVolumeMember(sourceURL) { throw splitArchiveRefusal() }
        // Finder の情報パネルによる権限変更は内容を変えず、mode は swap 自身が読み直すため比較から除く。
        guard try Self.currentIdentity(url: sourceURL, layout: volumeLayout).contentEquals(sourceIdentity)
        else { throw ArchiveEditError.archiveChanged }
        guard let slot = stack.slots.first(where: { $0.id == id }) else { throw ArchiveUndoStack.Failure.missingSlot }
        let verification = try slot.verification.flatMap {
            $0.matches(try ArchiveSetIdentity.capture(url: slot.url)) ? $0 : nil
        }
        let restorationFailure = try stack.swap(id, archive: sourceURL, encryption: encryptionSettings(), verification: entryVerification)
        password = slot.encryption.password
        passwordRevision &+= 1
        encryptsSevenZipHeaders = slot.encryption.encryptsSevenZipHeaders
        do { try reloadAfterMutation(verification: restorationFailure == nil ? verification : nil) }
        catch { throw restorationFailure ?? error }
        if let restorationFailure { throw restorationFailure }
    }

    func snapshot() -> (entries: [ArchiveEntry], generation: UInt64) {
        (invalidated ? [] : reader?.entries ?? [], generation)
    }

    // 入力待ちの間に変更され得るため、reopen の直前に世代をもう一度確かめる。
    nonisolated struct ReadRevision: Equatable, Sendable {
        let generation: UInt64
        let passwordRevision: UInt64
    }

    func resolveForExtraction(_ payloads: [ArchiveEntryPayload], progress: Progress? = nil) async throws
        -> sending (reader: ArchiveReader, selection: ExtractionSelection, quarantine: Data?) {
        let snapshot = try await resolveForPromiseExtraction(payloads, reusing: nil, progress: progress)
        return (snapshot.reader!, snapshot.selection, snapshot.quarantine)
    }

    func resolveForPromiseExtraction(_ payloads: [ArchiveEntryPayload], reusing: ReadRevision?,
                                     progress: Progress? = nil) async throws
        -> sending (reader: ArchiveReader?, selection: ExtractionSelection, quarantine: Data?, revision: ReadRevision) {
        guard !usesPendingReading else { throw ArchiveEntryPayload.staleSelection }
        let reader = try requireCurrentReader()
        let expectedGeneration = generation
        var subtrees: ArchiveEntryPayload.SubtreeIndex?
        let syntax = ExtractionPath.NameSyntax(reader.format)
        var selected: [Int: ArchiveEntry] = [:]
        for payload in payloads {
            guard payload.archiveURL == sourceURL else {
                throw ExtractionFailure.refused(String(localized: "選択した項目のアーカイブが一致しません。"))
            }
            if payload.isDirectory, subtrees == nil {
                subtrees = ArchiveEntryPayload.SubtreeIndex(entries: reader.entries, syntax: syntax)
            }
            for entry in try payload.resolve(in: reader.entries, generation: expectedGeneration, subtrees: subtrees, syntax: syntax) {
                selected[entry.index] = entry
            }
        }
        let selection = ExtractionSelection(entries: Array(selected.values))
        try await prepareEncryptedEntries(selection.entries, generation: expectedGeneration, progress: progress)
        try checkReadRequest(generation: expectedGeneration)
        let revision = ReadRevision(generation: generation, passwordRevision: passwordRevision)
        let reopened: ArchiveReader?
#if DEBUG
        if reusing != revision, let source = promiseSourceForTesting {
            reopened = try ArchiveReader.open(source: source, sourceURL: sourceURL, options: .kaitoFinder(password: password))
        } else { reopened = reusing == revision ? nil : try requireCurrentReader().reopen() }
#else
        reopened = reusing == revision ? nil : try requireCurrentReader().reopen()
#endif
        return (reopened, selection, quarantine, revision)
    }

    func resolvePendingForExtraction(_ payloads: [ArchiveEntryPayload], progress: Progress? = nil) async throws
        -> sending (reader: ArchiveReader, selection: ExtractionSelection, quarantine: Data?,
                    snapshot: ArchivePendingReadSnapshot, lease: StagingRegistry.ReadLease?) {
        guard let snapshot = pendingReadSnapshot, snapshot.generation == generation else { throw ArchiveEntryPayload.staleSelection }
        var selected: [Int: ArchiveEntry] = [:]
        for payload in payloads {
            guard payload.archiveURL == sourceURL else { throw ArchiveEntryPayload.staleSelection }
            for entry in try snapshot.resolve(payload) { selected[entry.index] = entry }
        }
        let entries = selected.values.sorted { $0.index < $1.index }
        let usesStaging = !snapshot.stagedURLs.isEmpty
        let base = entries.compactMap { entry -> ArchiveEntry? in
            if case .base(let source) = snapshot.sources[entry.index] { return source }
            return nil
        }
        try await prepareEncryptedEntries(base, generation: snapshot.generation, progress: progress)
        try checkReadRequest(generation: snapshot.generation)
        guard pendingReadSnapshot?.revision == snapshot.revision else { throw ArchiveEntryPayload.staleSelection }
        // パスワード待ちの要求はまだ読み始めていない。照合後に lease を取り、破棄との競合を閉じる。
        let lease = try usesStaging ? snapshot.staging?.acquireRead() : nil
        if usesStaging, lease == nil { throw ArchiveEntryPayload.staleSelection }
        // この境界以降は revision が変わっても、複製 reader と退避 lease の内容で完走する。
        // 即時追加と同じく、原本の印を優先し、なければ最初の追加元の印を全出力へ伝える。
        let savedQuarantine = try quarantine ?? ExtractionQuarantine.firstValue(from: snapshot.stagedURLs) { try Task.checkCancellation() }
        return (try requireCurrentReader().reopen(), .init(entries: entries), savedQuarantine, snapshot, lease)
    }

    func entries() -> [ArchiveEntry] {
        invalidated ? [] : reader?.entries ?? []
    }
}

nonisolated extension ArchiveSession {
    var reservationFormat: GyoshukuKit.ArchiveFormat {
        capabilities.mode?.outputFormat ?? .zip
    }
}
