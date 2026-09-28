import Darwin
import Foundation
import GyoshukuKit
import KaitoKit

/// 原本を更新する publish とは別の境界。最後の rename が成功するまで保存先に触れない。
nonisolated enum ArchiveCreationTransaction {
    static func run(plan: ArchiveCreationPlan, progress: Progress,
                    willPublish: (@Sendable () throws -> Void)? = nil,
                    registry: PendingWorkRegistry = .shared,
                    volumeIndex: RecoverableWorkIndex = .shared, metadataStore: ArchiveVolumeMetadataStore = .shared,
                    splitHooks: ArchiveSplitSaveHooks = .init()) throws -> URL {
        if let schedule = plan.splitSchedule {
            return try createSplit(plan: plan, schedule: schedule, progress: progress, willPublish: willPublish,
                index: volumeIndex, metadataStore: metadataStore, hooks: splitHooks)
        }
        for source in plan.sources {
            try ArchiveImportPlan.checkCancellation(progress)
            if isSameFile(source, plan.destination) {
                throw ExtractionFailure.refused(String(localized: "作成元の項目とは別の保存先を選んでください。"))
            }
        }
        guard ArchiveCreationPlan.hasAcceptedExtension(plan.destination, for: plan.format) else {
            let list = ArchiveCreationPlan.acceptedExtensions(for: plan.format).map { "." + $0 }.joined(separator: ", ")
            throw ExtractionFailure.refused(String(localized: "この形式のファイル名は次の拡張子で終わる必要があります: \(list)"))
        }
        let imported = try ArchiveImportPlan.build(urls: plan.sources, folder: "",
                                                  existing: plan.existing?.entries ?? [], progress: progress,
                                                  options: plan.importOptions, format: plan.format)
        guard imported.failures.isEmpty else {
            throw ExtractionFailure.refused(ArchiveFailureReport.describe(imported.failures, name: \.name, reason: \.reason))
        }
        // 選択フォルダの子も作成元。既存の保存先があるときだけ同一性を調べ、
        // 新規保存では全 source の実パスをもう一度解決する固定費を避ける。
        var destinationInfo = stat()
        if lstat(plan.destination.path, &destinationInfo) == 0 {
            for item in imported.items {
                try ArchiveImportPlan.checkCancellation(progress)
                if isSameFile(item.url, plan.destination) {
                    throw ExtractionFailure.refused(String(localized: "作成元の項目とは別の保存先を選んでください。"))
                }
            }
        }
        try ArchiveImportPlan.checkCancellation(progress)
        guard plan.destination.isFileURL, !plan.destination.path.contains("\0") else {
            throw WriterError.invalidPath(plan.destination.absoluteString)
        }
        if let existing = plan.existing, (existing.volumeLayout?.volumes.map(\.url) ?? [existing.url]).contains(where: { isSameFile($0, plan.destination) }) {
            throw ExtractionFailure.refused(String(localized: "元のアーカイブとは別の保存先を選んでください。"))
        }
        let ledger: ArchiveWriteProgress?
        if plan.existing?.volumeLayout != nil, imported.items.isEmpty {
            // The split-input producer owns its existing byte accounting.
            ledger = nil
            progress.totalUnitCount = Int64((plan.existing?.entries.count ?? 0) + 1)
            progress.completedUnitCount = 0
        } else {
            let pending = plan.existing?.pending
            let carried = (pending?.projected ?? plan.existing?.entries ?? []).filter {
                $0.pendingID == nil && ($0.kind != .directory || !$0.pathComponents.drop(while: { $0 == "." }).isEmpty)
            }
            let counted = (pending?.edits.removals.count ?? 0) + (pending?.edits.renames.count ?? 0) + (pending?.folders.count ?? 0)
            let additions = (pending?.additions.map { $0.sourceStamp.kind == .file ? $0.stagedStamp.size : 0 } ?? []) + imported.items.map(\.byteCount)
            ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: counted, additions: additions,
                itemCount: carried.count + additions.count + (pending?.folders.count ?? 0),
                carriedBytes: ArchiveWriteProgress.carriedBytes(carried),
                changesExisting: pending.map { !$0.edits.removals.isEmpty || !$0.edits.renames.isEmpty } ?? false,
                countsCarriedItems: plan.existing != nil))
        }
        let directory = plan.destination.deletingLastPathComponent()
            .appendingPathComponent(WorkAreaName.new + UUID().uuidString, isDirectory: true)
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
        // KaitoKit は gzip の中身が tar かどうかを名前でも判定する。仮出力にも本当の拡張子を付ける。
        let output = directory.appendingPathComponent("archive." + ArchiveCreationPlan.filenameExtension(for: plan.format))
        do {
            if let existing = plan.existing {
                try verifySource(existing)
                try existing.pending?.validate()
                if let pending = existing.pending {
                    try ArchiveSaveReplayPlan.validateRepresentability(pending.projected, format: plan.format)
                }
                if existing.volumeLayout != nil, imported.items.isEmpty {
                    let replay = try existing.pending ?? ArchiveSaveReplayPlan(base: existing.entries, generation: 0, pending: .init(), format: plan.format)
                    _ = try ArchiveSplitWorkProducer.produce(existing: existing, workURL: output, format: plan.format,
                        options: plan.options, plan: replay, progress: progress, didRead: splitHooks.didReadInputBytes)
                } else {
                    let rewriter = try ArchiveRewriter.open(url: existing.url, password: existing.password,
                                                            output: output, format: plan.format, options: plan.options)
                    let ledger = ledger!
                    ledger.begin(.rewriter(plan.format, readsAdditionsDuringCommit: rewriter.readsAdditionsDuringCommit),
                                 archiveBytes: 0, options: plan.options)
                    try ArchiveStageDiagnostics.measure(.mutate) {
                        try existing.pending?.replay(on: rewriter, progress: progress,
                            preservingOwnerIDs: plan.options.preserveOwnerIDs && plan.format.isTarFamily, ledger: ledger)
                        try add(imported.items, progress: progress, ledger: ledger, additionBase: existing.pending?.additions.count ?? 0,
                                batch: rewriter.add(_:events:))
                        try ArchiveImportPlan.checkCancellation(progress)
                        try rewriter.finishAdditions(progress: ledger.finishAdditions)
                    }
                    try ArchiveImportPlan.checkCancellation(progress)
                    try rewriter.commit(progress: ledger.commit) { done, total in
                        ledger.didCarry(done, total)
                        try ArchiveImportPlan.checkCancellation(progress)
                    }
                }
            } else {
                let writer = try ArchiveWriter.create(url: output, format: plan.format, options: plan.options)
                let ledger = ledger!
                ledger.begin(.writer(plan.format), archiveBytes: 0, options: plan.options)
                try ArchiveStageDiagnostics.measure(.mutate) {
                    try add(imported.items, progress: progress, ledger: ledger, batch: writer.add(_:events:))
                    try ArchiveImportPlan.checkCancellation(progress)
                    try writer.finishAdditions(progress: ledger.finishAdditions)
                }
                try ArchiveImportPlan.checkCancellation(progress)
                try writer.finish()
            }
        } catch RewriterError.password {
            // RewriterError は二種類の認証失敗をまとめる。入力した鍵の有無から UI の型へ戻す。
            throw plan.existing?.password == nil ? KaitoError.passwordRequired : KaitoError.wrongPassword
        }
        let quarantineSources = plan.sources + (plan.existing.map { $0.volumeLayout?.volumes.map(\.url) ?? [$0.url] } ?? [])
            + imported.items.map(\.url) + (plan.existing?.pending?.additions.map(\.stagedURL) ?? [])
        // フォルダ自体にだけ印の付いた app や空フォルダも対象にする。
        let quarantine = try plan.existing?.quarantine ?? ExtractionQuarantine.firstValue(from: quarantineSources) {
            try ArchiveImportPlan.checkCancellation(progress)
        }
        try ExtractionQuarantine.apply(quarantine, to: output)
        _ = try ArchiveReader.open(url: output, options: .kaitoFinder(password: plan.options.password))
        try willPublish?()
        try ArchiveImportPlan.checkCancellation(progress)
        // 書き直しの間に変わった巻も、保存先へ公開する直前に検出する。
        if let existing = plan.existing { try verifySource(existing) }
        try plan.existing?.pending?.validate()
        try (plan.existing?.publication ?? ArchiveSavePublication.current.get())?.enter(progress: progress)
        guard rename(output.path, plan.destination.path) == 0 else { throw ExtractionFailure.system(errno) }
        // rewriter が省く root directory record も含め、公開後は必ず完了を示す。
        if let ledger { ledger.didPublish() }
        else { progress.completedUnitCount = progress.totalUnitCount }
        return plan.destination
    }

    private static func createSplit(plan: ArchiveCreationPlan, schedule: VolumePlan.Schedule, progress: Progress,
                                    willPublish: (@Sendable () throws -> Void)?, index: RecoverableWorkIndex,
                                    metadataStore: ArchiveVolumeMetadataStore, hooks: ArchiveSplitSaveHooks) throws -> URL {
        guard plan.sources.isEmpty, let existing = plan.existing,
              ArchiveCreationPlan.hasAcceptedExtension(plan.destination, for: plan.format) else { throw VolumePublishError.invalidPlan }
        try verifySource(existing)
        let replay = try existing.pending ?? ArchiveSaveReplayPlan(base: existing.entries, generation: 0, pending: .init(), format: plan.format)
        try ArchiveSaveReplayPlan.validateRepresentability(replay.projected, format: plan.format)
        let parent = try VolumePublishFS.canonicalParent(of: plan.destination)
        var target = VolumeSetTarget(parent: parent, newSetScheme: .numbered(stem: plan.destination.lastPathComponent, width: 3),
                                    schedule: schedule, allowHazardousVolume: plan.allowHazardousVolume)
        target.additionalQuarantine = try existing.quarantine ?? ExtractionQuarantine.firstValue(from:
            (existing.volumeLayout?.volumes.map(\.url) ?? [existing.url]) + replay.additions.map(\.stagedURL)) {
                try ArchiveImportPlan.checkCancellation(progress)
            }
        // Use archive bytes, as M5 does: a highly compressed source can be far larger
        // when expanded. M2 recalculates the complete plan from W before any member is placed.
        let identity = try existing.identity ?? ArchiveSetIdentity.capture(url: existing.url, layout: existing.volumeLayout)
        var estimate = identity.volumes.reduce(UInt64(0)) { $0 + $1.size }
        let additionalWorkBytes: UInt64
        if let layout = existing.volumeLayout, case .numbered = layout.scheme { additionalWorkBytes = estimate }
        else { additionalWorkBytes = 0 }
        for addition in replay.additions {
            let next = estimate.addingReportingOverflow(addition.sourceStamp.size)
            let padded = next.partialValue.addingReportingOverflow(VolumePlan.perEntryOverheadEstimate)
            guard !next.overflow, !padded.overflow else { throw VolumePublishError.invalidPlan }
            estimate = padded.partialValue
        }
        estimate = max(1, estimate)
        _ = try ArchiveSplitSavePipeline.run(target: target, estimatedLength: estimate, additionalWorkBytes: additionalWorkBytes, plan: replay,
            password: plan.options.password, progress: progress, publication: existing.publication ?? ArchiveSavePublication.current.get(),
            index: index, metadataStore: metadataStore, hooks: hooks, willPublish: {
                try willPublish?()
                try verifySource(existing)
            }, keepsPendingChanges: existing.pending?.isEmpty == false) { split in
                try ArchiveSplitWorkProducer.produce(existing: existing, workURL: split.workURL, format: plan.format,
                    options: plan.options, plan: replay, progress: progress, didRead: hooks.didReadInputBytes)
            }
        // Return the user's spelling, even though the publisher operates on a canonical directory.
        return plan.destination.appendingPathExtension("001")
    }

    private static func verifySource(_ existing: ArchiveCreationPlan.Existing) throws {
        guard let identity = existing.identity else { return }
        guard try ArchiveSetIdentity.capture(url: existing.url, layout: existing.volumeLayout) == identity else {
            throw ExtractionFailure.refused(String(localized: "処理中にアーカイブが別の操作で変更されました。"))
        }
    }

    private static func isSameFile(_ source: URL, _ destination: URL) -> Bool {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        if source == destination { return true }
        // 大文字・小文字だけが違う名前や hard link でも、原本を保存先にはしない。
        var original = stat(), output = stat()
        return lstat(source.path, &original) == 0 && lstat(destination.path, &output) == 0
            && original.st_dev == output.st_dev && original.st_ino == output.st_ino
    }

    private static func add(_ items: [ArchiveImportPlan.Item], progress: Progress, ledger: ArchiveWriteProgress, additionBase: Int = 0,
                            batch: ([ArchiveAddition], ((ArchiveAdditionEvent) throws -> Void)?) throws -> Void) throws {
        let additions = items.map { item in
            ArchiveAddition(path: item.path, source: item.isDirectory
                ? .directory(modificationDate: nil) : .contents(of: item.url))
        }
        guard !additions.isEmpty else { return }
        do {
            try batch(additions) { event in
                switch event {
                case .willStart(let index):
                    try ArchiveImportPlan.checkCancellation(progress)
                    #if DEBUG
                    let item = items[index]
                    if !item.isDirectory { ArchiveImportTransaction.willAddFileForTesting.get()?(item.url) }
                    #endif
                case .progress(let index, let value):
                    try ledger.addition(additionBase + index)(value)
                case .didFinish(let index):
                    ledger.didFinishAddition(additionBase + index)
                }
            }
        } catch let error as ArchiveAdditionError {
            if let underlying = error.underlying as? RewriterError { throw underlying }
            throw ExtractionFailure.refused("\(items[error.index].path): \(ArchiveErrorText.describe(error.underlying))")
        }
    }
}
