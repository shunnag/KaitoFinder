import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class LHAUpdateEditTests: XCTestCase {
    func testImmediateEditsPreserveMembersAttributesAndAdoptVerifiedReader() async throws {
        for mixed in [false, true] {
            for operation in 0..<9 {
                let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.make(directory.url, mixed: mixed)
                try FileManager.default.setAttributes([.posixPermissions: 0o640, .creationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: archive.path)
                let quarantine = Data("0083;00000001;KaitoFinder;P4".utf8), tag = Data("tag".utf8)
                try ExtractionQuarantine.apply(quarantine, to: archive)
                XCTAssertEqual(tag.withUnsafeBytes { setxattr(archive.path, "user.kaito", $0.baseAddress, $0.count, 0, 0) }, 0)
                let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
                var attributes = stat(); XCTAssertEqual(lstat(archive.path, &attributes), 0)
                let session = try ArchiveSession(url: archive), entries = await session.entries()
                let beforeContents = try ArchiveOracle.contents(ArchiveReader.open(url: archive), including: .nonDirectories)
                let folder = entries[2].name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let target = entries[mixed && operation == 2 ? 3 : 1]
                let source = directory.url.appendingPathComponent(operation == 7 ? target.name : "added")
                try Data("new".utf8).write(to: source)
                let progress = Progress(), trace = LHAUpdateTrace()
                let parent = target.name.split(separator: "/").dropLast().joined(separator: "/")
                let prefix = parent.isEmpty ? "" : parent + "/"
                var rename: String?
                if operation == 2 {
                    // 実の writer で固定部分の長さを得て、元の header と同長の名前を選ぶ。
                    let sample = directory.url.appendingPathComponent("header.lzh")
                    let writer = try ArchiveWriter.create(url: sample, format: .lha)
                    try writer.add(data: Data(), as: prefix + "x"); try writer.finish()
                    let sampleEntry = try XCTUnwrap(ArchiveReader.open(url: sample).entries.first)
                    let fixed = try XCTUnwrap(sampleEntry.formatSpecific["dataOffset"].flatMap(Int.init)) - 1
                    let length = try XCTUnwrap(target.formatSpecific["dataOffset"].flatMap(Int.init))
                        - XCTUnwrap(target.formatSpecific["headerOffset"].flatMap(Int.init))
                    rename = String(repeating: "r", count: try XCTUnwrap(length > fixed ? length - fixed : nil))
                } else if operation == 3 { rename = "a-much-longer-name" }
                try await trace.observing {
                    try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                        try LHAUpdateFixture.assertWork(work, archive: archive, bytes: original, identity: identity)
                    }) {
                        switch operation {
                        case 0, 1:
                            let result = try await session.remove([LHAUpdateFixture.selection(operation == 0 ? target : entries.last!)], progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        case 2, 3:
                            let result = try await session.rename(LHAUpdateFixture.selection(target), to: rename!, progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        case 4:
                            let selection = ArchiveEditSelection(path: folder, isDirectory: true, entries: entries.filter { $0.name.hasPrefix(folder + "/") })
                            let result = try await session.rename(selection, to: "renamed-folder", progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        case 5, 7:
                            let result = try await session.append(urls: [source], to: "", progress: progress, resolveConflict: { _ in .init(choice: .replace) })
                            XCTAssertTrue(result.failures.isEmpty); XCTAssertNil(result.reloadFailure)
                        case 6:
                            let result = try await session.createFolder(in: "", baseName: "new", progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        default:
                            let result = try await session.edit(moving: [.init(selection: LHAUpdateFixture.selection(target), folder: folder)], progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        }
                    }
                }
                let expected: [LHAUpdater.CommitStrategy] = [.splice, .inPlacePatch, .inPlacePatch, .splice, .splice,
                                                            .appendOnly, .appendOnly, .splice, .splice]
                XCTAssertEqual(trace.strategies.withLock { $0 }, [expected[operation]], "mixed=\(mixed), operation=\(operation)")
                trace.assertRoute([.updaterOpen])
                XCTAssertEqual(trace.adoptions.withLock { $0 }, [.adopted])
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                let fresh = try ArchiveReader.open(url: archive, options: .kaitoFinder()), current = await session.entries()
                XCTAssertEqual(current, fresh.entries)
                let output = try Data(contentsOf: archive)
                for entry in fresh.entries {
                    if let old = entries.first(where: { $0.name == entry.name }), !(operation == 7 && entry.name == target.name) {
                        XCTAssertEqual(try LHAUpdateFixture.group(entry, in: output), try LHAUpdateFixture.group(old, in: original), entry.name)
                    }
                }
                if let rename {
                    let entry = try XCTUnwrap(fresh.entries.first { $0.name == prefix + rename })
                    XCTAssertEqual(entry.formatSpecific["headerLevel"], "2")
                    XCTAssertEqual(try LHAUpdateFixture.group(entry, in: output, payloadOnly: true),
                                   try LHAUpdateFixture.group(target, in: original, payloadOnly: true))
                }
                if operation == 4 {
                    let entry = try XCTUnwrap(fresh.entries.first { $0.name == "renamed-folder/" })
                    XCTAssertEqual(entry.kind, .directory); XCTAssertEqual(entry.formatSpecific["method"], "-lhd-")
                    XCTAssertEqual(entry.formatSpecific["headerLevel"], "2")
                }
                var expectedContents = beforeContents
                switch operation {
                case 0: expectedContents.removeValue(forKey: target.name)
                case 1: expectedContents.removeValue(forKey: entries.last!.name)
                case 2, 3: expectedContents[prefix + rename!] = expectedContents.removeValue(forKey: target.name)
                case 4:
                    expectedContents = Dictionary(uniqueKeysWithValues: beforeContents.map { name, bytes in
                        (name.hasPrefix(folder + "/") ? "renamed-folder/" + name.dropFirst(folder.count + 1) : name, bytes)
                    })
                case 5: expectedContents["added"] = Data("new".utf8)
                case 7: expectedContents[target.name] = Data("new".utf8)
                case 8: expectedContents[folder + "/" + target.name] = expectedContents.removeValue(forKey: target.name)
                default: break
                }
                XCTAssertEqual(try ArchiveOracle.contents(fresh, including: .nonDirectories), expectedContents)
                var saved = stat(); XCTAssertEqual(lstat(archive.path, &saved), 0)
                XCTAssertEqual(saved.st_mode & 0o7777, attributes.st_mode & 0o7777)
                XCTAssertEqual(saved.st_birthtimespec.tv_sec, attributes.st_birthtimespec.tv_sec)
                XCTAssertEqual(saved.st_birthtimespec.tv_nsec, attributes.st_birthtimespec.tv_nsec)
                XCTAssertEqual(try ExtractionQuarantine.read(from: archive), quarantine)
                var savedTag = Data(count: tag.count)
                XCTAssertEqual(savedTag.withUnsafeMutableBytes { getxattr(archive.path, "user.kaito", $0.baseAddress, $0.count, 0, 0) }, tag.count)
                XCTAssertEqual(savedTag, tag)
                await session.close()
            }
        }
    }

    func testDeleteAllThenAddImmediatelyAndDeferred() async throws {
        for deferred in [false, true] {
            let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.make(directory.url)
            let source = directory.url.appendingPathComponent("added"); try Data("new".utf8).write(to: source)
            let stamp = try ArchiveImportSourceStamp(source), session = try ArchiveSession(url: archive)
            for removing in [true, false] {
                let snapshot = try await session.deferredSnapshot(), progress = Progress()
                if deferred {
                    var pending = ArchivePendingChanges()
                    if removing { pending.removals = Set(snapshot.entries.map { .init(index: $0.index, expectedName: $0.name, baseGeneration: snapshot.generation) }) }
                    else { pending.additions = [.init(id: UUID(), path: "added", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)] }
                    let publication = ArchiveSavePublication(); defer { publication.finish() }
                    let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: progress, publication: publication)
                    XCTAssertNil(result.reloadFailure)
                } else if removing {
                    let selections = snapshot.entries.filter { !$0.name.hasPrefix("folder/") }.map(LHAUpdateFixture.selection)
                        + [ArchiveEditSelection(path: "folder", isDirectory: true, entries: snapshot.entries.filter { $0.name.hasPrefix("folder/") })]
                    let result = try await session.remove(selections, progress: progress)
                    XCTAssertNil(result.reloadFailure)
                } else {
                    let result = try await session.append(urls: [source], to: "", progress: progress)
                    XCTAssertNil(result.reloadFailure)
                }
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                XCTAssertEqual(session.capabilities.mode, .update(.lha))
                XCTAssertEqual(try ArchiveReader.open(url: archive).entries.map(\.name), removing ? [] : ["added"])
                if removing { XCTAssertEqual(try Data(contentsOf: archive), Data([0])) }
            }
            await session.close()
        }
    }

    func testMixedCP932DeclaredAndASCIINamesSurviveJapaneseAdditionAndRename() async throws {
        let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.frozen("names-cp932-mixed", at: directory.url)
        let original = try Data(contentsOf: archive), session = try ArchiveSession(url: archive), entries = await session.entries()
        XCTAssertNil(session.capabilities.lhaRewriteReason)
        let source = directory.url.appendingPathComponent("追加.txt"); try Data("added".utf8).write(to: source)
        let trace = LHAUpdateTrace()
        try await trace.observing {
            let result = try await session.append(urls: [source], to: "", progress: Progress())
            XCTAssertNil(result.reloadFailure)
            let result2 = try await session.rename(LHAUpdateFixture.selection(entries[2]), to: "改名.txt", progress: Progress())
            XCTAssertNil(result2.reloadFailure)
        }
        trace.assertRoute([.updaterOpen, .updaterOpen])
        let reader = try ArchiveReader.open(url: archive), output = try Data(contentsOf: archive)
        XCTAssertEqual(reader.entries.map(\.name), ["漫画/表紙.txt", "東京.txt", "改名.txt", "追加.txt"])
        for index in 0..<2 {
            XCTAssertEqual(reader.entries[index].rawName, entries[index].rawName)
            XCTAssertEqual(try LHAUpdateFixture.group(reader.entries[index], in: output), try LHAUpdateFixture.group(entries[index], in: original))
        }
        await session.close()
    }
}
