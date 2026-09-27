import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
@_spi(SevenZipEditLayout) import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class SevenZipUpdateEditTests: XCTestCase {
    func testFrozenImmediateEditsKeepUntouchedPacksAndAdoptReader() async throws {
        for fixture in ["g_plain", "g_aes", "g_aesh", "z_default", "z_aes", "z_aesh", "lib"] {
            for operation in ["first", "last", "same", "long", "folder", "add", "mkdir", "replace", "move"] {
                let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.frozen(fixture, at: directory.url)
                let before = try SevenZipUpdateFixture.reader(archive), entries = before.entries
                let password = fixture.contains("aes") ? "secret" : nil
                let session = try ArchiveSession(url: archive, password: password)
                let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
                let files = entries.filter { $0.kind == .file && $0.formatSpecific["emptyStream"] == "false" }
                let target = try XCTUnwrap(operation == "last" ? files.last : files.first)
                let source = directory.url.appendingPathComponent(operation == "replace" ? target.pathComponents.last! : "added.txt")
                try Data("new".utf8).write(to: source)
                let trace = SevenZipUpdateTrace(), progress = Progress()
                var removed: Set<Int> = [], renamed: [Int: String] = [:]
                try await trace.observing {
                    try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                        try SevenZipUpdateFixture.assertWork(work, archive: archive, bytes: original, identity: identity)
                    }) {
                        switch operation {
                        case "first", "last":
                            let result = try await session.remove([SevenZipUpdateFixture.selection(target)], progress: progress)
                            XCTAssertNil(result.reloadFailure); removed.insert(target.index)
                        case "same", "long":
                            let name = operation == "same" ? String(repeating: "x", count: target.pathComponents.last!.utf8.count) : "a-much-longer-name.txt"
                            let result = try await session.rename(SevenZipUpdateFixture.selection(target), to: name, progress: progress)
                            XCTAssertNil(result.reloadFailure)
                            renamed[target.index] = (ArchiveEditPlan.key(target.name).split(separator: "/").map(String.init).dropLast() + [name]).joined(separator: "/")
                        case "folder":
                            let folder = try XCTUnwrap(entries.first { folder in
                                folder.kind == .directory && !ArchiveEditPlan.key(folder.name).isEmpty &&
                                entries.contains { $0.kind == .file && ArchiveEditPlan.key($0.name).hasPrefix(ArchiveEditPlan.key(folder.name) + "/") }
                            })
                            let key = ArchiveEditPlan.key(folder.name)
                            let children = entries.filter { ArchiveEditPlan.key($0.name) == key || ArchiveEditPlan.key($0.name).hasPrefix(key + "/") }
                            let selection = ArchiveEditSelection(path: key, isDirectory: true, entries: children)
                            let result = try await session.rename(selection, to: "renamed-folder", progress: progress)
                            XCTAssertNil(result.reloadFailure)
                            let parent = key.split(separator: "/").dropLast().map(String.init)
                            for child in children { renamed[child.index] = (parent + ["renamed-folder"]).joined(separator: "/") + String(ArchiveEditPlan.key(child.name).dropFirst(key.count)) }
                        case "add", "replace":
                            let parent = operation == "replace" ? ArchiveEditPlan.key(target.name).split(separator: "/").map(String.init).dropLast().joined(separator: "/") : ""
                            let result = try await session.append(urls: [source], to: parent, progress: progress, resolveConflict: { _ in .init(choice: .replace) })
                            XCTAssertTrue(result.failures.isEmpty); XCTAssertNil(result.reloadFailure)
                            if operation == "replace" { removed.insert(target.index) }
                        case "mkdir":
                            let result = try await session.createFolder(in: "", baseName: "new", progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        default:
                            let parent = ArchiveEditPlan.key(target.name).split(separator: "/").map(String.init).dropLast().joined(separator: "/")
                            let destination = try XCTUnwrap(entries.first { $0.kind == .directory && !ArchiveEditPlan.key($0.name).isEmpty && ArchiveEditPlan.key($0.name) != parent })
                            let key = ArchiveEditPlan.key(destination.name)
                            let result = try await session.edit(moving: [.init(selection: SevenZipUpdateFixture.selection(target), folder: key)], progress: progress)
                            XCTAssertNil(result.reloadFailure)
                            renamed[target.index] = key + "/" + target.pathComponents.last!
                        }
                    }
                }
                trace.assertRoute([.updaterOpen])
                XCTAssertEqual(trace.adoptions.withLock { $0 }, [.adopted])
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount, fixture + "/" + operation)
                let after = try SevenZipUpdateFixture.reader(archive), output = try Data(contentsOf: archive)
                let adopted = await session.entries()
                XCTAssertEqual(adopted, after.entries)
                let survivors = entries.filter { !removed.contains($0.index) }
                XCTAssertEqual(after.entries.prefix(survivors.count).map { ArchiveEditPlan.key($0.name) },
                               survivors.map { ArchiveEditPlan.key(renamed[$0.index] ?? $0.name) }, fixture + "/" + operation)
                for (old, new) in zip(survivors, after.entries) {
                    if old.kind != .directory { XCTAssertEqual(try before.read(old), try after.read(new)) }
                    XCTAssertEqual(new.isEncrypted, old.isEncrypted)
                    if renamed[old.index] == nil { XCTAssertEqual(new.rawName, old.rawName) }
                }
                try SevenZipUpdateFixture.assertCarried(before, bytes: original, after: after, output: output, removed: removed)
                let snapshot = try XCTUnwrap(before.sevenZipEditingSnapshot())
                let touchedSolid = snapshot.files.indices.contains { index in
                    guard removed.contains(index), let substream = snapshot.files[index].substreamIndex else { return false }
                    return snapshot.folders[snapshot.substreams[substream].folderIndex].substreamIndices.count > 1
                }
                let strategy: SevenZipUpdater.CommitStrategy = touchedSolid ? (operation == "replace" ? .relocatedAppend : .reencoded)
                    : operation == "add" || operation == "mkdir" ? .appendOnly
                    : operation == "first" || operation == "replace" ? .compacted : .headerOnly
                XCTAssertEqual(trace.strategies.withLock { $0 }, [strategy], fixture + "/" + operation)
                await session.close()
            }
        }
    }

    @MainActor func testAttributesAndAllDeletedThenAddedRemainEditable() async throws {
        let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.make(directory.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640, .creationDate: SevenZipUpdateFixture.date], ofItemAtPath: archive.path)
        let quarantine = Data("0083;00000001;KaitoFinder;P5".utf8), tag = Data("tag".utf8)
        try ExtractionQuarantine.apply(quarantine, to: archive)
        XCTAssertEqual(tag.withUnsafeBytes { setxattr(archive.path, "user.kaito", $0.baseAddress, $0.count, 0, 0) }, 0)
        var old = stat(); XCTAssertEqual(lstat(archive.path, &old), 0)
        let session = try ArchiveSession(url: archive), entries = await session.entries()
        let selections = EntryNode.tree(from: entries).children.map { ArchiveEditSelection($0) }
        _ = try await session.remove(selections, progress: Progress())
        XCTAssertTrue(session.capabilities.canEdit)
        XCTAssertTrue(try SevenZipUpdateFixture.reader(archive).entries.isEmpty)
        _ = try await session.createFolder(in: "", baseName: "new", progress: Progress())
        let added = directory.url.appendingPathComponent("added"); try Data("after empty".utf8).write(to: added)
        _ = try await session.append(urls: [added], to: "", progress: Progress())
        XCTAssertEqual(try SevenZipUpdateFixture.contents(SevenZipUpdateFixture.reader(archive)), ["added": Data("after empty".utf8)])
        var actual = stat(); XCTAssertEqual(lstat(archive.path, &actual), 0)
        XCTAssertEqual(actual.st_mode, old.st_mode)
        XCTAssertEqual(actual.st_birthtimespec.tv_sec, old.st_birthtimespec.tv_sec)
        XCTAssertEqual(actual.st_birthtimespec.tv_nsec, old.st_birthtimespec.tv_nsec)
        XCTAssertEqual(try ExtractionQuarantine.read(from: archive), quarantine)
        var value = Data(count: tag.count)
        XCTAssertEqual(value.withUnsafeMutableBytes { getxattr(archive.path, "user.kaito", $0.baseAddress, $0.count, 0, 0) }, tag.count)
        XCTAssertEqual(value, tag)
        XCTAssertEqual(session.capabilities.mode, .update(.sevenZip))
        await session.close()
    }
    func testMixedEncryptionPreservesExistingStatesAndEncryptsNewEntries() async throws {
        let directory = try ArchiveTestDirectory(), plain = directory.url.appendingPathComponent("plain.7z")
        let writer = try ArchiveWriter.create(url: plain, format: .sevenZip)
        try writer.add(data: Data("plain".utf8), as: "plain"); try writer.finish()
        let archive = directory.url.appendingPathComponent("mixed.7z")
        let updater = try SevenZipUpdater.open(url: plain, output: archive, options: .init(password: "secret"))
        try updater.add(data: Data("encrypted".utf8), as: "encrypted"); try updater.commit()
        let original = try SevenZipUpdateFixture.reader(archive), bytes = try Data(contentsOf: archive)
        XCTAssertEqual(original.entries.map(\.isEncrypted), [false, true])
        let session = try ArchiveSession(url: archive, password: "secret")
        let source = directory.url.appendingPathComponent("added"); try Data("new".utf8).write(to: source)
        _ = try await session.append(urls: [source], to: "", progress: Progress())
        let output = try SevenZipUpdateFixture.reader(archive)
        XCTAssertEqual(output.entries.map(\.isEncrypted), [false, true, true])
        XCTAssertEqual(try SevenZipUpdateFixture.contents(output), ["plain": Data("plain".utf8), "encrypted": Data("encrypted".utf8), "added": Data("new".utf8)])
        try SevenZipUpdateFixture.assertCarried(original, bytes: bytes, after: output, output: Data(contentsOf: archive), removed: [])
        await session.close()
    }

    func testAttributeLessSourcesKeepDirectoryKindsAndOmitAddedAttributes() async throws {
        for fixture in ["solid_zero", "zero_lzma2"] {
            let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.frozen(fixture, at: directory.url)
            let session = try ArchiveSession(url: archive)
            if fixture == "solid_zero" {
                let entries = await session.entries()
                _ = try await session.remove([SevenZipUpdateFixture.selection(entries[0])], progress: Progress())
            }
            let source = directory.url.appendingPathComponent("added")
            try Data("new".utf8).write(to: source)
            try FileManager.default.setAttributes([.posixPermissions: 0o755, .modificationDate: SevenZipUpdateFixture.date], ofItemAtPath: source.path)
            _ = try await session.append(urls: [source], to: "", progress: Progress())
            _ = try await session.createFolder(in: "", baseName: "new-directory", progress: Progress())
            let reader = try SevenZipUpdateFixture.reader(archive)
            XCTAssertTrue(try XCTUnwrap(reader.sevenZipEditingSnapshot()).files.allSatisfy { $0.attributes == nil })
            XCTAssertEqual(reader.entries.last?.kind, .directory)
            let added = try XCTUnwrap(reader.entries.first { $0.name == "added" })
            XCTAssertEqual(added.modificationDate, SevenZipUpdateFixture.date)
            XCTAssertEqual(try reader.read(added), Data("new".utf8))
            XCTAssertTrue(session.capabilities.canEdit)
            await session.close()
        }
    }

}
