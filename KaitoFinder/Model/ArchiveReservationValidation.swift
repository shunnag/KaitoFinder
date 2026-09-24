import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization

nonisolated struct ArchiveReservationValidation: Sendable {
    let base: [ArchiveEntry]
    let format: GyoshukuKit.ArchiveFormat
    private let occupancy: ArchivePathOccupancy?

    init(base: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat) {
        self.base = base
        self.format = format
        // 不正名・重複・hard link は全体検査の順序と文言も維持する。
        var index = ArchivePathOccupancy()
        do {
            for entry in base {
                guard entry.kind != .hardlink,
                      try ArchiveEditPlan.normalizedPath(entry.name, directory: entry.kind == .directory, format: format)
                        .utf8.elementsEqual(entry.name.utf8),
                      entry.pathComponents.joined(separator: "/") == ArchiveEditPlan.key(entry.name) else {
                    occupancy = nil
                    return
                }
                index.insert(ArchiveEditPlan.key(entry.name), directory: entry.kind == .directory)
            }
            try ArchiveSaveReplayPlan.validateRepresentability(base, format: format)
            occupancy = index
        } catch { occupancy = nil }
    }

    func context(for pending: ArchivePendingChanges) -> ArchivePathOccupancy.Overlay? {
        guard let occupancy else { return nil }
        for (reference, path) in pending.renames where !pending.removals.contains(reference) {
            guard (try? ArchiveEditPlan.normalizedPath(path, directory: base[reference.index].kind == .directory, format: format)) != nil else { return nil }
        }
        for addition in pending.additions {
            guard (try? ArchiveEditPlan.normalizedPath(addition.path, directory: addition.sourceStamp.kind == .directory, format: format)) != nil else { return nil }
        }
        for folder in pending.createdFolders {
            guard (try? ArchiveEditPlan.normalizedPath(folder.path, directory: true, format: format)) != nil else { return nil }
        }
        var result = ArchivePathOccupancy.Overlay(occupancy)
        for reference in pending.removals {
            result.remove(ArchiveEditPlan.key(reference.expectedName), directory: base[reference.index].kind == .directory)
        }
        for (reference, name) in pending.renames where !pending.removals.contains(reference) {
            let directory = base[reference.index].kind == .directory
            result.remove(ArchiveEditPlan.key(reference.expectedName), directory: directory)
            result.insert(ArchiveEditPlan.key(name), directory: directory)
        }
        for addition in pending.additions { result.insert(ArchiveEditPlan.key(addition.path), directory: addition.sourceStamp.kind == .directory) }
        for folder in pending.createdFolders { result.insert(ArchiveEditPlan.key(folder.path), directory: true) }
        return result
    }

    func validate(_ pending: ArchivePendingChanges, projection: ArchivePendingProjection) throws {
        guard var current = context(for: pending) else {
            try Self.validateFull(projection.entries, format: format)
            return
        }
        var changed = pending.renames.keys.filter { !pending.removals.contains($0) }.map(\.index)
        changed.sort()
        changed.append(contentsOf: base.count..<(base.count + pending.additions.count + pending.createdFolders.count))
        for index in changed {
            try Task.checkCancellation()
            guard let position = projection.positions[index] else { throw ArchiveEditError.staleSelection }
            let entry = projection.entries[position], directory = entry.kind == .directory
            let key = ArchiveEditPlan.key(entry.name)
            current.remove(key, directory: directory)
            let collision = current.collides(key, directory: directory)
            current.insert(key, directory: directory)
            if collision {
                try Self.validateFull(projection.entries, format: format)
                return
            }
        }
        for index in changed {
            let entry = projection.entries[projection.positions[index]!]
            try ArchiveRewriter.probe(entries: [entry.pendingCopy(index: 0)], format: format)
        }
    }

    static func validateFull(_ entries: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat) throws {
        ArchiveReservationDiagnostics.record(.fullValidation)
        try ArchiveSaveReplayPlan.validateRepresentability(entries, format: format)
    }
}

nonisolated struct ArchiveReservationState: Sendable {
    let revision: UInt64
    let format: GyoshukuKit.ArchiveFormat
    let projection: ArchivePendingProjection
    let occupancy: ArchivePathOccupancy.Overlay?
    let reading: ArchivePendingReadSnapshot
    let tree: EntryNode
    let filters: [EntryTreeFilter.Configuration: EntryTreeFilter]
    let changesDiffer: Bool

    @concurrent static func build(base: [ArchiveEntry], generation: UInt64, changes: ArchivePendingChanges,
                                  validation: ArchiveReservationValidation, staging: StagingRegistry.Lease?,
                                  validates: Bool = false, previous: ArchivePendingChanges? = nil,
                                  reusing: ArchiveReservationState? = nil, baseTree: EntryNode? = nil,
                                  filters configurations: Set<EntryTreeFilter.Configuration> = [],
                                  checksCancellation: Bool = true) async throws -> Self {
        ArchiveReservationDiagnostics.record(.projection)
        let sameEntries = previous.map { $0.removals == changes.removals && $0.renames == changes.renames &&
            $0.additions == changes.additions && $0.createdFolders == changes.createdFolders } ?? false
        let projection = try sameEntries && reusing != nil ? reusing!.projection
            : ArchivePendingProjection(changes.projection(base: base, generation: generation))
        if validates { try validation.validate(changes, projection: projection) }
        if checksCancellation { try Task.checkCancellation() }
        let occupancy = validation.context(for: changes)
        let tree = sameEntries && reusing != nil ? reusing!.tree
            : (changes.isEmpty ? baseTree : nil) ?? EntryNode.tree(from: projection.entries, format: validation.format)
        let subtrees: ArchiveEntryPayload.SubtreeIndex
        if sameEntries, let reusing { subtrees = reusing.reading.subtrees }
        else if occupancy != nil { subtrees = .init(entries: projection.entries, components: { $0.pathComponents }) }
        else { subtrees = .init(entries: projection.entries) }
        var comparable = changes
        comparable.revision = previous?.revision ?? changes.revision
        let filters = Dictionary(uniqueKeysWithValues: configurations.map { configuration in
            (configuration, EntryTreeFilter(root: tree, query: configuration.query, showsHiddenFiles: configuration.showsHiddenFiles))
        })
        return try Self(revision: changes.revision, format: validation.format, projection: projection, occupancy: occupancy,
            reading: .init(base: base, generation: generation, changes: changes, staging: staging, projection: projection, subtrees: subtrees),
            tree: tree, filters: filters, changesDiffer: previous.map { comparable != $0 } ?? true)
    }
}

nonisolated enum ArchiveBackgroundRelease {
    // 最後の参照を先に actor から外し、解放 Task との競争で main に破棄を戻さない。
    static func release<Value: Sendable>(_ value: inout Value?) {
        let retired = Mutex(value)
        value = nil
        Task.detached { retired.withLock { $0 = nil } }
    }
}
