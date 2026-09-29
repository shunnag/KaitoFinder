import Darwin
import Foundation
import GyoshukuKit
@_spi(TarEditLayout) import KaitoKit

nonisolated struct ArchiveImportResult: Sendable {
    let addedPaths: [String]
    let failures: [ArchiveImportPlan.Failure]
    var reloadFailure: String?
    var publishedIdentity: ArchiveSetIdentity?
}

/// session の actor 内だけで実行する。書庫の原本へ書くのは最後の rename 一回だけ。
nonisolated enum ArchiveImportTransaction {
    // 文書・session の公開 API を変えず、append の子 Task にも注入を引き継ぐ。
    static let pendingWorkRegistry = TaskLocal<PendingWorkRegistry>(wrappedValue: .shared)

    static func createFolder(plan: ArchiveNewFolderPlan, archive: URL, mode: ArchiveCapabilities.Mode,
                             options: WriterOptions = WriterOptions(), password: String? = nil, progress: Progress,
                             willOpenUpdater: (@Sendable () throws -> Void)? = nil,
                             willPublish: (@Sendable () throws -> Void)? = nil, expectedIdentity: ArchiveSetIdentity? = nil,
                    verifiedOutput: ArchiveVerifiedOutputSink? = nil,
                    sessionReader: sending ArchiveReader? = nil) throws -> ArchiveImportResult {
        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 1, additions: [], itemCount: 1,
            carriedBytes: ArchiveWriteProgress.carriedBytes(plan.existing), changesExisting: false))
        let identity = try publish(archive: archive, mode: mode, options: options, password: password, progress: progress,
            ledger: ledger,
            willOpenUpdater: willOpenUpdater, willPublish: willPublish, expectedIdentity: expectedIdentity,
            verifiedOutput: verifiedOutput, sessionReader: sessionReader,
            expectedOutput: .init(existing: plan.existing, additions: [.init(adding: plan.path, kind: .directory)], mode: mode)) { updater in
            try ArchiveStageDiagnostics.measure(.planValidation) {
                try ArchiveEditPlan.verifyNames(updater.entryNames, existing: plan.existing)
            }
            try ArchiveImportPlan.checkCancellation(progress)
            try updater.addDirectory(plan.path)
            ledger.didCount()
        }
        return ArchiveImportResult(addedPaths: [plan.path], failures: [], publishedIdentity: identity)
    }

    // phase hook は同じ worker 上で呼び、取消し・障害の境界を XCTest で再現する。
    static func run(plan: ArchiveImportPlan, archive: URL, mode: ArchiveCapabilities.Mode,
                    options: WriterOptions = WriterOptions(), password: String? = nil, progress: Progress,
                    didProcess: (@Sendable (Int) throws -> Void)? = nil,
                    willPublish: (@Sendable () throws -> Void)? = nil, expectedIdentity: ArchiveSetIdentity? = nil,
                    verifiedOutput: ArchiveVerifiedOutputSink? = nil,
                    sessionReader: sending ArchiveReader? = nil) throws -> ArchiveImportResult {
        guard plan.failures.isEmpty, !plan.items.isEmpty else {
            return ArchiveImportResult(addedPaths: [], failures: plan.failures)
        }
        guard let existing = plan.expectedEntries else { throw ArchiveEditError.staleSelection }
        for stamp in plan.sourceStamps {
            try ArchiveImportPlan.checkCancellation(progress)
            try stamp.verify()
        }
        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: plan.replacingEntries.count,
            additions: plan.items.map(\.byteCount), itemCount: plan.items.count,
            carriedBytes: ArchiveWriteProgress.carriedBytes(existing, removing: plan.replacingEntries),
            changesExisting: !plan.replacingEntries.isEmpty))
        let quarantine = try ExtractionQuarantine.firstValue(from: plan.items.lazy.map(\.url)) {
            try ArchiveImportPlan.checkCancellation(progress)
        }
        let expectedOutput = try ArchiveOutputProjection(existing: existing, removing: plan.replacingEntries,
                                                        additions: plan.items.map { try .init(adding: $0) }, mode: mode)
        let identity = try publish(archive: archive, mode: mode, options: options, password: password, progress: progress, ledger: ledger, willPublish: {
            for stamp in plan.sourceStamps { try ArchiveImportPlan.checkCancellation(progress); try stamp.verify() }
            try willPublish?()
        },
            expectedIdentity: expectedIdentity, verifiedOutput: verifiedOutput, sessionReader: sessionReader,
            additionalQuarantine: quarantine, registry: pendingWorkRegistry.get(),
            expectedOutput: expectedOutput) { updater in
            try ArchiveStageDiagnostics.measure(.planValidation) {
                try ArchiveEditPlan.verifyNames(updater.entryNames, existing: existing)
            }
            if !plan.replacingEntries.isEmpty {
                try updater.remove(entriesAt: plan.replacingEntries)
                ledger.didCount(plan.replacingEntries.count)
            }
            let additions = plan.items.map { item in
                ArchiveAddition(path: item.path, source: item.isDirectory
                    ? .directory(modificationDate: nil) : .contents(of: item.url))
            }
            if !additions.isEmpty {
                var callbackFailure: (any Error)?
                do {
                    try updater.add(additions) { event in
                        switch event {
                        case .willStart(let index):
                            try ArchiveImportPlan.checkCancellation(progress)
                            #if DEBUG
                            let item = plan.items[index]
                            if !item.isDirectory { willAddFileForTesting.get()?(item.url) }
                            #endif
                        case .progress(let index, let value):
                            try ledger.addition(index)(value)
                        case .didFinish(let index):
                            ledger.didFinishAddition(index)
                            do { try didProcess?(index) }
                            catch { callbackFailure = error; throw error }
                        }
                    }
                } catch let error as ArchiveAdditionError {
                    // callback 自身が、別の操作の batch エラーを投げることがある。
                    if let callbackFailure { throw callbackFailure }
                    throw ExtractionFailure.refused("\(plan.items[error.index].path): \(ArchiveErrorText.describe(error.underlying))")
                }
            }
            for stamp in plan.sourceStamps {
                try ArchiveImportPlan.checkCancellation(progress)
                try stamp.verify()
            }
        }
        return ArchiveImportResult(addedPaths: plan.items.map(\.path), failures: [], publishedIdentity: identity)
    }

    // 追加・削除・改名で公開境界を共有し、undo が退避する原本を必ず一致させる。
    // 段階は prepareWorkDirectory → produceWork → verifyWork → publishWork。原本へ触るのは publishWork の rename だけ。
    @discardableResult static func publish(archive: URL, mode: ArchiveCapabilities.Mode, options: WriterOptions, password: String? = nil, progress: Progress,
                        ledger: ArchiveWriteProgress,
                        commitProgress: ((ArchiveUpdater.CommitProgress) throws -> Void)? = nil,
                        willOpenUpdater: (@Sendable () throws -> Void)? = nil,
                        willPublish: (@Sendable () throws -> Void)?,
                        expectedIdentity: ArchiveSetIdentity? = nil,
                        verifiedOutput: ArchiveVerifiedOutputSink? = nil,
                        sessionReader: sending ArchiveReader? = nil,
                        additionalQuarantine: Data? = nil,
                        registry: PendingWorkRegistry = .shared,
                        publication: ArchiveSavePublication? = nil,
                        deferredPlan: ArchiveSaveReplayPlan? = nil,
                        expectedOutput: ArchiveOutputProjection,
                        mutate: (any ArchiveEditing) throws -> Void) throws -> ArchiveSetIdentity {
        if ArchiveSplitVolume.isSplitVolumeMember(archive) { throw ArchiveEditError.splitArchive }
        try ArchiveImportPlan.checkCancellation(progress)
        let original = try ArchiveSetIdentity.capture(url: archive)
        let archiveBytes = ArchiveWriteProgress.sum(original.volumes.lazy.map(\.size))
        if let expectedIdentity, original != expectedIdentity { throw ArchiveEditError.archiveChanged }
        let directory = try prepareWorkDirectory(beside: archive, registry: registry)
        defer { registry.removeAndUnregister(directory) }
        do { try registry.recordIdentity(directory) }
        catch { NSLog("同一性の記録に失敗しました: %@", String(describing: error)) }
        let outputFormat = mode.outputFormat
        let context = PublishContext(archive: archive,
            work: directory.appendingPathComponent("archive." + ArchiveCreationPlan.filenameExtension(for: outputFormat)),
            outputFormat: outputFormat, password: password, options: options, progress: progress, ledger: ledger,
            archiveBytes: archiveBytes, deferredPlan: deferredPlan, expectedOutput: expectedOutput)
        let produced = try produceWork(mode: mode, context: context,
                                       willOpenUpdater: willOpenUpdater, sessionReader: sessionReader, mutate: mutate)
        if let additionalQuarantine {
            // 新規作成と同じく追加元の印も伝播する。原本の印があればそちらを保つ。
            // 公開前の作業コピーだけに付け、取消しや検証失敗で原本の属性を変えない。
            try ExtractionQuarantine.apply(try ExtractionQuarantine.read(from: context.work) ?? additionalQuarantine, to: context.work)
        }
        #if DEBUG
        try didCommitForTesting.get()?(context.work)
        #endif
        let verified = try verifyWork(produced, context: context)
        #if DEBUG
        let publishSpan = ArchiveStageDiagnostics.begin(.publish)
        defer { publishSpan?.end() }
        #endif
        try publishWork(verified, produced: produced, context: context, original: original,
                        willPublish: willPublish, publication: publication, verifiedOutput: verifiedOutput)
        return verified.identity
    }

    /// publish 一回分の不変な入力。各段階の private static が共有する。
    private struct PublishContext {
        let archive: URL
        let work: URL
        let outputFormat: GyoshukuKit.ArchiveFormat
        let password: String?
        let options: WriterOptions
        let progress: Progress
        let ledger: ArchiveWriteProgress
        let archiveBytes: UInt64
        let deferredPlan: ArchiveSaveReplayPlan?
        let expectedOutput: ArchiveOutputProjection
    }

    /// 生成した作業ファイルの由来。fallback で rewrite に切り替わった mode と、splice 検証に要る情報を運ぶ。
    private struct ProducedWork {
        var publishedMode: ArchiveCapabilities.Mode
        var spliceBase: TarEditingSnapshot? = nil
        var spliced: CompressedTarCommitResult? = nil
    }

    /// 検証済みの作業ファイル。publish 直前まで同じ実体であることを source の fd と path で再確認する。
    private struct VerifiedWork {
        let identity: ArchiveSetIdentity
        let source: ArchiveVerifiedFileSource
        let reader: ArchiveReader
        let hint: URL
        let adoptable: Bool
    }

    /// 台帳に記録してから作業ディレクトリを作る。作成に失敗したら記録も取り消す。
    private static func prepareWorkDirectory(beside archive: URL, registry: PendingWorkRegistry) throws -> URL {
        let directory = archive.deletingLastPathComponent().appendingPathComponent(WorkAreaName.add + UUID().uuidString)
        do { try registry.register(directory) }
        catch { NSLog("台帳への記録に失敗しました: %@", String(describing: error)) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        } catch {
            registry.unregister(directory)
            throw error
        }
        return directory
    }

    /// rewriter 経路。作業ファイルが既にあれば EEXIST として拒否し、最後に原本の属性を写す。
    private static func rewrite(format: GyoshukuKit.ArchiveFormat, context: PublishContext,
                                mutate: (any ArchiveEditing) throws -> Void) throws {
        let archive = context.archive, work = context.work, ledger = context.ledger, progress = context.progress
        var info = stat()
        guard lstat(work.path, &info) != 0 else { throw ExtractionFailure.system(EEXIST) }
        guard errno == ENOENT else { throw ExtractionFailure.system(errno) }
        let rewriter = try ArchiveStageDiagnostics.measure(.rewriterOpen) {
            try ArchiveRewriter.open(url: archive, password: context.password, output: work, format: format, options: context.options)
        }
        // 入力の復号鍵と出力の暗号化設定を分離する。
        guard !rewriter.hasEncryptedEntries || context.password != nil else {
            throw ExtractionFailure.refused(ArchiveCapabilities(refusal: .encrypted).readOnlyReason!)
        }
        ledger.begin(.rewriter(format, readsAdditionsDuringCommit: rewriter.readsAdditionsDuringCommit), archiveBytes: context.archiveBytes, options: context.options)
        try ArchiveStageDiagnostics.measure(context.deferredPlan == nil ? .mutate : .replay) { try mutate(rewriter) }
        try ArchiveImportPlan.checkCancellation(progress)
        try rewriter.finishAdditions(progress: ledger.finishAdditions)
        try ArchiveStageDiagnostics.measure(.commit) {
            try rewriter.commit(progress: ledger.commit) { done, total in
                ledger.didCarry(done, total)
                try ArchiveImportPlan.checkCancellation(progress)
            }
        }
        try preserveAttributes(from: archive, to: work)
    }

    /// mode ごとの updater / rewriter で作業ファイルを作る。updater が requiresRewrite で拒否したら rewrite に切り替える。
    private static func produceWork(mode: ArchiveCapabilities.Mode, context: PublishContext,
                                    willOpenUpdater: (@Sendable () throws -> Void)?,
                                    sessionReader: sending ArchiveReader?,
                                    mutate: (any ArchiveEditing) throws -> Void) throws -> ProducedWork {
        let archive = context.archive, work = context.work, options = context.options, password = context.password
        let progress = context.progress, ledger = context.ledger, archiveBytes = context.archiveBytes, deferredPlan = context.deferredPlan
        var produced = ProducedWork(publishedMode: mode)
        switch mode {
        case .inPlace:
            try willOpenUpdater?()
            let updater = try ArchiveStageDiagnostics.measure(.updaterOpen) { try ArchiveUpdater.open(url: archive, output: work, options: options) }
            ledger.begin(.updater(.zip, processesAdditionsAtCommit: false), archiveBytes: archiveBytes, options: options)
            try ArchiveStageDiagnostics.measure(deferredPlan == nil ? .mutate : .replay) { try mutate(updater) }
            try ArchiveImportPlan.checkCancellation(progress)
            try updater.finishAdditions(progress: ledger.finishAdditions)
            try ArchiveStageDiagnostics.measure(.commit) {
                #if DEBUG
                try willCommitUpdaterForTesting.get()?()
                #endif
                try updater.commit(progress: ledger.commit)
            }
            #if DEBUG
            try didCommitUpdaterForTesting.get()?(updater)
            #endif
            try preserveAttributes(from: archive, to: work, includingCreationDate: true)
        case .rewrite(let format):
            try willOpenUpdater?()
            try rewrite(format: format, context: context, mutate: mutate)
        case .update(let format) where [.tarGzip, .tarBzip2, .tarXZ].contains(format):
            guard let reader = sessionReader else { throw ArchiveEditError.staleSelection }
            // 同じ独立 reader から Sendable な base を採り、reader の所有権は GK へ渡す。
            let spliceBase = reader.tarEditingSnapshot()
            try willOpenUpdater?()
            let updater: Result<CompressedTarUpdater, any Error>
            do {
                // sending の reader を計測 closure に捕捉せず、一度だけ移す。
                #if DEBUG
                let span = ArchiveStageDiagnostics.begin(.updaterOpen)
                defer { span?.end() }
                #endif
                updater = .success(try CompressedTarUpdater.open(reader: reader, output: work, format: format, options: options))
            } catch { updater = .failure(error) }
            produced = try runUpdaterRoute(updater: updater, format: format, context: context,
                processesAdditionsAtCommit: true, spliceBase: spliceBase,
                requiresRewrite: tarRewriteReason, commit: { try $0.commit(progress: $1) },
                mapVerificationFailure: tarVerificationFailure, didCommit: { updater in
                    #if DEBUG
                    try didCommitCompressedTarUpdaterForTesting.get()?(updater)
                    #endif
                }, mutate: mutate)
        case .update(.tar):
            try willOpenUpdater?()
            let updater = Result {
                try ArchiveStageDiagnostics.measure(.updaterOpen) {
                    try TarUpdater.open(url: archive, output: work, options: options)
                }
            }
            produced = try runUpdaterRoute(updater: updater, format: .tar, context: context,
                requiresRewrite: tarRewriteReason,
                commit: { try $0.commit(progress: $1); return nil },
                mapVerificationFailure: tarVerificationFailure, didCommit: { updater in
                    #if DEBUG
                    try didCommitTarUpdaterForTesting.get()?(updater)
                    #endif
                }, mutate: mutate)
        case .update(.lha):
            try willOpenUpdater?()
            let updater = Result {
                try ArchiveStageDiagnostics.measure(.updaterOpen) {
                    try LHAUpdater.open(url: archive, output: work, options: options)
                }
            }
            produced = try runUpdaterRoute(updater: updater, format: .lha, context: context,
                requiresRewrite: routeRewriteReason,
                commit: { try $0.commit(progress: $1); return nil },
                mapVerificationFailure: routeVerificationFailure, didCommit: { updater in
                    #if DEBUG
                    try didCommitLHAUpdaterForTesting.get()?(updater)
                    #endif
                }, mutate: mutate)
        case .update(.sevenZip):
            try willOpenUpdater?()
            let updater = Result {
                try ArchiveStageDiagnostics.measure(.updaterOpen) {
                    try SevenZipUpdater.open(url: archive, password: password, output: work, options: options)
                }
            }
            produced = try runUpdaterRoute(updater: updater, format: .sevenZip, context: context,
                copyingExtendedAttributes: false, requiresRewrite: routeRewriteReason,
                commit: { try $0.commit(progress: $1); return nil },
                mapVerificationFailure: routeVerificationFailure, didCommit: { updater in
                    #if DEBUG
                    try didCommitSevenZipUpdaterForTesting.get()?(updater)
                    #endif
                }, mutate: mutate)
        case .update: throw ArchiveEditError.staleSelection
        }
        return produced
    }

    /// open の拒否だけを rewrite に切り替え、変更・commit・検証失敗の境界を共通に保つ。
    private static func runUpdaterRoute<U: ArchiveEditing>(updater opened: Result<U, any Error>,
        format: GyoshukuKit.ArchiveFormat, context: PublishContext,
        processesAdditionsAtCommit: Bool = false, spliceBase: TarEditingSnapshot? = nil,
        copyingExtendedAttributes: Bool = true,
        requiresRewrite: (any Error) -> String?,
        commit: (U, @escaping (ArchiveUpdater.CommitProgress) throws -> Void) throws -> CompressedTarCommitResult?,
        mapVerificationFailure: (any Error) -> ArchiveVerificationFailure?,
        didCommit: (U) throws -> Void, mutate: (any ArchiveEditing) throws -> Void) throws -> ProducedWork {
        let updater: U
        switch opened {
        case .success(let value): updater = value
        case .failure(let error):
            guard let reason = requiresRewrite(error) else { throw error }
            #if DEBUG
            didFallBackToRewriteForTesting.get()?(reason)
            #endif
            try rewrite(format: format, context: context, mutate: mutate)
            return ProducedWork(publishedMode: .rewrite(format))
        }
        let ledger = context.ledger
        ledger.begin(.updater(format, processesAdditionsAtCommit: processesAdditionsAtCommit),
                     archiveBytes: context.archiveBytes, options: context.options)
        try ArchiveStageDiagnostics.measure(context.deferredPlan == nil ? .mutate : .replay) { try mutate(updater) }
        try ArchiveImportPlan.checkCancellation(context.progress)
        try updater.finishAdditions(progress: ledger.finishAdditions)
        let commitCallback = ledger.commit
        var produced = ProducedWork(publishedMode: .update(format), spliceBase: spliceBase)
        do {
            produced.spliced = try ArchiveStageDiagnostics.measure(.commit) {
                #if DEBUG
                try willCommitUpdaterForTesting.get()?()
                #endif
                return try commit(updater, commitCallback)
            }
        } catch {
            guard let failure = mapVerificationFailure(error) else { throw error }
            throw failure.reported(file: context.archive)
        }
        #if DEBUG
        try didCommit(updater)
        #endif
        try preserveAttributes(from: context.archive, to: context.work, includingCreationDate: true,
                               copyingExtendedAttributes: copyingExtendedAttributes)
        return produced
    }

    private static func tarRewriteReason(_ error: any Error) -> String? {
        guard let error = error as? TarUpdaterError, case .requiresRewrite(let reason) = error else { return nil }
        return reason
    }

    private static func routeRewriteReason(_ error: any Error) -> String? {
        guard let error = error as? UpdaterRouteError, case .requiresRewrite(let reason) = error else { return nil }
        return reason
    }

    private static func tarVerificationFailure(_ error: any Error) -> ArchiveVerificationFailure? {
        guard let error = error as? TarUpdaterError, case .outputVerificationFailed = error else { return nil }
        return .updaterVerification(.init(error))
    }

    private static func routeVerificationFailure(_ error: any Error) -> ArchiveVerificationFailure? {
        guard let error = error as? UpdaterRouteError, case .outputVerificationFailed = error else { return nil }
        return .updaterVerification(.init(error))
    }

    /// 作業ファイルを reader で開き直し、ZIP の件数と投影（expectedOutput）で検証する。原本にはまだ触れない。
    private static func verifyWork(_ produced: ProducedWork, context: PublishContext) throws -> VerifiedWork {
        let archive = context.archive, work = context.work, options = context.options, outputFormat = context.outputFormat
        // 検証前の実体を記録し、公開直前までの差し替え・書き換えを拒否する。
        let identity: ArchiveSetIdentity
        let source: ArchiveVerifiedFileSource
        let verified: ArchiveReader
        let adoptable = ArchiveVerifiedOutput.usesPublishedName(archive, format: outputFormat)
        let hint = adoptable ? archive.standardizedFileURL : work
        do { source = try ArchiveVerifiedFileSource(url: work) }
        catch { throw ArchiveVerificationFailure.sourceOpen(.init(error)).reported(file: archive) }
        #if DEBUG
        try didOpenVerificationSourceForTesting.get()?(work)
        #endif
        try verifyWorkIdentity(source: source, work: work, phase: .beforeVerification, archive: archive)
        identity = source.identity
        if let spliced = produced.spliced {
            let actual = source.fileIdentity, expected = spliced.output
            guard actual.device == expected.device, actual.inode == expected.inode, actual.size == expected.size,
                  actual.modificationSeconds == expected.modificationSeconds,
                  actual.modificationNanoseconds == expected.modificationNanoseconds else {
                throw ArchiveVerificationFailure.updaterVerification(.init(
                    TarUpdaterError.outputVerificationFailed(reason: "output identity"))).reported(file: archive)
            }
        }
        do {
            let verificationOptions = ReaderOptions.kaitoFinderVerification(password: options.password)
            verified = try ArchiveStageDiagnostics.measure(.verificationOpen) {
                guard let spliced = produced.spliced, let spliceBase = produced.spliceBase else {
                    return try ArchiveReader.open(source: source, sourceURL: hint, options: verificationOptions)
                }
                do {
                    return try ArchiveReader.openSplicedCompressedTar(output: source, sourceURL: hint, base: spliceBase,
                        splice: CompressedTarSplice(segments: spliced.segments.map(Self.kaitoKitSegment)), options: verificationOptions)
                } catch let error as TarSpliceVerificationError where error.reason == .baseNotSpliceable {
                    #if DEBUG
                    didFallBackToFullVerificationForTesting.get()?("\(error.reason)")
                    #endif
                    return try ArchiveReader.open(source: source, sourceURL: hint, options: verificationOptions)
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw ArchiveVerificationFailure.readerOpen(.init(error)).reported(file: archive) }
        if outputFormat == .zip {
            try ArchiveStageDiagnostics.measure(.outputProbe) {
                let count: UInt64
                do { count = try ArchiveUpdater.probe(url: work).entryCount }
                catch is CancellationError { throw CancellationError() }
                catch { throw ArchiveVerificationFailure.outputProbe(.init(error)).reported(file: archive) }
                guard count == UInt64(verified.entries.count) else {
                    throw ArchiveVerificationFailure.outputCount(expected: UInt64(verified.entries.count), actual: count).reported(file: archive)
                }
            }
        }
        try ArchiveStageDiagnostics.measure(.entryComparison) {
            if let failure = context.expectedOutput.resolving(produced.publishedMode).validationFailure(verified, format: outputFormat) {
                throw failure.reported(file: archive)
            }
        }
        #if DEBUG
        try didVerifyForTesting.get()?(work)
        #endif
        return VerifiedWork(identity: identity, source: source, reader: verified, hint: hint, adoptable: adoptable)
    }

    /// 公開境界。原本が変わっていないことを確かめ、rename 一回で作業ファイルを原本に差し替える。
    private static func publishWork(_ verified: VerifiedWork, produced: ProducedWork, context: PublishContext,
                                    original: ArchiveSetIdentity, willPublish: (@Sendable () throws -> Void)?,
                                    publication: ArchiveSavePublication?, verifiedOutput: ArchiveVerifiedOutputSink?) throws {
        let archive = context.archive, work = context.work, progress = context.progress
        try willPublish?()
        try ArchiveImportPlan.checkCancellation(progress)
        guard try ArchiveSetIdentity.capture(url: archive) == original else {
            throw ExtractionFailure.refused(String(localized: "処理中にアーカイブが別の操作で変更されました。"))
        }
        // 作業中に兄弟が現れた場合も、一巻だけの置換を拒否する。
        if ArchiveSplitVolume.isSplitVolumeMember(archive) { throw ArchiveEditError.splitArchive }
        // 作業ファイルへ復元した属性も含め、同一ボリュームで一括公開する。
        // ここが取消しの境界。成功後に取消しとして返してはならない。
        try verifyWorkIdentity(source: verified.source, work: work, phase: .beforePublication, archive: archive)
        try (publication ?? ArchiveSavePublication.current.get())?.enter(progress: progress)
        guard rename(work.path, archive.path) == 0 else { throw ExtractionFailure.system(errno) }
        #if DEBUG
        didPublishForTesting.get()?(archive)
        #endif
        verifiedOutput?.publishedMode = produced.publishedMode
        if verified.adoptable {
            verifiedOutput?.output = ArchiveVerifiedOutput(identity: verified.identity, reader: verified.reader, source: verified.source,
                hint: verified.hint, verificationPassword: context.options.password, format: context.outputFormat)
        }
        context.ledger.didPublish()
    }

    private static func kaitoKitSegment(_ segment: CompressedTarOutputSegment) -> CompressedTarSplice.Segment {
        switch segment {
        case .reused(let output, let base): .reused(output: output, base: base)
        case .encoded(let output): .encoded(output: output)
        }
    }

    private static func verifyWorkIdentity(source: ArchiveVerifiedFileSource, work: URL,
                                           phase: ArchiveVerificationFailure.Phase, archive: URL) throws {
        // volume UUID の取得成否や URL の resource cache に依存させない。
        // ctime/atime は xattr・Spotlight・読み出しでも変わるので内容の同一性には使わない。
        for anchor in [ArchiveVerificationFailure.Anchor.descriptor, .path] {
            let current: ArchiveFileIdentity
            do {
                current = try anchor == .descriptor ? ArchiveFileIdentity.capture(descriptor: source.descriptor)
                    : ArchiveFileIdentity.capture(url: work)
            } catch {
                throw ArchiveVerificationFailure.identity(phase, anchor, expected: source.fileIdentity,
                    actual: nil, error: .init(error)).reported(file: archive)
            }
            guard current == source.fileIdentity else {
                throw ArchiveVerificationFailure.identity(phase, anchor, expected: source.fileIdentity,
                    actual: current, error: nil).reported(file: archive)
            }
        }
    }

    private static func preserveAttributes(from archive: URL, to work: URL, includingCreationDate: Bool = false,
                                           copyingExtendedAttributes: Bool = true) throws {
        var info = stat()
        guard lstat(archive.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
        guard chmod(work.path, info.st_mode & 0o7777) == 0 else { throw ExtractionFailure.system(errno) }
        if includingCreationDate {
            // Date の浮動小数への往復で原本の作成日の精度を落とさない。
            var attributes = attrlist()
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
            var created = info.st_birthtimespec
            guard setattrlist(work.path, &attributes, &created, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0 else {
                throw ExtractionFailure.system(errno)
            }
        }
        // 7z の sequential 出力は原本の xattr を運ばない。clone は既に属性を持つ。
        guard copyingExtendedAttributes else { return }
        // 単一作業ファイルと rewrite の両方で、Finder タグや quarantine を含む全 xattr を運ぶ。
        let size = listxattr(archive.path, nil, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { throw ExtractionFailure.system(errno) }
        var names = [CChar](repeating: 0, count: size)
        let count = names.withUnsafeMutableBufferPointer {
            listxattr(archive.path, $0.baseAddress, $0.count, XATTR_NOFOLLOW)
        }
        guard count >= 0 else { throw ExtractionFailure.system(errno) }
        guard count == size else { throw ExtractionFailure.refused(String(localized: "処理中にアーカイブが別の操作で変更されました。")) }
        for nameBytes in names.split(separator: 0) {
            try (Array(nameBytes) + [0]).withUnsafeBufferPointer { name in
                let size = getxattr(archive.path, name.baseAddress!, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { throw ExtractionFailure.system(errno) }
                var value = Data(count: size)
                let count = value.withUnsafeMutableBytes {
                    getxattr(archive.path, name.baseAddress!, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                }
                guard count >= 0 else { throw ExtractionFailure.system(errno) }
                guard count == size else { throw ExtractionFailure.refused(String(localized: "処理中にアーカイブが別の操作で変更されました。")) }
                let status = value.withUnsafeBytes {
                    setxattr(work.path, name.baseAddress!, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
                }
                guard status == 0 else { throw ExtractionFailure.system(errno) }
            }
        }
    }
}
