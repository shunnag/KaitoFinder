import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class DeferredSavePlanEquivalenceTests: XCTestCase {
    private func entry(_ index: Int, _ name: String, kind: EntryKind = .file, target: String? = nil) -> ArchiveEntry {
        archiveColumnEntry(name, index: index, kind: kind, size: kind == .directory ? 0 : 1, compressed: nil, method: "stored",
                           pathComponents: ArchivePath.components(name),
                           formatSpecific: target.map { ["hardLinkTargetIndex": $0] } ?? [:])
    }
    private func reference(_ entry: ArchiveEntry) -> ArchivePendingChanges.BaseReference {
        .init(index: entry.index, expectedName: entry.name, baseGeneration: 0)
    }
    private func failure(_ body: () throws -> Void) -> String? {
        do { try body(); return nil }
        catch { return String(reflecting: type(of: error)) + ":" + String(reflecting: error) }
    }
    private func renameSignature(_ edits: [ArchiveEditPlan.Rename]) -> [String] {
        var temporary: [String: String] = [:]
        return edits.map { rename in
            let path: String
            if rename.path.hasPrefix(".KaitoFinder-rename-") {
                let key = rename.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if temporary[key] == nil { temporary[key] = "#\(temporary.count + 1)" }
                path = temporary[key]! + (rename.path.hasSuffix("/") ? "/" : "")
            } else { path = rename.path }
            return "\(rename.entry.index):\(rename.entry.expectedName):\(rename.entry.isDirectory):\(path)"
        }
    }
    private func compare(_ base: [ArchiveEntry], _ pending: ArchivePendingChanges, format: GyoshukuKit.ArchiveFormat = .zip,
                         file: StaticString = #filePath, line: UInt = #line) {
        var expected: ReferenceArchiveSaveReplayPlan?, actual: ArchiveSaveReplayPlan?
        let oldError = failure { expected = try .init(base: base, generation: 0, pending: pending, format: format) }
        let newError = failure { actual = try .init(base: base, generation: 0, pending: pending, format: format) }
        XCTAssertEqual(newError, oldError, file: file, line: line)
        guard let expected, let actual else { return }
        XCTAssertEqual(actual.edits.removals.map(\.index), expected.edits.removals.map(\.index), file: file, line: line)
        XCTAssertEqual(actual.edits.removals.map(\.expectedName), expected.edits.removals.map(\.expectedName), file: file, line: line)
        XCTAssertEqual(renameSignature(actual.edits.renames), renameSignature(expected.edits.renames), file: file, line: line)
        XCTAssertEqual(actual.projected, expected.projected, file: file, line: line)
        XCTAssertEqual(actual.renamePasses, expected.renamePasses, file: file, line: line)
        XCTAssertEqual(failure { try ArchiveSaveReplayPlan.validateRepresentability(actual.projected, format: format) },
                       failure { try ReferenceArchiveSaveReplayPlan.validateRepresentability(expected.projected, format: format) }, file: file, line: line)
    }

    func testGeneratedPlansMatchReferenceIncludingInvalidAndConflictingNames() throws {
        let base = (0..<6).map { entry($0, "f\($0)") }
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("source")
        try Data([1]).write(to: source)
        let stamp = try ArchiveImportSourceStamp(source)
        for mask in 0..<256 {
            var pending = ArchivePendingChanges()
            for index in base.indices {
                if (mask >> index) & 1 != 0 { pending.renames[reference(base[index])] = "f\((index + 1) % base.count)" }
                if (mask >> (index + 2)) & 1 != 0 { pending.removals.insert(reference(base[index])) }
            }
            if mask % 3 == 0 { pending.createdFolders = [.init(id: UUID(), path: mask % 2 == 0 ? "new/" : "f1/")] }
            if mask % 5 == 0 { pending.additions = [.init(id: UUID(), path: mask % 2 == 0 ? "added" : "f0", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)] }
            compare(base, pending)
        }
        for names in [["a", "b"], ["é", "e\u{301}"], ["same", "same"], ["./a", "b"], ["././a", "b"], ["a/../bad", "b"], ["a", "a/child"], ["a/", "a/child", "b/", "b/child"]] {
            let entries = names.enumerated().map { entry($0.offset, $0.element, kind: $0.element.hasSuffix("/") ? .directory : .file) }
            for target in ["renamed", "../bad", "./a", "é", "e\u{301}", "", "a/child", "a", "b", "bad\0name"] {
                var pending = ArchivePendingChanges(); pending.renames[reference(entries[0])] = target
                compare(entries, pending)
                pending.renames[reference(entries[1])] = "a"
                compare(entries, pending)
            }
        }
        let folders = [entry(0, "a/", kind: .directory), entry(1, "a/child"), entry(2, "b/", kind: .directory), entry(3, "b/child")]
        var swap = ArchivePendingChanges()
        for (index, name) in ["b/", "b/child", "a/", "a/child"].enumerated() { swap.renames[reference(folders[index])] = name }
        compare(folders, swap)
        let chain = (0..<51).map { entry($0, "f\($0)") }
        var pending = ArchivePendingChanges()
        for index in 0..<50 { pending.renames[reference(chain[index])] = "f\(index + 1)" }
        pending.removals.insert(reference(chain[50])); compare(chain, pending)
        pending.removals.removeAll(); compare(chain, pending)
    }

    func testHardLinkTargetsAndChainsMatchReference() {
        let base = [entry(0, "target"), entry(1, "link", kind: .hardlink, target: "0"), entry(2, "chain", kind: .hardlink, target: "1")]
        for removed in 0..<8 {
            for renamed in 0..<8 {
                var pending = ArchivePendingChanges()
                for index in base.indices {
                    if removed & (1 << index) != 0 { pending.removals.insert(reference(base[index])) }
                    if renamed & (1 << index) != 0 { pending.renames[reference(base[index])] = "renamed\(index)" }
                }
                for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip, .lha] { compare(base, pending, format: format) }
            }
        }
    }

    func testCachedAndUncachedValidationHaveIdenticalErrors() {
        let base = [entry(0, "a"), entry(1, "b"), entry(2, "folder/", kind: .directory), entry(3, "folder/child"), entry(4, "é"), entry(5, "e\u{301}")]
        var occupancy = ArchivePathOccupancy()
        for entry in base { occupancy.insert(ArchiveEditPlan.key(entry.name), directory: entry.kind == .directory) }
        for target in ["new", "b", "folder", "folder/", "folder/new", "é", "./a", "../bad"] {
            for removed in [[], [0], [1], [2, 3]] {
                for repeats in [false, true] {
                    let plan = ArchiveEditPlan(removals: removed.map { .init(base[$0]) },
                        renames: [.init(entry: .init(base[0]), path: target), .init(entry: .init(base[0]), path: "final")], existing: base)
                    let additions = [(path: "b", isDirectory: false)]
                    XCTAssertEqual(failure { try plan.validateChanges(entries: base, additions: additions, allowsRepeatedRenames: repeats) },
                        failure { try plan.validateChanges(entries: base, additions: additions, allowsRepeatedRenames: repeats, occupancy: .init(occupancy)) })
                }
            }
        }
    }

    func testKeyCountsAreBoundedByEntriesAndChanges() throws {
        let count = 20_000, children = 100
        let base = (0..<count).map { entry($0, $0 >= count - children ? "folder/f\($0)" : "f\($0)") }
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("added")
        try Data([1]).write(to: source)
        let stamp = try ArchiveImportSourceStamp(source)
        for chain in [false, true] {
            var pending = ArchivePendingChanges()
            if chain {
                for index in 0..<50 { pending.renames[reference(base[index])] = "f\(index + 1)" }
                pending.renames[reference(base[50])] = "new-end"
            } else { pending.renames[reference(base[0])] = "renamed" }
            pending.removals = Set(([51] + Array((count - children)..<count)).map { reference(base[$0]) })
            pending.additions = [.init(id: UUID(), path: "added", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)]
            pending.createdFolders = [.init(id: UUID(), path: "new/")]
            let keys = ArchiveTestCounter()
            let plan = try ArchiveTestCounters.editPlanKeys.withValue(keys) { try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending) }
            XCTAssertLessThanOrEqual(keys.value, count + 3 * (pending.renames.count + pending.additions.count + pending.createdFolders.count))
            let bound = pending.removals.count + 2 * plan.edits.renames.count + pending.additions.count + pending.createdFolders.count + 8
            let validating = ArchiveTestCounter()
            try ArchiveTestCounters.editPlanKeys.withValue(validating) { try plan.validate() }
            XCTAssertLessThanOrEqual(validating.value, bound)
            let replaying = ArchiveTestCounter(), editor = StubEditor(base.map(\.name))
            try ArchiveTestCounters.editPlanKeys.withValue(replaying) { try plan.replay(on: editor, progress: Progress()) }
            XCTAssertLessThanOrEqual(replaying.value, bound)
        }
        for deletes in [false, true] {
            var pending = ArchivePendingChanges()
            if deletes { pending.removals = Set(base.prefix(100).map(reference)) }
            let keys = ArchiveTestCounter()
            _ = try ArchiveTestCounters.editPlanKeys.withValue(keys) { try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending) }
            XCTAssertLessThanOrEqual(keys.value, 8)
        }
    }

    func testRepresentabilityFastPathPreservesHardLinkIndexSemantics() {
        let base = [entry(0, "target"), entry(1, "link", kind: .hardlink, target: "0"), entry(2, "chain", kind: .hardlink, target: "1")]
        let fixtures: [([ArchiveEntry], Int)] = [
            (base, 0), ([entry(3, "a"), entry(10, "b")], 0), ([base[0], base[2]], 1),
            ([entry(0, "target"), entry(1, "bad", kind: .hardlink, target: "20")], 1),
            ([entry(0, "target"), entry(1, "bad", kind: .hardlink, target: "-1")], 1),
            ([entry(0, "target"), entry(1, "bad", kind: .hardlink, target: "not-an-index")], 0),
            ([entry(0, "target"), entry(1, "link", kind: .hardlink, target: "+0")], 0)
        ]
        for (entries, slow) in fixtures {
            for format: GyoshukuKit.ArchiveFormat in [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha] {
                let counter = ArchiveTestCounter()
                let actual = ArchiveTestCounters.slowRepresentability.withValue(counter) {
                    failure { try ArchiveSaveReplayPlan.validateRepresentability(entries, format: format) }
                }
                XCTAssertEqual(actual, failure { try ReferenceArchiveSaveReplayPlan.validateRepresentability(entries, format: format) })
                XCTAssertEqual(counter.value, slow)
            }
        }
    }

    private final class StubEditor: ArchiveEditing {
        let entryNames: [String]
        init(_ names: [String]) { entryNames = names }
        func add(contentsOf url: URL, as path: String) throws {}
        func add(contentsOf url: URL, as path: String, ownerIDs: ArchiveOwnerIDs?) throws {}
        func addDirectory(_ path: String, modificationDate: Date?, ownerIDs: ArchiveOwnerIDs?) throws {}
        func add(data: Data, as path: String, modificationDate: Date?, permissions: UInt16?) throws {}
        func addDirectory(_ path: String) throws {}
        func remove(entriesAt indices: [Int]) throws {}
        func rename(entryAt index: Int, to path: String) throws {}
        func commit() throws {}
    }
}
