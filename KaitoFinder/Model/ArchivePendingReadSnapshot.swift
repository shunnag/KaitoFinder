import Foundation
import KaitoKit
import Synchronization

/// 表示した版の origin と出力名。読み始める前だけ現行版と照合し、その後は値と lease を保持する。
nonisolated struct ArchivePendingReadSnapshot: Sendable {
    enum Source: Sendable {
        case base(ArchiveEntry)
        case staged(ArchivePendingChanges.PendingAddition)
        case folder
    }
    let generation: UInt64
    let revision: UInt64
    let nameSyntax: ExtractionPath.NameSyntax
    let base: [ArchiveEntry]
    var entries: [ArchiveEntry] { storage.value.entries }
    var sources: Sources { storage.value.sources }
    let staging: StagingRegistry.Lease?
    let stagedURLs: [URL]
    private var positions: [Int: Int] { storage.value.positions }
    private var pendingIndices: [UUID: Int] { storage.value.pendingIndices }
    var subtrees: ArchiveEntryPayload.SubtreeIndex { storage.value.subtrees }
    private let storage: Storage

    init(base: [ArchiveEntry], generation: UInt64, changes: ArchivePendingChanges,
         staging: StagingRegistry.Lease?, nameSyntax: ExtractionPath.NameSyntax, projection: ArchivePendingProjection? = nil,
         subtrees: ArchiveEntryPayload.SubtreeIndex? = nil) throws {
        self.base = base
        self.nameSyntax = nameSyntax
        self.generation = generation
        revision = changes.revision
        self.staging = staging
        stagedURLs = changes.additions.map(\.stagedURL)
        let projection = try projection ?? ArchivePendingProjection(changes.projection(base: base, generation: generation))
        storage = .ready(.init(base: base, changes: changes, projection: projection, nameSyntax: nameSyntax, subtrees: subtrees))
    }

    init(deferredBase base: [ArchiveEntry], generation: UInt64, changes: ArchivePendingChanges,
         staging: StagingRegistry.Lease?, nameSyntax: ExtractionPath.NameSyntax) throws {
        try changes.validate(base: base, generation: generation)
        self.base = base
        self.nameSyntax = nameSyntax
        self.generation = generation
        revision = changes.revision
        self.staging = staging
        stagedURLs = changes.additions.map(\.stagedURL)
        // Undo は版を即座に公開し、重い索引は読み取り worker が必要になった時だけ作る。
        storage = .deferred(.init(base: base, changes: changes, nameSyntax: nameSyntax))
    }

    private struct Contents: Sendable {
        let entries: [ArchiveEntry]
        let sources: Sources
        let positions: [Int: Int]
        let pendingIndices: [UUID: Int]
        let subtrees: ArchiveEntryPayload.SubtreeIndex

        init(base: [ArchiveEntry], changes: ArchivePendingChanges, projection: ArchivePendingProjection, nameSyntax: ExtractionPath.NameSyntax,
             subtrees: ArchiveEntryPayload.SubtreeIndex? = nil) {
            entries = projection.entries
            positions = projection.positions
            self.subtrees = subtrees ?? .init(entries: entries, syntax: nameSyntax)
            pendingIndices = Dictionary(uniqueKeysWithValues: entries.suffix(changes.additions.count + changes.createdFolders.count).compactMap { entry in
                entry.pendingID.map { ($0, entry.index) }
            })
            sources = Sources(base: base, positions: positions,
                additions: Dictionary(uniqueKeysWithValues: changes.additions.enumerated().map { (base.count + $0.offset, $0.element) }))
        }
    }

    private enum Storage: Sendable {
        case ready(Contents), deferred(DeferredContents)
        var value: Contents {
            switch self {
            case .ready(let value): value
            case .deferred(let value): value.contents
            }
        }
    }

    private final class DeferredContents: Sendable {
        let base: [ArchiveEntry]
        let changes: ArchivePendingChanges
        let nameSyntax: ExtractionPath.NameSyntax
        private let cached = Mutex<Contents?>(nil)
        init(base: [ArchiveEntry], changes: ArchivePendingChanges, nameSyntax: ExtractionPath.NameSyntax) {
            self.base = base
            self.changes = changes
            self.nameSyntax = nameSyntax
        }
        var contents: Contents {
            cached.withLock { value in
                if let value { return value }
                let result = Contents(base: base, changes: changes,
                    projection: .init(changes.projection(validatedBase: base)), nameSyntax: nameSyntax)
                value = result
                return result
            }
        }
    }

    struct Sources: Sendable {
        let base: [ArchiveEntry]
        let positions: [Int: Int]
        let additions: [Int: ArchivePendingChanges.PendingAddition]
        subscript(index: Int) -> Source? {
            guard positions[index] != nil else { return nil }
            if base.indices.contains(index) { return .base(base[index]) }
            return additions[index].map(Source.staged) ?? .folder
        }
    }

    private func entry(at index: Int) -> ArchiveEntry? { positions[index].map { entries[$0] } }

    func origin(for entry: ArchiveEntry) -> ArchiveEntryPayload.Origin? {
        // 初回表示のサムネイル照会では、全件の読み取り索引を main で作らない。
        if case .deferred(let contents) = storage, contents.changes.isEmpty {
            guard base.indices.contains(entry.index), base[entry.index] == entry else { return nil }
            return .base(index: entry.index, expectedName: entry.name, baseGeneration: generation)
        }
        guard self.entry(at: entry.index) == entry else { return nil }
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
            anchor = entry(at: index)
        case .pending(let id): anchor = pendingIndices[id].flatMap { entry(at: $0) }
        }
        guard let anchor, self.origin(for: anchor) == origin else { throw ArchiveEntryPayload.staleSelection }
        if payload.isDirectory {
            let components = (try? ExtractionPath.components(payload.path, syntax: nameSyntax)) ?? Array(ArchivePath.components(payload.path).drop(while: { $0 == "." }))
            let selected = subtrees.subtree(for: components)
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
