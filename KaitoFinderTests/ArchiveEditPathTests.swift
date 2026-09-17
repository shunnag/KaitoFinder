import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveEditPathTests: XCTestCase {
    func testPathHelpersKeepCombiningChildrenAndCanonicalParentsTogether() {
        XCTAssertEqual(ArchivePath.components("cafe\u{301}/\u{301}child"), ["cafe\u{301}", "\u{301}child"])
        XCTAssertTrue(ArchivePath.isDescendant("cafe\u{301}/\u{301}child", of: "café"))
        XCTAssertFalse(ArchivePath.isDescendant("caféteria/child", of: "café"))
        XCTAssertEqual(ArchivePath.replacingPrefix(of: "cafe\u{301}/\u{301}child", from: "café", to: "moved"),
                       "moved/\u{301}child")
        XCTAssertTrue(EntryNode.isHiddenName("folder/.\u{301}hidden"))
        XCTAssertThrowsError(try ArchiveImportPlan.path("folder/bad:\u{301}name"))
        XCTAssertThrowsError(try ArchiveImportPlan.path("folder/bad\\\u{301}name"))
    }

    @MainActor func testCombiningMarksCannotHideSeparatorsInAFileRename() async throws {
        let fixture = try ScenarioFixture(), session = try ArchiveSession(url: fixture.archive)
        let entries = await session.entries()
        let file = try XCTUnwrap(EntryNode.tree(from: entries).children.first { !$0.isDirectory })
        for name in ["../\u{301}escape", "/\u{301}absolute", "parent/\u{301}child", "bad\\\u{301}name", "bad:\u{301}name"] {
            XCTAssertThrowsError(try ArchiveEditPlan.build(removing: [],
                renaming: [.init(selection: ArchiveEditSelection(file), name: name)], existing: entries)) {
                XCTAssertEqual($0 as? ArchiveEditError, .invalidName(name))
            }
        }
    }

    @MainActor func testLeadingCombiningMarkInAChildNameDoesNotHideItsParent() async throws {
        let fixture = try ScenarioFixture(script: #"""
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('source', b'source')
            z.writestr('target/\u0301child', b'child')
        """#)
        let session = try ArchiveSession(url: fixture.archive)
        let entries = await session.entries(), file = try await selection("source", session: session)
        XCTAssertThrowsError(try ArchiveEditPlan.build(removing: [],
            renaming: [.init(selection: file, name: "target")], existing: entries)) {
            XCTAssertEqual($0 as? ArchiveEditError, .collision("target"))
        }
        let folder = try await selection("target", session: session)
        let result = try await session.rename(folder, to: "renamed", progress: Progress())
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), [
            "source": Data("source".utf8), "renamed/\u{301}child": Data("child".utf8)
        ])
    }

    private func fixture() throws -> ScenarioFixture {
        try ScenarioFixture(script: #"""
        with tarfile.open(p, 'w') as t:
            for name in ['./', './folder/', './target/', './target/untitled/']:
                item = tarfile.TarInfo(name); item.type = tarfile.DIRTYPE
                t.addfile(item)
            for name, data in [('./folder/child.txt', b'child'), ('././folder/deeper/leaf.txt', b'leaf'), ('./target/keep.txt', b'keep')]:
                item = tarfile.TarInfo(name); item.size = len(data)
                t.addfile(item, io.BytesIO(data))
        """#, suffix: "tar")
    }

    @MainActor private func selection(_ path: String, session: ArchiveSession) async throws -> ArchiveEditSelection {
        let root = EntryNode.tree(from: await session.entries())
        var pending = root.children
        while let node = pending.popLast() {
            if node.path == path { return ArchiveEditSelection(node) }
            pending.append(contentsOf: node.children)
        }
        throw ArchiveEditError.staleSelection
    }

    @MainActor func testRenameDirectoryWithLeadingDotComponentsPreservesEveryDescendant() async throws {
        let fixture = try fixture(), session = try ArchiveSession(url: fixture.archive)
        let folder = try await selection("folder", session: session)
        let result = try await session.rename(folder, to: "renamed", progress: Progress())
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(Set(result.renamedPaths), ["renamed/", "renamed/child.txt", "renamed/deeper/leaf.txt"])
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), [
            "renamed/child.txt": Data("child".utf8), "renamed/deeper/leaf.txt": Data("leaf".utf8), "target/keep.txt": Data("keep".utf8)
        ])
        await session.close()
    }

    @MainActor func testMoveIntoDirectoryWithLeadingDotComponents() async throws {
        let fixture = try fixture(), session = try ArchiveSession(url: fixture.archive)
        let folder = try await selection("folder", session: session)
        let result = try await session.edit(moving: [.init(selection: folder, folder: "target")], progress: Progress())
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(Set(result.renamedPaths), ["target/folder/", "target/folder/child.txt", "target/folder/deeper/leaf.txt"])
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive)["target/folder/deeper/leaf.txt"], Data("leaf".utf8))
        await session.close()
    }

    func testNewFolderResolvesDisplayedParentAndOccupiedNamesInDotPrefixedTar() async throws {
        let fixture = try fixture(), session = try ArchiveSession(url: fixture.archive)
        let result = try await session.createFolder(in: "target", baseName: "untitled", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["target/untitled 2/"])
        XCTAssertNil(result.reloadFailure)
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive)["target/keep.txt"], Data("keep".utf8))
        await session.close()
    }

    @MainActor func testDisplayedDirectoryCollisionIsRejectedBeforeOpeningUpdater() async throws {
        let fixture = try fixture(), session = try ArchiveSession(url: fixture.archive)
        let entries = await session.entries(), folder = try await selection("folder", session: session)
        let before = try ScenarioFixture.digest(fixture.archive)
        XCTAssertThrowsError(try ArchiveEditPlan.build(removing: [], renaming: [.init(selection: folder, name: "target")], existing: entries)) {
            XCTAssertEqual($0 as? ArchiveEditError, .collision("target"))
        }
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        await session.close()
    }
}
