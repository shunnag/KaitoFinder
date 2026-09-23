import Darwin
import Foundation
import KaitoKit
import Synchronization

nonisolated struct VolumePublishRecovery: Sendable {
    enum Direction: Sendable, Equatable { case discardedPreparation, forward, backward, cleanup }
    enum Result: Sendable, Equatable {
        case recovered(staging: URL, direction: Direction, disposal: VolumeDisposal)
        case held(staging: URL, reason: String, disposal: VolumeDisposal? = nil)
        case owned(URL)
    }
    private static let mutex = Mutex(())
    let index: RecoverableWorkIndex
    let operations: VolumePublishOperations
    init(index: RecoverableWorkIndex = .shared, operations: VolumePublishOperations = .init()) {
        self.index = index; self.operations = operations
    }
    static func recoverAll(parents: [URL] = [], mountedVolume: URL? = nil) -> [Result] {
        Self().recoverAll(parents: parents, mountedVolume: mountedVolume)
    }
    func recoverAll(parents: [URL] = [], mountedVolume: URL? = nil) -> [Result] {
        var staging: Set<URL> = [], results: [Result] = []
        do {
            let mounts = try operations.mountedVolumes()
            let mountedUUID = try mountedVolume.map { try operations.volumeInfo(VolumePublishDirectory($0)).uuid }
            for entry in try index.entries() {
                let original = URL(fileURLWithPath: entry.stagingPath, isDirectory: true)
                do {
                    if let mountedUUID, mountedUUID != entry.volumeUUID { continue }
                    let roots = Set(mounts.filter { $0.uuid == entry.volumeUUID }.map(\.root))
                    guard VolumePublishFS.knownUUID(entry.volumeUUID), roots.count == 1,
                          let root = roots.first, let resolved = entry.resolved(on: root, uuid: entry.volumeUUID) else {
                        results.append(.held(staging: original, reason: "Volume UUID is unavailable or ambiguous"))
                        continue
                    }
                    // Rebase only after finding this staging (or its durable tombstone) on the unique volume.
                    let parent = try VolumePublishDirectory(resolved.deletingLastPathComponent())
                    if try parent.info(resolved.lastPathComponent) != nil || parent.info(resolved.lastPathComponent + ".discard") != nil {
                        if resolved.path != original.path { try index.rebase(entry, to: resolved) }
                        staging.insert(resolved)
                    } else {
                        results.append(recover(staging: resolved, alreadyLockedGate: nil, indexedEntry: entry))
                    }
                } catch { results.append(.held(staging: original, reason: "Volume unavailable: \(error)")) }
            }
        } catch { results.append(.held(staging: index.fileURL, reason: "Recovery index: \(error)")) }
        for parentURL in Set(parents + staging.map { $0.deletingLastPathComponent() }) {
            do {
                let parent = try VolumePublishDirectory(parentURL)
                for name in try parent.names() where name.hasPrefix(VolumePublishFS.stagingPrefix) {
                    staging.insert(parentURL.appendingPathComponent(name, isDirectory: true))
                }
            } catch { results.append(.held(staging: parentURL, reason: "Parent unavailable: \(error)")) }
        }
        for url in staging.sorted(by: { $0.path < $1.path }) { results.append(recover(staging: url)) }
        for case .held(let url, let reason, _) in results { NSLog("分割アーカイブの回復を保留: %@ (%@)", url.path, reason) }
        return results
    }

    func recover(staging url: URL, options: ReaderOptions = .kaitoFinder(), presenter: (any NSFilePresenter)? = nil) -> Result {
        recover(staging: url, alreadyLockedGate: nil, options: options, presenter: presenter)
    }

    /// begin が同じ set lock を保持して分類するときだけ、再取得を省く。
    func recover(staging url: URL, alreadyLockedGate: String?, options: ReaderOptions = .kaitoFinder(), presenter: (any NSFilePresenter)? = nil,
                 indexedEntry: RecoverableWorkIndex.Entry? = nil) -> Result {
        Self.mutex.withLock { _ in
            do {
                guard let baseName = VolumePublishRemoval.stagingName(url.lastPathComponent) else {
                    throw VolumePublishError.unsafePath(url.path)
                }
                let parent = try VolumePublishDirectory(url.deletingLastPathComponent())
                let volume = try operations.volumeInfo(parent)
                let originalURL = parent.url.appendingPathComponent(baseName, isDirectory: true)
                let entry = try indexedEntry ?? index.entries().first { $0.stagingPath == originalURL.path }
                if try url.lastPathComponent.hasSuffix(".discard") || (parent.info(baseName) == nil && parent.info(baseName + ".discard") != nil) {
                    try VolumePublishRemoval.remove(baseName + ".discard", from: parent, operations: operations)
                    try parent.sync(full: true)
                    if try parent.info(baseName) == nil { try index.removeCompleted(originalURL) }
                    return .recovered(staging: url, direction: .cleanup, disposal: .removed)
                }
                if try parent.info(url.lastPathComponent) == nil {
                    guard let entry else { return .recovered(staging: url, direction: .cleanup, disposal: .none) }
                    let lock = try entry.gateName.flatMap { gate in
                        try gate == alreadyLockedGate ? nil : VolumePublishLock.setLock(volumeUUID: volume.uuid,
                            gateInode: nil, parent: parent.url, gate: gate, directory: index.setLocksURL)
                    }
                    defer { lock?.release() }
                    let roots = Set(try operations.mountedVolumes().filter { $0.uuid == entry.volumeUUID }.map(\.root))
                    guard VolumePublishFS.knownUUID(entry.volumeUUID), entry.volumeUUID == volume.uuid,
                          roots.count == 1, let root = roots.first,
                          let resolved = entry.resolved(on: root, uuid: entry.volumeUUID) else { throw VolumePublishError.system(ENOENT) }
                    let resolvedParent = try VolumePublishDirectory(resolved.deletingLastPathComponent())
                    var actual = stat(), expected = stat()
                    guard fstat(parent.fd, &actual) == 0, fstat(resolvedParent.fd, &expected) == 0,
                          actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino,
                          entry.parentInode == actual.st_ino,
                          try resolvedParent.info(resolved.lastPathComponent) == nil,
                          try resolvedParent.info(resolved.lastPathComponent + ".discard") == nil else { throw VolumePublishError.setChanged }
                    try index.removeCompleted(URL(fileURLWithPath: entry.stagingPath))
                    return .recovered(staging: url, direction: .cleanup, disposal: .none)
                }
                let staging = try parent.directory(url.lastPathComponent)
                let preview = try? VolumePublishJournal.inspect(staging)
                let gate = preview?.newGate ?? entry?.gateName ?? alreadyLockedGate ?? url.lastPathComponent
                let setLock = try gate == alreadyLockedGate ? nil : VolumePublishLock.setLock(
                    volumeUUID: volume.uuid, gateInode: nil, parent: parent.url, gate: gate, directory: index.setLocksURL)
                defer { setLock?.release() }
                let journal: VolumePublishJournal
                let record: VolumePublishJournalRecord
                do {
                    journal = try VolumePublishJournal(staging: staging, create: false)
                    record = try journal.read()
                    try record.validate(stagingName: url.lastPathComponent)
                } catch VolumePublishError.ownerAlive { throw VolumePublishError.ownerAlive }
                catch {
                    guard try Self.incompletePreparation(staging) else { throw error }
                    try staging.verifyPath()
                    try index.authorizeCleanup(url)
                    try VolumePublishRemoval.discard(staging, parent: parent, operations: operations)
                    try parent.sync(full: true)
                    try index.removeCompleted(url)
                    return .recovered(staging: url, direction: .discardedPreparation, disposal: .removed)
                }
                defer { journal.release() }
                var transaction = VolumePublishTransaction(parent: parent, staging: staging, journal: journal,
                    renamer: VolumeExclusiveRename(usesFallback: record.usesExclusiveRenameFallback, verifiesPaths: false), index: index,
                    record: record, operations: operations)
                if record.phase == .done || entry?.cleanupAuthorized == true {
                    // Never resurrect an old set after commit. Unlink needs a fresh live-copy proof.
                    var allowRemoval = false
                    if record.phase == .done {
                        do { try transaction.validateHashes(in: parent); allowRemoval = true }
                        catch { /* Trash remains recoverable; an unlink is forbidden. */ }
                    }
                    let disposal = record.phase == .done ? try transaction.dispose("old", allowRemoval: allowRemoval) : .none
                    if case .kept = disposal { return .held(staging: url, reason: "Committed; cleanup pending", disposal: disposal) }
                    try transaction.removeEmptyStaging()
                    return .recovered(staging: url, direction: .cleanup, disposal: disposal)
                }
                if try transaction.preparedIsDisposable() {
                    let disposal = try transaction.discardPrepared()
                    return .recovered(staging: url, direction: .discardedPreparation, disposal: disposal)
                }
                if try transaction.abandonedIsDisposable() { return try finishBackward(&transaction) }
                let contents = try transaction.inspect()
                var direction: Direction
                if contents.abandoned || record.phase == .abandoned {
                    guard contents.allOld || contents.newAtFinal.contains(true) else {
                        return .held(staging: url, reason: "Incomplete old set; no placed new volumes to withdraw")
                    }
                    direction = .backward
                }
                else if contents.allNew && contents.allOld && transaction.forwardObstacles(contents).isEmpty { direction = .forward }
                else if contents.allOld { direction = .backward }
                else { return .held(staging: url, reason: "Incomplete old set; recovery cannot prove a safe direction") }
                if direction == .backward, !contents.newAtFinal.contains(true),
                   !contents.foreignFinal.isDisjoint(with: Set(record.oldVolumes.map(\.name))) {
                    return .held(staging: url, reason: "An old name has an unrelated occupant")
                }
                if direction == .backward, contents.oldDirectoryEmpty, !contents.newAtFinal.contains(true) {
                    // Internal staging renames only. If that proof changes, stop before any live move.
                    try transaction.rollback(allowLiveMoves: false)
                    return try finishBackward(&transaction)
                }
                // S4 validated the format. All-final hash proof permits cleanup without moving a live name.
                if direction == .forward, contents.newAtFinal.allSatisfy({ $0 }) {
                    do { try transaction.validateHashes(in: parent) }
                    catch let error as VolumePublishError {
                        switch error {
                        case .contentMismatch, .nameOccupied: direction = .backward
                        default: throw error
                        }
                    }
                    if direction == .forward { return try finishForward(&transaction, options: options) }
                }
                let gateURL = parent.url.appendingPathComponent(record.newGate)
                let excluded = presenter.map { ObjectIdentifier($0) }
                try Self.requireUnpresented(record, parent: parent, excluding: excluded)
                try operations.willCoordinate(gateURL)
                let coordinator = VolumePublishCoordination(gate: gateURL, presenter: presenter)
                let liveURLs = Set(record.oldVolumes.map(\.name) + record.newVolumes.map(\.name))
                    .map { parent.url.appendingPathComponent($0) }
                return try coordinator.withAccess(gate: gateURL, additional: liveURLs, timeout: 10) {
                    let prepared = transaction, chosenDirection = direction
                    return try VolumePublishUncancelled.run {
                        var transaction = prepared
                        let lease = try VolumePublishCriticalSection.shared.enter()
                        defer { withExtendedLifetime(lease) {} }
                        if journal.usesOwnerFallback {
                            transaction.record.owner = try VolumePublishProcessIdentity.capture()
                            guard transaction.record.owner != nil else { throw VolumePublishError.journalUnreadable }
                            try journal.write(transaction.record)
                        }
                        if chosenDirection == .backward {
                            try Self.requireUnpresented(record, parent: parent, excluding: excluded)
                            try transaction.rollback()
                            return try finishBackward(&transaction)
                        }
                        // coordinator を待つ間に非協調 writer が変えた状態も再確認する。
                        let current = try transaction.inspect()
                        guard current.allOld else {
                            return .held(staging: url, reason: "Old set changed while acquiring coordination")
                        }
                        do {
                            if let foreign = transaction.forwardObstacles(current).sorted().first { throw VolumePublishError.nameOccupied(foreign) }
                            // すべて最終名にある場合は gate を再び隠す必要がない。
                            if !current.newAtFinal.allSatisfy({ $0 }) {
                                try Self.requireUnpresented(record, parent: parent, excluding: excluded)
                                try transaction.retireOld(hook: { _ in })
                                _ = try transaction.placeNew(hook: { _ in })
                            }
                        } catch {
                            // 配置・占有の失敗では、foreign gate の横に自分の新巻を残さない。
                            try Self.requireUnpresented(record, parent: parent, excluding: excluded)
                            try transaction.rollback()
                            return try finishBackward(&transaction)
                        }
                        // S4 already opened these exact bytes with the caller's credentials.
                        do { try transaction.validateHashes(in: parent) }
                        catch let error as VolumePublishError {
                            switch error {
                            case .contentMismatch, .nameOccupied:
                                try Self.requireUnpresented(record, parent: parent, excluding: excluded)
                                try transaction.rollback()
                                return try finishBackward(&transaction)
                            default: throw error
                            }
                        }
                        return try finishForward(&transaction, options: options)
                    }
                }
            } catch VolumePublishError.ownerAlive { return .owned(url) }
            catch { return .held(staging: url, reason: String(describing: error)) }
        }
    }
    private static func requireUnpresented(_ record: VolumePublishJournalRecord, parent: VolumePublishDirectory,
                                           excluding excluded: ObjectIdentifier?) throws {
        let names = Set(record.oldVolumes.map(\.name) + record.newVolumes.map(\.name))
        let urls = names.map { parent.url.appendingPathComponent($0).standardizedFileURL }
        let identities = try names.compactMap { try parent.info($0) }
        for presenter in NSFileCoordinator.filePresenters where ObjectIdentifier(presenter) != excluded {
            guard let url = presenter.presentedItemURL else { continue }
            var info = stat()
            if urls.contains(url.standardizedFileURL) || (lstat(url.path, &info) == 0 && identities.contains {
                $0.st_dev == info.st_dev && $0.st_ino == info.st_ino
            }) { throw VolumePublishError.publishedVerificationPending(staging: parent.url, diagnostic: "A volume is presented by an open document") }
        }
    }
    private func finishForward(_ transaction: inout VolumePublishTransaction, options: ReaderOptions) throws -> Result {
        try transaction.phase(.done)
        // Format checking is an optional diagnostic AFTER commit, never a recovery requirement.
        if let report = operations.recoveryReaderDiagnostic {
            do { _ = try operations.openReader(transaction.parent.url.appendingPathComponent(transaction.record.newGate), options); report(nil) }
            catch { report(String(describing: error)) }
        }
        let disposal = try transaction.dispose("old")
        if case .kept = disposal { return .held(staging: transaction.staging.url, reason: "Committed; cleanup pending", disposal: disposal) }
        try transaction.removeEmptyStaging()
        return .recovered(staging: transaction.staging.url, direction: .forward, disposal: disposal)
    }
    private func finishBackward(_ transaction: inout VolumePublishTransaction) throws -> Result {
        let disposal = try transaction.dispose("abandoned")
        if case .kept = disposal { return .held(staging: transaction.staging.url, reason: "Old set restored; cleanup pending", disposal: disposal) }
        try transaction.removeEmptyStaging()
        return .recovered(staging: transaction.staging.url, direction: .backward, disposal: disposal)
    }
    private static func incompletePreparation(_ staging: VolumePublishDirectory) throws -> Bool {
        // journal 不明時は名前の whitelist も不明。空の reserved 領域だけを証拠にする。
        for name in ["old", "new", "abandoned"] {
            if try staging.info(name) != nil {
                let directory = try staging.directory(name)
                if try directory.names().contains(where: { !$0.hasPrefix("._") && $0 != ".DS_Store" }) { return false }
            }
        }
        return true
    }
}
