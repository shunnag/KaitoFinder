import Foundation
import KaitoKit

/// 表示した版の origin と出力名。読み始める前だけ現行版と照合し、その後は値と lease を保持する。
nonisolated struct ArchivePendingReadSnapshot: Sendable {
    enum Source: Sendable {
        case base(ArchiveEntry)
        case staged(ArchivePendingChanges.PendingAddition)
        case folder
    }
    let generation: UInt64
    let revision: UInt64
    let base: [ArchiveEntry]
    let entries: [ArchiveEntry]
    let sources: [Int: Source]
    let staging: StagingRegistry.Lease?
    let stagedURLs: [URL]
    private let byIndex: [Int: ArchiveEntry]
    private let pendingIndices: [UUID: Int]
    private let subtrees: ArchiveEntryPayload.SubtreeIndex

    init(base: [ArchiveEntry], generation: UInt64, changes: ArchivePendingChanges,
         staging: StagingRegistry.Lease?) throws {
        self.base = base
        self.generation = generation
        revision = changes.revision
        self.staging = staging
        stagedURLs = changes.additions.map(\.stagedURL)
        let entries = try changes.projection(base: base, generation: generation)
        self.entries = entries
        byIndex = Dictionary(uniqueKeysWithValues: entries.map { ($0.index, $0) })
        pendingIndices = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.pendingID.map { ($0, entry.index) }
        })
        subtrees = .init(entries: entries)
        let additions = Dictionary(uniqueKeysWithValues: changes.additions.map { ($0.id, $0) })
        sources = Dictionary(uniqueKeysWithValues: entries.map { entry in
            let source: Source
            if let id = entry.pendingID {
                source = additions[id].map(Source.staged) ?? .folder
            } else { source = .base(base[entry.index]) }
            return (entry.index, source)
        })
    }

    func origin(for entry: ArchiveEntry) -> ArchiveEntryPayload.Origin? {
        guard byIndex[entry.index] == entry else { return nil }
        if let id = entry.pendingID { return .pending(id) }
        return .base(index: entry.index, expectedName: base[entry.index].name, baseGeneration: generation)
    }

    func payload(for entry: ArchiveEntry, archive: URL) -> ArchiveEntryPayload {
        .init(archiveURL: archive, generation: generation, entryIndex: entry.index, path: entry.name,
              isDirectory: entry.kind == .directory, revision: revision, origin: origin(for: entry))
    }

    func source(for origin: ArchiveEntryPayload.Origin) -> Source? {
        switch origin {
        case .base(let index, _, _): sources[index]
        case .pending(let id): pendingIndices[id].flatMap { sources[$0] }
        }
    }

    func resolve(_ payload: ArchiveEntryPayload) throws -> [ArchiveEntry] {
        guard payload.generation == generation, payload.revision == revision, let origin = payload.origin else {
            throw ArchiveEntryPayload.staleSelection
        }
        let anchor: ArchiveEntry?
        switch origin {
        case .base(let index, let expectedName, let baseGeneration):
            guard baseGeneration == generation, base.indices.contains(index),
                  base[index].name.utf8.elementsEqual(expectedName.utf8) else { throw ArchiveEntryPayload.staleSelection }
            anchor = byIndex[index]
        case .pending(let id): anchor = pendingIndices[id].flatMap { byIndex[$0] }
        }
        guard let anchor, self.origin(for: anchor) == origin else { throw ArchiveEntryPayload.staleSelection }
        if payload.isDirectory {
            let selected = subtrees.subtree(for: try ExtractionPath.components(payload.path))
            guard selected.contains(anchor), !selected.isEmpty else { throw ArchiveEntryPayload.staleSelection }
            if let index = payload.entryIndex {
                guard anchor.index == index, anchor.kind == .directory,
                      anchor.name.utf8.elementsEqual(payload.path.utf8) else { throw ArchiveEntryPayload.staleSelection }
            }
            return selected
        }
        guard anchor.index == payload.entryIndex, anchor.kind != .directory,
              anchor.name.utf8.elementsEqual(payload.path.utf8) else { throw ArchiveEntryPayload.staleSelection }
        return [anchor]
    }
}
