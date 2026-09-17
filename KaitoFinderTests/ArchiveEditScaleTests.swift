import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveEditScaleTests: XCTestCase {
    func testDeepPathsDoNotDuplicateEveryPrefixOrRecurseDuringRelease() {
        let parent = Array(repeating: "x", count: 16_000).joined(separator: "/")
        var index = ArchivePathOccupancy()
        index.insert(parent + "/first", directory: false)
        index.insert(parent + "/second", directory: false)
        XCTAssertTrue(index.collides(parent, directory: false))
        XCTAssertFalse(index.collides(parent, directory: true))
        index.remove(parent + "/first", directory: false)
        XCTAssertTrue(index.containsSubtree(at: "x"))
        index.remove(parent + "/second", directory: false)
        XCTAssertFalse(index.containsSubtree(at: "x"))
        index.insert("new/file", directory: false)
        XCTAssertTrue(index.collides("new", directory: false))
        XCTAssertFalse(index.collides("x", directory: false))
    }

    func testCountedPathsMatchPairwiseCollisionsThroughoutInsertionsAndRemovals() {
        let paths = ["", "a", "ab", "a/child", "a//child", "a/", "./a", "/", "/a",
                     "café/file", "cafe\u{301}/file", "café", "a/\u{301}b", "a/\u{301}b/child"]
        var records: [(String, Bool)] = [], index = ArchivePathOccupancy()
        var state: UInt64 = 0x942D
        func next(_ upper: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(upper))
        }
        func descendant(_ path: String, of parent: String) -> Bool {
            path.precomposedStringWithCanonicalMapping.utf8
                .starts(with: (parent + "/").precomposedStringWithCanonicalMapping.utf8)
        }
        for step in 0..<400 {
            if !records.isEmpty, next(3) == 0 {
                let removed = records.remove(at: next(records.count))
                index.remove(removed.0, directory: removed.1)
            } else {
                let record = (paths[next(paths.count)], next(2) == 0)
                records.append(record)
                index.insert(record.0, directory: record.1)
            }
            for path in paths {
                XCTAssertEqual(index.containsSubtree(at: path), records.contains { other, _ in
                    other == path || descendant(other, of: path)
                }, "step \(step), subtree \(path)")
                for directory in [false, true] {
                    let collision = records.contains { other, otherDirectory in
                        other == path || (!directory && descendant(other, of: path)) ||
                            (!otherDirectory && descendant(path, of: other))
                    }
                    XCTAssertEqual(index.collides(path, directory: directory), collision, "step \(step), \(path)")
                }
            }
        }
        for (path, directory) in records { index.remove(path, directory: directory) }
        for path in paths { XCTAssertFalse(index.containsSubtree(at: path)) }
    }

    private func entry(_ index: Int, path: String) -> ArchiveEntry {
        ArchiveEntry(index: index, rawName: RawName(bytes: Array(path.utf8)), name: path,
            pathComponents: path.split(separator: "/").map(String.init), kind: .file,
            uncompressedSize: 1, compressedSize: 1, modificationDate: nil, posixPermissions: nil,
            isEncrypted: false, solidGroup: -1, crc32: nil, methodDescription: "stored", formatSpecific: [:])
    }

    @MainActor func testLargeFolderRenamePlanningScalesWithEntryCount() throws {
        for count in [1_000, 2_000, 4_000] {
            let entries = (0..<count).map { entry($0, path: "source/file\($0)") }
            let tree = EntryNode.tree(from: entries)
            let selection = ArchiveEditSelection(try XCTUnwrap(tree.children.first))
            let start = ContinuousClock.now
            let plan = try ArchiveEditPlan.build(removing: [],
                renaming: [.init(selection: selection, name: "renamed")], existing: entries)
            let elapsed = start.duration(to: .now)
            print("Edit plan benchmark: \(count) entries, folder rename, \(elapsed)")
            XCTAssertEqual(plan.renames.count, count)
            XCTAssertEqual(plan.renames.map(\.entry.index), Array(0..<count))
            XCTAssertEqual(plan.renames.map(\.path), (0..<count).map { "renamed/file\($0)" })
            if ProcessInfo.processInfo.environment["CI"] == nil {
                XCTAssertLessThan(elapsed, .seconds(2))
            }
        }
    }

    @MainActor func testManyFolderSelectionsValidateCompleteSubtreesWithoutRepeatedScans() throws {
        let entries = (0..<10_000).map { entry($0, path: "folder\($0 / 2)/file\($0)") }
        let selections = EntryNode.tree(from: entries).children.map(ArchiveEditSelection.init)
        let start = ContinuousClock.now
        let plan = try ArchiveEditPlan.build(removing: selections, renaming: [], existing: entries)
        let elapsed = start.duration(to: .now)
        print("Edit plan benchmark: 5,000 folders, 10,000 entries, deletion, \(elapsed)")
        XCTAssertEqual(plan.removals.map(\.index), Array(0..<10_000))
        if ProcessInfo.processInfo.environment["CI"] == nil {
            XCTAssertLessThan(elapsed, .seconds(2))
        }
    }
}
