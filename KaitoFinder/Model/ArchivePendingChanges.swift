import Foundation
import KaitoKit
import GyoshukuKit

/// index は基底の世代と名前を伴って初めて参照として使える。
nonisolated struct ArchivePendingChanges: Sendable, Equatable {
    struct BaseReference: Sendable, Hashable {
        let index: Int
        let expectedName: String
        let baseGeneration: UInt64
    }
    struct PendingAddition: Sendable, Equatable {
        let id: UUID
        var path: String
        let stagedURL: URL
        let sourceStamp: ArchiveImportSourceStamp
        let stagedStamp: ArchiveImportSourceStamp
        // 即時追加の addDirectory と同じ 0755。保存待ちで日時が動かないよう予約時に確定する。
        var reservedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var savedDate: Date {
            sourceStamp.kind == .directory ? reservedAt
                : Date(timeIntervalSince1970: floor(sourceStamp.date.timeIntervalSince1970))
        }
        var savedPermissions: UInt16 {
            sourceStamp.kind == .directory || sourceStamp.kind == .symlink ? 0o755 : sourceStamp.permissions
        }
    }
    struct CreatedFolder: Sendable, Equatable {
        let id: UUID
        var path: String
        var date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    }
    var removals: Set<BaseReference> = []
    var renames: [BaseReference: String] = [:]
    var additions: [PendingAddition] = []
    var createdFolders: [CreatedFolder] = []
    var outputEncryption: ArchiveEncryptionSettings?
    var revision: UInt64 = 0

    var count: Int { removals.count + renames.count + additions.count + createdFolders.count + (outputEncryption == nil ? 0 : 1) }
    var isEmpty: Bool { count == 0 }

    var hasEffectiveChanges: Bool {
        !removals.isEmpty || !additions.isEmpty || !createdFolders.isEmpty || outputEncryption != nil ||
            renames.contains { ArchiveEditPlan.key($0.key.expectedName) != ArchiveEditPlan.key($0.value) }
    }

    @concurrent func requiresReplay(base: [ArchiveEntry], generation: UInt64) async throws -> Bool {
        try validate(base: base, generation: generation)
        return hasEffectiveChanges
    }

    func validate(base: [ArchiveEntry], generation: UInt64) throws {
        for reference in removals.union(renames.keys) {
            guard reference.baseGeneration == generation else { throw ArchiveEditError.staleSelection }
            guard base.indices.contains(reference.index), base[reference.index].index == reference.index,
                  base[reference.index].name.utf8.elementsEqual(reference.expectedName.utf8) else {
                throw ArchiveEditError.indexMismatch(reference.index)
            }
        }
    }

    func projection(base: [ArchiveEntry], generation: UInt64) throws -> [ArchiveEntry] {
        try validate(base: base, generation: generation)
        return projection(validatedBase: base)
    }

    func projection(validatedBase base: [ArchiveEntry]) -> [ArchiveEntry] {
        if removals.isEmpty, renames.isEmpty, additions.isEmpty, createdFolders.isEmpty { return base }
        let removed = Set(removals.map(\.index))
        let names = Dictionary(uniqueKeysWithValues: renames.map { ($0.key.index, $0.value) })
        var result: [ArchiveEntry] = []
        result.reserveCapacity(base.count - removed.count + additions.count + createdFolders.count)
        for entry in base where !removed.contains(entry.index) {
            // planner が子孫も明示的に予約する。名前から祖先の改名を再適用しない。
            let path = names[entry.index] ?? entry.name
            result.append(path.utf8.elementsEqual(entry.name.utf8) ? entry : entry.pendingCopy(name: path))
        }
        for (offset, addition) in additions.enumerated() {
            let stamp = addition.sourceStamp
            result.append(Self.synthetic(index: base.count + offset, id: addition.id,
                path: addition.path, kind: stamp.kind, size: stamp.kind == .directory ? 0 : stamp.size,
                date: addition.savedDate, permissions: addition.savedPermissions))
        }
        for (offset, folder) in createdFolders.enumerated() {
            result.append(Self.synthetic(index: base.count + additions.count + offset,
                id: folder.id, path: folder.path, kind: .directory, size: 0, date: folder.date, permissions: 0o755))
        }
        return result
    }

    private static func synthetic(index: Int, id: UUID, path: String, kind: EntryKind,
                                  size: UInt64, date: Date?, permissions: UInt16? = nil) -> ArchiveEntry {
        let name = kind == .directory && !path.hasSuffix("/") ? path + "/" : path
        return ArchiveEntry(index: index, rawName: RawName(bytes: Array(name.utf8)), name: name,
            pathComponents: ArchivePath.components(name), kind: kind, uncompressedSize: size, compressedSize: nil,
            modificationDate: date, posixPermissions: permissions, isEncrypted: false, solidGroup: -1, crc32: nil,
            methodDescription: "", formatSpecific: ["kaitofinder.pending": id.uuidString])
    }
}

nonisolated extension ArchiveEntry {
    var pendingID: UUID? { formatSpecific["kaitofinder.pending"].flatMap(UUID.init(uuidString:)) }

    func pendingCopy(index: Int? = nil, name: String? = nil, kind: EntryKind? = nil,
                     formatSpecific: [String: String]? = nil) -> ArchiveEntry {
        let path = name ?? self.name
        if index == nil, name == nil, kind == nil, formatSpecific == nil { return self }
        return ArchiveEntry(index: index ?? self.index, rawName: rawName, name: path,
            pathComponents: name == nil || path.utf8.elementsEqual(self.name.utf8) ? pathComponents : ArchivePath.components(path),
            kind: kind ?? self.kind, uncompressedSize: uncompressedSize,
            compressedSize: compressedSize, modificationDate: modificationDate, posixPermissions: posixPermissions,
            isEncrypted: isEncrypted, solidGroup: solidGroup, crc32: crc32, methodDescription: methodDescription,
            formatSpecific: formatSpecific ?? self.formatSpecific, isIncomplete: isIncomplete)
    }
}

/// 既存 planner だけに連続 index を渡し、結果は表示の origin へ必ず戻す。
nonisolated struct ArchivePendingProjection: Sendable {
    let entries: [ArchiveEntry]
    let planningEntries: [ArchiveEntry]
    let positions: [Int: Int]

    init(_ entries: [ArchiveEntry]) {
        self.entries = entries
        planningEntries = entries.enumerated().allSatisfy { $0.offset == $0.element.index } ? entries
            : entries.enumerated().map { $0.element.pendingCopy(index: $0.offset) }
        positions = Dictionary(uniqueKeysWithValues: entries.lazy.enumerated().map { ($0.element.index, $0.offset) })
    }

    func selection(_ selection: ArchiveEditSelection) throws -> ArchiveEditSelection {
        let mapped = try selection.entries.map { entry in
            guard let position = positions[entry.index], entries[position] == entry else { throw ArchiveEditError.staleSelection }
            return planningEntries[position]
        }
        return .init(path: selection.path, isDirectory: selection.isDirectory, entries: mapped)
    }
}

@MainActor final class ArchivePendingEditor {
    private(set) var changes = ArchivePendingChanges()
    private(set) var base: [ArchiveEntry] = []
    private(set) var baseGeneration: UInt64?
    private(set) var baseSession: ObjectIdentifier?
    private(set) var validation: ArchiveReservationValidation?
    private(set) var prepared: ArchiveReservationState?
    private(set) var staging: StagingRegistry.Lease?
    private(set) var stagingTask: Task<[ArchivePendingChanges.PendingAddition], Error>?
    private var batches: [URL] = []
    var stagingCheckpoint: Int { batches.count }
    // 大きな別 volume のコピーも、取消し境界を決定的に試験する。
    var allowsClone = true
    var didCopyStagingBytes: (@Sendable (Int) -> Void)?
    let registry: StagingRegistry

    init(registry: StagingRegistry = .shared) { self.registry = registry }

    func install(base: [ArchiveEntry], generation: UInt64, format: GyoshukuKit.ArchiveFormat = .zip,
                 sessionID: ObjectIdentifier? = nil, checksCancellation: Bool = true) async throws {
        if let baseGeneration, baseGeneration != generation, !changes.isEmpty { throw ArchiveEditError.staleSelection }
        if baseGeneration == generation, baseSession == sessionID, validation?.format == format { return }
        let revision = changes.revision
        var validation: ArchiveReservationValidation? = await Self.makeValidation(base: base, format: format)
        defer { ArchiveBackgroundRelease.release(&validation) }
        if checksCancellation { try Task.checkCancellation() }
        guard changes.revision == revision else { throw ArchiveEditError.staleSelection }
        try changes.validate(base: base, generation: generation)
        var retired = Optional((self.base, self.validation, prepared))
        self.base = base
        baseGeneration = generation
        baseSession = sessionID
        self.validation = validation
        prepared = nil
        ArchiveBackgroundRelease.release(&retired)
    }

    @concurrent private static func makeValidation(base: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat) async -> ArchiveReservationValidation {
        ArchiveReservationDiagnostics.record(.baseValidation)
        return ArchiveReservationValidation(base: base, format: format)
    }

    func prepare(generation: UInt64, filters: Set<EntryTreeFilter.Configuration> = [], baseTree: EntryNode? = nil,
                 checksCancellation: Bool = true) async throws -> ArchiveReservationState {
        guard baseGeneration == generation, let validation else { throw ArchiveEditError.staleSelection }
        if let prepared, prepared.revision == changes.revision, filters.isSubset(of: Set(prepared.filters.keys)) { return prepared }
        let revision = changes.revision, sessionID = baseSession
        var next: ArchiveReservationState? = try await ArchiveReservationState.build(base: base, generation: generation, changes: changes,
                                                           validation: validation, staging: staging, previous: changes,
                                                           reusing: prepared, baseTree: baseTree, filters: filters, checksCancellation: checksCancellation)
        defer { ArchiveBackgroundRelease.release(&next) }
        guard baseGeneration == generation, baseSession == sessionID, changes.revision == revision else { throw ArchiveEditError.staleSelection }
        ArchiveBackgroundRelease.release(&prepared)
        prepared = next
        return next!
    }

    func projection(generation: UInt64) throws -> ArchivePendingProjection {
        if let baseGeneration, baseGeneration != generation { throw ArchiveEditError.staleSelection }
        if let prepared, prepared.revision == changes.revision { return prepared.projection }
        return try ArchivePendingProjection(changes.projection(base: base, generation: generation))
    }

    func replace(_ value: ArchivePendingChanges, prepared: ArchiveReservationState? = nil) {
        let revision = changes.revision &+ 1
        changes = value
        changes.revision = revision
        ArchiveBackgroundRelease.release(&self.prepared)
        self.prepared = prepared
    }

    func stage(_ items: [ArchiveImportPlan.Item], sourceStamps: [ArchiveImportSourceStamp] = [], progress: Progress) async throws -> [ArchivePendingChanges.PendingAddition] {
        if staging == nil { staging = try registry.create(id: UUID()) }
        let lease = staging!
        let directory = lease.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let allowsClone = allowsClone, didCopy = didCopyStagingBytes
        let task = Task { try await Self.stage(items, sourceStamps: sourceStamps, in: directory, progress: progress,
                                               allowsClone: allowsClone, didCopy: didCopy) }
        stagingTask = task
        defer { stagingTask = nil }
        do {
            let additions = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try ArchiveImportPlan.checkCancellation(progress)
            guard staging === lease else { throw CancellationError() }
            batches.append(directory)
            return additions
        } catch {
            try? await StagingRegistry.removeSnapshotInBackground(directory)
            if staging === lease, batches.isEmpty {
                staging = nil
                await lease.removeWhenUnused()
            }
            throw error
        }
    }

    @concurrent private static func stage(_ items: [ArchiveImportPlan.Item], sourceStamps: [ArchiveImportSourceStamp], in directory: URL,
                                         progress: Progress, allowsClone: Bool,
                                         didCopy: (@Sendable (Int) -> Void)?) async throws -> [ArchivePendingChanges.PendingAddition] {
        ArchiveReservationDiagnostics.record(.sourceVerification)
        for stamp in sourceStamps { try ArchiveImportPlan.checkCancellation(progress); try stamp.verify() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var result: [ArchivePendingChanges.PendingAddition] = []
        for item in items {
            try ArchiveImportPlan.checkCancellation(progress)
            let id = UUID(), stamp = try ArchiveImportSourceStamp(item.url)
            let itemDirectory = directory.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: itemDirectory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let target = itemDirectory.appendingPathComponent(item.url.lastPathComponent)
            try StagingRegistry.copySnapshot(from: item.url, to: target, isDirectory: item.isDirectory,
                                            progress: progress, allowsClone: allowsClone, didCopy: didCopy)
            try stamp.verify()
            result.append(.init(id: id, path: item.path, stagedURL: target, sourceStamp: stamp,
                                stagedStamp: try ArchiveImportSourceStamp(target)))
        }
        for stamp in sourceStamps { try ArchiveImportPlan.checkCancellation(progress); try stamp.verify() }
        return result
    }

    func cancelStaging() { stagingTask?.cancel() }

    func discardStaging(after checkpoint: Int) async {
        let discarded = Array(batches.dropFirst(checkpoint))
        batches.removeLast(discarded.count)
        for directory in discarded { try? await StagingRegistry.removeSnapshotInBackground(directory) }
        if batches.isEmpty, stagingTask == nil, let lease = staging {
            staging = nil
            await lease.removeWhenUnused()
        }
    }

    func applying(_ plan: ArchiveEditPlan, projection: ArchivePendingProjection) throws -> ArchivePendingChanges {
        guard let generation = baseGeneration else { throw ArchiveEditError.staleSelection }
        return Self.applying(plan, projection: projection, changes: changes, base: base, generation: generation)
    }

    nonisolated static func applying(_ plan: ArchiveEditPlan, projection: ArchivePendingProjection,
                                    changes: ArchivePendingChanges, base: [ArchiveEntry], generation: UInt64) -> ArchivePendingChanges {
        var next = changes
        func reference(_ entry: ArchiveEntry) -> ArchivePendingChanges.BaseReference {
            .init(index: entry.index, expectedName: base[entry.index].name, baseGeneration: generation)
        }
        var removedIDs: Set<UUID> = []
        for removal in plan.removals {
            let origin = projection.entries[removal.index]
            if let id = origin.pendingID {
                removedIDs.insert(id)
            } else {
                next.removals.insert(reference(origin))
                next.renames.removeValue(forKey: reference(origin))
            }
        }
        if !removedIDs.isEmpty {
            next.additions.removeAll { removedIDs.contains($0.id) }
            next.createdFolders.removeAll { removedIDs.contains($0.id) }
        }
        let additionPositions = Dictionary(uniqueKeysWithValues: next.additions.enumerated().map { ($0.element.id, $0.offset) })
        let folderPositions = Dictionary(uniqueKeysWithValues: next.createdFolders.enumerated().map { ($0.element.id, $0.offset) })
        for rename in plan.renames {
            let origin = projection.entries[rename.entry.index]
            if let id = origin.pendingID {
                if let index = additionPositions[id] { next.additions[index].path = rename.path }
                if let index = folderPositions[id] { next.createdFolders[index].path = rename.path }
            } else {
                let ref = reference(origin)
                next.renames[ref] = rename.path
            }
        }
        return next
    }

    // 履歴が参照する staging はここまで保持し、文書の cleanup が書き込み完了後に解放する。
    func reset() -> StagingRegistry.Lease? {
        let old = staging
        staging = nil
        batches.removeAll()
        replace(ArchivePendingChanges())
        var retired = Optional((base, validation))
        base = []
        validation = nil
        ArchiveBackgroundRelease.release(&retired)
        baseGeneration = nil
        baseSession = nil
        return old
    }
}
