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
            let entries = try index.entries() // 索引が空なら、起動時も didMount でも mount root に触れない。
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
                        // mount の通知では、その volume と無関係な保存済みのパスを調べない。
                        let candidate = VolumePublishFS.relativePath(stored, on: root) != nil ? stored
                            : entry.resolved(on: root, uuid: volume.uuid)
                        guard let candidate, !VolumePublishFS.knownUUID(entry.volumeUUID) || entry.volumeUUID == volume.uuid else { continue }
                        guard let found = try discover(candidate, entry: entry, volume: volume, root: root, requireStaging: true) else { continue }
                        results.append(recover(staging: candidate, alreadyLockedGate: nil, indexedEntry: entry,
                            volume: volume, volumeRoot: root, mounts: [], parent: found.parent))
                        visited.insert(candidate); scanParents[found.parent.url] = (volume, root)
                        continue
                    }
                    // 保存したパスは、複製された volume も含めて、最も安く曖昧さの少ない発見の手がかり。
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
            // 残った手がかりだけを一度だけ解決する。回復のロックも set lock も持たずに行う。
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

    /// 上限付きの worker では読み取りだけの発見を行う。時間切れになった worker が後から回復や削除をすることはない。
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

    /// begin は S0 で得た volume の情報を渡す。set lock を持っている間に mount probe を走らせないため。
    func recover(staging url: URL, alreadyLockedGate: String?, options: ReaderOptions = .kaitoFinder(), presenter: (any NSFilePresenter)? = nil,
                 indexedEntry: RecoverableWorkIndex.Entry? = nil, volume suppliedVolume: VolumePublishFS.VolumeInfo? = nil,
                 volumeRoot suppliedRoot: URL? = nil, mounts suppliedMounts: VolumePublishFS.MountScan? = nil,
                 parent suppliedParent: VolumePublishDirectory? = nil) -> Result {
        do {
            guard let baseName = VolumePublishRemoval.stagingName(url.lastPathComponent) else {
                throw VolumePublishError.unsafePath(url.path)
            }
            // S1 の所有は mkdir や journal より先に見える。所有中のものを飛ばすのに mount probe は要らない。
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
                // 所有せずに鍵を読み、公開側と同じ順（set → staging）でロックを取る。
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
                    return try removeTombstone(baseName, parent: parent, indexedURL: indexedURL, staging: url)
                }
                if try parent.info(url.lastPathComponent) == nil {
                    return try resolveMissingStaging(entry: entry, mounts: mounts, volume: volume, parent: parent,
                                                     indexedURL: indexedURL, staging: url)
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
                    // commit 後に旧セットを復活させない。unlink には、公開中の巻の証明をその場で取り直す必要がある。
                    var allowRemoval = false
                    if record.phase == .done {
                        do { try transaction.validateHashes(in: parent); allowRemoval = true }
                        catch { /* Trash なら取り戻せるので残す。unlink は許さない。 */ }
                    }
                    if record.phase == .done, allowRemoval { _ = transaction.persistMetadataWarning() }
                    return finishCleanup(&transaction, direction: .cleanup,
                                         area: record.phase == .done ? "old" : nil, allowRemoval: allowRemoval,
                                         liveSetProven: record.phase != .done || allowRemoval)
                }
                if try transaction.preparedIsDisposable() {
                    let disposal = try transaction.discardPrepared()
                    return .recovered(staging: url, direction: .discardedPreparation, disposal: disposal)
                }
                if try transaction.abandonedIsDisposable() { return try finishBackward(&transaction) }
                let contents = try transaction.inspect()
                var direction: Direction
                switch Self.chooseDirection(contents, record: record, forwardObstacles: transaction.forwardObstacles(contents)) {
                case .proceed(let chosen): direction = chosen
                case .hold(let reason): return .held(staging: url, reason: reason)
                }
                if direction == .backward, contents.oldDirectoryEmpty, !contents.newAtFinal.contains(true) {
                    // staging の中の rename だけで済む。その証明が変わったら、公開中の名前を動かす前に止まる。
                    try transaction.rollback(allowLiveMoves: false)
                    return try finishBackward(&transaction)
                }
                // 形式は S4 で検証済み。全巻が最終名にあり hash で証明できれば、公開中の名前を動かさずに片付けてよい。
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
                    return try UncancelledThread.run {
                        try self.finishUnderCoordination(prepared, direction: chosenDirection, journal: journal, record: record,
                                                         parent: parent, excluding: excluded, options: options, staging: url)
                    }
                }
            } catch VolumePublishError.ownerAlive { return .owned(url) }
            catch { return .held(staging: url, reason: String(describing: error)) }
        }
    }
    /// 破棄が確定した staging の墓標（<name>.discard）を消す。原本の名前がもう無ければ索引の項目も外す。
    private func removeTombstone(_ baseName: String, parent: VolumePublishDirectory, indexedURL: URL, staging url: URL) throws -> Result {
        try VolumePublishRemoval.remove(baseName + ".discard", from: parent, operations: operations)
        try parent.sync(full: true)
        if try parent.info(baseName) == nil { try index.removeCompleted(indexedURL) }
        return .recovered(staging: url, direction: .cleanup, disposal: .removed)
    }

    /// staging が親に無い。索引の手がかり（volume UUID・相対パス・親 inode）が今の親と一致し、
    /// 解決先にも staging と墓標が無いと証明できたときだけ索引の項目を外す。
    private func resolveMissingStaging(entry: RecoverableWorkIndex.Entry?, mounts: VolumePublishFS.MountScan,
                                       volume: VolumePublishFS.VolumeInfo, parent: VolumePublishDirectory,
                                       indexedURL: URL, staging url: URL) throws -> Result {
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

    private enum DirectionChoice { case proceed(Direction), hold(reason: String) }
    /// 回復の向きの判定表。forward は新旧の全巻が揃い foreign な障害物が無いときだけ、backward は旧セットが揃っているときだけ。
    /// それ以外は理由を付けて保留する。
    private static func chooseDirection(_ contents: VolumePublishTransaction.Contents, record: VolumePublishJournalRecord,
                                        forwardObstacles: Set<String>) -> DirectionChoice {
        let direction: Direction
        if contents.abandoned || record.phase == .abandoned {
            guard contents.allOld || contents.newAtFinal.contains(true) else {
                return .hold(reason: "Incomplete old set; no placed new volumes to withdraw")
            }
            direction = .backward
        }
        else if contents.allNew && contents.allOld && forwardObstacles.isEmpty { direction = .forward }
        else if contents.allOld { direction = .backward }
        else { return .hold(reason: "Incomplete old set; recovery cannot prove a safe direction") }
        if direction == .backward, !contents.newAtFinal.contains(true),
           !contents.foreignFinal.isDisjoint(with: Set(record.oldVolumes.map(\.name))) {
            return .hold(reason: "An old name has an unrelated occupant")
        }
        return .proceed(direction)
    }

    /// coordinator と臨界区間の内側で、後退（rollback）または前進（退避 → 配置 → hash 証明 → done）を完了する。
    /// 待っている間に非協調 writer が変えた状態は inspect で再確認し、証明できなければ保留か後退にする。
    private func finishUnderCoordination(_ prepared: VolumePublishTransaction, direction chosenDirection: Direction,
                                         journal: VolumePublishJournal, record: VolumePublishJournalRecord,
                                         parent: VolumePublishDirectory, excluding excluded: ObjectIdentifier?,
                                         options: ReaderOptions, staging url: URL) throws -> Result {
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
        // この byte 列は S4 が呼び出し元の資格情報で開き済み。
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
        _ = transaction.persistMetadataWarning()
        // 形式の検査は commit の後の任意の診断で、回復の条件にはしない。
        if let report = operations.recoveryReaderDiagnostic {
            do { _ = try operations.openReader(transaction.parent.url.appendingPathComponent(transaction.record.newGate), options); report(nil) }
            catch { report(String(describing: error)) }
        }
        return finishCleanup(&transaction, direction: .forward, area: "old")
    }
    private func finishBackward(_ transaction: inout VolumePublishTransaction) throws -> Result {
        _ = transaction.persistMetadataWarning(restored: true)
        let oldRestored = try transaction.record.oldVolumes.allSatisfy {
            try $0.matches(in: transaction.parent, useHash: transaction.record.hashesOldVolumes)
        }
        return finishCleanup(&transaction, direction: .backward, area: "abandoned", liveSetProven: oldRestored)
    }

    /// commit・rollback・durable な片付けの許可の後にだけ呼ぶ。失敗したら片付けの作業を残す。
    private func finishCleanup(_ transaction: inout VolumePublishTransaction, direction: Direction,
                               area: String?, allowRemoval: Bool = true, liveSetProven: Bool = true) -> Result {
        func result(_ disposal: VolumeDisposal) -> Result {
            if case .kept = disposal, !liveSetProven {
                return .held(staging: transaction.staging.url, reason: "Live set is not proved; backup retained", disposal: disposal)
            }
            return .recovered(staging: transaction.staging.url, direction: direction, disposal: disposal)
        }
        do {
            let disposal = try area.map { try transaction.dispose($0, allowRemoval: allowRemoval) } ?? .none
            if case .kept = disposal {
                if transaction.record.phase == .done { try transaction.markOldKept() }
            } else { try transaction.removeEmptyStaging() }
            return result(disposal)
        } catch {
            NSLog("Volume recovery cleanup pending: %@ (%@)", transaction.staging.url.path, String(describing: error))
            return result(.kept(transaction.staging.url))
        }
    }
    private static func incompletePreparation(_ staging: VolumePublishDirectory) throws -> Bool {
        // journal 不明時は名前の whitelist も不明。空の reserved 領域だけを証拠にする。
        for name in ["old", "new", "abandoned"] {
            if try staging.info(name) != nil {
                let directory = try staging.directory(name)
                // journal が無ければ、AppleDouble の volume でも ._<巻> を自分のものと判断できない。
                if try directory.names().contains(where: { $0 != ".DS_Store" }) { return false }
            }
        }
        return true
    }
}
