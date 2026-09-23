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
    var isEmpty: Bool { edits.removals.isEmpty && edits.renames.isEmpty && additions.isEmpty && folders.isEmpty && outputEncryption == nil }

    init(base: [ArchiveEntry], generation: UInt64, pending: ArchivePendingChanges) throws {
        let projected = try pending.projection(base: base, generation: generation)
        self.projected = projected
        let removed = Set(pending.removals.map(\.index))
        let survivors = projected.filter { $0.pendingID == nil }
        var desired: [Int: String] = [:]
        for entry in survivors where !entry.name.utf8.elementsEqual(base[entry.index].name.utf8) {
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
        var parked: Set<Int> = []
        while !remaining.isEmpty {
            var advanced = false
            for index in remaining.keys.sorted() {
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
                // 循環の一頂点を空き名へ退避する。同じ base index の二度目の改名を許す。
                guard let index = remaining.keys.sorted().first(where: { !parked.contains($0) }) else {
                    throw ArchiveEditError.conflictingSelection
                }
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
        if !edits.removals.isEmpty { try editor.remove(entriesAt: edits.removals.map(\.index)) }
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
    private let lease = Mutex<VolumePublishCriticalSection.Lease?>(nil)
    let counter: VolumePublishCriticalSection
    init(counter: VolumePublishCriticalSection = .shared) { self.counter = counter }
    var hasPublishedBoundary: Bool { lease.withLock { $0 != nil } }
    func enter(progress: Progress) throws {
        let acquired = try counter.enter { try ArchiveImportPlan.checkCancellation(progress) }
        lease.withLock { $0 = acquired }
    }
    func finish() { lease.withLock { $0 = nil } }
}
