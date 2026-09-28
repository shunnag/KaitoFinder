import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class TarUpdateEditTests: XCTestCase {
    private static func assertWork(_ work: URL, archive: URL, original: Data, identity: ArchiveFileIdentity) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.deletingLastPathComponent().path), ["archive.tar"])
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(try ArchiveFileIdentity.capture(url: archive), identity)
    }

    func testImmediateEditsKeepMemberBytesAttributesAndAdoptVerifiedReader() async throws {
        let expected: [TarUpdater.CommitStrategy] = [.splice, .inPlacePatch, .inPlacePatch, .splice, .inPlacePatch,
                                                     .appendOnly, .appendOnly, .splice, .inPlacePatch]
        for operation in expected.indices {
            let directory = try ArchiveTestDirectory(), archive = try TarUpdateFixture.archive(directory.url)
            try FileManager.default.setAttributes([.posixPermissions: 0o640, .creationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: archive.path)
            let quarantine = Data("0083;00000001;KaitoFinder;P2".utf8), tag = Data("tag".utf8)
            try ExtractionQuarantine.apply(quarantine, to: archive)
            XCTAssertEqual(tag.withUnsafeBytes { setxattr(archive.path, "user.kaito", $0.baseAddress, $0.count, 0, 0) }, 0)
            let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
            var attributes = stat(); XCTAssertEqual(lstat(archive.path, &attributes), 0)
            let session = try ArchiveSession(url: archive), entries = await session.entries()
            let source = directory.url.appendingPathComponent(operation == 7 ? "remove" : "added")
            try Data("new".utf8).write(to: source)
            let strategies = Mutex<[TarUpdater.CommitStrategy?]>([]), adoption = Mutex<[ArchiveReaderAdoption]>([])
            let progress = Progress()
            try await ArchiveSession.readerAdoptionObserverForTesting.withValue({ event in adoption.withLock { $0.append(event) } }) {
                try await ArchiveImportTransaction.didCommitTarUpdaterForTesting.withValue({ updater in
                    strategies.withLock { $0.append(updater.lastCommitStrategy) }
                }) {
                    try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                        try Self.assertWork(work, archive: archive, original: original, identity: identity)
                    }) {
                        switch operation {
                        case 0, 1:
                            let result = try await session.remove([TarUpdateFixture.selection(entries[operation == 0 ? 1 : 4])], progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        case 2, 3:
                            let result = try await session.rename(TarUpdateFixture.selection(entries[1]),
                                to: operation == 2 ? "rename" : String(repeating: "n", count: 150), progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        case 4:
                            let selection = ArchiveEditSelection(path: "folder", isDirectory: true, entries: Array(entries[2...3]))
                            let result = try await session.rename(selection, to: "renamed", progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        case 5, 7:
                            let result = try await session.append(urls: [source], to: "", progress: progress, resolveConflict: { _ in .init(choice: .replace) })
                            XCTAssertNil(result.reloadFailure)
                        case 6:
                            let result = try await session.createFolder(in: "", baseName: "new", progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        default:
                            let result = try await session.edit(moving: [.init(selection: TarUpdateFixture.selection(entries[1]), folder: "folder")], progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        }
                    }
                }
            }
            XCTAssertEqual(strategies.withLock { $0 }, [expected[operation]], "operation \(operation)")
            XCTAssertEqual(adoption.withLock { $0 }, [.adopted])
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
            let fresh = try ArchiveReader.open(url: archive, options: .kaitoFinder()), current = await session.entries()
            XCTAssertEqual(current, fresh.entries)
            let groups = TarUpdateFixture.groups(try Data(contentsOf: archive)), before = TarUpdateFixture.groups(original)
            for entry in fresh.entries {
                if let index = entries.firstIndex(where: { $0.name == entry.name }), !(operation == 7 && entry.name == "remove") {
                    XCTAssertEqual(groups[entry.index], before[index], entry.name)
                    XCTAssertEqual(entry.formatSpecific["uid"], "501"); XCTAssertEqual(entry.formatSpecific["gid"], "20")
                }
            }
            XCTAssertTrue(groups[0].range(of: Data("alice".utf8)) != nil)
            XCTAssertTrue(groups[0].range(of: Data("SCHILY.xattr.user.kaito=kept".utf8)) != nil)
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

    func testDeferredFiveChangesAndRenameOnlyKeepProjectedStorageOrder() async throws {
        for renameOnly in [false, true] {
            let directory = try ArchiveTestDirectory(), archive = try TarUpdateFixture.archive(directory.url)
            let session = try ArchiveSession(url: archive), snapshot = try await session.deferredSnapshot()
            let source = directory.url.appendingPathComponent("added"); try Data("new".utf8).write(to: source)
            let stamp = try ArchiveImportSourceStamp(source)
            var pending = ArchivePendingChanges()
            pending.renames[.init(index: 1, expectedName: "remove", baseGeneration: snapshot.generation)] = "renamed"
            if !renameOnly {
                pending.removals = [.init(index: 3, expectedName: "folder/child", baseGeneration: snapshot.generation),
                                    .init(index: 4, expectedName: "last", baseGeneration: snapshot.generation)]
                pending.additions = [.init(id: UUID(), path: "added", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)]
                pending.createdFolders = [.init(id: UUID(), path: "new/")]
            }
            let expected = try pending.projection(base: snapshot.entries, generation: snapshot.generation).map(\.name)
            let publication = ArchiveSavePublication(); defer { publication.finish() }
            let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([]), progress = Progress()
            let result = try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
            }) { try await session.savePending(pending, baseGeneration: snapshot.generation, progress: progress, publication: publication) }
            XCTAssertNil(result.reloadFailure)
            XCTAssertEqual(try ArchiveReader.open(url: archive).entries.map(\.name), expected)
            XCTAssertEqual(try ArchiveReader.open(url: archive).entries.map(\.index), Array(expected.indices))
            XCTAssertEqual(stages.withLock { $0.filter { $0 == .updaterOpen || $0 == .rewriterOpen || $0 == .workCopy } }, [.updaterOpen])
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
            await session.close()
        }
    }

    func testDeleteAllThenAddToEmptyTarImmediatelyAndDeferred() async throws {
        for deferred in [false, true] {
            let directory = try ArchiveTestDirectory(), archive = try TarUpdateFixture.archive(directory.url)
            let source = directory.url.appendingPathComponent("added")
            try Data("new".utf8).write(to: source)
            let stamp = try ArchiveImportSourceStamp(source), session = try ArchiveSession(url: archive)
            for removing in [true, false] {
                let snapshot = try await session.deferredSnapshot()
                if deferred {
                    var pending = ArchivePendingChanges()
                    if removing { pending.removals = Set(snapshot.entries.map { .init(index: $0.index, expectedName: $0.name, baseGeneration: snapshot.generation) }) }
                    else { pending.additions = [.init(id: UUID(), path: "added", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)] }
                    let publication = ArchiveSavePublication(); defer { publication.finish() }
                    let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
                    XCTAssertNil(result.reloadFailure)
                } else if removing {
                    let selections = snapshot.entries.filter { $0.kind != .directory && !$0.name.hasPrefix("folder/") }.map(TarUpdateFixture.selection)
                        + [ArchiveEditSelection(path: "folder", isDirectory: true, entries: snapshot.entries.filter { $0.name.hasPrefix("folder/") })]
                    let result = try await session.remove(selections, progress: Progress())
                    XCTAssertNil(result.reloadFailure)
                } else {
                    let result = try await session.append(urls: [source], to: "", progress: Progress())
                    XCTAssertNil(result.reloadFailure)
                }
                XCTAssertEqual(session.capabilities.mode, .update(.tar))
                XCTAssertEqual(try ArchiveReader.open(url: archive).entries.map(\.name), removing ? [] : ["added"])
            }
            await session.close()
        }
    }

    func testStructuralFallbackOpensAndMutatesExactlyOnce() throws {
        var sparse = TarUpdateFixture.member("sparse", type: 83, body: Data())
        sparse.replaceSubrange(257..<265, with: Data("ustar  \0".utf8)); TarUpdateFixture.checksum(&sparse)
        var legacy = TarUpdateFixture.member("name", body: Data())
        legacy.replaceSubrange(0..<4, with: Data([0x93, 0xfa, 0x96, 0x7b])); TarUpdateFixture.checksum(&legacy)
        let root = TarUpdateFixture.member("./", type: 53, body: Data())
        for prefix in [TarUpdateFixture.pax("uid", "501", type: 103) + root, sparse, legacy] {
            for deferred in [false, true] {
                let directory = try ArchiveTestDirectory(), archive = try TarUpdateFixture.archive(directory.url,
                    bytes: prefix + TarUpdateFixture.member("keep") + TarUpdateFixture.member("remove") + Data(count: 1024))
                let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
                let entries = try ArchiveReader.open(url: archive).entries
                var pending = ArchivePendingChanges()
                pending.removals = [.init(index: entries.count - 1, expectedName: "remove", baseGeneration: 0)]
                let plan = try ArchiveSaveReplayPlan(base: entries, generation: 0, pending: pending, format: .tar)
                let openings = ArchiveTestCounter(), mutations = ArchiveTestCounter(), fallbacks = ArchiveTestCounter()
                let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([]), progress = Progress(totalUnitCount: 2)
                try ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallbacks.increment() }) {
                    try ArchiveStageDiagnostics.observer.withValue({ event in
                        if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
                    }) {
                        try ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                            try Self.assertWork(work, archive: archive, original: original, identity: identity)
                        }) {
                            try ArchiveImportTransaction.publish(archive: archive, mode: .update(.tar), options: .init(), progress: progress,
                                willOpenUpdater: { openings.increment() }, willPublish: nil, deferredPlan: deferred ? plan : nil,
                                expectedOutput: .init(plan: plan, mode: .update(.tar))) { editor in
                                    mutations.increment(); try plan.replay(on: editor, progress: progress)
                                }
                        }
                    }
                }
                XCTAssertEqual(openings.value, 1); XCTAssertEqual(mutations.value, 1); XCTAssertEqual(fallbacks.value, 1)
                XCTAssertEqual(stages.withLock { $0.filter { $0 == .updaterOpen || $0 == .rewriterOpen } }, [.updaterOpen, .rewriterOpen])
                XCTAssertEqual(stages.withLock { $0.filter { $0 == .mutate || $0 == .replay } }, [deferred ? .replay : .mutate])
                let reader = try ArchiveReader.open(url: archive)
                XCTAssertEqual(progress.totalUnitCount, Int64(entries.count + 2))
                XCTAssertEqual(progress.completedUnitCount, Int64(reader.entries.count + 2))
                try ArchiveOutputProjection(plan: plan, mode: .rewrite(.tar)).validate(reader)
                XCTAssertTrue(ArchiveCapabilities.inspect(reader: reader, url: archive).canEdit)
            }
        }
    }

    func testOutputOrderAndLinkCorruptionAndUpdaterVerificationAreRejected() async throws {
        let bytes = TarUpdateFixture.member("one") + TarUpdateFixture.member("two")
            + TarUpdateFixture.member("link", type: 49, body: Data(), link: "one") + Data(count: 1024)
        for corruption in 0..<3 {
            let directory = try ArchiveTestDirectory(), archive = try TarUpdateFixture.archive(directory.url, bytes: bytes)
            let session = try ArchiveSession(url: archive), fallback = ArchiveTestCounter()
            do {
                try await ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallback.increment() }) {
                    try await ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
                        if corruption == 2 { throw TarUpdaterError.outputVerificationFailed(reason: "injected") }
                    }) {
                        try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                            var output = try Data(contentsOf: work)
                            if corruption == 0 {
                                let first = output.subdata(in: 0..<1024)
                                output.replaceSubrange(0..<1024, with: output.subdata(in: 1024..<2048))
                                output.replaceSubrange(1024..<2048, with: first)
                            } else {
                                var header = output.subdata(in: 2048..<2560)
                                header.replaceSubrange(157..<160, with: Data("two".utf8)); TarUpdateFixture.checksum(&header)
                                output.replaceSubrange(2048..<2560, with: header)
                            }
                            try output.write(to: work)
                        }) { _ = try await session.createFolder(in: "", baseName: "new", progress: Progress()) }
                    }
                }
                XCTFail("Corrupt output must not publish")
            } catch { XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed) }
            XCTAssertEqual(fallback.value, 0)
            XCTAssertEqual(try Data(contentsOf: archive), bytes)
            XCTAssertTrue(session.capabilities.canEdit)
            await session.close()
        }
    }

    func testRequiresRewriteAfterOpenDoesNotReplayMutation() throws {
        let directory = try ArchiveTestDirectory(), archive = try TarUpdateFixture.archive(directory.url)
        let entries = try ArchiveReader.open(url: archive).entries, calls = ArchiveTestCounter(), fallback = ArchiveTestCounter()
        for duringCommit in [false, true] {
            XCTAssertThrowsError(try ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallback.increment() }) {
                try ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
                    throw TarUpdaterError.requiresRewrite(reason: "commit must not fall back")
                }) {
                    try ArchiveImportTransaction.publish(archive: archive, mode: .update(.tar), options: .init(), progress: Progress(),
                        willPublish: nil, expectedOutput: .init(existing: entries, mode: .update(.tar))) { _ in
                            calls.increment()
                            if !duringCommit { throw TarUpdaterError.requiresRewrite(reason: "mutate must not fall back") }
                        }
                }
            }) { XCTAssertTrue($0 is TarUpdaterError) }
            XCTAssertEqual(try Data(contentsOf: archive), TarUpdateFixture.bytes)
        }
        XCTAssertEqual(calls.value, 2); XCTAssertEqual(fallback.value, 0)
    }

    func testZeroByteCommitProgressFinishesAndCancellationKeepsOriginal() throws {
        let directory = try ArchiveTestDirectory(), archive = try TarUpdateFixture.archive(directory.url)
        let entries = try ArchiveReader.open(url: archive).entries, progress = Progress(totalUnitCount: 1)
        try ArchiveImportTransaction.publish(archive: archive, mode: .update(.tar), options: .init(), progress: progress,
            willPublish: nil, expectedOutput: .init(existing: entries, mode: .update(.tar))) { _ in }
        XCTAssertEqual(progress.totalUnitCount, 1001); XCTAssertEqual(progress.completedUnitCount, 1001)
        let original = try Data(contentsOf: archive)
        XCTAssertThrowsError(try ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({ progress.cancel() }) {
            try ArchiveImportTransaction.publish(archive: archive, mode: .update(.tar), options: .init(), progress: progress,
                willPublish: nil, expectedOutput: .init(existing: entries, mode: .update(.tar))) { _ in }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    func testCarriedNamesKeepExactBytes() async throws {
        let names = ["./dot", "/absolute", "double//slash", "cafe\u{301}"]
        let bytes = names.reduce(Data()) { $0 + TarUpdateFixture.member($1) } + Data(count: 1024)
        let directory = try ArchiveTestDirectory(), archive = try TarUpdateFixture.archive(directory.url, bytes: bytes)
        let session = try ArchiveSession(url: archive)
        XCTAssertTrue(session.capabilities.canEdit)
        let result = try await session.createFolder(in: "", baseName: "new", progress: Progress())
        XCTAssertNil(result.reloadFailure)
        let saved = try ArchiveReader.open(url: archive).entries
        XCTAssertEqual(saved.prefix(4).map { $0.rawName.bytes }, names.map { Array($0.utf8) })
        XCTAssertEqual(Array(TarUpdateFixture.groups(try Data(contentsOf: archive)).prefix(4)), TarUpdateFixture.groups(bytes))
        await session.close()
    }

    private func volumeEdits(_ root: URL) async throws -> [ArchiveEntry] {
        let archive = try TarUpdateFixture.archive(root), session = try ArchiveSession(url: archive)
        let source = root.appendingPathComponent("added"); try Data("new".utf8).write(to: source)
        var entries = await session.entries()
        let removed = try await session.remove([TarUpdateFixture.selection(entries[1])], progress: Progress())
        XCTAssertNil(removed.reloadFailure)
        let added = try await session.append(urls: [source], to: "", progress: Progress())
        XCTAssertNil(added.reloadFailure)
        entries = await session.entries()
        let renamed = try await session.rename(TarUpdateFixture.selection(entries[0]), to: "kept", progress: Progress())
        XCTAssertNil(renamed.reloadFailure)
        let snapshot = try await session.deferredSnapshot()
        var pending = ArchivePendingChanges(); pending.createdFolders = [.init(id: UUID(), path: "saved/", date: Date(timeIntervalSince1970: 1_700_000_000))]
        let publication = ArchiveSavePublication(); defer { publication.finish() }
        let saved = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
        XCTAssertNil(saved.reloadFailure)
        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first { $0.name == "added" })), Data("new".utf8))
        let result = await session.entries(); await session.close()
        return result
    }

    private func checkVolume(_ fileSystem: String) async throws {
        let disk = try VolumePublishTestDisk(fileSystem), directory = try ArchiveTestDirectory()
        let baseline = try await volumeEdits(directory.url), actual = try await volumeEdits(disk.mount)
        XCTAssertEqual(actual.map(\.name), baseline.map(\.name)); XCTAssertEqual(actual.map(\.kind), baseline.map(\.kind))
        XCTAssertEqual(actual.map(\.uncompressedSize), baseline.map(\.uncompressedSize))
    }
    func testHFSPlusEditsMatchAPFS() async throws { try await checkVolume("HFS+") }
    func testExFATEditsMatchAPFS() async throws { try await checkVolume("ExFAT") }
    func testFAT32EditsMatchAPFS() async throws { try await checkVolume("MS-DOS FAT32") }
    func testSequentialEditsWithoutCloneMatchAPFS() async throws {
        let a = try ArchiveTestDirectory(), b = try ArchiveTestDirectory()
        let baseline = try await volumeEdits(a.url)
        let strategies = Mutex<[TarUpdater.CommitStrategy?]>([])
        let actual = try await TarUpdater.$testingDisablesClone.withValue(true) {
            try await ArchiveImportTransaction.didCommitTarUpdaterForTesting.withValue({ updater in strategies.withLock { $0.append(updater.lastCommitStrategy) } }) {
                try await volumeEdits(b.url)
            }
        }
        XCTAssertEqual(strategies.withLock { $0 }, Array(repeating: .sequential, count: 4))
        XCTAssertEqual(actual.map(\.name), baseline.map(\.name)); XCTAssertEqual(actual.map(\.kind), baseline.map(\.kind))
        XCTAssertEqual(actual.map(\.uncompressedSize), baseline.map(\.uncompressedSize))
    }
}
