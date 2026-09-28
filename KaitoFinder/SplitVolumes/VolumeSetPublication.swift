import Darwin
import Foundation
import KaitoKit
import Synchronization

/// presenter は coordinator へ渡すだけで、worker から直接呼び出さない。
nonisolated struct VolumeSetTarget: @unchecked Sendable {
    let parent: URL
    let layout: ArchiveVolumeLayout?
    let expected: ArchiveSetIdentity?
    let scheme: ArchiveVolumeSet.Scheme
    let schedule: VolumePlan.Schedule
    let allowHazardousVolume: Bool
    let filePresenter: (any NSFilePresenter)?
    var oldVolumeDisposal: VolumeOldDisposalPolicy = .trash
    var writesVolumeMetadata = false
    var additionalQuarantine: Data? = nil

    init(parent: URL, layout: ArchiveVolumeLayout, expected: ArchiveSetIdentity,
         schedule: VolumePlan.Schedule, allowHazardousVolume: Bool = false, filePresenter: (any NSFilePresenter)? = nil) {
        self.parent = parent; self.layout = layout; self.expected = expected; scheme = layout.scheme
        self.schedule = schedule; self.allowHazardousVolume = allowHazardousVolume; self.filePresenter = filePresenter
    }

    init(parent: URL, newSetScheme: ArchiveVolumeSet.Scheme, schedule: VolumePlan.Schedule,
         allowHazardousVolume: Bool = false, filePresenter: (any NSFilePresenter)? = nil) {
        self.parent = parent; layout = nil; expected = nil; scheme = newSetScheme
        self.schedule = schedule; self.allowHazardousVolume = allowHazardousVolume; self.filePresenter = filePresenter
    }
}

/// 分割セットを書き直して公開する。コメントの手順番号は次の意味で使う（gate は旧 gate を最初に退け、新 gate を最後に置く）。
/// - S0: begin の読み取りだけの事前検査。権限・次巻名の占有・空き容量・fd の予算・FAT32 の 4 GiB 上限・同じ stem の未解決の公開。
/// - S1: 回復索引への登録と、staging（`.KaitoFinder-vol-<UUID>`）・journal・work/new/old の作成。
/// - W: staging/work/<stem> に作る単一の作業書庫。呼び出し側が S2 で作る。
/// - S2: rewriter が URL から組み立て直した入力セットを、編集を再生する前に照合する（`verifyAssembledInput`）。
/// - S3: W を末尾から new/ の巻へ切り出す（`VolumeSplitter`）。
/// - S4: new/ の巻を全文 hash と KaitoKit の reader で検証し、新巻を journal に phase=prepared で記録する。
/// - S5: 取り消せる最後の点。調整の中で旧巻を再証明し、臨界区間に入る。以後は取消しを観測しない。
/// - S6・S7: 旧 gate、続いて残りの旧巻を old/ へ退避する。S8・S9: gate 以外の新巻、最後に新 gate を配置する。
/// - S10: 配置した新セットを検証する。S11: durable な done を書き、旧巻と staging を片付ける。
/// S5〜S11 の各点には `VolumePublishStep` の同名の hook がある。
/// M2・M5・M6 は分割編集の実装段階の番号で、M2 がこの公開部品、M5 が保存時モードの分割保存（design.md「分割セットの保存（M5）」）、
/// M6 が即時編集と別名保存の分割出力（design.md「即時編集と別名で保存の分割出力（M6）」）。
///
/// 同期 API。ArchiveSession actor から一度だけ publish する。drop は所有ロックだけを解放する。
nonisolated final class VolumeSetPublication: Sendable {
    private struct State { var started = false; var finished = false; var cancelled = false }
    private let state = Mutex(State())
    private let target: VolumeSetTarget
    private let parent: VolumePublishDirectory
    private let staging: VolumePublishDirectory
    private let journal: VolumePublishJournal
    private let setLock: VolumePublishLock
    private let stagingLock: VolumePublishLock
    private let isNetworkVolume: Bool
    private let stampsProveContent: Bool
    private let index: RecoverableWorkIndex
    private let renamer: VolumeExclusiveRename
    private let initialRecord: VolumePublishJournalRecord
    private let options: ReaderOptions
    private let coordinationTimeout: TimeInterval
    private let hook: @Sendable (VolumePublishStep) throws -> Void
    private let criticalSection: VolumePublishCriticalSection
    private let operations: VolumePublishOperations
    private let metadataStore: ArchiveVolumeMetadataStore

    var stagingURL: URL { staging.url }
    var workURL: URL { staging.url.appendingPathComponent("work", isDirectory: true).appendingPathComponent(initialRecord.workName) }

    private init(target: VolumeSetTarget, parent: VolumePublishDirectory, staging: VolumePublishDirectory,
                 journal: VolumePublishJournal, setLock: VolumePublishLock, stagingLock: VolumePublishLock,
                 isNetworkVolume: Bool, stampsProveContent: Bool, index: RecoverableWorkIndex,
                 renamer: VolumeExclusiveRename, record: VolumePublishJournalRecord, options: ReaderOptions,
                 coordinationTimeout: TimeInterval, criticalSection: VolumePublishCriticalSection, operations: VolumePublishOperations,
                 metadataStore: ArchiveVolumeMetadataStore,
                 hook: @escaping @Sendable (VolumePublishStep) throws -> Void) {
        self.target = target; self.parent = parent; self.staging = staging; self.journal = journal
        self.setLock = setLock; self.index = index; self.renamer = renamer; initialRecord = record
        self.stagingLock = stagingLock; self.isNetworkVolume = isNetworkVolume
        self.stampsProveContent = stampsProveContent
        self.options = options; self.coordinationTimeout = coordinationTimeout
        self.criticalSection = criticalSection; self.hook = hook; self.operations = operations; self.metadataStore = metadataStore
    }

    static func begin(_ target: VolumeSetTarget, estimatedOutputLength: UInt64, additionalWorkBytes: UInt64 = 0,
                      progress: Progress = Progress(), index: RecoverableWorkIndex = .shared, options: ReaderOptions = .kaitoFinder(),
                      coordinationTimeout: TimeInterval = 10, criticalSection: VolumePublishCriticalSection = .shared,
                      operations: VolumePublishOperations = .init(), metadataStore: ArchiveVolumeMetadataStore = .shared,
                      fault: @escaping @Sendable (VolumePublishStep) throws -> Void = { _ in }) throws -> VolumeSetPublication {
        func checkCancellation() throws {
            if progress.isCancelled || Task.isCancelled { throw CancellationError() }
        }
        try checkCancellation()
        let plan = try VolumePlan(totalLength: estimatedOutputLength, schedule: target.schedule,
                                  scheme: target.scheme, layout: target.layout)
        let parent = try VolumePublishDirectory(target.parent)
        let volume = try operations.volumeInfo(parent)
        // ns mtime を信頼できる APFS だけ。永続化せず、回復は従来の全文 hash を使う。
        let stampsProveContent = operations.allowsStampRecheck && volume.fileSystem == "apfs" && volume.hazard == nil
        let volumeRoot = try VolumePublishFS.volumeRoot(parent)
        try checkWorkLength(estimatedOutputLength, fileSystem: volume.fileSystem)
        if let hazard = volume.hazard, !target.allowHazardousVolume { throw VolumePublishError.hazardousVolume(hazard) }
        let setLock = try VolumePublishLock.setLock(volumeUUID: volume.uuid, gateInode: target.expected?.volumes.first?.inode,
                                                  parent: parent.url, gate: plan.gateName, directory: index.setLocksURL)
        try checkOldPermissions(target, parent: parent)
        try checkOccupancy(plan: plan, oldCount: target.layout?.volumes.count ?? 0, parent: parent)
        try verifyExpected(target, parent: parent)
        try checkSpace(requiredOutput: estimatedOutputLength, additionalWorkBytes: additionalWorkBytes,
                       largest: plan.largestVolume, available: volume.available)
        try checkDescriptorBudget(plan.volumes.count)
        guard case .numbered(let stem, let width) = target.scheme else { throw VolumePublishError.unsupportedScheme }
        let indexedWork = try index.entries()
        for name in try parent.names(checkCancellation: checkCancellation) where name.hasPrefix(VolumePublishFS.stagingPrefix) {
            try checkCancellation()
            let url = parent.url.appendingPathComponent(name)
            let previous = try? VolumePublishJournal.inspect(parent.directory(name))
            let base = VolumePublishRemoval.stagingName(name) ?? name
            let indexedGate = indexedWork.first { URL(fileURLWithPath: $0.stagingPath).lastPathComponent == base }?.gateName
            // An unreadable, unattributed sibling is not evidence of an unresolved publication of this stem.
            guard previous.map({ $0.stem == stem }) ?? (indexedGate == plan.gateName) else { continue }
            let result = VolumePublishRecovery(index: index, operations: operations, metadataStore: metadataStore).recover(staging: url,
                alreadyLockedGate: plan.gateName, options: options, presenter: target.filePresenter,
                volume: volume, volumeRoot: volumeRoot, parent: parent)
            if case .recovered = result { continue }
            if case .owned = result { throw VolumePublishError.ownerAlive }
            // Re-read after cleanup: only a still-readable, valid done journal exempts this backup.
            if let completed = try? VolumePublishJournal.inspect(parent.directory(name)), completed.phase == .done {
                try completed.validate(stagingName: base)
                continue // A later publication may already have replaced this generation's new set.
            }
            throw VolumePublishError.unresolvedPublication(url)
        }

        try checkOccupancy(plan: plan, oldCount: target.layout?.volumes.count ?? 0, parent: parent)
        try verifyExpected(target, parent: parent)

        var oldRecords: [VolumePublishJournalRecord.OldVolume] = []
        for old in target.expected?.volumes ?? [] {
            try checkCancellation()
            let hash = volume.needsOldHashes ? try VolumePublishFS.hash(parent, old.fileName, checkCancellation: checkCancellation) : nil
            oldRecords.append(.init(old, sha256: hash))
        }
        try verifyExpected(target, parent: parent)
        try checkCancellation()

        // S1: probe には staging が必要。S0 の全 read-only 検査後、W を受け取る前に実行する。
        let stagingName = VolumePublishFS.stagingPrefix + UUID().uuidString
        let stagingURL = parent.url.appendingPathComponent(stagingName, isDirectory: true)
        let stagingLock = try VolumePublishLock.stagingLock(stagingName, directory: index.stagingLocksURL)
        defer {
            try? stagingLock.removeIfResolved(stagingName, parent: parent, index: index)
            withExtendedLifetime(stagingLock) {}
        }
        // mkdir より先に索引へ。S1 途中の crash でも launch/didMount が発見できる。
        try index.register(stagingURL, volumeUUID: volume.uuid, gateName: plan.gateName, nonLocalVolume: !volume.isLocal,
                           stagingLockName: stagingName, volumeRoot: volumeRoot, fileSystem: volume.fileSystem)
        var createdStaging: VolumePublishDirectory?
        do {
            try fault(.registered)
            let staging = try parent.directory(stagingName, create: true)
            createdStaging = staging
            try parent.sync(full: true)
            try fault(.stagingCreated)
            let journal = try VolumePublishJournal(staging: staging, create: true)
            try fault(.journalCreated)
            let renamer = try VolumeExclusiveRename(parent: parent, staging: staging, volume: volume)
            _ = try staging.directory("work", create: true)
            _ = try staging.directory("new", create: true)
            _ = try staging.directory("old", create: true)
            let owner = journal.usesOwnerFallback ? try VolumePublishProcessIdentity.capture() : nil
            if journal.usesOwnerFallback, owner == nil { throw VolumePublishError.journalUnreadable }
            var record = VolumePublishJournalRecord(phase: .prepared, schemeTag: "numbered", stagingName: stagingName, stem: stem, width: width,
                volumeUUID: volume.uuid, hashesOldVolumes: volume.needsOldHashes,
                usesExclusiveRenameFallback: renamer.usesFallback, oldVolumes: oldRecords, newVolumes: [],
                oldGate: target.layout?.gateURL.lastPathComponent, newGate: plan.gateName, workName: stem, totalLength: 0,
                createdAt: Date(), appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown", owner: owner)
            record.oldVolumeDisposal = target.oldVolumeDisposal
            try journal.write(record)
            try staging.sync(); try parent.sync()
            try checkCancellation()
            return VolumeSetPublication(target: target, parent: parent, staging: staging, journal: journal, setLock: setLock,
                stagingLock: stagingLock, isNetworkVolume: !volume.isLocal, stampsProveContent: stampsProveContent,
                index: index, renamer: renamer, record: record,
                options: options, coordinationTimeout: coordinationTimeout,
                criticalSection: criticalSection, operations: operations, metadataStore: metadataStore, hook: fault)
        } catch is SimulatedCrash { throw SimulatedCrash() }
        catch {
            // S5 より前の生成物は原本の状態や Trash に依存せず削除する。
            if let staging = createdStaging {
                try VolumePublishRemoval.discard(staging, parent: parent, operations: operations, isNetworkVolume: !volume.isLocal)
                try parent.sync(full: true)
            }
            try index.removeCompleted(stagingURL)
            throw error
        }
    }

    /// S2: rewriter が URL から再構築した全巻を、編集を再生する前に照合する。
    func verifyAssembledInput(_ volumeSet: ArchiveVolumeSet?, progress: Progress = Progress()) throws {
        try ArchiveImportPlan.checkCancellation(progress)
        guard let expected = target.expected else {
            guard volumeSet == nil else { throw VolumePublishError.setChanged }
            return
        }
        if let volumeSet {
            guard ArchiveSetIdentity(volumeSet: volumeSet) == expected else { throw VolumePublishError.setChanged }
        } else if expected.volumes.count != 1 { throw VolumePublishError.setChanged }
        try Self.verifyExpected(target, parent: parent)
        for old in initialRecord.oldVolumes {
            guard try old.matches(in: parent, useHash: initialRecord.hashesOldVolumes, checkCancellation: { try ArchiveImportPlan.checkCancellation(progress) }) else { throw VolumePublishError.setChanged }
        }
    }

    /// rollback 後の入力セットの identity。rollback の rename は synthetic inode を変えうるので、session が新しい inode を
    /// 採用する前に journal の旧巻記録で原本の byte を証明し、その前後の identity が同じことを確かめる。
    func restoredInputIdentity() throws -> ArchiveSetIdentity {
        guard let layout = target.layout else { throw VolumePublishError.invalidPlan }
        let identity = try ArchiveSetIdentity.capture(layout: layout)
        for old in initialRecord.oldVolumes {
            guard try old.matches(in: parent, useHash: initialRecord.hashesOldVolumes) else { throw VolumePublishError.setChanged }
        }
        guard try ArchiveSetIdentity.capture(layout: layout) == identity else { throw VolumePublishError.setChanged }
        return identity
    }

    var input: ArchiveVolumeInput? {
        guard let layout = target.layout, let expected = target.expected else { return nil }
        return ArchiveVolumeInput(layout: layout, expected: expected, oldVolumes: initialRecord.oldVolumes,
                                  usesHashes: initialRecord.hashesOldVolumes)
    }

    /// 置き換える入力セットの全巻を W へ連結する。コピーは `ArchiveVolumeInput.copy(to:progress:)` で、別 stem の別名保存と同じ。
    /// 新しいセット（入力なし）では invalidPlan。
    func copyInputToWork(progress: Progress) throws {
        guard let input else { throw VolumePublishError.invalidPlan }
        try input.copy(to: workURL, progress: progress)
    }

    func publish(progress: Progress, validation: (@Sendable (ArchiveReader) throws -> Void)? = nil) throws -> PublishedVolumeSet {
        try state.withLock { state in
            guard !state.started, !state.finished else { throw VolumePublishError.alreadyUsed }
            state.started = true
        }
        defer { journal.release(); stagingLock.release(); setLock.release(); state.withLock { $0.finished = true } }
        var transaction = VolumePublishTransaction(parent: parent, staging: staging, journal: journal,
            renamer: renamer, index: index, record: initialRecord, operations: operations,
            stagingLock: stagingLock, isNetworkVolume: isNetworkVolume, stampsProveContent: stampsProveContent,
            metadataStore: metadataStore)
        var critical = false
        do {
            try checkCancellation(progress)
            let work = try staging.directory("work")
            guard let info = try work.info(initialRecord.workName), info.isRegularFile, info.st_size > 0 else { throw VolumePublishError.invalidPlan }
            try Self.checkWorkLength(UInt64(info.st_size), fileSystem: operations.volumeInfo(parent).fileSystem)
            let plan = try VolumePlan(totalLength: UInt64(info.st_size), schedule: target.schedule, scheme: target.scheme, layout: target.layout)
            try Self.checkOccupancy(plan: plan, oldCount: initialRecord.oldVolumes.count, parent: parent)
            try Self.checkSpace(requiredOutput: 0, additionalWorkBytes: 0, largest: plan.largestVolume,
                                available: operations.volumeInfo(parent).available)
            let draft: ArchiveVolumeMetadata.PublicationDraft?
            if target.writesVolumeMetadata {
                if let layout = target.layout, try VolumePublishFS.usesAppleDouble(parent) {
                    transaction.record.previousMetadata = try? metadataStore.entry(for: layout.gateURL)?.publication
                }
                // 世代の上限と旧属性の読み取りは W を切り出す前に確定する。
                draft = try ArchiveVolumeMetadata.prepareDraft(plan: plan, schedule: target.schedule,
                    oldLayout: target.layout, store: metadataStore, additionalQuarantine: target.additionalQuarantine)
            } else { draft = nil }
            transaction.record.newVolumes = try ArchiveStageDiagnostics.measure(.splitCopy) {
                try VolumeSplitter.split(workURL: workURL, into: staging.directory("new"),
                    plan: plan, oldLayout: target.layout,
                    avoidsAppleDouble: target.writesVolumeMetadata && (try VolumePublishFS.usesAppleDouble(parent)),
                    additionalQuarantine: target.additionalQuarantine, checkCancellation: { try self.checkCancellation(progress) })
            }
            transaction.record.totalLength = plan.totalLength
            transaction.record.metadata = try draft?.finish(volumes: transaction.record.newVolumes)
            if let metadata = transaction.record.metadata { try ArchiveVolumeMetadata.writeNative(metadata, in: staging.directory("new")) }
            try transaction.validateNew(in: staging.directory("new"), options: options, validation: validation)
            try transaction.phase(.prepared)
            try Self.verifyExpected(target, parent: parent)
            let gateURL = parent.url.appendingPathComponent(plan.gateName)
            try operations.willCoordinate(gateURL)
            let coordinator = VolumePublishCoordination(gate: gateURL, presenter: target.filePresenter, request: operations.coordinate)
            #if DEBUG
            let observer = ArchiveStageDiagnostics.observer.get()
            #endif
            return try coordinator.withAccess(gate: gateURL, timeout: coordinationTimeout) {
                try checkCancellation(progress)
                try Self.verifyExpected(target, parent: parent)
                try transaction.proveOldBeforeRetiring()
                try Self.checkOccupancy(plan: plan, oldCount: initialRecord.oldVolumes.count, parent: parent)
                let lease = try criticalSection.enter { try checkCancellation(progress) }
                defer { withExtendedLifetime(lease) {} }
                critical = true
                progress.isCancellable = false
                let prepared = transaction
                #if DEBUG
                // TaskLocal は detach した thread へ自動では渡らない。
                return try UncancelledThread.run {
                    try ArchiveStageDiagnostics.observer.withValue(observer) { try self.commitPrepared(prepared, plan: plan, validation: validation) }
                }
                #else
                return try UncancelledThread.run { try self.commitPrepared(prepared, plan: plan, validation: validation) }
                #endif
            }
        } catch is SimulatedCrash { throw SimulatedCrash() }
        catch {
            if !critical { _ = try? transaction.discardPrepared() }
            throw error
        }
    }

    /// S5 以降の臨界区間。旧巻の退避、新巻の配置、S10 の検証、durable done、旧巻の後片付けを順に行う。
    /// S11 の hook までの失敗は rollback して rolledBack を投げる（保留すべき検証失敗と SimulatedCrash はそのまま投げる）。
    /// done を書いた後に残るのは後片付けだけで、その失敗は committed の cleanupFailed に載せる。
    private func commitPrepared(_ prepared: VolumePublishTransaction, plan: VolumePlan,
                                validation: (@Sendable (ArchiveReader) throws -> Void)?) throws -> PublishedVolumeSet {
        var transaction = prepared
        do {
            try hook(.s5)
            try transaction.retireOld(hook: hook)
            let inodes = try transaction.placeNew(hook: hook)
            do { try transaction.validateNew(in: parent, inodes: inodes, options: options, validation: validation) }
            catch let error as VolumePublishError {
                if case .contentMismatch = error { throw error }
                // 次巻名の占有は namespace の衝突。reader の一時エラーとは分けて引き戻す。
                if case .nameOccupied = error { throw error }
                if Self.requiresHold(error) { throw error }
                throw VolumePublishError.publishedVerificationPending(staging: staging.url, diagnostic: String(describing: error))
            } catch {
                throw VolumePublishError.publishedVerificationPending(staging: staging.url, diagnostic: String(describing: error))
            }
            try hook(.s10)
            try hook(.s11)
        } catch is SimulatedCrash { throw SimulatedCrash() }
        catch let failure as VolumePublishError where Self.requiresHold(failure) { throw failure }
        catch {
            let underlying = String(describing: error)
            do { try transaction.rollback() }
            catch { throw VolumePublishError.rollbackIncomplete(staging.url) }
            var disposal: VolumeDisposal = .none
            var cleanupFailure = transaction.persistMetadataWarning(restored: true)
            do {
                disposal = try transaction.dispose("abandoned")
                if case .kept = disposal { cleanupFailure = "Generated data retained" }
                else { try transaction.removeEmptyStaging() }
            } catch { cleanupFailure = String(describing: error) }
            throw VolumePublishError.rolledBack(underlying: underlying, cleanupFailed: cleanupFailure, disposal: disposal)
        }
        var layout = ArchiveVolumeLayout(scheme: plan.scheme, volumes: plan.volumes.map {
            .init(url: parent.url.appendingPathComponent($0.name), length: $0.length)
        }, openedVolumeIndex: 0)
        layout.savedSchedule = target.schedule
        let identity: ArchiveSetIdentity
        // この durable な境界以降は cleanup のみ。失敗しても新しい identity を返す。
        do {
            identity = try ArchiveSetIdentity.capture(layout: layout)
            try transaction.phase(.done)
        } catch {
            throw VolumePublishError.publishedVerificationPending(staging: staging.url, diagnostic: String(describing: error))
        }
        var disposal: VolumeDisposal = .none
        let metadataWarning = transaction.persistMetadataWarning()
        var cleanupFailure = metadataWarning
        do {
            try hook(.committed)
            disposal = try transaction.dispose("old")
            try hook(.oldDisposed)
            if case .kept = disposal {
                try transaction.markOldKept()
                cleanupFailure = "Superseded old volumes retained"
            }
            else { try transaction.removeEmptyStaging(hook: hook) }
        } catch is SimulatedCrash { throw SimulatedCrash() }
        catch { cleanupFailure = String(describing: error) }
        return PublishedVolumeSet(gateURL: layout.gateURL, layout: layout, identity: identity,
            oldVolumesDisposal: disposal, usedExclusiveRenameFallback: renamer.usesFallback,
            outcome: .committed(cleanupFailed: cleanupFailure), metadataWarning: metadataWarning)
    }

    private static func requiresHold(_ error: VolumePublishError) -> Bool {
        if case .publishedReaderFailed = error { return true }
        if case .publishedVerificationPending = error { return true }
        return false
    }

    static func checkWorkLength(_ length: UInt64, fileSystem: String) throws {
        if VolumePublishFS.fat32Family.contains(fileSystem.lowercased()), length >= UInt64(UInt32.max) {
            // 別 volume の W の所有権管理は持たない。S0 で明示的に拒否し、巨大な書き込みを始めない。
            throw VolumePublishError.fat32WorkFileTooLarge(length: length)
        }
    }

    /// publish 前は同期で片付ける。準備中は取消要求、S5 後の要求は観測しない。
    func cancel() {
        let cleanup = state.withLock { state in
            state.cancelled = true
            guard !state.started, !state.finished else { return false }
            state.finished = true
            return true
        }
        guard cleanup else { return }
        defer { journal.release(); stagingLock.release(); setLock.release() }
        let transaction = VolumePublishTransaction(parent: parent, staging: staging, journal: journal,
            renamer: renamer, index: index, record: initialRecord, operations: operations,
            stagingLock: stagingLock, isNetworkVolume: isNetworkVolume, metadataStore: metadataStore)
        _ = try? transaction.discardPrepared()
    }

    private func checkCancellation(_ progress: Progress) throws {
        if progress.isCancelled || Task.isCancelled || state.withLock({ $0.cancelled }) { throw CancellationError() }
    }

    private static func verifyExpected(_ target: VolumeSetTarget, parent: VolumePublishDirectory) throws {
        try parent.verifyPath()
        if let layout = target.layout, let expected = target.expected {
            guard layout.volumes.allSatisfy({ $0.url.deletingLastPathComponent().path == parent.url.path }),
                  layout.volumes.enumerated().allSatisfy({ $0.element.url.lastPathComponent == layout.fileName(forVolumeAt: $0.offset, count: layout.volumes.count) }),
                  (try? ArchiveSetIdentity.capture(layout: layout)) == expected else { throw VolumePublishError.setChanged }
        } else if target.expected != nil || target.layout != nil { throw VolumePublishError.setChanged }
    }

    static func checkOldPermissions(_ target: VolumeSetTarget, parent: VolumePublishDirectory) throws {
        var directoryInfo = stat()
        guard fstat(parent.fd, &directoryInfo) == 0, faccessat(parent.fd, ".", W_OK | X_OK, 0) == 0 else {
            throw VolumePublishError.system(errno)
        }
        for old in target.expected?.volumes ?? [] {
            guard let info = try parent.info(old.fileName), info.isRegularFile,
                  faccessat(parent.fd, old.fileName, W_OK, 0) == 0,
                  info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0,
                  directoryInfo.st_mode & S_ISVTX == 0 || info.st_uid == geteuid() else { throw VolumePublishError.setChanged }
        }
    }

    static func checkOccupancy(plan: VolumePlan, oldCount: Int, parent: VolumePublishDirectory) throws {
        for index in oldCount...max(oldCount, plan.volumes.count) {
            try parent.requireAbsent(plan.scheme.fileName(forVolumeAt: index, count: plan.volumes.count + 1))
        }
    }

    private static func checkSpace(requiredOutput: UInt64, additionalWorkBytes: UInt64, largest: UInt64, available: UInt64) throws {
        let a = requiredOutput.addingReportingOverflow(largest)
        let b = a.partialValue.addingReportingOverflow(VolumePublishFS.margin)
        let c = b.partialValue.addingReportingOverflow(additionalWorkBytes)
        let required: UInt64 = a.overflow || b.overflow || c.overflow ? .max : c.partialValue
        guard available >= required else { throw VolumePublishError.insufficientSpace(required: required, available: available) }
    }

    private static func checkDescriptorBudget(_ count: Int) throws {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { throw VolumePublishError.system(errno) }
        let bound = min(limit.rlim_cur, rlim_t(OPEN_MAX))
        let openCount = (0..<Int32(bound)).reduce(0) { $0 + (fcntl($1, F_GETFD) >= 0 ? 1 : 0) }
        guard UInt64(openCount + 3 * count + 32) < limit.rlim_cur else { throw VolumePublishError.system(EMFILE) }
    }
}
