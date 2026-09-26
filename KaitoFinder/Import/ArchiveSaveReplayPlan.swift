import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization

/// 削除→衝突しない順の改名→追加を、editor に触る前に最後まで検証する。
nonisolated struct ArchiveSaveReplayPlan: Sendable {
    let edits: ArchiveEditPlan
    let additions: [ArchivePendingChanges.PendingAddition]
    let folders: [ArchivePendingChanges.CreatedFolder]
    let outputEncryption: ArchiveEncryptionSettings?
    let projected: [ArchiveEntry]
    let renamePasses: Int
    private let baseKeys: [Int: String]
    private let baseOccupancy: ArchivePathOccupancy?
    var isEmpty: Bool { edits.removals.isEmpty && edits.renames.isEmpty && additions.isEmpty && folders.isEmpty && outputEncryption == nil }

    @concurrent static func build(base: [ArchiveEntry], generation: UInt64, pending: ArchivePendingChanges,
                                  format: GyoshukuKit.ArchiveFormat = .zip, progress: Progress = Progress(),
                                  baseOccupancy cached: ArchivePathOccupancy? = nil) async throws -> Self {
        try Self(base: base, generation: generation, pending: pending, format: format, progress: progress, baseOccupancy: cached)
    }

    init(base: [ArchiveEntry], generation: UInt64, pending: ArchivePendingChanges,
         format: GyoshukuKit.ArchiveFormat = .zip, progress: Progress = Progress(),
         baseOccupancy cached: ArchivePathOccupancy? = nil) throws {
        #if DEBUG
        let span = ArchiveStageDiagnostics.begin(.replayPlan)
        defer { span?.end() }
        #endif
        ArchiveReservationDiagnostics.record(.replayPlan)
        let projected = try pending.projection(base: base, generation: generation)
        self.projected = projected
        let removed = Set(pending.removals.map(\.index))
        var baseKeys: [Int: String] = [:]
        func baseKey(_ index: Int) -> String {
            if let key = baseKeys[index] { return key }
            let key = ArchiveEditPlan.key(base[index].name)
            baseKeys[index] = key
            return key
        }
        var desiredKeys: [Int: String] = [:], desired: [Int: String] = [:]
        for reference in pending.renames.keys.sorted(by: { $0.index < $1.index }) where !removed.contains(reference.index) {
            desiredKeys[reference.index] = ArchiveEditPlan.key(pending.renames[reference]!)
        }
        let needsNames = !pending.additions.isEmpty || !pending.createdFolders.isEmpty
            || desiredKeys.contains { $0.value != baseKey($0.key) }
        let baseOccupancy: ArchivePathOccupancy?
        func prepareNames() throws {
            guard needsNames else { desiredKeys = [:]; return }
            for index in removed { _ = baseKey(index) }
            for reference in pending.renames.keys.sorted(by: { $0.index < $1.index }) where !removed.contains(reference.index) {
                let index = reference.index
                if desiredKeys[index] == baseKey(index) { desiredKeys.removeValue(forKey: index); continue }
                desired[index] = try ArchiveEditPlan.normalizedPath(pending.renames[reference]!, directory: base[index].kind == .directory, format: format)
            }
        }
        if let cached {
            baseOccupancy = cached
            try prepareNames()
            for index in removed { _ = baseKey(index) }
        } else {
            baseOccupancy = try ArchiveStageDiagnostics.measure(.planKeys) {
                guard needsNames else { desiredKeys = [:]; return nil }
                var occupancy = ArchivePathOccupancy()
                for entry in base { occupancy.insert(baseKey(entry.index), directory: entry.kind == .directory) }
                try prepareNames()
                return occupancy
            }
        }
        self.baseOccupancy = baseOccupancy
        var occupied = ArchivePathOccupancy.Overlay(baseOccupancy ?? .init())
        for index in baseOccupancy == nil ? [] : removed.sorted() {
            occupied.remove(baseKey(index), directory: base[index].kind == .directory)
        }
        // 最終形の検査を先に行い、解決不能な衝突を一時名で隠さない。
        var final = occupied
        for index in desired.keys { final.remove(baseKey(index), directory: base[index].kind == .directory) }
        for index in desired.keys.sorted() {
            let path = desired[index]!, key = desiredKeys[index]!, directory = base[index].kind == .directory
            guard !final.collides(key, directory: directory) else { throw ArchiveEditError.collision(path) }
            final.insert(key, directory: directory)
        }
        for entry in projected where entry.pendingID != nil {
            let directory = entry.kind == .directory
            let path = try ArchiveEditPlan.normalizedPath(entry.name, directory: directory, format: format)
            let key = ArchiveEditPlan.key(path)
            guard !final.collides(key, directory: directory) else { throw ArchiveEditError.collision(path) }
            final.insert(key, directory: directory)
        }
        var current: [Int: String] = [:]
        var remaining = desired, ordered: [ArchiveEditPlan.Rename] = []
        var parked: Set<Int> = [], passes = 0
        while !remaining.isEmpty {
            passes += 1
            try ArchiveImportPlan.checkCancellation(progress)
            var advanced = false
            for index in remaining.keys.sorted() {
                try ArchiveImportPlan.checkCancellation(progress)
                let directory = base[index].kind == .directory
                let path = remaining[index]!, key = desiredKeys[index]!
                occupied.remove(current[index] ?? baseKey(index), directory: directory)
                if occupied.collides(key, directory: directory) {
                    occupied.insert(current[index] ?? baseKey(index), directory: directory)
                    continue
                }
                ordered.append(.init(entry: .init(base[index]), path: path))
                occupied.insert(key, directory: directory)
                current[index] = key
                remaining.removeValue(forKey: index)
                advanced = true
            }
            if !advanced {
                // 独立した循環を一度にほどき、フォルダ同士の交換でも全件走査を繰り返さない。
                var occupants: [String: Int] = [:], ambiguous: Set<String> = []
                for entry in base where !removed.contains(entry.index) {
                    let key = current[entry.index] ?? baseKey(entry.index)
                    if occupants.updateValue(entry.index, forKey: key) != nil { ambiguous.insert(key) }
                }
                var visited: Set<Int> = [], breaks: [Int] = []
                for start in remaining.keys.sorted() where !visited.contains(start) {
                    var route: [Int] = [], positions: [Int: Int] = [:], cursor: Int? = start
                    while let index = cursor, remaining[index] != nil, !visited.contains(index) {
                        try ArchiveImportPlan.checkCancellation(progress)
                        if let position = positions[index] {
                            if let candidate = route[position...].filter({ !parked.contains($0) }).min() { breaks.append(candidate) }
                            break
                        }
                        positions[index] = route.count
                        route.append(index)
                        let key = desiredKeys[index]!
                        cursor = ambiguous.contains(key) ? nil : occupants[key]
                    }
                    visited.formUnion(route)
                }
                if breaks.isEmpty {
                    guard let index = remaining.keys.sorted().first(where: { !parked.contains($0) }) else {
                        throw ArchiveEditError.conflictingSelection
                    }
                    breaks = [index]
                }
                for index in breaks.sorted() {
                    try ArchiveImportPlan.checkCancellation(progress)
                    parked.insert(index)
                    let directory = base[index].kind == .directory
                    var path: String
                    repeat { path = ".KaitoFinder-rename-" + UUID().uuidString }
                    while occupied.containsSubtree(at: path) || final.containsSubtree(at: path)
                    occupied.remove(current[index] ?? baseKey(index), directory: directory)
                    occupied.insert(path, directory: directory)
                    current[index] = path
                    ordered.append(.init(entry: .init(base[index]), path: directory ? path + "/" : path))
                }
            }
        }
        renamePasses = passes
        edits = ArchiveEditPlan(removals: removed.sorted().map { .init(base[$0]) }, renames: ordered, existing: base, format: format)
        additions = pending.additions
        folders = pending.createdFolders
        outputEncryption = pending.outputEncryption
        // 保存する memo は削除・改名で使う分だけ。循環の全件走査はここで手放す。
        let touched = removed.union(pending.renames.keys.map(\.index))
        self.baseKeys = baseKeys.filter { touched.contains($0.key) }
        try validate(baseKeys: baseOccupancy == nil ? nil : baseKeys)
    }

    func validate() throws { try validate(baseKeys: baseKeys) }

    private func validate(baseKeys: [Int: String]?) throws {
        try edits.validate(entries: edits.existing, additions:
            additions.map { ($0.path, $0.sourceStamp.kind == .directory) } + folders.map { ($0.path, true) },
            allowsRepeatedRenames: true, occupancy: baseOccupancy.map { .init($0) }, baseKeys: baseKeys)
        for addition in additions { try addition.stagedStamp.verify() }
    }

    static func validateRepresentability(_ entries: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat) throws {
        #if DEBUG
        let span = ArchiveStageDiagnostics.begin(.validateRepresentability)
        defer { span?.end() }
        #endif
        let hasHardLinks = entries.contains { $0.kind == .hardlink }
        let identityIndices = !hasHardLinks || entries.enumerated().allSatisfy { position, entry in
            entry.index == position && (entry.kind != .hardlink || entry.formatSpecific["hardLinkTargetIndex"].flatMap(Int.init).map {
                entries.indices.contains($0)
            } ?? true)
        }
        if identityIndices {
            try ArchiveStageDiagnostics.measure(.representabilityProbe) { try ArchiveRewriter.probe(entries: entries, format: format) }
            return
        }
        #if DEBUG
        ArchiveTestCounters.slowRepresentability.get()?.increment()
        #endif
        let positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.index, $0.offset) })
        let planned = entries.enumerated().map { position, entry in
            var metadata = entry.formatSpecific
            var kind = entry.kind
            if kind == .hardlink, let original = metadata["hardLinkTargetIndex"].flatMap(Int.init) {
                if let target = positions[original] { metadata["hardLinkTargetIndex"] = String(target) }
                else { kind = .file; metadata.removeValue(forKey: "hardLinkTargetIndex") }
            }
            return entry.pendingCopy(index: position, kind: kind, formatSpecific: metadata)
        }
        try ArchiveStageDiagnostics.measure(.representabilityProbe) { try ArchiveRewriter.probe(entries: planned, format: format) }
    }

    func replay(on editor: any ArchiveEditing, sourcePassword: String? = nil, progress: Progress,
                preservingOwnerIDs: Bool = false, ledger: ArchiveWriteProgress? = nil, additionBase: Int = 0) throws {
        try edits.verifyNames(editor.entryNames)
        try validate()
        try ArchiveImportPlan.checkCancellation(progress)
        if !edits.removals.isEmpty {
            try editor.remove(entriesAt: edits.removals.map(\.index))
            if let ledger { ledger.didCount(edits.removals.count) }
            else { progress.completedUnitCount += Int64(edits.removals.count) }
        }
        for rename in edits.renames {
            try ArchiveImportPlan.checkCancellation(progress)
            try editor.rename(entryAt: rename.entry.index, to: rename.path)
            if let ledger { ledger.didCount() }
            else { progress.completedUnitCount += 1 }
        }
        // 7z の追加位置は、暗号化を変える既存 pack の長さを先に含めて決める。
        if outputEncryption != nil, let updater = editor as? any ArchiveReencrypting {
            try updater.reencryptExistingEntries(currentPassword: sourcePassword)
        }
        for (index, addition) in additions.enumerated() {
            try ArchiveImportPlan.checkCancellation(progress)
            if addition.sourceStamp.kind == .directory {
                try editor.addDirectory(addition.path, modificationDate: addition.savedDate,
                                        ownerIDs: preservingOwnerIDs ? .init(user: 0, group: 0) : nil)
            } else if let ledger {
                try editor.add(contentsOf: addition.stagedURL, as: addition.path,
                               ownerIDs: preservingOwnerIDs ? .init(user: addition.sourceStamp.userID, group: addition.sourceStamp.groupID) : nil,
                               progress: ledger.addition(additionBase + index))
            } else if preservingOwnerIDs {
                try editor.add(contentsOf: addition.stagedURL, as: addition.path,
                               ownerIDs: .init(user: addition.sourceStamp.userID, group: addition.sourceStamp.groupID))
            }
            else { try editor.add(contentsOf: addition.stagedURL, as: addition.path) }
            if let ledger { ledger.didFinishAddition(additionBase + index) }
            else { progress.completedUnitCount += 1 }
        }
        for folder in folders {
            try ArchiveImportPlan.checkCancellation(progress)
            try editor.addDirectory(folder.path, modificationDate: folder.date,
                                    ownerIDs: preservingOwnerIDs ? .init(user: 0, group: 0) : nil)
            if let ledger { ledger.didCount() }
            else { progress.completedUnitCount += 1 }
        }
    }

}

/// 単一ファイルでも rename から文書の同期完了までは終了期限と取消しを越える。
nonisolated final class ArchiveSavePublication: Sendable {
    // 即時編集の子 Task も、保存と同じ公開境界を共有する。
    static let current = TaskLocal<ArchiveSavePublication?>(wrappedValue: nil)
    private struct State {
        var lease: VolumePublishCriticalSection.Lease?
        var published = false
    }
    private let state = Mutex(State())
    private let cancellationLock = NSRecursiveLock()
    let counter: VolumePublishCriticalSection
    init(counter: VolumePublishCriticalSection = .shared) { self.counter = counter }
    var hasPublishedBoundary: Bool { state.withLock { $0.published } }
    func enter(progress: Progress) throws {
        try cancellationLock.withLock {
            try state.withLock {
                $0.lease = try counter.enter { try ArchiveImportPlan.checkCancellation(progress) }
                $0.published = true
                progress.isCancellable = false
            }
        }
    }
    func enterSplitBoundary() throws {
        try cancellationLock.withLock {
            try state.withLock {
                $0.lease = try counter.enter()
                $0.published = true
            }
        }
    }
    func cancelBeforePublication(progress: Progress, cancel: () -> Void) {
        // 子 Task の取消しハンドラが再入しても、公開境界とは直列にする。
        cancellationLock.withLock {
            guard !hasPublishedBoundary, progress.isCancellable else { return }
            if !progress.isCancelled { progress.cancel() }
            cancel()
        }
    }

    @MainActor func watchCancellation(progress: Progress, cancel: @escaping @Sendable () -> Void) -> ArchiveProgressCancellation {
        ArchiveProgressCancellation(progress: progress, publication: self) { _ in cancel() }
    }

    func finish() { state.withLock { $0.lease = nil } }
}
