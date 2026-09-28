import Foundation
import GyoshukuKit
import KaitoKit

nonisolated struct ArchiveEditSelection: Sendable {
    let path: String
    let isDirectory: Bool
    let entries: [ArchiveEntry]

    init(path: String, isDirectory: Bool, entries: [ArchiveEntry]) {
        self.path = path
        self.isDirectory = isDirectory
        self.entries = entries
    }

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

nonisolated struct ArchiveEditMove: Sendable {
    let selection: ArchiveEditSelection
    let folder: String
}

nonisolated struct ArchiveEditResult: Sendable {
    let removedPaths: [String]
    let renamedPaths: [String]
    var reloadFailure: String?
    var publishedIdentity: ArchiveSetIdentity?
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
    let format: GyoshukuKit.ArchiveFormat

    init(removals: [Entry], renames: [Rename], existing: [ArchiveEntry], format: GyoshukuKit.ArchiveFormat = .zip) {
        self.removals = removals
        self.renames = renames
        self.existing = existing
        self.format = format
    }

    static func build(removing selections: [ArchiveEditSelection], renaming: [ArchiveEditRename],
                      moving: [ArchiveEditMove] = [], existing: [ArchiveEntry],
                      format: GyoshukuKit.ArchiveFormat = .zip,
                      occupancy cached: ArchivePathOccupancy.Overlay? = nil) throws -> Self {
        // 実体のない親フォルダも移動先になる。ファイルを親として扱うことはない。
        var folders: Set<String> = [], files: Set<String> = []
        if !moving.isEmpty, cached == nil {
            for entry in existing {
                let path = key(entry.name)
                let parts = ArchivePath.components(path)
                if entry.kind == .directory { folders.insert(path) }
                else { files.insert(path) }
                for count in 1..<max(1, parts.count) {
                    folders.insert(parts.prefix(count).joined(separator: "/"))
                }
            }
        }
        let moves = try moving.map { move in
            let source = key(move.selection.path), folder = key(move.folder)
            let parent = ArchivePath.components(source).dropLast().joined(separator: "/")
            guard parent != folder else { throw ArchiveEditError.sameLocation(move.selection.path) }
            if move.selection.isDirectory, folder == source || ArchivePath.isDescendant(folder, of: source) {
                throw ArchiveEditError.destinationInsideSource(move.selection.path)
            }
            if !folder.isEmpty {
                let parts = ArchivePath.components(folder)
                guard cached?.isFolder(folder) ?? (folders.contains(folder) && !(1...max(1, parts.count)).contains(where: {
                    files.contains(parts.prefix($0).joined(separator: "/"))
                })) else { throw ArchiveEditError.missingFolder(move.folder) }
            }
            let leaf = ArchivePath.components(source).last ?? ""
            return (selection: move.selection, destination: folder.isEmpty ? leaf : folder + "/" + leaf)
        }
        let hasFolders = (selections + renaming.map(\.selection) + moving.map(\.selection)).contains { $0.isDirectory }
        // 抽出と同じ索引を使うが、成分は EntryNode の表示と揃え、途中の . などを解決しない。
        let selectionIndex = hasFolders && cached == nil ? ArchiveEntryPayload.SubtreeIndex(entries: existing, syntax: .init(format), components: {
            Array($0.pathComponents.drop(while: { $0 == "." }))
        }) : nil
        var removed: [Int: Entry] = [:]
        for selection in selections {
            try validate(selection, existing: existing, subtrees: selectionIndex, occupancy: cached)
            for entry in selection.entries { removed[entry.index] = Entry(entry) }
        }
        var initial = ArchivePathOccupancy()
        if cached == nil, !renaming.isEmpty || !moving.isEmpty {
            for entry in existing { initial.insert(key(entry.name), directory: entry.kind == .directory) }
        }
        var occupied = cached ?? .init(initial)
        for entry in removed.values { occupied.remove(key(entry.expectedName), directory: entry.isDirectory) }
        var renamed: Set<Int> = [], destinations: Set<String> = [], changes: [Rename] = []
        // 改名と移動は同じ部分木変換。衝突・index 照合・正準等価の扱いを分岐させない。
        func rename(_ selection: ArchiveEditSelection, to destination: String) throws {
            let indices = Set(selection.entries.map(\.index))
            guard indices.isDisjoint(with: removed.keys), indices.isDisjoint(with: renamed) else {
                throw ArchiveEditError.conflictingSelection
            }
            renamed.formUnion(indices)
            guard destinations.insert(key(destination)).inserted else { throw ArchiveEditError.collision(destination) }
            // 子だけを持つ仮想フォルダも占有済み。別のフォルダへの暗黙の併合を防ぐ。
            // この部分木だけを除き、他の改名は従来どおり元の場所も占有していると扱う。
            for index in indices {
                occupied.remove(key(existing[index].name), directory: existing[index].kind == .directory)
            }
            let collision = occupied.containsSubtree(at: key(destination))
            for index in indices {
                occupied.insert(key(existing[index].name), directory: existing[index].kind == .directory)
            }
            guard !collision else { throw ArchiveEditError.collision(destination) }
            for entry in selection.entries {
                let path: String
                if selection.isDirectory {
                    if key(entry.name) == key(selection.path) {
                        path = destination + (entry.kind == .directory ? "/" : "")
                    } else {
                        // tree が同じフォルダとして束ねる正準等価の接頭辞も、一緒に書き換える。
                        guard let renamed = ArchivePath.replacingPrefix(of: displayPath(entry.name),
                            from: selection.path, to: destination) else { throw ArchiveEditError.staleSelection }
                        path = renamed
                    }
                } else { path = destination }
                let normalized = try normalizedPath(path, directory: entry.kind == .directory, format: format)
                if !entry.name.utf8.elementsEqual(normalized.utf8) {
                    changes.append(Rename(entry: Entry(entry), path: normalized))
                }
            }
        }
        for change in renaming {
            let selection = change.selection
            try validate(selection, existing: existing, subtrees: selectionIndex, occupancy: cached)
            let leaf = try leafName(change.name, format: format)
            let parent = ArchivePath.components(selection.path).dropLast().joined(separator: "/")
            try rename(selection, to: parent.isEmpty ? leaf : parent + "/" + leaf)
        }
        for move in moves {
            try validate(move.selection, existing: existing, subtrees: selectionIndex, occupancy: cached)
            try rename(move.selection, to: move.destination)
        }
        let plan = Self(removals: removed.values.sorted { $0.index < $1.index }, renames: changes, existing: existing, format: format)
        try plan.validate(entries: existing, occupancy: cached)
        return plan
    }

    private static func validate(_ selection: ArchiveEditSelection, existing: [ArchiveEntry],
                                 subtrees: ArchiveEntryPayload.SubtreeIndex?, occupancy: ArchivePathOccupancy.Overlay?) throws {
        guard !selection.path.isEmpty, !selection.entries.isEmpty else { throw ArchiveEditError.staleSelection }
        for entry in selection.entries { try validate(Entry(entry), entries: existing) }
        if selection.isDirectory {
            let components = ArchivePath.components(selection.path)
            if let occupancy {
                let indices = Set(selection.entries.map(\.index))
                guard indices.count == occupancy.selectionCount(at: key(selection.path)), selection.entries.allSatisfy({ entry in
                    let parts = entry.pathComponents
                    return parts.starts(with: components) && (parts.count > components.count || entry.kind == .directory)
                }) else { throw ArchiveEditError.staleSelection }
                return
            }
            let current = Set(subtrees?.subtree(for: components).map(\.index) ?? [])
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

    func validate(entries: [ArchiveEntry], additions: [(path: String, isDirectory: Bool)] = [],
                  allowsRepeatedRenames: Bool = false, occupancy: ArchivePathOccupancy.Overlay? = nil,
                  baseKeys: [Int: String]? = nil) throws {
        for entry in removals + renames.map(\.entry) { try Self.validate(entry, entries: entries) }
        try validateChanges(entries: entries, additions: additions, allowsRepeatedRenames: allowsRepeatedRenames, occupancy: occupancy, baseKeys: baseKeys)
    }

    func validateChanges(entries: [ArchiveEntry], additions: [(path: String, isDirectory: Bool)] = [],
                         allowsRepeatedRenames: Bool = false, occupancy cached: ArchivePathOccupancy.Overlay? = nil,
                         baseKeys: [Int: String]? = nil) throws {
        let removed = Set(removals.map(\.index))
        guard !renames.isEmpty || !additions.isEmpty else { return }
        var initial = ArchivePathOccupancy()
        var names: [Int: String] = [:], renamed: Set<Int> = []
        if cached == nil {
            for entry in entries where !removed.contains(entry.index) {
                let key = Self.key(entry.name)
                initial.insert(key, directory: entry.kind == .directory)
                names[entry.index] = key
            }
        }
        var occupied = cached ?? .init(initial)
        if cached != nil {
            for index in removed {
                let entry = entries[index]
                occupied.remove(baseKeys?[index] ?? Self.key(entry.name), directory: entry.kind == .directory)
            }
        }
        for change in renames {
            guard !removed.contains(change.entry.index), renamed.insert(change.entry.index).inserted || allowsRepeatedRenames else {
                throw ArchiveEditError.conflictingSelection
            }
            let path = try Self.normalizedPath(change.path, directory: change.entry.isDirectory, format: format)
            let key = Self.key(path)
            // updater は予約順で衝突を調べる。最終形だけでなく途中の全予約も先に検証する。
            if let previous = names[change.entry.index] ?? (cached == nil ? nil : baseKeys?[change.entry.index] ?? Self.key(change.entry.expectedName)) {
                occupied.remove(previous, directory: change.entry.isDirectory)
            }
            guard !occupied.collides(key, directory: change.entry.isDirectory) else {
                throw ArchiveEditError.collision(path)
            }
            names[change.entry.index] = key
            occupied.insert(key, directory: change.entry.isDirectory)
        }
        for addition in additions {
            let path = try Self.normalizedPath(addition.path, directory: addition.isDirectory, format: format)
            let key = Self.key(path)
            guard !occupied.collides(key, directory: addition.isDirectory) else { throw ArchiveEditError.collision(path) }
            occupied.insert(key, directory: addition.isDirectory)
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

    static func verifyNames(_ names: [String], existing: [ArchiveEntry]) throws {
        // 選択外に子や同名の兄弟が増えていても、古い一覧による検証を使い回さない。
        guard names.count == existing.count,
              zip(names, existing).allSatisfy({ $0.utf8.elementsEqual($1.name.utf8) }) else {
            throw ArchiveEditError.staleSelection
        }
    }

    static func key(_ path: String) -> String {
        #if DEBUG
        ArchiveTestCounters.keys.get()?.increment()
        #endif
        let displayed = displayPath(path)
        return (displayed.hasSuffix("/") ? String(displayed.dropLast()) : displayed).precomposedStringWithCanonicalMapping
    }

    private static func displayPath(_ path: String) -> String {
        // EntryNode と rewriter と同じく先頭の ./ だけを外す。
        // 途中の .、..、空成分は保存し、normalizedPath で改名全体を拒否する。
        var bytes = path.utf8[...]
        while bytes.starts(with: [46, 47]) { bytes = bytes.dropFirst(2) }
        let displayed = String(decoding: bytes, as: UTF8.self)
        return displayed == "." ? "" : displayed
    }

    static func leafName(_ name: String, format: GyoshukuKit.ArchiveFormat = .zip) throws -> String {
        guard !name.utf8.contains(47) else { throw ArchiveEditError.invalidName(name) }
        return try normalizedPath(name, directory: false, format: format)
    }

    static func normalizedPath(_ path: String, directory: Bool, format: GyoshukuKit.ArchiveFormat = .zip) throws -> String {
        var name = path.precomposedStringWithCanonicalMapping
        if directory && !name.hasSuffix("/") { name += "/" }
        let body = directory ? String(name.dropLast()) : name
        let parts = ArchivePath.components(body, omittingEmptySubsequences: false)
        // writer と同じ制約を公開前に説明する。長い親パスを含む子孫も例外にしない。
        guard !body.isEmpty, !body.utf8.contains(0),
              format.allowsColonsAndBackslashes || (!body.utf8.contains(92) && !body.utf8.contains(58)),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              name.utf8.count <= Int(UInt16.max) else { throw ArchiveEditError.invalidName(path) }
        return name
    }
}

nonisolated struct ArchiveNewFolderPlan: Sendable {
    let path: String
    let existing: [ArchiveEntry]

    static func build(in folder: String, baseName: String, existing: [ArchiveEntry],
                      format: GyoshukuKit.ArchiveFormat = .zip,
                      occupancy cached: ArchivePathOccupancy.Overlay? = nil) throws -> Self {
        let base = try ArchiveEditPlan.leafName(baseName, format: format)
        let parent = folder.isEmpty ? "" : try ArchiveEditPlan.normalizedPath(folder, directory: false, format: format)
        var occupied: Set<String> = [], directories: Set<String> = [], files: Set<String> = []
        for entry in cached == nil ? existing : [] {
            let parts = ArchivePath.components(ArchiveEditPlan.key(entry.name), omittingEmptySubsequences: false)
            for count in 1...parts.count {
                let path = parts.prefix(count).joined(separator: "/")
                occupied.insert(path)
                if count < parts.count || entry.kind == .directory { directories.insert(path) }
                else { files.insert(path) }
            }
        }
        if !parent.isEmpty {
            guard cached.map({ $0.selectionCount(at: parent) > 0 }) ?? directories.contains(parent) else { throw ArchiveEditError.staleSelection }
            let parts = ArchivePath.components(parent)
            for count in 1...parts.count {
                let path = parts.prefix(count).joined(separator: "/")
                guard cached.map({ $0.firstFileAncestor(path) == nil }) ?? !files.contains(path) else { throw ArchiveEditError.collision(path) }
            }
        }
        var name = base, number = 2
        while true {
            let path = try ArchiveEditPlan.normalizedPath(parent.isEmpty ? name : parent + "/" + name, directory: true, format: format)
            if !(cached?.containsSubtree(at: ArchiveEditPlan.key(path)) ?? occupied.contains(ArchiveEditPlan.key(path))) { return Self(path: path, existing: existing) }
            // 仮想フォルダや表示から隠れた兄弟も予約済み。Finder と同じ空白付き連番で避ける。
            name = String(localized: "\(base) \(number)")
            number += 1
        }
    }
}
