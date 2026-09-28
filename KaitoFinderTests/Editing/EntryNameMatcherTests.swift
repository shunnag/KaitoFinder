import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class EntryNameMatcherTests: XCTestCase {
    private func reference(_ name: String, _ query: String) -> Bool {
        name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    func testEveryPrintableASCIIPairMatchesFoundation() {
        let bytes = Array(UInt8(0x20)...UInt8(0x7e))
        let singles = bytes.map { String(decoding: [$0], as: UTF8.self) }
        let matchers = singles.map { EntryNameMatcher(query: $0) }
        for first in bytes {
            for second in bytes {
                let name = String(decoding: [first, second], as: UTF8.self)
                for (query, matcher) in zip(singles, matchers) {
                    XCTAssertEqual(matcher.matches(name), reference(name, query), "\(name.debugDescription), \(query.debugDescription)")
                }
                for query in [name, String(decoding: [second, first], as: UTF8.self)] {
                    XCTAssertEqual(EntryNameMatcher(query: query).matches(name), reference(name, query))
                }
            }
        }
    }

    func testSeededRandomASCIIAndUppercaseSubstringsMatchFoundation() {
        var random = SplitMix64(state: 0x5038_2026_0926)
        for index in 0..<200_000 {
            let length = index.isMultiple(of: 2) ? 1 + Int(random.next() % 24) : Int(random.next() % 25)
            let bytes = (0..<length).map { _ in UInt8(0x20 + random.next() % 95) }
            let name = String(decoding: bytes, as: UTF8.self)
            let query: String
            if index.isMultiple(of: 2), !bytes.isEmpty {
                let start = Int(random.next() % UInt64(bytes.count))
                let count = min(1 + Int(random.next() % 6), bytes.count - start)
                query = String(decoding: bytes[start..<(start + count)], as: UTF8.self).uppercased()
            } else {
                let count = 1 + Int(random.next() % 6)
                query = String(decoding: (0..<count).map { _ in UInt8(0x20 + random.next() % 95) }, as: UTF8.self)
            }
            XCTAssertEqual(EntryNameMatcher(query: query).matches(name), reference(name, query),
                           "sample \(index): \(name.debugDescription), \(query.debugDescription)")
        }
    }

    func testEveryCJKOtherLetterRejectsPrintableASCIINamesLikeFoundation() {
        let printable = String(decoding: Array(UInt8(0x20)...UInt8(0x7e)), as: UTF8.self)
        let names = [printable, String(printable.reversed()), "", "file99999.txt", "FILE DATA 123", "e1", "^`~'\" ._-", "ee111"]
        for range in [0x3040...0x30ff, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xac00...0xd7a3,
                      0xf900...0xfaff, 0xff66...0xff9f, 0x20000...0x3134f] {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar.properties.generalCategory == .otherLetter else { continue }
                let letter = String(scalar)
                for query in [letter, "e" + letter, letter + "1"] {
                    let matcher = EntryNameMatcher(query: query)
                    for name in names {
                        XCTAssertFalse(reference(name, query), "U+\(String(value, radix: 16))")
                        XCTAssertFalse(matcher.matches(name), "U+\(String(value, radix: 16))")
                    }
                }
                for name in ["資料9.txt", "ﾌｧｲﾙ"] {
                    XCTAssertEqual(EntryNameMatcher(query: letter).matches(name), reference(name, letter))
                }
            }
        }
    }

    func testFoundationFallbackPreservesWidthDiacriticsControlsAndCombiningMarks() {
        let pairs = [("file.txt", "ｆｉｌｅ"), ("é", "e"), ("e\u{301}", "e"), ("カ", "ｶ"),
                     ("a\r\nb", "\r"), ("a\0b", "a"), ("a\tb", "b"), ("a\u{7f}b", "a"),
                     ("file\u{20dd}", "file"), ("資料file.txt", "file"), ("file.txt", "e\u{3099}"),
                     ("file.txt", "ー"), ("file.txt", "\u{ff9e}"), ("file.txt", "\u{309a}"),
                     ("file.txt", "\u{ff9f}"), ("ﾌｧｲﾙ", "ファイル"), ("資料9.txt", "資料9")]
        let counter = ArchiveTestCounter()
        ArchiveTestCounters.asciiNameMatches.withValue(counter) {
            for (name, query) in pairs {
                XCTAssertEqual(EntryNameMatcher(query: query).matches(name), reference(name, query), "\(name), \(query)")
            }
        }
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(EntryNameMatcher(query: "ｆｉｌｅ").matches("file.txt"))
    }

    func testFilterMatchesS33ReferenceForAllNodesCountsAndSizes() {
        for (count, japanese, hidden) in [(100_000, false, false), (10_000, true, false), (5_000, false, true)] {
            let entries = (0..<count).map { index in
                var name = japanese ? "資料\(index / 100)/文書\(index).txt" : "d\(index / 100)/file\(index).txt"
                if hidden && index.isMultiple(of: 3) { name = ".git/" + name }
                else if hidden && index.isMultiple(of: 5) { name = "__MACOSX/._x\(index)" }
                return archiveColumnEntry(name, index: index, size: UInt64(index % 11))
            }
            let root = EntryNode.tree(from: entries)
            var nodes = [root], cursor = 0
            while cursor < nodes.count { nodes.append(contentsOf: nodes[cursor].children); cursor += 1 }
            let queries = [japanese ? "文書" : "file", japanese ? "文書9999" : "file99999", "zzz", "FILE", "ｆｉｌｅ", "文書", ".", "d1/file", "資料9"]
            for showsHiddenFiles in [false, true] {
                for query in queries + [""] {
                    let actual = EntryTreeFilter(root: root, query: query, showsHiddenFiles: showsHiddenFiles)
                    let expected = EntryTreeFilterReference(root: root, query: query, showsHiddenFiles: showsHiddenFiles)
                    XCTAssertEqual(actual.totalCount, expected.totalCount)
                    XCTAssertEqual(actual.totalSize, expected.totalSize)
                    XCTAssertEqual(actual.matchingCount, expected.matchingCount)
                    XCTAssertFalse(nodes.contains { actual.contains($0) != expected.contains($0) },
                                   "\(count), ja=\(japanese), hidden=\(showsHiddenFiles), \(query)")
                }
            }
        }
    }

    func testFastPathVisitsEveryASCIINodeIncludingBridgedNamesAndEmptyRoot() {
        let entries = (0..<100_000).map { index in
            let bridged = NSString(format: "d%d/file%d.txt", index / 100, index) as String
            return archiveColumnEntry(bridged, index: index, size: 1)
        }
        let root = EntryNode.tree(from: entries)
        for query in ["file99999", "資料9"] {
            let counter = ArchiveTestCounter()
            ArchiveTestCounters.asciiNameMatches.withValue(counter) {
                _ = EntryTreeFilter(root: root, query: query)
            }
            XCTAssertEqual(counter.value, 101_001)
        }
    }

    func testJapaneseNamedNodesUseFoundationAndEmptyRootUsesASCII() {
        let entries = (0..<10_000).map { archiveColumnEntry("資料\($0 / 100)/文書\($0).txt", index: $0, size: 1) }
        let root = EntryNode.tree(from: entries), counter = ArchiveTestCounter()
        ArchiveTestCounters.asciiNameMatches.withValue(counter) {
            _ = EntryTreeFilter(root: root, query: "file")
        }
        // 空の root だけは D1 の印字可能 ASCII の条件を満たす。
        XCTAssertEqual(counter.value, 1)
        let named = ArchiveTestCounter()
        ArchiveTestCounters.asciiNameMatches.withValue(named) {
            let matcher = EntryNameMatcher(query: "file")
            for directory in root.children {
                XCTAssertFalse(matcher.matches(directory.name))
                for node in directory.children { XCTAssertFalse(matcher.matches(node.name)) }
            }
        }
        XCTAssertEqual(named.value, 0)
    }

    func testFilterRetainsRootAndRejectsOtherTreesAndConfigurations() {
        var root: EntryNode? = EntryNode.tree(from: [archiveColumnEntry("file.txt")])
        weak let retained = root
        var filter: EntryTreeFilter? = EntryTreeFilter(root: root!, query: "file")
        let configuration = EntryTreeFilter.Configuration(query: "file", showsHiddenFiles: false)
        XCTAssertTrue(filter!.isBuilt(for: root!, configuration: configuration))
        XCTAssertFalse(filter!.isBuilt(for: EntryNode.tree(from: root!.archiveEntries), configuration: configuration))
        XCTAssertFalse(filter!.isBuilt(for: root!, configuration: .init(query: "FILE", showsHiddenFiles: false)))
        XCTAssertFalse(filter!.isBuilt(for: root!, configuration: .init(query: "file", showsHiddenFiles: true)))
        root = nil
        withExtendedLifetime(filter) { XCTAssertNotNil(retained) }
        filter = nil
        XCTAssertNil(retained)
    }

    @MainActor func testCancelledBuildReturnsNilOffMainAndEmptyQueryIsNotCounted() async throws {
        let root = EntryNode.tree(from: (0..<2_000).map { archiveColumnEntry("file\($0)", index: $0) })
        let gate = ScenarioGate(), counter = ArchiveTestCounter()
        defer { gate.release() }
        let task = EntryTreeFilter.computeWillStartForTesting.withValue({
            XCTAssertFalse(Thread.isMainThread)
            gate.pauseOnce()
        }) {
            Task { await EntryTreeFilter.build(root: root, configuration: .init(query: "file", showsHiddenFiles: false)) }
        }
        try await scenarioWait { gate.isEntered }
        task.cancel()
        gate.release()
        let result = await task.value
        XCTAssertNil(result)
        ArchiveTestCounters.mainThreadFilters.withValue(counter) {
            _ = EntryTreeFilter(root: root, query: "")
            XCTAssertEqual(counter.value, 0)
            _ = EntryTreeFilter(root: root, query: "file")
            XCTAssertEqual(counter.value, 1)
        }
    }

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var value = state
            value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
            value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
            return value ^ (value >> 31)
        }
    }
}
