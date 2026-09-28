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
    #if DEBUG
    static let willAddFileForTesting = TaskLocal<(@Sendable (URL) -> Void)?>(wrappedValue: nil)
    static let didCommitForTesting = TaskLocal<(@Sendable (URL) throws -> Void)?>(wrappedValue: nil)
    static let didOpenVerificationSourceForTesting = TaskLocal<(@Sendable (URL) throws -> Void)?>(wrappedValue: nil)
    static let didVerifyForTesting = TaskLocal<(@Sendable (URL) throws -> Void)?>(wrappedValue: nil)
    static let didPublishForTesting = TaskLocal<(@Sendable (URL) -> Void)?>(wrappedValue: nil)
    static let didCommitUpdaterForTesting = TaskLocal<(@Sendable (ArchiveUpdater) throws -> Void)?>(wrappedValue: nil)
    static let willCommitUpdaterForTesting = TaskLocal<(@Sendable () throws -> Void)?>(wrappedValue: nil)
    static let didCommitTarUpdaterForTesting = TaskLocal<(@Sendable (TarUpdater) throws -> Void)?>(wrappedValue: nil)
    static let didCommitLHAUpdaterForTesting = TaskLocal<(@Sendable (LHAUpdater) throws -> Void)?>(wrappedValue: nil)
    static let didCommitSevenZipUpdaterForTesting = TaskLocal<(@Sendable (SevenZipUpdater) throws -> Void)?>(wrappedValue: nil)
    static let didCommitCompressedTarUpdaterForTesting = TaskLocal<(@Sendable (CompressedTarUpdater) throws -> Void)?>(wrappedValue: nil)
    static let didFallBackToRewriteForTesting = TaskLocal<(@Sendable (String) -> Void)?>(wrappedValue: nil)
    static let didFallBackToFullVerificationForTesting = TaskLocal<(@Sendable (String) -> Void)?>(wrappedValue: nil)
    #endif

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
                    // A callback can itself throw a batch error from another operation.
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
    @discardableResult static func publish(archive: URL, mode: ArchiveCapabilities.Mode, options: WriterOptions, password: String? = nil, progress: Progress,
                        ledger: ArchiveWriteProgress? = nil,
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
        let directory = archive.deletingLastPathComponent().appendingPathComponent(".KaitoFinder-add-" + UUID().uuidString)
        do { try registry.register(directory) }
        catch { NSLog("台帳への記録に失敗しました: %@", String(describing: error)) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        } catch {
            registry.unregister(directory)
            throw error
        }
        defer { registry.removeAndUnregister(directory) }
        do { try registry.recordIdentity(directory) }
        catch { NSLog("同一性の記録に失敗しました: %@", String(describing: error)) }
        let outputFormat = mode.outputFormat
        let work = directory.appendingPathComponent("archive." + ArchiveCreationPlan.filenameExtension(for: outputFormat))
        var publishedMode = mode
        var spliceBase: TarEditingSnapshot?
        var spliced: CompressedTarCommitResult?
        func updateCommitProgress() -> (ArchiveUpdater.CommitProgress) throws -> Void {
            if let ledger { return ledger.commit }
            // Compatibility for ledger-free callers, including the existing transaction test doubles.
            progress.totalUnitCount += 1_000
            var completed: Int64 = 0
            return { value in
                try ArchiveImportPlan.checkCancellation(progress)
                let units: Int64 = value.totalBytes == 0 ? 1_000
                    : Int64(min(1, Double(value.completedBytes) / Double(value.totalBytes)) * 1_000)
                let next = max(completed, units)
                progress.completedUnitCount += next - completed
                completed = next
            }
        }
        func rewriteBranch(format: GyoshukuKit.ArchiveFormat) throws {
            var info = stat()
            guard lstat(work.path, &info) != 0 else { throw ExtractionFailure.system(EEXIST) }
            guard errno == ENOENT else { throw ExtractionFailure.system(errno) }
            let rewriter = try ArchiveStageDiagnostics.measure(.rewriterOpen) {
                try ArchiveRewriter.open(url: archive, password: password, output: work, format: format, options: options)
            }
            // 入力の復号鍵と出力の暗号化設定を分離する。
            guard !rewriter.hasEncryptedEntries || password != nil else {
                throw ExtractionFailure.refused(ArchiveCapabilities(refusal: .encrypted).readOnlyReason!)
            }
            ledger?.begin(.rewriter(format, readsAdditionsDuringCommit: rewriter.readsAdditionsDuringCommit), archiveBytes: archiveBytes, options: options)
            try ArchiveStageDiagnostics.measure(deferredPlan == nil ? .mutate : .replay) { try mutate(rewriter) }
            try ArchiveImportPlan.checkCancellation(progress)
            if let ledger { try rewriter.finishAdditions(progress: ledger.finishAdditions) }
            // LHA・7z の fallback は、削除済みの項目と root を carry の予算に含めない。
            let carryCount = [.lha, .sevenZip].contains(format)
                ? expectedOutput.resolving(.rewrite(format)).entries.filter { !$0.isAddition }.count
                : rewriter.entryNames.count
            if ledger == nil { progress.totalUnitCount += Int64(carryCount) }
            try ArchiveStageDiagnostics.measure(.commit) {
                try rewriter.commit(progress: ledger?.commit) { done, total in
                    if let ledger { ledger.didCarry(done, total) }
                    else { progress.completedUnitCount += 1 }
                    try ArchiveImportPlan.checkCancellation(progress)
                }
            }
            try preserveAttributes(from: archive, to: work)
        }
        switch mode {
        case .inPlace:
            try willOpenUpdater?()
            let updater = try ArchiveStageDiagnostics.measure(.updaterOpen) { try ArchiveUpdater.open(url: archive, output: work, options: options) }
            ledger?.begin(.updater(.zip, processesAdditionsAtCommit: false), archiveBytes: archiveBytes, options: options)
            try ArchiveStageDiagnostics.measure(deferredPlan == nil ? .mutate : .replay) { try mutate(updater) }
            try ArchiveImportPlan.checkCancellation(progress)
            if let ledger { try updater.finishAdditions(progress: ledger.finishAdditions) }
            try ArchiveStageDiagnostics.measure(.commit) {
                #if DEBUG
                try willCommitUpdaterForTesting.get()?()
                #endif
                try updater.commit(progress: ledger?.commit ?? commitProgress)
            }
            #if DEBUG
            try didCommitUpdaterForTesting.get()?(updater)
            #endif
            try preserveAttributes(from: archive, to: work, includingCreationDate: true)
        case .rewrite(let format):
            try willOpenUpdater?()
            try rewriteBranch(format: format)
        case .update(let format) where [.tarGzip, .tarBzip2, .tarXZ].contains(format):
            guard let reader = sessionReader else { throw ArchiveEditError.staleSelection }
            // 同じ独立 reader から Sendable な base を採り、reader の所有権は GK へ渡す。
            spliceBase = reader.tarEditingSnapshot()
            try willOpenUpdater?()
            var updater: CompressedTarUpdater?
            do {
                // sending の reader を計測 closure に捕捉せず、一度だけ移す。
                #if DEBUG
                let span = ArchiveStageDiagnostics.begin(.updaterOpen)
                defer { span?.end() }
                #endif
                updater = try CompressedTarUpdater.open(reader: reader, output: work, format: format, options: options)
            } catch TarUpdaterError.requiresRewrite(let reason) {
                #if DEBUG
                didFallBackToRewriteForTesting.get()?(reason)
                #endif
            }
            if let updater {
                ledger?.begin(.updater(format, processesAdditionsAtCommit: true), archiveBytes: archiveBytes, options: options)
                try ArchiveStageDiagnostics.measure(deferredPlan == nil ? .mutate : .replay) { try mutate(updater) }
                try ArchiveImportPlan.checkCancellation(progress)
                if let ledger { try updater.finishAdditions(progress: ledger.finishAdditions) }
                let commitCallback = updateCommitProgress()
                do {
                    spliced = try ArchiveStageDiagnostics.measure(.commit) {
                        #if DEBUG
                        try willCommitUpdaterForTesting.get()?()
                        #endif
                        return try updater.commit(progress: commitCallback)
                    }
                } catch let error as TarUpdaterError {
                    guard case .outputVerificationFailed = error else { throw error }
                    throw ArchiveVerificationFailure.updaterVerification(.init(error)).reported(file: archive)
                }
                #if DEBUG
                try didCommitCompressedTarUpdaterForTesting.get()?(updater)
                #endif
                try preserveAttributes(from: archive, to: work, includingCreationDate: true)
            } else {
                spliceBase = nil
                publishedMode = .rewrite(format)
                try rewriteBranch(format: format)
            }
        case .update(.tar):
            try willOpenUpdater?()
            var updater: TarUpdater?
            do {
                updater = try ArchiveStageDiagnostics.measure(.updaterOpen) {
                    try TarUpdater.open(url: archive, output: work, options: options)
                }
            } catch TarUpdaterError.requiresRewrite(let reason) {
                #if DEBUG
                didFallBackToRewriteForTesting.get()?(reason)
                #endif
            }
            if let updater {
                ledger?.begin(.updater(.tar, processesAdditionsAtCommit: false), archiveBytes: archiveBytes, options: options)
                try ArchiveStageDiagnostics.measure(deferredPlan == nil ? .mutate : .replay) { try mutate(updater) }
                try ArchiveImportPlan.checkCancellation(progress)
                if let ledger { try updater.finishAdditions(progress: ledger.finishAdditions) }
                let commitCallback = updateCommitProgress()
                do {
                    try ArchiveStageDiagnostics.measure(.commit) {
                        #if DEBUG
                        try willCommitUpdaterForTesting.get()?()
                        #endif
                        try updater.commit(progress: commitCallback)
                    }
                } catch let error as TarUpdaterError {
                    guard case .outputVerificationFailed = error else { throw error }
                    throw ArchiveVerificationFailure.updaterVerification(.init(error)).reported(file: archive)
                }
                #if DEBUG
                try didCommitTarUpdaterForTesting.get()?(updater)
                #endif
                try preserveAttributes(from: archive, to: work, includingCreationDate: true)
            } else {
                publishedMode = .rewrite(.tar)
                try rewriteBranch(format: .tar)
            }
        case .update(.lha):
            try willOpenUpdater?()
            var updater: LHAUpdater?
            do {
                updater = try ArchiveStageDiagnostics.measure(.updaterOpen) {
                    try LHAUpdater.open(url: archive, output: work, options: options)
                }
            } catch UpdaterRouteError.requiresRewrite(let reason) {
                #if DEBUG
                didFallBackToRewriteForTesting.get()?(reason)
                #endif
            }
            if let updater {
                ledger?.begin(.updater(.lha, processesAdditionsAtCommit: false), archiveBytes: archiveBytes, options: options)
                try ArchiveStageDiagnostics.measure(deferredPlan == nil ? .mutate : .replay) { try mutate(updater) }
                try ArchiveImportPlan.checkCancellation(progress)
                if let ledger { try updater.finishAdditions(progress: ledger.finishAdditions) }
                let commitCallback = updateCommitProgress()
                do {
                    try ArchiveStageDiagnostics.measure(.commit) {
                        #if DEBUG
                        try willCommitUpdaterForTesting.get()?()
                        #endif
                        try updater.commit(progress: commitCallback)
                    }
                } catch let error as UpdaterRouteError {
                    guard case .outputVerificationFailed = error else { throw error }
                    throw ArchiveVerificationFailure.updaterVerification(.init(error)).reported(file: archive)
                }
                #if DEBUG
                try didCommitLHAUpdaterForTesting.get()?(updater)
                #endif
                try preserveAttributes(from: archive, to: work, includingCreationDate: true)
            } else {
                publishedMode = .rewrite(.lha)
                try rewriteBranch(format: .lha)
            }
        case .update(.sevenZip):
            try willOpenUpdater?()
            var updater: SevenZipUpdater?
            do {
                updater = try ArchiveStageDiagnostics.measure(.updaterOpen) {
                    try SevenZipUpdater.open(url: archive, password: password, output: work, options: options)
                }
            } catch UpdaterRouteError.requiresRewrite(let reason) {
                #if DEBUG
                didFallBackToRewriteForTesting.get()?(reason)
                #endif
            }
            if let updater {
                ledger?.begin(.updater(.sevenZip, processesAdditionsAtCommit: false), archiveBytes: archiveBytes, options: options)
                try ArchiveStageDiagnostics.measure(deferredPlan == nil ? .mutate : .replay) { try mutate(updater) }
                try ArchiveImportPlan.checkCancellation(progress)
                if let ledger { try updater.finishAdditions(progress: ledger.finishAdditions) }
                let commitCallback = updateCommitProgress()
                do {
                    try ArchiveStageDiagnostics.measure(.commit) {
                        #if DEBUG
                        try willCommitUpdaterForTesting.get()?()
                        #endif
                        try updater.commit(progress: commitCallback)
                    }
                } catch let error as UpdaterRouteError {
                    guard case .outputVerificationFailed = error else { throw error }
                    throw ArchiveVerificationFailure.updaterVerification(.init(error)).reported(file: archive)
                }
                #if DEBUG
                try didCommitSevenZipUpdaterForTesting.get()?(updater)
                #endif
                try preserveAttributes(from: archive, to: work, includingCreationDate: true, copyingExtendedAttributes: false)
            } else {
                publishedMode = .rewrite(.sevenZip)
                try rewriteBranch(format: .sevenZip)
            }
        case .update: throw ArchiveEditError.staleSelection
        }
        if let additionalQuarantine {
            // 新規作成と同じく追加元の印も伝播する。原本の印があればそちらを保つ。
            // 公開前の作業コピーだけに付け、取消しや検証失敗で原本の属性を変えない。
            try ExtractionQuarantine.apply(try ExtractionQuarantine.read(from: work) ?? additionalQuarantine, to: work)
        }
        #if DEBUG
        try didCommitForTesting.get()?(work)
        #endif
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
        if let spliced {
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
                guard let spliced, let spliceBase else {
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
            if let failure = expectedOutput.resolving(publishedMode).validationFailure(verified, format: outputFormat) {
                throw failure.reported(file: archive)
            }
        }
        #if DEBUG
        try didVerifyForTesting.get()?(work)
        #endif
        #if DEBUG
        let publishSpan = ArchiveStageDiagnostics.begin(.publish)
        defer { publishSpan?.end() }
        #endif
        try willPublish?()
        try ArchiveImportPlan.checkCancellation(progress)
        guard try ArchiveSetIdentity.capture(url: archive) == original else {
            throw ExtractionFailure.refused(String(localized: "処理中にアーカイブが別の操作で変更されました。"))
        }
        // 作業中に兄弟が現れた場合も、一巻だけの置換を拒否する。
        if ArchiveSplitVolume.isSplitVolumeMember(archive) { throw ArchiveEditError.splitArchive }
        // 作業ファイルへ復元した属性も含め、同一ボリュームで一括公開する。
        // ここが取消しの境界。成功後に取消しとして返してはならない。
        try verifyWorkIdentity(source: source, work: work, phase: .beforePublication, archive: archive)
        try (publication ?? ArchiveSavePublication.current.get())?.enter(progress: progress)
        guard rename(work.path, archive.path) == 0 else { throw ExtractionFailure.system(errno) }
        #if DEBUG
        didPublishForTesting.get()?(archive)
        #endif
        verifiedOutput?.publishedMode = publishedMode
        if adoptable {
            verifiedOutput?.output = ArchiveVerifiedOutput(identity: identity, reader: verified, source: source,
                hint: hint, verificationPassword: options.password, format: outputFormat)
        }
        if let ledger { ledger.didPublish() }
        else { progress.completedUnitCount += 1 }
        return identity
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
