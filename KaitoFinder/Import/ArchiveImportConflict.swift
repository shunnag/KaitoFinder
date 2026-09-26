import Darwin
import Foundation
import GyoshukuKit
import KaitoKit

nonisolated struct ArchiveConflictDecision: Sendable {
    enum Choice: Sendable { case replace, skip }
    let choice: Choice
    var applyToRemaining = false
}

nonisolated struct ArchiveImportConflict: Sendable {
    typealias Resolver = @MainActor @Sendable (Self) async throws -> ArchiveConflictDecision
    let path: String
    let existing: ArchiveConflictItem
    let incoming: ArchiveConflictItem
    let remainingCount: Int

    // フォルダや型の違う項目を、通常ファイルへの一括指定で削除しない。
    var allowsBatchChoice: Bool {
        existing.kind == .file && incoming.kind == .file && existing.entryCount == 1
    }
}

nonisolated struct ArchiveConflictItem: Sendable {
    enum Source: Sendable {
        case file(URL)
        case archive(ArchiveEntryPayload)
    }
    let name: String
    let location: String
    let kind: EntryKind
    let size: UInt64?
    let modificationDate: Date?
    let entryCount: Int
    let source: Source?
    var stagingLease: StagingRegistry.ReadLease? = nil

    static func archived(_ entries: [ArchiveEntry], path: String, archive: URL, generation: UInt64) -> Self {
        let direct = entries.filter { normalized($0) == path }
        let directory = entries.contains { $0.kind == .directory || normalized($0) != path }
        let kind = directory ? EntryKind.directory : direct.first?.kind ?? .other
        let source: Source?
        if entries.count == 1, let entry = entries.first, entry.kind == .file, !entry.isIncomplete {
            source = .archive(ArchiveEntryPayload(archiveURL: archive, generation: generation,
                entryIndex: entry.index, path: entry.name, isDirectory: false))
        } else { source = nil }
        return Self(name: ArchivePath.components(path).last ?? path,
                    location: archive.lastPathComponent + "/" + path,
                    kind: kind, size: totalSize(entries.filter { $0.kind != .directory }.map(\.uncompressedSize)),
                    modificationDate: direct.first?.modificationDate,
                    entryCount: directory ? descendantCount(entries.map(normalized), below: path) : entries.count, source: source)
    }

    static func normalized(_ entry: ArchiveEntry) -> String {
        entry.pathComponents.drop(while: { $0 == "." }).joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    static func totalSize(_ sizes: [UInt64?]) -> UInt64? {
        var total: UInt64 = 0
        for size in sizes {
            guard let size else { return nil }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    static func descendantCount(_ paths: [String], below root: String) -> Int {
        let depth = ArchivePath.components(root).count
        // 仮想フォルダも一つとして数える。各 entry の全接頭辞を join し直すと
        // 深さの二乗に比例するため、共通成分を平坦な木へ一度だけ登録する。
        // 再帰的な参照型を使わず、深いパスの解放でもスタックを消費しない。
        var descendants: [[String: Int]] = [[:]]
        for path in paths {
            var parent = 0
            for part in ArchivePath.components(path).dropFirst(depth) {
                if let child = descendants[parent][part] { parent = child }
                else {
                    let child = descendants.count
                    descendants.append([:])
                    descendants[parent][part] = child
                    parent = child
                }
            }
        }
        return descendants.count - 1
    }
}

/// 確認中や圧縮中に元ファイルが差し替わったら、表示した情報への同意を流用しない。
nonisolated struct ArchiveImportSourceStamp: Sendable, Equatable {
    let url: URL
    private let identity: [Int64]
    let kind: EntryKind
    let size: UInt64
    let date: Date
    let permissions: UInt16
    let userID: UInt32
    let groupID: UInt32
    let hardLinkIdentity: [Int64]?

    init(_ url: URL) throws {
        self.url = url
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
        identity = Self.identity(info)
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        case S_IFREG: kind = .file
        default: kind = .other
        }
        size = UInt64(max(0, info.st_size))
        date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        permissions = UInt16(info.st_mode & 0o7777)
        userID = info.st_uid
        groupID = info.st_gid
        hardLinkIdentity = kind == .file && info.st_nlink > 1 ? Array(identity.prefix(2)) : nil
    }

    func verify() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, Self.identity(info) == identity else {
            throw ExtractionFailure.refused(String(localized: "確認中に追加元が変更されました。もう一度追加してください: \(url.lastPathComponent)。"))
        }
    }

    func verify(descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.identity(info) == identity else { throw ArchiveEntryPayload.staleSelection }
    }

    private static func identity(_ info: stat) -> [Int64] {
        [Int64(info.st_dev), Int64(bitPattern: info.st_ino), Int64(info.st_mode), info.st_size,
         Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
         Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }
}

/// 衝突の判断だけを行う。すべての回答が揃うまで updater を開かない。
nonisolated enum ArchiveConflictResolution {
    typealias ItemProvider = @Sendable ([ArchiveEntry], String) throws -> ArchiveConflictItem
    struct Candidate: Sendable {
        let path: String
        let info: ArchiveConflictItem
    }
    struct Result: Sendable {
        let accepted: [Int]
        let replaced: [ArchiveEntry]
    }

    static func existingGroups(_ entries: [ArchiveEntry], folder: String, matching: Set<String>? = nil) -> [String: [ArchiveEntry]] {
        let parent = ArchivePath.components(folder)
        let leaves = matching.map { Set($0.compactMap { ArchivePath.components($0).last }) }
        var groups: [String: [ArchiveEntry]] = [:]
        for entry in entries {
            let parts = Array(entry.pathComponents.drop(while: { $0 == "." }))
            guard parts.count > parent.count, parts.prefix(parent.count).elementsEqual(parent) else { continue }
            if let leaves, !leaves.contains(parts[parent.count]) { continue }
            let path = parts.prefix(parent.count + 1).joined(separator: "/").precomposedStringWithCanonicalMapping
            groups[path, default: []].append(entry)
        }
        return groups
    }

    @concurrent static func resolve(_ candidates: [Candidate], existing: [String: [ArchiveEntry]], archive: URL,
                        generation: UInt64, progress: Progress,
                        existingItems: [String: ArchiveConflictItem] = [:],
                        itemProvider: ItemProvider? = nil,
                        resolver: ArchiveImportConflict.Resolver) async throws -> Result {
        #if DEBUG
        var planning = ArchiveStageDiagnostics.begin(.planBuild)
        defer { planning?.end() }
        #endif
        var occupied = Set(existing.keys), remaining = 0
        for candidate in candidates {
            if !occupied.insert(candidate.path).inserted { remaining += 1 }
        }
        var accepted: [String: Int] = [:], replaced: [Int: ArchiveEntry] = [:]
        var batchChoice: ArchiveConflictDecision.Choice?
        for (index, candidate) in candidates.enumerated() {
            try ArchiveImportPlan.checkCancellation(progress)
            let previous = try accepted[candidate.path].map { candidates[$0].info }
                ?? existingItems[candidate.path] ?? existing[candidate.path].map {
                    try itemProvider?($0, candidate.path) ?? ArchiveConflictItem.archived($0, path: candidate.path, archive: archive, generation: generation)
                }
            if let previous {
                let conflict = ArchiveImportConflict(path: candidate.path, existing: previous, incoming: candidate.info,
                                                     remainingCount: remaining)
                let decision: ArchiveConflictDecision
                if conflict.allowsBatchChoice, let batchChoice { decision = .init(choice: batchChoice) }
                else {
                    // 確認 UI の待ち時間は計画の構築に含めない。
                    #if DEBUG
                    planning?.end()
                    planning = nil
                    #endif
                    decision = try await resolver(conflict)
                    #if DEBUG
                    planning = ArchiveStageDiagnostics.begin(.planBuild)
                    #endif
                }
                try ArchiveImportPlan.checkCancellation(progress)
                if decision.applyToRemaining, conflict.allowsBatchChoice { batchChoice = decision.choice }
                remaining -= 1
                if decision.choice == .skip { continue }
                for entry in existing[candidate.path] ?? [] { replaced[entry.index] = entry }
            }
            // 同じ追加操作の入力同士も同じ確認を通す。最後に採用した一つだけを書き込む。
            accepted[candidate.path] = index
        }
        return Result(accepted: accepted.values.sorted(), replaced: replaced.values.sorted { $0.index < $1.index })
    }
}

extension ArchiveImportPlan {
    @concurrent static func resolving(urls: [URL], folder: String, existing: [ArchiveEntry], archive: URL, generation: UInt64,
                          progress: Progress, options: Options, format: GyoshukuKit.ArchiveFormat = .zip,
                          existingItems: [String: ArchiveConflictItem] = [:],
                          itemProvider: ArchiveConflictResolution.ItemProvider? = nil,
                          occupancy: ArchivePathOccupancy.Overlay? = nil,
                          resolver: ArchiveImportConflict.Resolver) async throws -> Self {
        #if DEBUG
        var planning = ArchiveStageDiagnostics.begin(.planBuild)
        defer { planning?.end() }
        #endif
        let target = folder.isEmpty ? "" : try path(folder, format: format)
        // 既存と同じ規則で追加先の実在・ファイル祖先を検証する。
        _ = try build(urls: [], folder: target, existing: existing, progress: progress, options: options, format: format, occupancy: occupancy)
        var batches: [[Item]] = [], stamps: [[ArchiveImportSourceStamp]] = []
        var candidates: [ArchiveConflictResolution.Candidate] = [], failures: [Failure] = []
        for url in urls {
            let scanned = try build(urls: [url], folder: "", existing: [], progress: progress, options: options, format: format)
            failures.append(contentsOf: scanned.failures)
            guard let root = scanned.items.first else { continue }
            let items = scanned.items.map {
                Item(url: $0.url, path: target.isEmpty ? $0.path : target + "/" + $0.path, isDirectory: $0.isDirectory)
            }
            let identities = try items.map { try checkCancellation(progress); return try ArchiveImportSourceStamp($0.url) }
            let first = identities[0]
            let info = ArchiveConflictItem(name: url.lastPathComponent, location: url.deletingLastPathComponent().path,
                kind: first.kind, size: ArchiveConflictItem.totalSize(identities.filter { $0.kind != .directory }.map { $0.size }),
                modificationDate: first.date, entryCount: first.kind == .directory ? max(0, items.count - 1) : 1,
                source: first.kind == .file ? .file(root.url) : nil)
            candidates.append(.init(path: items[0].path, info: info))
            batches.append(items)
            stamps.append(identities)
        }
        guard failures.isEmpty else { return Self(failures: failures) }
        let groups = ArchiveConflictResolution.existingGroups(existing, folder: target, matching: Set(candidates.map(\.path)))
        #if DEBUG
        planning?.end()
        planning = nil
        #endif
        let result = try await ArchiveConflictResolution.resolve(candidates,
            existing: groups, archive: archive,
            generation: generation, progress: progress, existingItems: existingItems, itemProvider: itemProvider, resolver: resolver)
        #if DEBUG
        planning = ArchiveStageDiagnostics.begin(.planBuild)
        #endif
        return Self(items: result.accepted.flatMap { batches[$0] }, replacingEntries: result.replaced.map(\.index),
                    expectedEntries: existing, sourceStamps: result.accepted.flatMap { stamps[$0] })
    }
}
