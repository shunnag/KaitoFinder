import Darwin
import Foundation
import KaitoKit

/// journal に載る名前と予約ディレクトリだけが判定対象。Finder/AppleDouble 等は判定に使わない。
nonisolated struct VolumePublishTransaction: Sendable {
    let parent: VolumePublishDirectory
    let staging: VolumePublishDirectory
    let journal: VolumePublishJournal
    let renamer: VolumeExclusiveRename
    let index: RecoverableWorkIndex
    var record: VolumePublishJournalRecord
    var operations = VolumePublishOperations()
    var stagingLock: VolumePublishLock? = nil
    var isNetworkVolume = false
    var metadataStore = ArchiveVolumeMetadataStore.shared
    var indexedURL: URL? = nil
    var oldProof: [String: Stamp] = [:]
    var newProof: [String: Stamp] = [:]

    struct Stamp: Sendable, Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let seconds: Int64
        let nanoseconds: Int64
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            seconds = Int64(info.st_mtimespec.tv_sec); nanoseconds = Int64(info.st_mtimespec.tv_nsec)
        }
    }
    struct Contents: Sendable {
        let oldAtFinal: [Bool]
        let oldRetired: [Bool]
        let newStaged: [Bool]
        let newAtFinal: [Bool]
        let abandoned: Bool
        let oldDirectoryEmpty: Bool
        let foreignFinal: Set<String>
        var allOld: Bool { zip(oldAtFinal, oldRetired).allSatisfy { $0 || $1 } }
        var allNew: Bool { !newStaged.isEmpty && zip(newStaged, newAtFinal).allSatisfy { $0 || $1 } }
    }

    var forwardNames: Set<String> { Set(record.newVolumes.map(\.name) + [record.nextName]) }
    func forwardObstacles(_ contents: Contents) -> Set<String> { contents.foreignFinal.intersection(forwardNames) }

    func optionalDirectory(_ name: String) throws -> VolumePublishDirectory? {
        guard let info = try staging.info(name) else { return nil }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw VolumePublishError.unsafePath(name) }
        return try staging.directory(name)
    }
    func oldDirectoryEmpty() throws -> Bool {
        guard let old = try optionalDirectory("old") else { return true }
        return try record.oldVolumes.allSatisfy { try old.info($0.name) == nil }
    }
    func preparedIsDisposable() throws -> Bool {
        guard record.phase == .prepared, try oldDirectoryEmpty(), try staging.info("abandoned") == nil else { return false }
        let new = try optionalDirectory("new")
        for volume in record.newVolumes {
            if try new?.info(volume.name) == nil, try volume.matches(in: parent) { return false }
        }
        return true
    }

    func abandonedIsDisposable() throws -> Bool {
        guard record.phase == .abandoned, try oldDirectoryEmpty(), try staging.info("new") == nil else { return false }
        guard let abandoned = try optionalDirectory("abandoned") else { return true }
        return try record.newVolumes.allSatisfy { try abandoned.info($0.name) == nil || $0.matches(in: abandoned) }
    }

    mutating func inspect() throws -> Contents {
        try record.validate(stagingName: staging.url.lastPathComponent)
        try parent.verifyPath(); try staging.verifyPath()
        let old = try optionalDirectory("old"), new = try optionalDirectory("new")
        let abandoned = try optionalDirectory("abandoned")
        guard new == nil || abandoned == nil else { throw VolumePublishError.validationFailed }
        var oldFinal: [Bool] = [], retired: [Bool] = []
        for volume in record.oldVolumes {
            var atFinal = try oldMatches(volume, in: parent)
            let atOld = try old.map { try oldMatches(volume, in: $0) } ?? false
            if atFinal && atOld {
                guard let replacement = record.newVolumes.first(where: { $0.name == volume.name }),
                      try newMatches(replacement, in: parent) else { throw VolumePublishError.validationFailed }
                atFinal = false
            }
            oldFinal.append(atFinal); retired.append(atOld)
        }
        let oldNames = Set(zip(record.oldVolumes, oldFinal).filter { $0.1 }.map { $0.0.name })
        var newStaged: [Bool] = [], newFinal: [Bool] = []
        for volume in record.newVolumes {
            let staged = try new.map { try newMatches(volume, in: $0) } ?? false
            let final = try !oldNames.contains(volume.name) && newMatches(volume, in: parent)
            if staged && final { throw VolumePublishError.validationFailed }
            newStaged.append(staged); newFinal.append(final)
        }
        let newNames = Set(zip(record.newVolumes, newFinal).filter { $0.1 }.map { $0.0.name })
        var foreign: Set<String> = []
        let maximum = max(record.oldVolumes.count, record.newVolumes.count)
        let names = Set(record.oldVolumes.map(\.name) + record.newVolumes.map(\.name)
                        + [record.scheme.fileName(forVolumeAt: maximum, count: maximum + 1)])
        for name in names where !oldNames.contains(name) && !newNames.contains(name) {
            if try parent.info(name) != nil { foreign.insert(name) }
        }
        return Contents(oldAtFinal: oldFinal, oldRetired: retired, newStaged: newStaged,
                        newAtFinal: newFinal, abandoned: abandoned != nil,
                        oldDirectoryEmpty: try oldDirectoryEmpty(), foreignFinal: foreign)
    }

    mutating func phase(_ value: VolumePublishJournalRecord.Phase) throws {
        record.phase = value
        try journal.write(record)
    }

    func persistMetadata() throws {
        guard let metadata = record.metadata, try VolumePublishFS.usesAppleDouble(parent) else { return }
        let layout = ArchiveVolumeLayout(scheme: record.scheme, volumes: record.newVolumes.map {
            .init(url: parent.url.appendingPathComponent($0.name), length: $0.length)
        }, openedVolumeIndex: 0)
        try metadataStore.save(metadata, layout: layout)
    }
    func persistRestoredMetadata() throws {
        guard let metadata = record.previousMetadata, try VolumePublishFS.usesAppleDouble(parent),
              try record.oldVolumes.allSatisfy({ try $0.matches(in: parent, useHash: record.hashesOldVolumes) }) else { return }
        // FAT/SMB can change a synthetic inode on rename. Re-key only a proved complete old set.
        let layout = ArchiveVolumeLayout(scheme: record.scheme, volumes: record.oldVolumes.map {
            .init(url: parent.url.appendingPathComponent($0.name), length: $0.size)
        }, openedVolumeIndex: 0)
        try metadataStore.save(metadata, layout: layout)
    }
    mutating func markOldKept() throws {
        guard record.phase == .done, record.keptOldVolumes != true else { return }
        record.keptOldVolumes = true
        try journal.write(record)
    }
    func barrier(_ point: VolumePublishBarrier) throws {
        try parent.sync(full: true)
        operations.didBarrier(point)
    }

    /// S5 の全 hash 照合の証拠。rename 中は inode/size/mtime が変わったものだけ再検査する。
    mutating func proveOldBeforeRetiring() throws {
        for volume in record.oldVolumes {
            guard try volume.matches(in: parent, useHash: record.hashesOldVolumes),
                  let info = try parent.info(volume.name) else { throw VolumePublishError.setChanged }
            if record.hashesOldVolumes { operations.didHash(parent.url.appendingPathComponent(volume.name)) }
            oldProof[volume.name] = Stamp(info)
        }
    }
    mutating func oldMatches(_ volume: VolumePublishJournalRecord.OldVolume, in directory: VolumePublishDirectory) throws -> Bool {
        guard let info = try directory.info(volume.name), info.st_mode & S_IFMT == S_IFREG else { return false }
        if oldProof[volume.name] == Stamp(info) { return true }
        let matches = try volume.matches(in: directory, useHash: record.hashesOldVolumes)
        if record.hashesOldVolumes { operations.didHash(directory.url.appendingPathComponent(volume.name)) }
        if matches { oldProof[volume.name] = Stamp(info) }
        return matches
    }
    mutating func newMatches(_ volume: VolumePublishJournalRecord.NewVolume, in directory: VolumePublishDirectory) throws -> Bool {
        guard let info = try directory.info(volume.name), info.st_mode & S_IFMT == S_IFREG else { return false }
        if newProof[volume.name] == Stamp(info) { return true }
        let matches = try volume.matches(in: directory)
        operations.didHash(directory.url.appendingPathComponent(volume.name))
        if matches { newProof[volume.name] = Stamp(info) }
        return matches
    }
    mutating func retireOld(hook: (VolumePublishStep) throws -> Void) throws {
        guard record.phase != .done else { throw VolumePublishError.alreadyUsed }
        try phase(.retiring)
        let old = try optionalDirectory("old")
        let gateRetired: Bool
        if let gate = record.oldVolumes.first, let old { gateRetired = try oldMatches(gate, in: old) }
        else { gateRetired = record.oldVolumes.isEmpty }
        if gateRetired, let gate = record.newVolumes.first, try newMatches(gate, in: parent) {
            let new = try optionalDirectory("new") ?? staging.directory("new", create: true)
            try renamer.move(gate.name, from: parent, to: new)
        }
        if let gate = record.oldVolumes.first, let old { try retire(gate, to: old) }
        try barrier(.retiredGate)
        try hook(.s6)
        if let old {
            for i in record.oldVolumes.indices.dropFirst() {
                try retire(record.oldVolumes[i], to: old)
                try hook(.retiredVolume(i))
            }
        }
        try hook(.s7)
    }
    private mutating func retire(_ volume: VolumePublishJournalRecord.OldVolume, to old: VolumePublishDirectory) throws {
        if try oldMatches(volume, in: old) {
            if forwardNames.contains(volume.name), try parent.info(volume.name) != nil {
                guard let replacement = record.newVolumes.first(where: { $0.name == volume.name }),
                      try newMatches(replacement, in: parent),
                      try optionalDirectory("new")?.info(volume.name) == nil else { throw VolumePublishError.nameOccupied(volume.name) }
            }
            return
        }
        guard try oldMatches(volume, in: parent), let before = try parent.info(volume.name) else { throw VolumePublishError.setChanged }
        let fd = try parent.openFile(volume.name)
        defer { close(fd) }
        var held = stat()
        guard fstat(fd, &held) == 0, VolumePublishFS.sameFile(before, held) else { throw VolumePublishError.setChanged }
        try renamer.move(volume.name, from: parent, to: old)
        // FAT の rename は synthetic inode を変えうる。保持 fd で移動先を照合し、再 hash はしない。
        guard fstat(fd, &held) == 0, let after = try old.info(volume.name), VolumePublishFS.sameFile(held, after),
              held.st_dev == before.st_dev, held.st_size == before.st_size,
              held.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              held.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              record.hashesOldVolumes || held.st_ino == before.st_ino else { throw VolumePublishError.setChanged }
        oldProof[volume.name] = Stamp(after)
    }
    mutating func placeNew(hook: (VolumePublishStep) throws -> Void) throws -> [String: UInt64] {
        guard record.phase != .done else { throw VolumePublishError.alreadyUsed }
        try phase(.placing)
        let new = try optionalDirectory("new")
        var inodes: [String: UInt64] = [:]
        for i in record.newVolumes.indices.dropFirst() {
            try place(record.newVolumes[i], from: new, inodes: &inodes)
            try hook(.placedVolume(i))
        }
        try barrier(.placedSiblings)
        try hook(.s8)
        guard let gate = record.newVolumes.first else { throw VolumePublishError.validationFailed }
        try place(gate, from: new, inodes: &inodes)
        try parent.sync(full: true)
        try phase(.placed)
        try hook(.s9)
        return inodes
    }
    private mutating func place(_ volume: VolumePublishJournalRecord.NewVolume, from new: VolumePublishDirectory?,
                               inodes: inout [String: UInt64]) throws {
        if try parent.info(volume.name) == nil {
            guard let new, try newMatches(volume, in: new) else { throw VolumePublishError.contentMismatch(volume.name) }
            try renamer.move(volume.name, from: new, to: parent)
        } else if try !newMatches(volume, in: parent) { throw VolumePublishError.nameOccupied(volume.name) }
        guard let info = try parent.info(volume.name), info.st_mode & S_IFMT == S_IFREG else { throw VolumePublishError.validationFailed }
        inodes[volume.name] = info.st_ino
    }

    mutating func validateHashes(in directory: VolumePublishDirectory, inodes: [String: UInt64]? = nil) throws {
        try record.validate(stagingName: staging.url.lastPathComponent)
        guard !record.newVolumes.isEmpty else { throw VolumePublishError.validationFailed }
        try directory.verifyPath()
        try directory.requireAbsent(record.nextName)
        var identityChanged = false
        for volume in record.newVolumes {
            guard try volume.matches(in: directory), let info = try directory.info(volume.name) else { throw VolumePublishError.contentMismatch(volume.name) }
            if let inodes, inodes[volume.name] != info.st_ino { identityChanged = true }
            operations.didHash(directory.url.appendingPathComponent(volume.name))
            newProof[volume.name] = Stamp(info)
        }
        try directory.requireAbsent(record.nextName) // A noncooperating writer may have appended during hashing.
        if identityChanged {
            throw VolumePublishError.publishedVerificationPending(staging: staging.url,
                diagnostic: "Published and verified by hash; placed inode changed")
        }
    }
    mutating func validateNew(in directory: VolumePublishDirectory, inodes: [String: UInt64]? = nil,
                             options: ReaderOptions = .kaitoFinder(), validation: (@Sendable (ArchiveReader) throws -> Void)? = nil) throws {
        try validateHashes(in: directory, inodes: inodes)
        do {
            let reader = try operations.openReader(directory.url.appendingPathComponent(record.newGate), options)
            if record.newVolumes.count == 1 {
                guard reader.volumeSet == nil else { throw VolumePublishError.validationFailed }
            } else {
                guard let set = reader.volumeSet, set.volumes.count == record.newVolumes.count, set.scheme == record.scheme else { throw VolumePublishError.validationFailed }
                for (actual, wanted) in zip(set.volumes, record.newVolumes) {
                    guard actual.url.lastPathComponent == wanted.name, actual.length == wanted.length,
                          let info = try directory.info(wanted.name), actual.inode == info.st_ino,
                          inodes == nil || inodes?[wanted.name] == actual.inode else { throw VolumePublishError.validationFailed }
                }
            }
            try validation?(reader)
        } catch {
            // reader の失敗は byte の破損と別。hash が一致する新セットを後退させない。
            try validateHashes(in: directory, inodes: inodes)
            if directory.url == parent.url {
                throw VolumePublishError.publishedReaderFailed(staging: staging.url,
                    diagnostic: "Published and verified by hash; reader failed: \(error)")
            }
            throw VolumePublishError.stagedReaderFailed(String(describing: error))
        }
        if validation != nil { try validateHashes(in: directory, inodes: inodes) }
        try directory.requireAbsent(record.nextName)
    }

    mutating func rollback(allowLiveMoves: Bool = true) throws {
        guard record.phase != .done else { throw VolumePublishError.alreadyUsed }
        if try staging.info("abandoned") == nil {
            if try staging.info("new") != nil { try renamer.move("new", from: staging, to: staging, as: "abandoned", verifyPaths: false) }
            else { _ = try staging.directory("abandoned", create: true); try staging.sync() }
        }
        let abandoned = try staging.directory("abandoned"), old = try optionalDirectory("old")
        var failure: (any Error)?
        // foreign gate でも停止せず、証明できる新巻をすべて先に引き戻す。
        for (i, volume) in record.newVolumes.enumerated() {
            do {
                let original = record.oldVolumes.first { $0.name == volume.name }
                let backedUp = try original.map { original in try old.map { try original.matches(in: $0, useHash: record.hashesOldVolumes) } ?? false } ?? false
                let isOld = try original?.matches(in: parent, useHash: record.hashesOldVolumes) ?? false
                if !isOld || backedUp, try volume.matches(in: parent) {
                    guard allowLiveMoves else { throw VolumePublishError.setChanged }
                    try renamer.move(volume.name, from: parent, to: abandoned, verifyPaths: false)
                }
            } catch {
                if i == 0 { throw error }
                if failure == nil { failure = error }
            }
            if i == 0 { try barrier(.withdrawnGate) }
        }
        if let failure { throw failure }
        if !allowLiveMoves {
            guard try oldDirectoryEmpty() else { throw VolumePublishError.setChanged }
        }
        try phase(.abandoned)
        if allowLiveMoves { try restoreOld() }
        try persistRestoredMetadata()
    }
    private mutating func restoreOld() throws {
        // Nothing retired means no restoration is owed, even if live names changed independently.
        if try oldDirectoryEmpty() { return }
        let old = try optionalDirectory("old")
        if let gate = record.oldVolumes.first, try gate.matches(in: parent, useHash: record.hashesOldVolumes),
           try !record.oldVolumes.allSatisfy({ try $0.matches(in: parent, useHash: record.hashesOldVolumes) }) {
            guard let old else { throw VolumePublishError.setChanged }
            try renamer.move(gate.name, from: parent, to: old, verifyPaths: false)
            try barrier(.withdrawnGate)
        }
        // 新巻の引き戻しを済ませてから旧名の占有を判定する。foreign gate に旧兄弟も繋がない。
        for volume in record.oldVolumes {
            if try parent.info(volume.name) != nil, try !volume.matches(in: parent, useHash: record.hashesOldVolumes) {
                throw VolumePublishError.nameOccupied(volume.name)
            }
        }
        if !record.oldVolumes.isEmpty {
            try parent.requireAbsent(record.scheme.fileName(forVolumeAt: record.oldVolumes.count, count: record.oldVolumes.count + 1))
        }
        for volume in record.oldVolumes.dropFirst() { try restore(volume, from: old) }
        // 次の旧巻名は gate を戻す前に確認。離れた new-only の foreign 名には触れない。
        if !record.oldVolumes.isEmpty {
            try parent.requireAbsent(record.scheme.fileName(forVolumeAt: record.oldVolumes.count, count: record.oldVolumes.count + 1))
        }
        try barrier(.restoredSiblings)
        guard try record.oldVolumes.dropFirst().allSatisfy({ try $0.matches(in: parent, useHash: record.hashesOldVolumes) }) else {
            throw VolumePublishError.setChanged
        }
        if let gate = record.oldVolumes.first { try restore(gate, from: old) }
        for volume in record.oldVolumes {
            guard try volume.matches(in: parent, useHash: record.hashesOldVolumes) else { throw VolumePublishError.setChanged }
        }
        try barrier(.restoredOld)
    }
    private func restore(_ volume: VolumePublishJournalRecord.OldVolume, from old: VolumePublishDirectory?) throws {
        if try volume.matches(in: parent, useHash: record.hashesOldVolumes) { return }
        guard let old, try volume.matches(in: old, useHash: record.hashesOldVolumes) else { throw VolumePublishError.setChanged }
        try renamer.move(volume.name, from: old, to: parent, verifyPaths: false)
    }

    /// Trash → 証明できる生成物・superseded だけ remove → それ以外は keep。
    func dispose(_ name: String, allowRemoval: Bool = true) throws -> VolumeDisposal {
        guard let directory = try optionalDirectory(name) else { return .none }
        func volumesAreProven() throws -> Bool {
            if name == "old" {
                return try record.phase == .done && record.oldVolumes.allSatisfy {
                    try directory.info($0.name) == nil || $0.matches(in: directory, useHash: record.hashesOldVolumes)
                }
            }
            return try record.phase == .abandoned && record.newVolumes.allSatisfy {
                try directory.info($0.name) == nil || $0.matches(in: directory)
            }
        }
        if name == "old", try !volumesAreProven() { return .kept(directory.url) }
        try directory.verifyPath()
        let names = name == "old" ? record.oldVolumes.map(\.name) : record.newVolumes.map(\.name)
        if try names.allSatisfy({ try directory.info($0) == nil }) {
            try VolumePublishRemoval.remove(name, from: staging, operations: operations)
            try staging.sync()
            return .none
        }
        let trashed: URL
        do { trashed = try operations.trash(directory.url) }
        catch {
            try directory.verifyPath()
            // Trash が失敗するまでの間にも変更されうるので、unlink の直前に証拠を更新する。
            guard allowRemoval, try volumesAreProven() else { return .kept(directory.url) }
            if name == "old" {
                // Durable done is not evidence that the live copy still exists now.
                var proof = self
                do { try proof.validateHashes(in: parent) }
                catch { return .kept(directory.url) }
            }
            do { try VolumePublishRemoval.remove(name, from: staging, operations: operations) }
            catch is SimulatedCrash { throw SimulatedCrash() }
            catch { return .kept(directory.url) }
            try staging.sync(full: true)
            return .removed
        }
        try staging.sync(full: true)
        return .trashed(trashed)
    }
    func discardPrepared() throws -> VolumeDisposal {
        // 呼び出し元が pre-S5 または prepared の無移動を証明した領域。旧巻の変更は無関係。
        let ownership = try stagingLock ?? VolumePublishLock.stagingLock(staging.url.lastPathComponent, directory: index.stagingLocksURL)
        defer { withExtendedLifetime(ownership) {} }
        try discardStaging()
        try parent.sync(full: true)
        try index.removeCompleted(indexedURL ?? staging.url)
        try ownership.removeIfResolved(staging.url.lastPathComponent, parent: parent, index: index)
        return .removed
    }
    func removeEmptyStaging(hook: (VolumePublishStep) throws -> Void = { _ in }) throws {
        let ownership = try stagingLock ?? VolumePublishLock.stagingLock(staging.url.lastPathComponent, directory: index.stagingLocksURL)
        defer { withExtendedLifetime(ownership) {} }
        for name in ["old", "new", "abandoned"] {
            if let directory = try optionalDirectory(name) {
                let names = name == "old" ? record.oldVolumes.map(\.name) : record.newVolumes.map(\.name)
                guard try names.allSatisfy({ try directory.info($0) == nil }) else { throw VolumePublishError.unsafePath(directory.url.path) }
            }
        }
        if let work = try optionalDirectory("work"), let info = try work.info(record.workName) {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size == 0, info.st_nlink == 1 else { throw VolumePublishError.unsafePath(record.workName) }
        }
        try staging.verifyPath(); try journal.verifyPath(staging)
        try index.authorizeCleanup(indexedURL ?? staging.url)
        try discardStaging()
        try parent.sync(full: true)
        try hook(.stagingRemoved)
        try index.removeCompleted(indexedURL ?? staging.url)
        try hook(.indexRemoved)
        try ownership.removeIfResolved(staging.url.lastPathComponent, parent: parent, index: index)
    }

    private func discardStaging() throws {
        try journal.verifyPath(staging)
        journal.release() // SMB may refuse to rename a directory containing our open journal.
        try VolumePublishRemoval.discard(staging, parent: parent, operations: operations, isNetworkVolume: isNetworkVolume)
    }
}
