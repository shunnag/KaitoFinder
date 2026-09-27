import Foundation
import KaitoKit

nonisolated enum ArchiveReservationComputation {
    @concurrent static func edit(removing: [ArchiveEditSelection], renaming: [ArchiveEditRename], moving: [ArchiveEditMove],
                                state: ArchiveReservationState, changes: ArchivePendingChanges, base: [ArchiveEntry],
                                generation: UInt64) async throws -> (ArchivePendingChanges, ArchiveEditResult) {
        ArchiveReservationDiagnostics.record(.planning)
        let projection = state.projection
        let plan = try ArchiveEditPlan.build(removing: removing.map { try projection.selection($0) },
            renaming: renaming.map { .init(selection: try projection.selection($0.selection), name: $0.name) },
            moving: moving.map { .init(selection: try projection.selection($0.selection), folder: $0.folder) },
            existing: projection.planningEntries, format: state.format, occupancy: state.occupancy)
        return apply(plan, state: state, changes: changes, base: base, generation: generation)
    }

    @concurrent static func applyValidated(_ plan: ArchiveEditPlan, state: ArchiveReservationState, changes: ArchivePendingChanges,
                                           base: [ArchiveEntry], generation: UInt64) async -> (ArchivePendingChanges, ArchiveEditResult) {
        apply(plan, state: state, changes: changes, base: base, generation: generation)
    }

    private static func apply(_ plan: ArchiveEditPlan, state: ArchiveReservationState, changes: ArchivePendingChanges,
                              base: [ArchiveEntry], generation: UInt64) -> (ArchivePendingChanges, ArchiveEditResult) {
        (ArchivePendingEditor.applying(plan, projection: state.projection, changes: changes, base: base, generation: generation),
         ArchiveEditResult(removedPaths: plan.removals.map(\.expectedName), renamedPaths: plan.renames.map(\.path)))
    }

    @concurrent static func folder(in folder: String, baseName: String, state: ArchiveReservationState,
                                  changes: ArchivePendingChanges) async throws -> (ArchivePendingChanges, ArchiveImportResult) {
        let plan = try ArchiveNewFolderPlan.build(in: folder, baseName: baseName, existing: state.projection.planningEntries,
                                                 format: state.format, occupancy: state.occupancy)
        var next = changes
        next.createdFolders.append(.init(id: UUID(), path: plan.path))
        return (next, ArchiveImportResult(addedPaths: [plan.path], failures: []))
    }

    @concurrent static func importPlan(urls: [URL], folder: String, state: ArchiveReservationState, archive: URL,
                                      progress: Progress, options: ArchiveImportPlan.Options,
                                      resolver: ArchiveImportConflict.Resolver?) async throws -> ArchiveImportPlan {
        ArchiveReservationDiagnostics.record(.importPlanning)
        if let resolver {
            return try await ArchiveImportPlan.resolving(urls: urls, folder: folder, existing: state.projection.planningEntries,
                archive: archive, generation: state.reading.generation, progress: progress, options: options, format: state.format,
                itemProvider: { entries, path in
                    try conflictItem(entries.map { state.projection.entries[$0.index] }, path: path, state: state, archive: archive)
                }, occupancy: state.occupancy, resolver: resolver)
        }
        return try ArchiveImportPlan.build(urls: urls, folder: folder, existing: state.projection.planningEntries,
                                           progress: progress, options: options, format: state.format, occupancy: state.occupancy)
    }

    @concurrent static func append(_ plan: ArchiveImportPlan, additions: [ArchivePendingChanges.PendingAddition],
                                  state: ArchiveReservationState, changes: ArchivePendingChanges,
                                  base: [ArchiveEntry], generation: UInt64) async -> ArchivePendingChanges {
        let removals = plan.replacingEntries.map { ArchiveEditPlan.Entry(state.projection.planningEntries[$0]) }
        var next = ArchivePendingEditor.applying(.init(removals: removals, renames: [], existing: state.projection.planningEntries, format: state.format),
            projection: state.projection, changes: changes, base: base, generation: generation)
        next.additions += additions
        return next
    }

    @concurrent static func move(_ selections: [ArchiveEditSelection], folder: String, state: ArchiveReservationState,
                                changes: ArchivePendingChanges, base: [ArchiveEntry], archive: URL, generation: UInt64,
                                progress: Progress, resolver: ArchiveImportConflict.Resolver) async throws -> (ArchivePendingChanges, ArchiveEditResult) {
        let projection = state.projection
        let target = folder.isEmpty ? "" : try ArchiveImportPlan.path(folder, format: state.format)
        _ = try ArchiveImportPlan.build(urls: [], folder: target, existing: projection.planningEntries,
                                       progress: progress, format: state.format, occupancy: state.occupancy)
        var moving: [ArchiveEditSelection] = [], candidates: [ArchiveConflictResolution.Candidate] = []
        for selection in selections {
            let mapped = try projection.selection(selection)
            let source = try ArchiveImportPlan.path(selection.path, format: state.format)
            if ArchivePath.components(source).dropLast().joined(separator: "/") == target { continue }
            if selection.isDirectory, target == source || ArchivePath.isDescendant(target, of: source) {
                throw ArchiveEditError.destinationInsideSource(source)
            }
            let leaf = ArchivePath.components(source).last!
            let destination = target.isEmpty ? leaf : target + "/" + leaf
            moving.append(mapped)
            candidates.append(.init(path: destination, info: try conflictItem(selection.entries, path: source, state: state, archive: archive)))
        }
        let resolution = try await ArchiveConflictResolution.resolve(candidates,
            existing: ArchiveConflictResolution.existingGroups(projection.planningEntries, folder: target, matching: Set(candidates.map(\.path))),
            archive: archive, generation: generation, progress: progress,
            itemProvider: { entries, path in
                try conflictItem(entries.map { projection.entries[$0.index] }, path: path, state: state, archive: archive)
            }, resolver: resolver)
        let removals = resolution.replaced.map { ArchiveEditSelection(path: $0.name, isDirectory: false, entries: [$0]) }
        let plan = try ArchiveEditPlan.build(removing: removals, renaming: [],
            moving: resolution.accepted.map { .init(selection: moving[$0], folder: target) },
            existing: projection.planningEntries, format: state.format, occupancy: state.occupancy)
        return apply(plan, state: state, changes: changes, base: base, generation: generation)
    }

    private static func conflictItem(_ entries: [ArchiveEntry], path: String, state: ArchiveReservationState, archive: URL) throws -> ArchiveConflictItem {
        ArchiveReservationDiagnostics.record(.conflictItem)
        let info = ArchiveConflictItem.archived(entries, path: path, archive: archive, generation: state.reading.generation)
        let source: ArchiveConflictItem.Source?
        var lease: StagingRegistry.ReadLease?
        if entries.count == 1, let entry = entries.first, entry.pendingID != nil,
           case .staged(let addition) = state.reading.sources[entry.index], addition.sourceStamp.kind == .file {
            lease = try state.reading.staging?.acquireRead()
            guard lease != nil else { throw ArchiveEntryPayload.staleSelection }
            source = .file(addition.stagedURL)
        } else if entries.count == 1, let entry = entries.first, entry.kind == .file, !entry.isIncomplete {
            source = .archive(state.reading.payload(for: entry, archive: archive))
        } else { source = info.source }
        return .init(name: info.name, location: info.location, kind: info.kind, size: info.size,
            modificationDate: info.modificationDate, entryCount: info.entryCount, source: source, stagingLease: lease)
    }
}
