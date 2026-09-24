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
    var isEmpty: Bool { edits.removals.isEmpty && edits.renames.isEmpty && additions.isEmpty && folders.isEmpty && outputEncryption == nil }

    @concurrent static func build(base: [ArchiveEntry], generation: UInt64, pending: ArchivePendingChanges,
                                  progress: Progress = Progress()) async throws -> Self {
        try Self(base: base, generation: generation, pending: pending, progress: progress)
    }

    init(base: [ArchiveEntry], generation: UInt64, pending: ArchivePendingChanges, progress: Progress = Progress()) throws {
        ArchiveReservationDiagnostics.record(.replayPlan)
        let projected = try pending.projection(base: base, generation: generation)
        self.projected = projected
        let removed = Set(pending.removals.map(\.index))
        let survivors = projected.filter { $0.pendingID == nil }
        var desired: [Int: String] = [:]
        for entry in survivors where ArchiveEditPlan.key(entry.name) != ArchiveEditPlan.key(base[entry.index].name) {
            desired[entry.index] = try ArchiveEditPlan.normalizedPath(entry.name, directory: entry.kind == .directory)
        }
        // 最終形の検査を先に行い、解決不能な衝突を一時名で隠さない。
        var final = ArchivePathOccupancy()
        for entry in survivors where desired[entry.index] == nil {
            final.insert(ArchiveEditPlan.key(entry.name), directory: entry.kind == .directory)
        }
        for entry in projected where entry.pendingID != nil || desired[entry.index] != nil {
            let path = try ArchiveEditPlan.normalizedPath(entry.name, directory: entry.kind == .directory)
            guard !final.collides(ArchiveEditPlan.key(path), directory: entry.kind == .directory) else {
                throw ArchiveEditError.collision(path)
            }
            final.insert(ArchiveEditPlan.key(path), directory: entry.kind == .directory)
        }
        var occupied = ArchivePathOccupancy(), names: [Int: String] = [:]
        for entry in base where !removed.contains(entry.index) {
            let key = ArchiveEditPlan.key(entry.name)
            occupied.insert(key, directory: entry.kind == .directory)
            names[entry.index] = key
        }
        var remaining = desired, ordered: [ArchiveEditPlan.Rename] = []
        var parked: Set<Int> = [], passes = 0
        while !remaining.isEmpty {
            passes += 1
            try ArchiveImportPlan.checkCancellation(progress)
            var advanced = false
            for index in remaining.keys.sorted() {
                try ArchiveImportPlan.checkCancellation(progress)
                let directory = base[index].kind == .directory
                let path = remaining[index]!, key = ArchiveEditPlan.key(path)
                occupied.remove(names[index]!, directory: directory)
                if occupied.collides(key, directory: directory) {
                    occupied.insert(names[index]!, directory: directory)
                    continue
                }
                ordered.append(.init(entry: .init(base[index]), path: path))
                occupied.insert(key, directory: directory)
                names[index] = key
                remaining.removeValue(forKey: index)
                advanced = true
            }
            if !advanced {
                // 独立した循環を一度にほどき、フォルダ同士の交換でも全件走査を繰り返さない。
                var occupants: [String: Int] = [:], ambiguous: Set<String> = []
                for (index, key) in names {
                    if occupants.updateValue(index, forKey: key) != nil { ambiguous.insert(key) }
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
                        let key = ArchiveEditPlan.key(remaining[index]!)
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
                    occupied.remove(names[index]!, directory: directory)
                    occupied.insert(path, directory: directory)
                    names[index] = path
                    ordered.append(.init(entry: .init(base[index]), path: directory ? path + "/" : path))
                }
            }
        }
        renamePasses = passes
        edits = ArchiveEditPlan(removals: removed.sorted().map { .init(base[$0]) }, renames: ordered, existing: base)
        additions = pending.additions
        folders = pending.createdFolders
        outputEncryption = pending.outputEncryption
        try validate()
    }

    func validate() throws {
        try edits.validate(entries: edits.existing, additions:
            additions.map { ($0.path, $0.sourceStamp.kind == .directory) } + folders.map { ($0.path, true) },
            allowsRepeatedRenames: true)
        for addition in additions { try addition.stagedStamp.verify() }
    }

    static func validateRepresentability(_ entries: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat) throws {
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
        try ArchiveRewriter.probe(entries: planned, format: format)
    }

    func replay(on editor: any ArchiveEditing, progress: Progress) throws {
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
            if addition.sourceStamp.kind == .directory { try addDirectory(addition.path, date: addition.savedDate, to: editor) }
            else { try editor.add(contentsOf: addition.stagedURL, as: addition.path) }
            progress.completedUnitCount += 1
        }
        for folder in folders {
            try ArchiveImportPlan.checkCancellation(progress)
            try addDirectory(folder.path, date: folder.date, to: editor)
            progress.completedUnitCount += 1
        }
    }

    private func addDirectory(_ path: String, date: Date, to editor: any ArchiveEditing) throws {
        // addDirectory は保存時の Date() を使うため、0755 の空ディレクトリから予約日時を渡す。
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KaitoFinder-directory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o755, .modificationDate: date])
        defer { try? FileManager.default.removeItem(at: url) }
        try editor.add(contentsOf: url, as: path)
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
