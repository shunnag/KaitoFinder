import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization

nonisolated enum ArchivePasswordChallenge: Equatable, Sendable {
    case required, incorrect

    init?(_ error: any Error) {
        switch error as? KaitoError {
        case .passwordRequired: self = .required
        case .wrongPassword: self = .incorrect
        default: return nil
        }
    }

    func message(bundle: Bundle = .main) -> String {
        switch self {
        case .required: String(localized: "アーカイブのパスワードを入力してください。", bundle: bundle)
        case .incorrect: String(localized: "パスワードが違います。もう一度入力してください。", bundle: bundle)
        }
    }
}

/// スレッドセーフではない reader を所有し、値型の一覧だけを外へ渡す。
actor ArchiveSession {
    typealias PasswordPrompt = @MainActor @Sendable (ArchivePasswordChallenge) async throws -> String
    private var reader: ArchiveReader?
    private(set) var password: String?
    private var closed = false
    private var invalidated = false
    private var verifiedEntries: Set<Int> = []
    private var passwordRevision: UInt64 = 0
    // UI の接続だけは同期的に済ませ、display 直後の読み出しとの競合を避ける。
    nonisolated private let promptStorage = Mutex<PasswordPrompt?>(nil)
    nonisolated private let capabilitiesObserver = Mutex<(@MainActor @Sendable () -> Void)?>(nil)
    nonisolated private let capabilitiesStorage: Mutex<ArchiveCapabilities>
    nonisolated var capabilities: ArchiveCapabilities { capabilitiesStorage.withLock { $0 } }
    nonisolated private let generationStorage = Mutex<UInt64>(0)
    nonisolated var generation: UInt64 { generationStorage.withLock { $0 } }
    nonisolated let sourceURL: URL
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
    private var sourceIdentity: [Int64]
    nonisolated let writerOptions: @Sendable (GyoshukuKit.ArchiveFormat) -> WriterOptions
    nonisolated private let importOptions: @Sendable () -> ArchiveImportPlan.Options
    private(set) var quarantine: Data?

    init(url: URL, password: String? = nil,
         writerOptions: @escaping @Sendable (GyoshukuKit.ArchiveFormat) -> WriterOptions = { _ in WriterOptions() },
         importOptions: @escaping @Sendable () -> ArchiveImportPlan.Options = { .init() }) throws {
        sourceURL = url
        self.password = password
        self.writerOptions = writerOptions
        self.importOptions = importOptions
        sourceIdentity = try ArchiveImportTransaction.identity(url)
        quarantine = try ExtractionQuarantine.read(from: url)
        let reader = try ArchiveReader.open(url: url, options: ReaderOptions(password: password))
        self.reader = reader
        formatStorage = Mutex(reader.format)
        capabilitiesStorage = Mutex(ArchiveCapabilities.inspect(url: url, format: reader.format, password: password))
        encryptionStorage = Mutex(EncryptionState(hasEncryptedEntries: reader.entries.contains(where: \.isEncrypted),
                                                  hasKnownPassword: password != nil))
        encryptsSevenZipHeaders = Self.hasEncryptedHeaders(url: url, format: reader.format, password: password)
        guard try ArchiveImportTransaction.identity(url) == sourceIdentity else { throw ArchiveEditError.archiveChanged }
    }

    func extractionReader() throws -> sending ArchiveReader {
        let reader = try requireCurrentReader()
        return try reader.reopen()
    }

    func extractionSnapshot() async throws -> sending (reader: ArchiveReader, quarantine: Data?) {
        let entries = try requireCurrentReader().entries
        try await prepareEncryptedEntries(entries, generation: generation)
        return (try requireCurrentReader().reopen(), quarantine)
    }

    func preparedPassword() async throws -> String? {
        let expectedGeneration = generation
        let entries = try requireCurrentReader().entries
        try await prepareEncryptedEntries(entries, generation: expectedGeneration)
        try checkReadRequest(generation: expectedGeneration)
        return password
    }

    private func requireCurrentReader() throws -> ArchiveReader {
        guard !closed, let reader else { throw CancellationError() }
        guard !invalidated else { throw ExtractionFailure.refused(String(localized: "変更後のアーカイブを読み直せませんでした。")) }
        // reopenは旧inodeを保持する。文書を開いてからの置換・削除を先に検出する。
        guard try ArchiveImportTransaction.identity(sourceURL) == sourceIdentity else { throw ArchiveEditError.archiveChanged }
        return reader
    }

    nonisolated func setPasswordPrompt(_ prompt: PasswordPrompt?) {
        promptStorage.withLock { $0 = prompt }
    }

    nonisolated func setCapabilitiesObserver(_ observer: (@MainActor @Sendable () -> Void)?) {
        capabilitiesObserver.withLock { $0 = observer }
    }

    // entry ごとのエラーが文字列になる前に認証を完了する。出力はまだ作らないので、
    // 途中でパスワードを取り消しても、複数項目の一部だけを公開することがない。
    private func prepareEncryptedEntries(_ entries: [ArchiveEntry], generation expectedGeneration: UInt64) async throws {
        let encrypted = entries.filter(\.isEncrypted)
        guard !encrypted.isEmpty else { return }
        while true {
            try checkReadRequest(generation: expectedGeneration)
            do {
                try verify(encrypted.filter { !verifiedEntries.contains($0.index) }, using: requireCurrentReader())
                verifiedEntries.formUnion(encrypted.map(\.index))
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
                        let replacement = try ArchiveReader.open(url: sourceURL, options: ReaderOptions(password: candidate))
                        guard replacement.entries == (try requireCurrentReader().entries) else {
                            throw ExtractionFailure.refused(String(localized: "アーカイブが変更されています。開き直してください。"))
                        }
                        try verify(encrypted, using: replacement)
                        try checkReadRequest(generation: expectedGeneration)
                        // 間違った候補は保持しない。採用は検証が最後まで成功した時だけ。
                        reader = replacement
                        password = candidate
                        passwordRevision &+= 1
                        verifiedEntries = Set(encrypted.map(\.index))
                        refreshCapabilities()
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

    private func verify(_ entries: [ArchiveEntry], using reader: ArchiveReader) throws {
        for entry in entries {
            // ZipCrypto の短い照合値だけでは誤った鍵を除外できない。CRC / HMAC まで読む。
            // 同じ鍵・世代で成功済みの entry は呼出側が除き、再度の検証を省く。
            try ExtractionService.consume(reader.stream(entry), checkCancellation: { try Task.checkCancellation() }) { _ in }
        }
    }

    func close() {
        closed = true
        password = nil
        reader = nil
        verifiedEntries.removeAll()
        promptStorage.withLock { $0 = nil }
        capabilitiesObserver.withLock { $0 = nil }
        passwordRevision &+= 1
        encryptionStorage.withLock { $0.hasKnownPassword = false }
    }

    // 追加と fresh open は await を挟まず直列化し、promise の解決を割り込ませない。
    func append(urls: [URL], to folder: String, progress: Progress,
                didProcess: (@Sendable (Int) throws -> Void)? = nil,
                willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveImportResult {
        let reader = try requireCurrentReader()
        guard capabilities.canAppend else {
            throw ExtractionFailure.refused(capabilities.readOnlyReason ?? String(localized: "このアーカイブは変更できません。"))
        }
        try verifyBeforeEditing()
        let plan = try ArchiveImportPlan.build(urls: urls, folder: folder, existing: reader.entries,
                                               progress: progress, options: importOptions())
        let mode = capabilities.mode!
        var result = try ArchiveImportTransaction.run(plan: plan, archive: sourceURL, mode: mode,
                                                     options: options(for: mode), password: password, progress: progress,
                                                     didProcess: didProcess, willPublish: willPublish, expectedIdentity: sourceIdentity)
        if !result.addedPaths.isEmpty {
            // 公開済みの書き込みと表示の失敗を区別し、旧 byte に戻ったとは報告しない。
            do { try reloadAfterMutation() }
            catch { result.reloadFailure = Self.reloadFailureMessage }
        }
        return result
    }

    func remove(_ selections: [ArchiveEditSelection], progress: Progress,
                willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveEditResult {
        try edit(removing: selections, progress: progress, willPublish: willPublish)
    }

    func createFolder(in folder: String, baseName: String = String(localized: "名称未設定フォルダ"), progress: Progress,
                      willOpenUpdater: (@Sendable () throws -> Void)? = nil,
                      willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveImportResult {
        let reader = try requireCurrentReader()
        guard capabilities.canAppend else {
            throw ExtractionFailure.refused(capabilities.readOnlyReason ?? String(localized: "このアーカイブは変更できません。"))
        }
        try ArchiveImportPlan.checkCancellation(progress)
        try verifyBeforeEditing()
        // 名前決定も同じ actor 内で行い、連続した作成が同じ空き名を予約しないようにする。
        let plan = try ArchiveNewFolderPlan.build(in: folder, baseName: baseName, existing: reader.entries)
        let mode = capabilities.mode!
        var result = try ArchiveImportTransaction.createFolder(plan: plan, archive: sourceURL, mode: mode,
                                                               options: options(for: mode), password: password, progress: progress,
                                                               willOpenUpdater: willOpenUpdater, willPublish: willPublish, expectedIdentity: sourceIdentity)
        do { try reloadAfterMutation() }
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
        // canAppend は編集の共通門番。拒否理由も追加と揃える。
        guard capabilities.canAppend else {
            throw ExtractionFailure.refused(capabilities.readOnlyReason ?? String(localized: "このアーカイブは変更できません。"))
        }
        try ArchiveImportPlan.checkCancellation(progress)
        try verifyBeforeEditing()
        let plan = try ArchiveEditPlan.build(removing: removing, renaming: renaming, moving: moving, existing: reader.entries)
        let mode = capabilities.mode!
        var result = try ArchiveEditTransaction.run(plan: plan, archive: sourceURL, mode: mode,
                                                   options: options(for: mode), password: password, progress: progress,
                                                   willOpenUpdater: willOpenUpdater, willPublish: willPublish, expectedIdentity: sourceIdentity)
        if result.published {
            do { try reloadAfterMutation() }
            catch { result.reloadFailure = Self.reloadFailureMessage }
        }
        return result
    }

    private func options(for mode: ArchiveCapabilities.Mode) -> WriterOptions {
        let format: GyoshukuKit.ArchiveFormat
        switch mode {
        case .inPlace: format = .zip
        case .rewrite(let output): format = output
        }
        return encryptionSettings().applying(to: writerOptions(format), format: format)
    }

    func encryptionSettings() -> ArchiveEncryptionSettings {
        ArchiveEncryptionSettings(password: hasEncryptedEntries || encryptsSevenZipHeaders ? password : nil,
                                  zipEncryption: ArchiveEncryptionSettings.zipMethod(in: reader?.entries ?? []),
                                  encryptsSevenZipHeaders: encryptsSevenZipHeaders)
    }

    private func verifyBeforeEditing() throws {
        let reader = try requireCurrentReader()
        let encrypted = reader.entries.filter(\.isEncrypted)
        if !encrypted.isEmpty, password == nil {
            throw ExtractionFailure.refused(ArchiveCapabilities(refusal: .encrypted).readOnlyReason!)
        }
        try verify(encrypted.filter { !verifiedEntries.contains($0.index) }, using: reader)
        verifiedEntries.formUnion(encrypted.map(\.index))
    }

    func updatePassword(_ action: ArchivePasswordAction, settings: ArchiveEncryptionSettings,
                        progress: Progress, willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchivePasswordEditResult {
        _ = try requireCurrentReader()
        guard let format = passwordFormat, capabilities.canAppend,
              action == .set ? !hasEncryptedEntries : hasEncryptedEntries && hasKnownPassword else {
            throw ExtractionFailure.refused(capabilities.readOnlyReason ?? String(localized: "このアーカイブは変更できません。"))
        }
        try verifyBeforeEditing()
        if action != .remove, settings.password?.isEmpty != false {
            throw ExtractionFailure.refused(String(localized: "パスワードを入力してください。"))
        }
        let output = action == .remove ? ArchiveEncryptionSettings() : settings
        progress.totalUnitCount = 1
        progress.completedUnitCount = 0
        try ArchiveImportTransaction.publish(archive: sourceURL, mode: .rewrite(format),
            options: output.applying(to: writerOptions(format), format: format), password: password,
            progress: progress, willPublish: willPublish, expectedIdentity: sourceIdentity) { _ in }
        // 公開後にだけ新しい鍵を採用する。取消しや競合では旧鍵を維持する。
        password = output.password
        passwordRevision &+= 1
        encryptsSevenZipHeaders = output.encryptsSevenZipHeaders
        do { try reloadAfterMutation(); return ArchivePasswordEditResult() }
        catch { return ArchivePasswordEditResult(reloadFailure: Self.reloadFailureMessage) }
    }

    private func refreshCapabilities() {
        guard let reader else { return }
        let capabilities = ArchiveCapabilities.inspect(url: sourceURL, format: reader.format, password: password)
        capabilitiesStorage.withLock { $0 = capabilities }
        encryptionStorage.withLock {
            $0 = EncryptionState(hasEncryptedEntries: reader.entries.contains(where: \.isEncrypted), hasKnownPassword: password != nil)
        }
        if let observer = capabilitiesObserver.withLock({ $0 }) { Task { @MainActor in observer() } }
    }

    // KaitoKit の公開 entry metadata は header の暗号化を含まない。
    // パスワードなしで一覧を読めるかを調べ、既存の名前の保護を編集でも維持する。
    private static func hasEncryptedHeaders(url: URL, format: KaitoKit.ArchiveFormat, password: String?) -> Bool {
        guard format == .sevenZip, password != nil else { return false }
        do { _ = try ArchiveReader.open(url: url); return false }
        catch KaitoError.passwordRequired { return true }
        catch KaitoError.wrongPassword { return true }
        catch { return false }
    }

    // atomic replace 後はこの入口で reader と世代を一緒に更新する。
    // reopen() は旧 inode を保持するので、URL から開き直す。
    func reloadAfterMutation() throws {
        guard !closed else { throw CancellationError() }
        // 変更済みなら再オープンの失敗時も世代を進め、旧 reader への要求を拒否する。
        generationStorage.withLock { $0 += 1 }
        invalidated = true
        verifiedEntries.removeAll()
        capabilitiesStorage.withLock { $0 = ArchiveCapabilities(refusal: .unavailable(String(localized: "変更後のアーカイブを読み直せませんでした。"))) }
        let identity = try ArchiveImportTransaction.identity(sourceURL)
        let replacement = try ArchiveReader.open(url: sourceURL, options: ReaderOptions(password: password))
        let updatedQuarantine = try ExtractionQuarantine.read(from: sourceURL)
        reader = replacement
        quarantine = updatedQuarantine
        let updatedCapabilities = ArchiveCapabilities.inspect(url: sourceURL, format: replacement.format, password: password)
        guard try ArchiveImportTransaction.identity(sourceURL) == identity else { throw ArchiveEditError.archiveChanged }
        sourceIdentity = identity
        formatStorage.withLock { $0 = replacement.format }
        capabilitiesStorage.withLock { $0 = updatedCapabilities }
        encryptionStorage.withLock {
            $0 = EncryptionState(hasEncryptedEntries: replacement.entries.contains(where: \.isEncrypted), hasKnownPassword: password != nil)
        }
        encryptsSevenZipHeaders = Self.hasEncryptedHeaders(url: sourceURL, format: replacement.format, password: password)
        invalidated = false
    }

    // ReaderOptions や下位エラーの説明を公開結果へ持ち込まず、秘密を含まない文言に限定する。
    nonisolated static var reloadFailureMessage: String {
        String(localized: "変更は保存されましたが、アーカイブを読み直せませんでした。アーカイブを開き直してください。")
    }

    // append と同じ actor で置換と fresh open を連続させ、旧 inode の reader を渡さない。
    func restoreUndoSlot(_ id: UUID, from stack: ArchiveUndoStack) throws {
        guard let slot = stack.slots.first(where: { $0.id == id }) else { throw ArchiveUndoStack.Failure.missingSlot }
        let restorationFailure = try stack.swap(id, archive: sourceURL, encryption: encryptionSettings())
        password = slot.encryption.password
        passwordRevision &+= 1
        encryptsSevenZipHeaders = slot.encryption.encryptsSevenZipHeaders
        do { try reloadAfterMutation() }
        catch { throw restorationFailure ?? error }
        if let restorationFailure { throw restorationFailure }
    }

    func snapshot() -> (entries: [ArchiveEntry], generation: UInt64) {
        (invalidated ? [] : reader?.entries ?? [], generation)
    }

    // 入力待ちの間に変更され得るため、reopen の直前に世代をもう一度確かめる。
    func resolveForExtraction(_ payloads: [ArchiveEntryPayload]) async throws
        -> sending (reader: ArchiveReader, selection: ExtractionSelection, quarantine: Data?) {
        let reader = try requireCurrentReader()
        let expectedGeneration = generation
        var subtrees: ArchiveEntryPayload.SubtreeIndex?
        var selected: [Int: ArchiveEntry] = [:]
        for payload in payloads {
            guard payload.archiveURL == sourceURL else {
                throw ExtractionFailure.refused(String(localized: "選択した項目のアーカイブが一致しません。"))
            }
            if payload.isDirectory, subtrees == nil {
                subtrees = ArchiveEntryPayload.SubtreeIndex(entries: reader.entries)
            }
            for entry in try payload.resolve(in: reader.entries, generation: expectedGeneration, subtrees: subtrees) {
                selected[entry.index] = entry
            }
        }
        let selection = ExtractionSelection(entries: Array(selected.values))
        try await prepareEncryptedEntries(selection.entries, generation: expectedGeneration)
        try checkReadRequest(generation: expectedGeneration)
        return (try requireCurrentReader().reopen(), selection, quarantine)
    }

    func entries() -> [ArchiveEntry] {
        invalidated ? [] : reader?.entries ?? []
    }
}
