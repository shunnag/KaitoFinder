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
    private let baseOccupancy: ArchivePathOccupancy?
    var isEmpty: Bool { edits.removals.isEmpty && edits.renames.isEmpty && additions.isEmpty && folders.isEmpty && outputEncryption == nil }

    @concurrent static func build(base: [ArchiveEntry], generation: UInt64, pending: ArchivePendingChanges,
                                  format: GyoshukuKit.ArchiveFormat = .zip, progress: Progress = Progress()) async throws -> Self {
        try Self(base: base, generation: generation, pending: pending, format: format, progress: progress)
    }

    init(base: [ArchiveEntry], generation: UInt64, pending: ArchivePendingChanges,
         format: GyoshukuKit.ArchiveFormat = .zip, progress: Progress = Progress()) throws {
        #if DEBUG
        let span = ArchiveStageDiagnostics.begin(.replayPlan)
        defer { span?.end() }
        #endif
        ArchiveReservationDiagnostics.record(.replayPlan)
        let projected = try pending.projection(base: base, generation: generation)
        self.projected = projected
        let removed = Set(pending.removals.map(\.index))
        let names = try ArchiveStageDiagnostics.measure(.planKeys) {
            var desiredKeys: [Int: String] = [:]
            // 基底の正規化は全件走査の中だけで行う。同じ key の改名だけなら占有は不要。
            for reference in pending.renames.keys.sorted(by: { $0.index < $1.index }) where !removed.contains(reference.index) {
                desiredKeys[reference.index] = ArchiveEditPlan.key(pending.renames[reference]!)
            }
            var referenceKeys: [Int: String] = [:]
            let needsNames = !pending.additions.isEmpty || !pending.createdFolders.isEmpty || desiredKeys.contains {
                let key = ArchiveEditPlan.key(base[$0.key].name)
                referenceKeys[$0.key] = key
                return $0.value != key
            }
            guard needsNames else { return ([String](), ArchivePathOccupancy?.none, [Int: String](), [Int: String]()) }
            let keys = base.map { referenceKeys[$0.index] ?? ArchiveEditPlan.key($0.name) }
            var occupancy = ArchivePathOccupancy(), desired: [Int: String] = [:]
            for entry in base { occupancy.insert(keys[entry.index], directory: entry.kind == .directory) }
            for reference in pending.renames.keys.sorted(by: { $0.index < $1.index }) where !removed.contains(reference.index) {
                let index = reference.index
                if desiredKeys[index] == keys[index] { desiredKeys.removeValue(forKey: index); continue }
                desired[index] = try ArchiveEditPlan.normalizedPath(pending.renames[reference]!, directory: base[index].kind == .directory, format: format)
            }
            return (keys, Optional(occupancy), desired, desiredKeys)
        }
        let (baseKeys, baseOccupancy, desired, desiredKeys) = names
        self.baseOccupancy = baseOccupancy
        var occupied = ArchivePathOccupancy.Overlay(baseOccupancy ?? .init())
        for index in baseOccupancy == nil ? [] : removed.sorted() {
            occupied.remove(baseKeys[index], directory: base[index].kind == .directory)
        }
        // 最終形の検査を先に行い、解決不能な衝突を一時名で隠さない。
        var final = occupied
        for index in desired.keys { final.remove(baseKeys[index], directory: base[index].kind == .directory) }
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
                occupied.remove(current[index] ?? baseKeys[index], directory: directory)
                if occupied.collides(key, directory: directory) {
                    occupied.insert(current[index] ?? baseKeys[index], directory: directory)
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
                    let key = current[entry.index] ?? baseKeys[entry.index]
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
                    occupied.remove(current[index] ?? baseKeys[index], directory: directory)
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
        // init の全件走査で作った key は、初回の検査が終わったら保持しない。
        try validate(baseKeys: baseOccupancy == nil ? nil : baseKeys)
    }

    func validate() throws { try validate(baseKeys: nil) }

    private func validate(baseKeys: [String]?) throws {
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
                preservingOwnerIDs: Bool = false) throws {
        try edits.verifyNames(editor.entryNames)
        try validate()
        try ArchiveImportPlan.checkCancellation(progress)
        if !edits.removals.isEmpty {
            try editor.remove(entriesAt: edits.removals.map(\.index))
            progress.completedUnitCount += Int64(edits.removals.count)
        }
        for rename in edits.renames {
            try ArchiveImportPlan.checkCancellation(progress)
            try editor.rename(entryAt: rename.entry.index, to: rename.path)
            progress.completedUnitCount += 1
        }
        for addition in additions {
            try ArchiveImportPlan.checkCancellation(progress)
            if addition.sourceStamp.kind == .directory {
                try editor.addDirectory(addition.path, modificationDate: addition.savedDate,
                                        ownerIDs: preservingOwnerIDs ? .init(user: 0, group: 0) : nil)
            } else if preservingOwnerIDs {
                try editor.add(contentsOf: addition.stagedURL, as: addition.path,
                               ownerIDs: .init(user: addition.sourceStamp.userID, group: addition.sourceStamp.groupID))
            }
            else { try editor.add(contentsOf: addition.stagedURL, as: addition.path) }
            progress.completedUnitCount += 1
        }
        for folder in folders {
            try ArchiveImportPlan.checkCancellation(progress)
            try editor.addDirectory(folder.path, modificationDate: folder.date,
                                    ownerIDs: preservingOwnerIDs ? .init(user: 0, group: 0) : nil)
            progress.completedUnitCount += 1
        }
        if outputEncryption != nil, let updater = editor as? ArchiveUpdater {
            try updater.reencryptExistingEntries(currentPassword: sourcePassword)
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
