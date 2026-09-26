import Foundation
import GyoshukuKit
import KaitoKit

nonisolated struct ArchiveNameIndexChange: Sendable {
    var removed: [Int] = []
    var renamed: [Int: String] = [:]
    var appended: [(name: String, isDirectory: Bool)] = []
    var mode: ArchiveCapabilities.Mode

    init(removed: [Int] = [], renamed: [Int: String] = [:],
         appended: [(name: String, isDirectory: Bool)] = [], mode: ArchiveCapabilities.Mode) {
        self.removed = removed
        self.renamed = renamed
        self.appended = appended
        self.mode = mode
    }

    init(plan: ArchiveEditPlan, mode: ArchiveCapabilities.Mode) {
        self.init(removed: plan.removals.map(\.index), mode: mode)
        for rename in plan.renames { renamed[rename.entry.index] = rename.path }
    }

    init(plan: ArchiveSaveReplayPlan, mode: ArchiveCapabilities.Mode) {
        self.init(plan: plan.edits, mode: mode)
        appended = plan.additions.map { ($0.path, $0.sourceStamp.kind == .directory) }
            + plan.folders.map { ($0.path, true) }
    }
}

nonisolated struct ArchiveNameIndex: Sendable {
    let generation: UInt64
    let format: GyoshukuKit.ArchiveFormat
    let entryCount: Int
    let containsHardLinks: Bool
    let occupancy: ArchivePathOccupancy
    let representable: Bool
    var overlay: ArchivePathOccupancy.Overlay { .init(occupancy) }

    static func cleanKey(_ entry: ArchiveEntry, format: GyoshukuKit.ArchiveFormat) -> String? {
        guard let normalized = try? ArchiveEditPlan.normalizedPath(entry.name, directory: entry.kind == .directory, format: format),
              normalized.utf8.elementsEqual(entry.name.utf8) else { return nil }
        let key = ArchiveEditPlan.key(entry.name)
        return entry.pathComponents.joined(separator: "/") == key ? key : nil
    }

    static func build(entries: [ArchiveEntry], generation: UInt64, format: GyoshukuKit.ArchiveFormat,
                      provingRepresentability: Bool, checksCancellation: Bool) -> Self? {
        var occupancy = ArchivePathOccupancy(), hardLinks = false
        for (offset, entry) in entries.enumerated() {
            if checksCancellation, offset % 256 == 0, Task.isCancelled { return nil }
            guard let key = cleanKey(entry, format: format) else { return nil }
            occupancy.insert(key, directory: entry.kind == .directory)
            hardLinks = hardLinks || entry.kind == .hardlink
        }
        var representable = false
        if provingRepresentability {
            do { try ArchiveSaveReplayPlan.validateRepresentability(entries, format: format); representable = true }
            catch { /* 占有表は使えるが、全件検査の証明は継がない。 */ }
        }
        if checksCancellation, Task.isCancelled { return nil }
        return Self(generation: generation, format: format, entryCount: entries.count,
                    containsHardLinks: hardLinks, occupancy: occupancy, representable: representable)
    }

    func advancing(_ change: ArchiveNameIndexChange, previous: [ArchiveEntry], entries: [ArchiveEntry],
                   generation: UInt64, format: GyoshukuKit.ArchiveFormat) -> Self? {
        switch change.mode {
        case .inPlace, .update: break
        case .rewrite: return nil
        }
        guard self.generation &+ 1 == generation, self.format == format, entryCount == previous.count else { return nil }
        let removed = Set(change.removed)
        guard removed.count == change.removed.count,
              removed.allSatisfy(previous.indices.contains), change.renamed.keys.allSatisfy(previous.indices.contains),
              removed.isDisjoint(with: change.renamed.keys),
              entries.count == previous.count - removed.count + change.appended.count else { return nil }
        return ArchiveStageDiagnostics.measure(.nameIndexAdvance) {
            var position = 0, hardLinks = false, representable = self.representable
            var changed: [(entry: ArchiveEntry, key: String)] = []
            func checkChanged(_ entry: ArchiveEntry, name: String) -> Bool {
                guard let key = Self.cleanKey(entry, format: format), key == ArchiveEditPlan.key(name) else { return false }
                changed.append((entry, key))
                do { try ArchiveRewriter.probe(entries: [entry.pendingCopy(index: 0)], format: format) }
                catch { representable = false }
                return true
            }
            for (index, old) in previous.enumerated() where !removed.contains(index) {
                let new = entries[position]
                guard new.kind == old.kind else { return nil }
                if let name = change.renamed[index] {
                    guard checkChanged(new, name: name) else { return nil }
                } else if !new.name.utf8.elementsEqual(old.name.utf8) { return nil }
                hardLinks = hardLinks || new.kind == .hardlink
                position += 1
            }
            for addition in change.appended {
                let new = entries[position]
                guard (new.kind == .directory) == addition.isDirectory, checkChanged(new, name: addition.name) else { return nil }
                hardLinks = hardLinks || new.kind == .hardlink
                position += 1
            }
            var occupancy = self.occupancy
            for index in removed.union(change.renamed.keys) {
                occupancy.remove(ArchiveEditPlan.key(previous[index].name), directory: previous[index].kind == .directory)
            }
            for item in changed { occupancy.insert(item.key, directory: item.entry.kind == .directory) }
            return Self(generation: generation, format: format, entryCount: entries.count,
                        containsHardLinks: hardLinks, occupancy: occupancy, representable: representable)
        }
    }
}
