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
    private struct Discovery: Sendable {
        let parent: VolumePublishDirectory
        let volume: VolumePublishFS.VolumeInfo
        let root: URL
    }
    let index: RecoverableWorkIndex
    let operations: VolumePublishOperations
    let metadataStore: ArchiveVolumeMetadataStore
    init(index: RecoverableWorkIndex = .shared, operations: VolumePublishOperations = .init(),
         metadataStore: ArchiveVolumeMetadataStore = .shared) {
        self.index = index; self.operations = operations; self.metadataStore = metadataStore
    }
    static func recoverAll(parents: [URL] = [], mountedVolume: URL? = nil) -> [Result] {
        Self().recoverAll(parents: parents, mountedVolume: mountedVolume)
    }
    func recoverAll(parents: [URL] = [], mountedVolume: URL? = nil) -> [Result] {
        var results: [Result] = [], visited: Set<URL> = []
        var scanParents: [URL: (VolumePublishFS.VolumeInfo, URL)] = [:]
        do {
            let entries = try index.entries() // Empty launch/didMount must never touch a mount root.
            if mountedVolume == nil { try VolumePublishLock.sweepStagingLocks(index: index) }
            let notified = try entries.isEmpty ? nil : mountedVolume.map { root in
                (root, try VolumePublishMountProbe.run(root: root) { try operations.volumeInfo(VolumePublishDirectory(root)) })
            }
            var unresolved: [RecoverableWorkIndex.Entry] = []
            var discoveryFailures: [String: String] = [:]
            for entry in entries {
                let stored = URL(fileURLWithPath: entry.stagingPath, isDirectory: true)
                do {
                    if try VolumePublishLock.stagingIsOwned(stored.lastPathComponent, directory: index.stagingLocksURL) {
                        results.append(.owned(stored)); continue
                    }
                    if let (root, volume) = notified {
                        // Never examine an unrelated stored path on a mount notification.
                        let candidate = VolumePublishFS.relativePath(stored, on: root) != nil ? stored
                            : entry.resolved(on: root, uuid: volume.uuid)
                        guard let candidate, !VolumePublishFS.knownUUID(entry.volumeUUID) || entry.volumeUUID == volume.uuid else { continue }
                        guard let found = try discover(candidate, entry: entry, volume: volume, root: root, requireStaging: true) else { continue }
                        results.append(recover(staging: candidate, alreadyLockedGate: nil, indexedEntry: entry,
                            volume: volume, volumeRoot: root, mounts: [], parent: found.parent))
                        visited.insert(candidate); scanParents[found.parent.url] = (volume, root)
                        continue
                    }
                    // The stored path is the cheapest and least ambiguous discovery hint, including clones.
                    guard let found = try discover(stored, entry: entry, requireStaging: true) else { unresolved.append(entry); continue }
                    let volume = found.volume, root = found.root
                    guard !VolumePublishFS.knownUUID(entry.volumeUUID) || entry.volumeUUID == volume.uuid else {
                        unresolved.append(entry); continue
                    }
                    results.append(recover(staging: stored, alreadyLockedGate: nil, indexedEntry: entry,
                        volume: volume, volumeRoot: root, mounts: [], parent: found.parent))
                    visited.insert(stored); scanParents[found.parent.url] = (volume, root)
                } catch VolumePublishError.ownerAlive { results.append(.owned(stored)) }
                catch {
                    if notified == nil { unresolved.append(entry); discoveryFailures[entry.stagingPath] = String(describing: error) }
                    else { results.append(.held(staging: stored, reason: "Volume unavailable: \(error)")) }
                }
            }
            // Resolve only the remaining hints, once, outside every recovery/set lock.
            let resolvable = unresolved.filter { VolumePublishFS.knownUUID($0.volumeUUID) }
            let types = Set(resolvable.compactMap(\.fileSystem).map { $0.lowercased() })
            let mounts: VolumePublishFS.MountScan = try resolvable.isEmpty ? [] : (resolvable.contains { $0.nonLocalVolume == true }
                ? operations.nonLocalMountedVolumes(types) : operations.mountedVolumes(types))
            for failure in mounts.failures { results.append(.held(staging: failure.root, reason: "Mount probe skipped: \(failure.reason)")) }
            for entry in unresolved {
                let stored = URL(fileURLWithPath: entry.stagingPath, isDirectory: true)
                let roots = Set(mounts.volumes.filter { $0.uuid == entry.volumeUUID }.map(\.root))
                guard VolumePublishFS.knownUUID(entry.volumeUUID), roots.count == 1, let root = roots.first,
                      let resolved = entry.resolved(on: root, uuid: entry.volumeUUID) else {
                    let diagnostic = discoveryFailures[entry.stagingPath].map { "; stored-path probe: \($0)" } ?? ""
                    results.append(.held(staging: stored, reason: "Volume UUID is unavailable or ambiguous\(diagnostic)")); continue
                }
                do {
                    guard let found = try discover(resolved, entry: entry) else { throw VolumePublishError.system(ENOENT) }
                    let volume = found.volume
                    guard volume.uuid == entry.volumeUUID else { throw VolumePublishError.setChanged }
                    results.append(recover(staging: resolved, alreadyLockedGate: nil, indexedEntry: entry,
                        volume: volume, volumeRoot: root, mounts: mounts, parent: found.parent))
                    visited.insert(resolved); scanParents[found.parent.url] = (volume, root)
                } catch { results.append(.held(staging: stored, reason: "Volume unavailable: \(error)")) }
            }
        } catch { results.append(.held(staging: index.fileURL, reason: "Recovery discovery: \(error)")) }
        for url in parents where scanParents[url] == nil {
            do {
                scanParents[url] = try VolumePublishMountProbe.run(root: url) {
                    let parent = try VolumePublishDirectory(url)
                    return (try operations.volumeInfo(parent), try VolumePublishFS.volumeRoot(parent))
                }
            } catch { results.append(.held(staging: url, reason: "Parent unavailable: \(error)")) }
        }
        for (parentURL, metadata) in scanParents {
            do {
                let names = try VolumePublishMountProbe.run(root: parentURL) { try VolumePublishDirectory(parentURL).names() }
                for name in names where VolumePublishRemoval.stagingName(name) != nil {
                    let url = parentURL.appendingPathComponent(name, isDirectory: true)
                    guard !visited.contains(url), !visited.contains(parentURL.appendingPathComponent(VolumePublishRemoval.stagingName(name)!, isDirectory: true)) else { continue }
                    results.append(recover(staging: url, alreadyLockedGate: nil, volume: metadata.0,
                        volumeRoot: metadata.1, mounts: []))
                    visited.insert(url)
                }
            } catch { results.append(.held(staging: parentURL, reason: "Parent unavailable: \(error)")) }
        }
        for case .held(let url, let reason, _) in results { NSLog("分割アーカイブの回復を保留: %@ (%@)", url.path, reason) }
        return results
    }

    /// Only read-only discovery runs on the bounded worker. A timed-out worker cannot recover/delete later.
    private func discover(_ url: URL, entry: RecoverableWorkIndex.Entry? = nil,
                          volume: VolumePublishFS.VolumeInfo? = nil, root: URL? = nil,
                          requireStaging: Bool = false) throws -> Discovery? {
        try VolumePublishMountProbe.run(root: url) {
            let parent = try VolumePublishDirectory(url.deletingLastPathComponent())
            let present = try Self.hasStaging(url, in: parent)
            if requireStaging && !present { return nil as Discovery? }
            let info = try volume ?? operations.volumeInfo(parent)
            if present, let entry { try Self.requireAttribution(url, entry: entry, parent: parent) }
            return Discovery(parent: parent, volume: info, root: try root ?? VolumePublishFS.volumeRoot(parent))
        }
    }

    private static func hasStaging(_ url: URL, in parent: VolumePublishDirectory) throws -> Bool {
        try parent.info(url.lastPathComponent) != nil || parent.info(url.lastPathComponent + ".discard") != nil
    }

    private static func requireAttribution(_ url: URL, entry: RecoverableWorkIndex.Entry,
                                           parent: VolumePublishDirectory) throws {
        if try parent.info(url.lastPathComponent) == nil, try parent.info(url.lastPathComponent + ".discard") != nil { return }
        let record = try? VolumePublishJournal.inspect(parent.directory(url.lastPathComponent))
        if let record {
            try record.validate(stagingName: url.lastPathComponent)
            guard entry.gateName == nil || entry.gateName == record.newGate else { throw VolumePublishError.setChanged }
        } else if !VolumePublishFS.knownUUID(entry.volumeUUID) {
            throw VolumePublishError.journalUnreadable
        }
    }

    func recover(staging url: URL, options: ReaderOptions = .kaitoFinder(), presenter: (any NSFilePresenter)? = nil) -> Result {
        recover(staging: url, alreadyLockedGate: nil, options: options, presenter: presenter)
    }

    /// begin passes its S0 metadata, so no mount probe runs while its set lock is held.
    func recover(staging url: URL, alreadyLockedGate: String?, options: ReaderOptions = .kaitoFinder(), presenter: (any NSFilePresenter)? = nil,
                 indexedEntry: RecoverableWorkIndex.Entry? = nil, volume suppliedVolume: VolumePublishFS.VolumeInfo? = nil,
                 volumeRoot suppliedRoot: URL? = nil, mounts suppliedMounts: VolumePublishFS.MountScan? = nil,
                 parent suppliedParent: VolumePublishDirectory? = nil) -> Result {
        do {
            guard let baseName = VolumePublishRemoval.stagingName(url.lastPathComponent) else {
                throw VolumePublishError.unsafePath(url.path)
            }
            // S1 ownership is visible before mkdir or the journal. No mount probe is needed to skip it.
            if try VolumePublishLock.stagingIsOwned(baseName, directory: index.stagingLocksURL) { return .owned(url) }
            let metadata: Discovery
            if let suppliedParent, let suppliedVolume, let suppliedRoot {
                metadata = Discovery(parent: suppliedParent, volume: suppliedVolume, root: suppliedRoot)
            } else {
                guard let found = try discover(url, volume: suppliedVolume, root: suppliedRoot) else { throw VolumePublishError.system(ENOENT) }
                metadata = found
            }
            let parent = metadata.parent, volume = metadata.volume, root = metadata.root
            let originalURL = parent.url.appendingPathComponent(baseName, isDirectory: true)
            var parentInfo = stat()
            guard fstat(parent.fd, &parentInfo) == 0 else { throw VolumePublishError.system(errno) }
            let entry = try indexedEntry ?? index.entries().first {
                $0.matches(originalURL, volumeUUID: volume.uuid, root: root, parentInode: parentInfo.st_ino)
            }
            let mounts: VolumePublishFS.MountScan
            if let suppliedMounts { mounts = suppliedMounts }
            else if alreadyLockedGate == nil, let entry, VolumePublishFS.knownUUID(entry.volumeUUID),
                    try !Self.hasStaging(originalURL, in: parent) {
                let types = Set([entry.fileSystem].compactMap { $0?.lowercased() })
                mounts = try entry.nonLocalVolume == true ? operations.nonLocalMountedVolumes(types) : operations.mountedVolumes(types)
                for failure in mounts.failures { NSLog("Volume recovery mount probe skipped: %@ (%@)", failure.root.path, failure.reason) }
            } else { mounts = [] }
            return recoverLocked(staging: url, baseName: baseName, parent: parent, volume: volume, entry: entry,
                mounts: mounts,
                alreadyLockedGate: alreadyLockedGate, options: options, presenter: presenter)
        } catch { return .held(staging: url, reason: String(describing: error)) }
    }

    private func recoverLocked(staging url: URL, baseName: String, parent: VolumePublishDirectory,
                               volume: VolumePublishFS.VolumeInfo, entry: RecoverableWorkIndex.Entry?,
                               mounts: VolumePublishFS.MountScan, alreadyLockedGate: String?,
                               options: ReaderOptions, presenter: (any NSFilePresenter)?) -> Result {
        Self.mutex.withLock { _ in
            do {
                // Read the key without ownership, then acquire in the publisher's order: set → staging.
                let preview = try? VolumePublishJournal.inspect(parent.directory(baseName))
                let gate = preview?.newGate ?? entry?.gateName ?? alreadyLockedGate ?? baseName
                let setLock = try gate == alreadyLockedGate ? nil : VolumePublishLock.setLock(
                    volumeUUID: volume.uuid, gateInode: nil, parent: parent.url, gate: gate, directory: index.setLocksURL)
                defer { setLock?.release() }
                let stagingLock = try VolumePublishLock.stagingLock(baseName, directory: index.stagingLocksURL)
                defer {
                    do { try stagingLock.removeIfResolved(baseName, parent: parent, index: index) }
                    catch { NSLog("Volume recovery lock cleanup pending: %@ (%@)", url.path, String(describing: error)) }
                    stagingLock.release()
                }
                let originalURL = parent.url.appendingPathComponent(baseName, isDirectory: true)
                let indexedURL = entry.map { URL(fileURLWithPath: $0.stagingPath, isDirectory: true) } ?? originalURL
                if try url.lastPathComponent.hasSuffix(".discard") || (parent.info(baseName) == nil && parent.info(baseName + ".discard") != nil) {
                    try VolumePublishRemoval.remove(baseName + ".discard", from: parent, operations: operations)
                    try parent.sync(full: true)
                    if try parent.info(baseName) == nil { try index.removeCompleted(indexedURL) }
                    return .recovered(staging: url, direction: .cleanup, disposal: .removed)
                }
                if try parent.info(url.lastPathComponent) == nil {
                    guard let entry else { return .recovered(staging: url, direction: .cleanup, disposal: .none) }
                    let roots = Set(mounts.volumes.filter { $0.uuid == entry.volumeUUID }.map(\.root))
                    guard mounts.isComplete, VolumePublishFS.knownUUID(entry.volumeUUID), entry.volumeUUID == volume.uuid,
                          roots.count == 1, let root = roots.first,
                          let resolved = entry.resolved(on: root, uuid: entry.volumeUUID) else { throw VolumePublishError.system(ENOENT) }
                    let resolvedParent = try VolumePublishDirectory(resolved.deletingLastPathComponent())
                    var actual = stat(), expected = stat()
                    guard fstat(parent.fd, &actual) == 0, fstat(resolvedParent.fd, &expected) == 0,
                          actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino,
                          entry.parentInode == actual.st_ino,
                          try resolvedParent.info(resolved.lastPathComponent) == nil,
                          try resolvedParent.info(resolved.lastPathComponent + ".discard") == nil else { throw VolumePublishError.setChanged }
                    try index.removeCompleted(indexedURL)
                    return .recovered(staging: url, direction: .cleanup, disposal: .none)
                }
                let staging = try parent.directory(url.lastPathComponent)
                let journal: VolumePublishJournal
                let record: VolumePublishJournalRecord
                var openedJournal: VolumePublishJournal?
                defer { openedJournal?.release() }
                do {
                    journal = try VolumePublishJournal(staging: staging, create: false)
                    openedJournal = journal
                    record = try journal.read()
                    try record.validate(stagingName: url.lastPathComponent)
                } catch VolumePublishError.ownerAlive { throw VolumePublishError.ownerAlive }
                catch {
                    openedJournal?.release()
                    guard try Self.incompletePreparation(staging) else { throw error }
                    try staging.verifyPath()
                    try index.authorizeCleanup(indexedURL)
                    try VolumePublishRemoval.discard(staging, parent: parent, operations: operations, isNetworkVolume: !volume.isLocal)
                    try parent.sync(full: true)
                    try index.removeCompleted(indexedURL)
                    return .recovered(staging: url, direction: .discardedPreparation, disposal: .removed)
                }
                defer { journal.release() }
                guard record.newGate == gate else { throw VolumePublishError.setChanged }
                var transaction = VolumePublishTransaction(parent: parent, staging: staging, journal: journal,
                    renamer: VolumeExclusiveRename(usesFallback: record.usesExclusiveRenameFallback, verifiesPaths: false), index: index,
                    record: record, operations: operations, stagingLock: stagingLock, isNetworkVolume: !volume.isLocal,
                    metadataStore: metadataStore, indexedURL: indexedURL)
                if record.phase == .done || entry?.cleanupAuthorized == true {
                    // Never resurrect an old set after commit. Unlink needs a fresh live-copy proof.
                    var allowRemoval = false
                    if record.phase == .done {
                        do { try transaction.validateHashes(in: parent); allowRemoval = true }
                        catch { /* Trash remains recoverable; an unlink is forbidden. */ }
                    }
                    let disposal = record.phase == .done ? try transaction.dispose("old", allowRemoval: allowRemoval) : .none
                    if case .kept = disposal {
                        try transaction.markOldKept()
                        return .held(staging: url, reason: "Committed; cleanup pending", disposal: disposal)
                    }
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
        try transaction.persistMetadata()
        try transaction.phase(.done)
        // Format checking is an optional diagnostic AFTER commit, never a recovery requirement.
        if let report = operations.recoveryReaderDiagnostic {
            do { _ = try operations.openReader(transaction.parent.url.appendingPathComponent(transaction.record.newGate), options); report(nil) }
            catch { report(String(describing: error)) }
        }
        let disposal = try transaction.dispose("old")
        if case .kept = disposal {
            try transaction.markOldKept()
            return .held(staging: transaction.staging.url, reason: "Committed; cleanup pending", disposal: disposal)
        }
        try transaction.removeEmptyStaging()
        return .recovered(staging: transaction.staging.url, direction: .forward, disposal: disposal)
    }
    private func finishBackward(_ transaction: inout VolumePublishTransaction) throws -> Result {
        try transaction.persistRestoredMetadata()
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
                // Without a journal no ._<volume> sibling can be attributed, even on AppleDouble volumes.
                if try directory.names().contains(where: { $0 != ".DS_Store" }) { return false }
            }
        }
        return true
    }
}
