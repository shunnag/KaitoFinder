import XCTest
import KaitoKit
@testable import KaitoFinder

nonisolated final class EntryTreeTests: XCTestCase {
    @MainActor
    private func entry(_ path: String, index: Int = 0, kind: EntryKind = .file,
                       size: UInt64? = 2, compressed: UInt64? = 1) -> ArchiveEntry {
        ArchiveEntry(index: index, rawName: RawName(bytes: Array(path.utf8)), name: path,
                     pathComponents: path.split(separator: "/").map(String.init), kind: kind,
                     uncompressedSize: size, compressedSize: compressed, modificationDate: nil,
                     posixPermissions: nil, isEncrypted: false, solidGroup: -1, crc32: nil,
                     methodDescription: "stored", formatSpecific: [:])
    }

    @MainActor
    private func child(_ name: String, in node: EntryNode) throws -> EntryNode {
        try XCTUnwrap(node.children.first { $0.name == name })
    }

    @MainActor
    func testSynthesizesVirtualFoldersAndRecursiveSizes() throws {
        let root = EntryNode.tree(from: [entry("a.txt"), entry("sub/b.txt"), entry("sub/deep/c.txt")])
        XCTAssertEqual(Set(root.children.map(\.name)), ["a.txt", "sub"])
        let sub = try child("sub", in: root)
        let deep = try child("deep", in: sub)
        XCTAssertTrue(sub.isVirtual)
        XCTAssertTrue(deep.isVirtual)
        XCTAssertNil(sub.entry)
        XCTAssertEqual(sub.size, 4)
        XCTAssertEqual(sub.compressedSize, 2)
        XCTAssertEqual(deep.size, 2)
        XCTAssertEqual(root.size, 6)
        XCTAssertEqual(try child("c.txt", in: deep).entry?.name, "sub/deep/c.txt")
    }

    @MainActor
    func testExplicitDirectoriesMergeInEitherOrder() throws {
        let entries = [entry("sub/deep/c.txt"), entry("sub/", kind: .directory, size: 500),
                       entry("sub/deep/", kind: .directory, size: 500)]
        for ordered in [entries, Array(entries.reversed())] {
            let root = EntryNode.tree(from: ordered)
            XCTAssertEqual(root.children.count, 1)
            let sub = try child("sub", in: root)
            let deep = try child("deep", in: sub)
            XCTAssertEqual(sub.children.count, 1)
            XCTAssertFalse(sub.isVirtual)
            XCTAssertFalse(deep.isVirtual)
            XCTAssertEqual(sub.entry?.name, "sub/")
            XCTAssertEqual(root.size, 2)
        }
    }

    @MainActor
    func testLeadingDotNormalizationRetainsOriginalEntry() throws {
        let original = entry("././sub/a.txt")
        let root = EntryNode.tree(from: [entry("./", kind: .directory), original,
                                         entry("sub/", kind: .directory)])
        XCTAssertEqual(root.children.count, 1)
        let sub = try child("sub", in: root)
        XCTAssertFalse(sub.isVirtual)
        let file = try child("a.txt", in: sub)
        XCTAssertEqual(file.entry, original)
        XCTAssertEqual(file.entry?.rawName.bytes, Array("././sub/a.txt".utf8))
    }

    @MainActor
    func testParentAndInteriorDotComponentsAreNotResolved() throws {
        let root = EntryNode.tree(from: [entry("../escape.txt"), entry("sub/../b.txt"), entry("sub/./c.txt")])
        XCTAssertEqual(try child("..", in: root).children.first?.name, "escape.txt")
        let sub = try child("sub", in: root)
        XCTAssertEqual(Set(sub.children.map(\.name)), ["..", "."])
    }

    @MainActor
    func testEmptyDirectoryAndUnknownOrOverflowingSizes() throws {
        let root = EntryNode.tree(from: [entry("empty/", kind: .directory),
                                         entry("unknown/a", size: nil),
                                         entry("overflow/a", size: .max), entry("overflow/b")])
        XCTAssertEqual(try child("empty", in: root).size, 0)
        XCTAssertNil(try child("unknown", in: root).size)
        XCTAssertNil(try child("overflow", in: root).size)
        XCTAssertNil(root.size)
    }

    @MainActor
    func testDuplicateFilesAndFileDirectoryCollisionRemainVisible() {
        let root = EntryNode.tree(from: [entry("same", index: 0), entry("same", index: 1),
                                         entry("same/child", index: 2)])
        XCTAssertEqual(root.children.count, 3)
        XCTAssertEqual(root.children.filter { !$0.isDirectory }.compactMap { $0.entry?.index }, [0, 1])
        XCTAssertEqual(root.size, 6)
    }

    @MainActor
    func testEmptyArchive() {
        let root = EntryNode.tree(from: [])
        XCTAssertTrue(root.children.isEmpty)
        XCTAssertEqual(root.size, 0)
    }

    @MainActor func testFilterKeepsMatchingLeavesAndAncestorsUsingFullNodes() throws {
        let entries = [entry("parent/branch/needle.txt", index: 0), entry("parent/branch/hidden.txt", index: 1),
                       entry("parent/hidden/deeper.bin", index: 2), entry("outside.txt", index: 3)]
        let root = EntryNode.tree(from: entries), filter = EntryTreeFilter(root: root, query: "needle")
        let parent = try child("parent", in: root), branch = try child("branch", in: parent)
        XCTAssertEqual(filter.children(of: root), [parent])
        XCTAssertEqual(filter.children(of: parent), [branch])
        XCTAssertEqual(filter.children(of: branch).map(\.name), ["needle.txt"])
        XCTAssertTrue(try XCTUnwrap(filter.children(of: parent).first) === branch)
        XCTAssertEqual(branch.children.count, 2)
        XCTAssertEqual(ExtractionSelection(nodes: [parent]).entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(ArchiveEditSelection(parent).entries.map(\.index), [0, 1, 2])
        XCTAssertEqual(parent.size, 6)
        XCTAssertTrue(EntryTreeFilter(root: root, query: "parent/branch").children(of: root).isEmpty)
    }

    @MainActor func testMatchingFolderKeepsItsWholeSubtreeAndEmptyFoldersCanMatch() throws {
        let root = EntryNode.tree(from: [entry("photos/one.txt"), entry("photos/deep/two.txt"),
                                         entry("empty/", kind: .directory), entry("other.txt")])
        let photos = try child("photos", in: root), filter = EntryTreeFilter(root: root, query: "hoto")
        XCTAssertEqual(filter.children(of: root), [photos])
        XCTAssertEqual(filter.children(of: photos), photos.children)
        let deep = try child("deep", in: photos)
        XCTAssertEqual(filter.children(of: deep), deep.children)
        XCTAssertEqual(EntryTreeFilter(root: root, query: "mpt").children(of: root).map(\.name), ["empty"])
    }

    @MainActor func testFilterIsCaseAndDiacriticInsensitiveSubstringSearch() {
        let root = EntryNode.tree(from: [entry("Résumé.PDF"), entry("cafe\u{301}.txt"), entry("unrelated")])
        for (query, expected) in [("SUME.p", "Résumé.PDF"), ("AFÉ.T", "cafe\u{301}.txt")] {
            XCTAssertEqual(EntryTreeFilter(root: root, query: query).children(of: root).map(\.name), [expected])
        }
        XCTAssertTrue(EntryTreeFilter(root: root, query: "Résumé.PDF extra").children(of: root).isEmpty)
    }

    @MainActor func testJapaneseFilterFoldsWidthCaseAndDiacriticsButKeepsHiraganaDistinct() {
        let root = EntryNode.tree(from: [entry("カタカナ資料.txt"), entry("ｶﾀｶﾅ資料.txt"), entry("かたかな資料.txt"),
                                         entry("ﾃｽﾄ1.bin"), entry("テスト１.bin"), entry("Photo.JPG"),
                                         entry("café.txt"), entry("cafe.txt")])
        let katakana: Set<String> = ["カタカナ資料.txt", "ｶﾀｶﾅ資料.txt"]
        for query in ["ｶﾀｶﾅ", "カタカナ", "ﾀｶﾅ", "タカナ"] {
            XCTAssertEqual(Set(EntryTreeFilter(root: root, query: query).children(of: root).map(\.name)), katakana, query)
        }
        XCTAssertEqual(Set(EntryTreeFilter(root: root, query: "テスト1").children(of: root).map(\.name)),
                       ["ﾃｽﾄ1.bin", "テスト１.bin"])
        XCTAssertEqual(EntryTreeFilter(root: root, query: "photo").children(of: root).map(\.name), ["Photo.JPG"])
        XCTAssertEqual(Set(EntryTreeFilter(root: root, query: "cafe").children(of: root).map(\.name)), ["café.txt", "cafe.txt"])
        // 文字幅の違いだけを吸収し、ひらがなとカタカナは別の名前として検索する。
        let hiraganaMatches = Set(EntryTreeFilter(root: root, query: "たかな").children(of: root).map(\.name))
        XCTAssertEqual(hiraganaMatches, ["かたかな資料.txt"])
        XCTAssertTrue(hiraganaMatches.isDisjoint(with: katakana))
        XCTAssertEqual(EntryTreeFilter(root: root, query: "資料").children(of: root).count, 3)
    }

    @MainActor func testEmptyFilterReturnsOriginalChildrenIncludingDuplicateRecords() throws {
        let root = EntryNode.tree(from: [entry("same/", index: 0, kind: .directory), entry("same/", index: 1, kind: .directory),
                                         entry("same/a", index: 2), entry("same/a", index: 3)])
        let filter = EntryTreeFilter(root: root, query: ""), same = try child("same", in: root)
        XCTAssertEqual(filter.children(of: root), root.children)
        XCTAssertEqual(filter.children(of: same), same.children)
        XCTAssertEqual(same.representedEntries.map(\.index), [0, 1])
        XCTAssertEqual(ArchiveEditSelection(same).entries.map(\.index), [0, 1, 2, 3])
        XCTAssertTrue(EntryTreeFilter(root: root, query: "missing").children(of: root).isEmpty)
    }

    @MainActor
    func testZIPAndTarFixturesThroughArchiveSession() async throws {
        // テスト用書庫もリポジトリ内に作り、外部の checkout は変更しない。
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("build/Fixtures/\(UUID().uuidString)")
        let source = fixture.appendingPathComponent("src")
        let manager = FileManager.default
        try manager.createDirectory(at: source.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        for (path, contents) in [("a.txt", "a\n"), ("sub/b.txt", "b\n"), ("sub/deep/c.txt", "c\n")] {
            try Data(contents.utf8).write(to: source.appendingPathComponent(path))
        }
        let list = fixture.appendingPathComponent("files.txt")
        try Data("./a.txt\n./sub/b.txt\n./sub/deep/c.txt\n".utf8).write(to: list)
        let cases: [(String, String, [String], Bool)] = [
            ("nodirs.zip", "/usr/bin/zip", ["-D", "-q", "-r", fixture.appendingPathComponent("nodirs.zip").path, "."], true),
            ("dirs.zip", "/usr/bin/zip", ["-q", "-r", fixture.appendingPathComponent("dirs.zip").path, "."], false),
            ("nodirs.tar", "/usr/bin/tar", ["--no-recursion", "-cf", fixture.appendingPathComponent("nodirs.tar").path, "-T", list.path], true)
        ]
        for (filename, executable, arguments, virtual) in cases {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = source
            process.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { _, new in new }
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, filename)
            let url = fixture.appendingPathComponent(filename)
            let session = try ArchiveSession(url: url)
            let entries = await session.entries()
            XCTAssertEqual(entries.contains { $0.kind == .directory }, !virtual, filename)
            let root = EntryNode.tree(from: entries)
            XCTAssertEqual(Set(root.children.map(\.name)), ["a.txt", "sub"], filename)
            let sub = try child("sub", in: root)
            let deep = try child("deep", in: sub)
            XCTAssertEqual(Set(sub.children.map(\.name)), ["b.txt", "deep"], filename)
            XCTAssertEqual(deep.children.map(\.name), ["c.txt"], filename)
            XCTAssertEqual(sub.isVirtual, virtual, filename)
            XCTAssertEqual(deep.isVirtual, virtual, filename)
            XCTAssertEqual(root.size, 6, filename)
            XCTAssertEqual(sub.size, 4, filename)
            if filename.hasSuffix("tar") {
                XCTAssertEqual(try child("a.txt", in: root).entry?.name, "./a.txt")
            }
            let document = try ArchiveDocument(contentsOf: url, ofType: "public.data")
            XCTAssertFalse(document.isEntireFileLoaded)
            XCTAssertFalse(ArchiveDocument.autosavesInPlace)
            XCTAssertFalse(ArchiveDocument.preservesVersions)
            XCTAssertTrue(document.writableTypes(for: .saveOperation).isEmpty)
            let documentSession = try XCTUnwrap(document.session)
            let documentEntries = await documentSession.entries()
            XCTAssertEqual(documentEntries, entries)
            document.close()
        }
    }
}
