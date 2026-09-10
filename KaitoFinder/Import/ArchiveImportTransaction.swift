import Darwin
import Foundation
import GyoshukuKit
import KaitoKit

nonisolated struct ArchiveImportResult: Sendable {
    let addedPaths: [String]
    let failures: [ArchiveImportPlan.Failure]
    var reloadFailure: String?
}

nonisolated enum ArchiveEditError: Error, Equatable, LocalizedError {
    case invalidName(String)
    case collision(String)
    case indexMismatch(Int)
    case staleSelection
    case conflictingSelection

    var errorDescription: String? {
        switch self {
        case .invalidName(let name): "この名前には変更できません: \(name)"
        case .collision(let name): "同じ名前の項目が既にあります: \(name)"
        case .indexMismatch: "選択した項目と書庫内の項目が一致しません。書庫を開き直してください"
        case .staleSelection: "選択した項目が変更されています。書庫を開き直してください"
        case .conflictingSelection: "同じ項目への変更が重複しています"
        }
    }
}

nonisolated struct ArchiveEditSelection: Sendable {
    let path: String
    let isDirectory: Bool
    let entries: [ArchiveEntry]

    @MainActor init(_ node: EntryNode) {
        path = node.path
        isDirectory = node.isDirectory
        // representedEntries の重複した directory record も、既存の部分木収集で拾う。
        entries = ExtractionSelection(nodes: [node]).entries
    }
}

nonisolated struct ArchiveEditRename: Sendable {
    let selection: ArchiveEditSelection
    let name: String
}

nonisolated struct ArchiveEditResult: Sendable {
    let removedPaths: [String]
    let renamedPaths: [String]
    var reloadFailure: String?
    var published: Bool { !removedPaths.isEmpty || !renamedPaths.isEmpty }
}

nonisolated struct ArchiveEditPlan: Sendable {
    struct Entry: Sendable {
        let index: Int
        let expectedName: String
        let isDirectory: Bool

        init(index: Int, expectedName: String, isDirectory: Bool) {
            self.index = index
            self.expectedName = expectedName
            self.isDirectory = isDirectory
        }

        init(_ entry: ArchiveEntry) {
            self.init(index: entry.index, expectedName: entry.name, isDirectory: entry.kind == .directory)
        }
    }

    struct Rename: Sendable {
        let entry: Entry
        let path: String
    }

    let removals: [Entry]
    let renames: [Rename]
    let existing: [ArchiveEntry]

    static func build(removing selections: [ArchiveEditSelection], renaming: [ArchiveEditRename],
                      existing: [ArchiveEntry]) throws -> Self {
        var removed: [Int: Entry] = [:]
        for selection in selections {
            try validate(selection, existing: existing)
            for entry in selection.entries { removed[entry.index] = Entry(entry) }
        }
        var renamed: Set<Int> = [], destinations: Set<String> = [], changes: [Rename] = []
        for change in renaming {
            let selection = change.selection
            try validate(selection, existing: existing)
            let leaf = try leafName(change.name)
            let parent = selection.path.split(separator: "/").dropLast().joined(separator: "/")
            let destination = parent.isEmpty ? leaf : parent + "/" + leaf
            let indices = Set(selection.entries.map(\.index))
            guard indices.isDisjoint(with: removed.keys), indices.isDisjoint(with: renamed) else {
                throw ArchiveEditError.conflictingSelection
            }
            renamed.formUnion(indices)
            guard destinations.insert(key(destination)).inserted else { throw ArchiveEditError.collision(destination) }
            // 子だけを持つ仮想フォルダも占有済み。別のフォルダへの暗黙の併合を防ぐ。
            for entry in existing where removed[entry.index] == nil && !indices.contains(entry.index) {
                let components = key(entry.name).split(separator: "/", omittingEmptySubsequences: false)
                for count in 1...max(1, components.count) {
                    if components.prefix(count).joined(separator: "/") == key(destination) {
                        throw ArchiveEditError.collision(destination)
                    }
                }
            }
            for entry in selection.entries {
                let path: String
                if selection.isDirectory {
                    let prefix = selection.path + "/"
                    if key(entry.name) == key(selection.path) {
                        path = destination + (entry.kind == .directory ? "/" : "")
                    } else {
                        // tree が同じフォルダとして束ねる正準等価の接頭辞も、一緒に書き換える。
                        guard entry.name.hasPrefix(prefix) else { throw ArchiveEditError.staleSelection }
                        path = destination + "/" + entry.name.dropFirst(prefix.count)
                    }
                } else { path = destination }
                let normalized = try normalizedPath(path, directory: entry.kind == .directory)
                if !entry.name.utf8.elementsEqual(normalized.utf8) {
                    changes.append(Rename(entry: Entry(entry), path: normalized))
                }
            }
        }
        let plan = Self(removals: removed.values.sorted { $0.index < $1.index }, renames: changes, existing: existing)
        try plan.validate(entries: existing)
        return plan
    }

    private static func validate(_ selection: ArchiveEditSelection, existing: [ArchiveEntry]) throws {
        guard !selection.path.isEmpty, !selection.entries.isEmpty else { throw ArchiveEditError.staleSelection }
        for entry in selection.entries { try validate(Entry(entry), entries: existing) }
        if selection.isDirectory {
            let components = selection.path.split(separator: "/").map(String.init)
            let current = Set(existing.filter {
                let parts = $0.pathComponents.drop(while: { $0 == "." })
                return parts.starts(with: components) && (parts.count > components.count || $0.kind == .directory)
            }.map(\.index))
            // 選択後に子が増えた場合も、古い部分木だけを削除して孤児を残さない。
            guard current == Set(selection.entries.map(\.index)) else { throw ArchiveEditError.staleSelection }
        }
    }

    private static func validate(_ entry: Entry, entries: [ArchiveEntry]) throws {
        guard entries.indices.contains(entry.index), entries[entry.index].index == entry.index,
              entries[entry.index].name.utf8.elementsEqual(entry.expectedName.utf8),
              (entries[entry.index].kind == .directory) == entry.isDirectory else {
            throw ArchiveEditError.indexMismatch(entry.index)
        }
    }

    func validate(entries: [ArchiveEntry]) throws {
        for entry in removals + renames.map(\.entry) { try Self.validate(entry, entries: entries) }
        try validateChanges(entries: entries)
    }

    func validateChanges(entries: [ArchiveEntry]) throws {
        let removed = Set(removals.map(\.index))
        var names: [Int: String] = [:], renamed: Set<Int> = []
        for change in renames {
            guard !removed.contains(change.entry.index), renamed.insert(change.entry.index).inserted else {
                throw ArchiveEditError.conflictingSelection
            }
            let path = try Self.normalizedPath(change.path, directory: change.entry.isDirectory)
            let key = Self.key(path)
            // updater は予約順で衝突を調べる。最終形だけでなく途中の全予約も先に検証する。
            for other in entries where other.index != change.entry.index && !removed.contains(other.index) {
                let otherKey = Self.key(names[other.index] ?? other.name)
                guard key != otherKey,
                      !(!change.entry.isDirectory && otherKey.hasPrefix(key + "/")),
                      !(other.kind != .directory && key.hasPrefix(otherKey + "/")) else {
                    throw ArchiveEditError.collision(path)
                }
            }
            names[change.entry.index] = path
        }
    }

    func verifyNames(_ names: [String]) throws {
        // Swift の == は正準等価を許す。ここでは正規化せず、二つの open の相違を検出する。
        for entry in removals + renames.map(\.entry) {
            guard names.indices.contains(entry.index), names[entry.index].utf8.elementsEqual(entry.expectedName.utf8) else {
                throw ArchiveEditError.indexMismatch(entry.index)
            }
        }
        try Self.verifyNames(names, existing: existing)
    }

    fileprivate static func verifyNames(_ names: [String], existing: [ArchiveEntry]) throws {
        // 選択外に子や同名の兄弟が増えていても、古い一覧による検証を使い回さない。
        guard names.count == existing.count,
              zip(names, existing).allSatisfy({ $0.utf8.elementsEqual($1.name.utf8) }) else {
            throw ArchiveEditError.staleSelection
        }
    }

    fileprivate static func key(_ path: String) -> String {
        (path.hasSuffix("/") ? String(path.dropLast()) : path).precomposedStringWithCanonicalMapping
    }

    fileprivate static func leafName(_ name: String) throws -> String {
        guard !name.contains("/") else { throw ArchiveEditError.invalidName(name) }
        return try normalizedPath(name, directory: false)
    }

    fileprivate static func normalizedPath(_ path: String, directory: Bool) throws -> String {
        var name = path.precomposedStringWithCanonicalMapping
        if directory && !name.hasSuffix("/") { name += "/" }
        let body = directory ? String(name.dropLast()) : name
        let parts = body.split(separator: "/", omittingEmptySubsequences: false)
        // writer と同じ制約を公開前に説明する。長い親パスを含む子孫も例外にしない。
        guard !body.isEmpty, !body.contains("\0"), !body.contains("\\"), !body.contains(":"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              name.utf8.count <= Int(UInt16.max) else { throw ArchiveEditError.invalidName(path) }
        return name
    }
}

nonisolated struct ArchiveNewFolderPlan: Sendable {
    let path: String
    let existing: [ArchiveEntry]

    static func build(in folder: String, baseName: String, existing: [ArchiveEntry]) throws -> Self {
        let base = try ArchiveEditPlan.leafName(baseName)
        let parent = folder.isEmpty ? "" : try ArchiveEditPlan.normalizedPath(folder, directory: false)
        var occupied: Set<String> = [], directories: Set<String> = [], files: Set<String> = []
        for entry in existing {
            let parts = ArchiveEditPlan.key(entry.name).split(separator: "/", omittingEmptySubsequences: false)
            for count in 1...parts.count {
                let path = parts.prefix(count).joined(separator: "/")
                occupied.insert(path)
                if count < parts.count || entry.kind == .directory { directories.insert(path) }
                else { files.insert(path) }
            }
        }
        if !parent.isEmpty {
            guard directories.contains(parent) else { throw ArchiveEditError.staleSelection }
            let parts = parent.split(separator: "/")
            for count in 1...parts.count {
                let path = parts.prefix(count).joined(separator: "/")
                guard !files.contains(path) else { throw ArchiveEditError.collision(path) }
            }
        }
        var name = base, number = 2
        while true {
            let path = try ArchiveEditPlan.normalizedPath(parent.isEmpty ? name : parent + "/" + name, directory: true)
            if !occupied.contains(ArchiveEditPlan.key(path)) { return Self(path: path, existing: existing) }
            // 仮想フォルダや表示から隠れた兄弟も予約済み。Finder と同じ空白付き連番で避ける。
            name = String(localized: "\(base) \(number)")
            number += 1
        }
    }
}

nonisolated enum ArchiveEditTransaction {
    static func run(plan: ArchiveEditPlan, archive: URL, progress: Progress,
                    willOpenUpdater: (@Sendable () throws -> Void)? = nil,
                    willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveEditResult {
        guard !plan.removals.isEmpty || !plan.renames.isEmpty else {
            return ArchiveEditResult(removedPaths: [], renamedPaths: [])
        }
        progress.totalUnitCount = Int64(plan.removals.count + plan.renames.count + 1)
        progress.completedUnitCount = 0
        try ArchiveImportTransaction.publish(archive: archive, progress: progress,
                                             willOpenUpdater: willOpenUpdater, willPublish: willPublish) { updater in
            // 別 reader での照合では updater の index を証明できない。予約前に本人の一覧と照合する。
            try plan.verifyNames(updater.entryNames)
            try plan.validateChanges(entries: plan.existing)
            try ArchiveImportPlan.checkCancellation(progress)
            if !plan.removals.isEmpty {
                try updater.remove(entriesAt: plan.removals.map(\.index))
                progress.completedUnitCount += Int64(plan.removals.count)
            }
            for change in plan.renames {
                try ArchiveImportPlan.checkCancellation(progress)
                try updater.rename(entryAt: change.entry.index, to: change.path)
                progress.completedUnitCount += 1
            }
        }
        return ArchiveEditResult(removedPaths: plan.removals.map(\.expectedName), renamedPaths: plan.renames.map(\.path))
    }
}

/// session の actor 内だけで実行する。書庫の原本へ書くのは最後の rename 一回だけ。
nonisolated enum ArchiveImportTransaction {
    static func createFolder(plan: ArchiveNewFolderPlan, archive: URL, progress: Progress,
                             willOpenUpdater: (@Sendable () throws -> Void)? = nil,
                             willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveImportResult {
        progress.totalUnitCount = 2
        progress.completedUnitCount = 0
        try publish(archive: archive, progress: progress, willOpenUpdater: willOpenUpdater, willPublish: willPublish) { updater in
            try ArchiveEditPlan.verifyNames(updater.entryNames, existing: plan.existing)
            try ArchiveImportPlan.checkCancellation(progress)
            try updater.addDirectory(plan.path)
            progress.completedUnitCount += 1
        }
        return ArchiveImportResult(addedPaths: [plan.path], failures: [])
    }

    // phase hook は同じ worker 上で呼び、取消し・障害の境界を XCTest で再現する。
    static func run(plan: ArchiveImportPlan, archive: URL, progress: Progress,
                    didProcess: (@Sendable (Int) throws -> Void)? = nil,
                    willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveImportResult {
        guard plan.failures.isEmpty, !plan.items.isEmpty else {
            return ArchiveImportResult(addedPaths: [], failures: plan.failures)
        }
        progress.totalUnitCount = Int64(plan.items.count + 1)
        progress.completedUnitCount = 0
        try publish(archive: archive, progress: progress, willPublish: willPublish) { updater in
            for (index, item) in plan.items.enumerated() {
                try ArchiveImportPlan.checkCancellation(progress)
                // add(contentsOf:) のディレクトリ再帰は使わず、一項目ごとに取消しを確認する。
                do {
                    if item.isDirectory { try updater.addDirectory(item.path) }
                    else { try updater.add(contentsOf: item.url, as: item.path) }
                }
                catch { throw ExtractionFailure.refused("\(item.path): \(error)") }
                progress.completedUnitCount += 1
                try didProcess?(index)
            }
        }
        return ArchiveImportResult(addedPaths: plan.items.map(\.path), failures: [])
    }

    // 追加・削除・改名で公開境界を共有し、undo が退避する原本を必ず一致させる。
    static func publish(archive: URL, progress: Progress,
                        willOpenUpdater: (@Sendable () throws -> Void)? = nil,
                        willPublish: (@Sendable () throws -> Void)?,
                        mutate: (ArchiveUpdater) throws -> Void) throws {
        try ArchiveImportPlan.checkCancellation(progress)
        let original = try identity(archive)
        let directory = archive.deletingLastPathComponent().appendingPathComponent(".KaitoFinder-add-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = directory.appendingPathComponent("archive.zip")
        try FileManager.default.copyItem(at: archive, to: work)
        try willOpenUpdater?()
        let updater = try ArchiveUpdater.open(url: work)
        try mutate(updater)
        try ArchiveImportPlan.checkCancellation(progress)
        // commit の属性復元が失敗しても、変わるのは作業コピーだけ。
        try updater.commit()
        _ = try ArchiveReader.open(url: work)
        try willPublish?()
        try ArchiveImportPlan.checkCancellation(progress)
        guard try identity(archive) == original else {
            throw ExtractionFailure.refused("処理中に書庫が別の操作で変更されました")
        }
        // copyItem と updater が保持した属性も含め、同一ボリュームで一括公開する。
        // ここが取消しの境界。成功後に取消しとして返してはならない。
        guard rename(work.path, archive.path) == 0 else { throw ExtractionFailure.system(errno) }
        progress.completedUnitCount += 1
    }

    private static func identity(_ url: URL) throws -> [Int64] {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ExtractionFailure.refused("書庫の原本を確認できません")
        }
        return [Int64(info.st_dev), Int64(bitPattern: info.st_ino), info.st_size, Int64(info.st_mode),
                Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }
}
