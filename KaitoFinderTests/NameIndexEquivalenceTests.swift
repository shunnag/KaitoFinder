import Foundation
@_spi(Testing) import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class NameIndexEquivalenceTests: XCTestCase {
    private func entry(_ index: Int, _ name: String, kind: EntryKind = .file) -> ArchiveEntry {
        ArchiveEntry(index: index, rawName: .init(bytes: Array(name.utf8)), name: name,
            pathComponents: ArchivePath.components(name), kind: kind, uncompressedSize: kind == .directory ? 0 : 1,
            compressedSize: nil, modificationDate: nil, posixPermissions: nil, isEncrypted: false,
            solidGroup: -1, crc32: nil, methodDescription: "stored", formatSpecific: [:])
    }

    private func reference(_ entry: ArchiveEntry, generation: UInt64) -> ArchivePendingChanges.BaseReference {
        .init(index: entry.index, expectedName: entry.name, baseGeneration: generation)
    }

    private func checkIndex(_ session: ArchiveSession, file: StaticString = #filePath, line: UInt = #line) async throws {
        let snapshot = await session.snapshot()
        let index = try XCTUnwrap(session.nameIndex(generation: snapshot.generation, format: session.reservationFormat), file: file, line: line)
        let rebuilt = try XCTUnwrap(ArchiveNameIndex.build(entries: snapshot.entries, generation: snapshot.generation,
            format: session.reservationFormat, provingRepresentability: index.representable, checksCancellation: false), file: file, line: line)
        XCTAssertEqual(index.occupancy.keys(), rebuilt.occupancy.keys(), file: file, line: line)
        XCTAssertEqual(index.containsHardLinks, rebuilt.containsHardLinks, file: file, line: line)
        XCTAssertEqual(index.representable, rebuilt.representable, file: file, line: line)
        XCTAssertEqual(index.entryCount, snapshot.entries.count, file: file, line: line)
    }

    func testCleanPredicateAndHardLinksRetainMultiplicity() throws {
        for names in [["a", "a"], ["café", "cafe\u{301}"], ["K", "\u{212A}"], ["./a"], ["a//b"], ["a", "folder/", "folder/child"]] {
            let entries = names.enumerated().map { entry($0.offset, $0.element, kind: $0.element.hasSuffix("/") ? .directory : .file) }
            let index = ArchiveNameIndex.build(entries: entries, generation: 0, format: .zip,
                                               provingRepresentability: false, checksCancellation: false)
            XCTAssertEqual(index == nil, EntryNode.renameOccupancy(from: entries, format: .zip) == nil)
            if names == ["a", "a"] { XCTAssertEqual(index?.occupancy.keys()["a"], [false, false]) }
        }
        let links = [entry(0, "a"), entry(1, "link", kind: .hardlink)]
        let index = try XCTUnwrap(ArchiveNameIndex.build(entries: links, generation: 0, format: .tar,
            provingRepresentability: false, checksCancellation: false))
        XCTAssertTrue(index.containsHardLinks)
        XCTAssertEqual(index.occupancy.keys()["link"], [false])
        XCTAssertNil(ArchiveReservationValidation(base: links, format: .tar).occupancy)
    }

    @MainActor func testImmediateCorpusMatchesDisabledIndexIncludingRejections() async throws {
        for names in [["a", "b"], ["café", "cafe\u{301}"], ["K", "\u{212A}"], ["same", "same"], ["./a", "b"], ["a//b", "other"]] {
            let encoded = String(data: try JSONSerialization.data(withJSONObject: names), encoding: .utf8)!
            let fixture = try ScenarioFixture(script: """
            with zipfile.ZipFile(p, 'w') as z:
                for n in \(encoded): z.writestr(n, b'x')
                z.writestr('folder/', b''); z.writestr('folder/child', b'child')
                z.writestr('target/keep', b'keep')
            """)
            try await compareImmediate(archive: fixture.archive, directory: fixture.root)
        }
        let directory = try ArchiveTestDirectory()
        let archive = try TarUpdateFixture.archive(directory.url, bytes:
            TarUpdateFixture.member("a") + TarUpdateFixture.member("b")
            + TarUpdateFixture.member("link", type: 49, body: Data(), link: "a")
            + TarUpdateFixture.member("folder/", type: 53, body: Data())
            + TarUpdateFixture.member("folder/child") + TarUpdateFixture.member("target/keep") + Data(count: 1024))
        try await compareImmediate(archive: archive, directory: directory.url)
    }

    @MainActor private func compareImmediate(archive: URL, directory: URL) async throws {
        let original = try Data(contentsOf: archive)
        let incoming = directory.appendingPathComponent("child")
        try Data("incoming".utf8).write(to: incoming)
        for operation in ["remove_file", "remove_folder", "rename_file", "rename_folder", "move", "replace", "skip", "add", "folder", "invalid", "collision"] {
            var outcomes: [Outcome] = []
            for disabled in [true, false] {
                try original.write(to: archive)
                let session = try ArchiveSession(url: archive)
                let outcome = await ArchiveSession.nameIndexDisabledForTesting.withValue(disabled) {
                    do {
                        let entries = await session.entries(), root = EntryNode.tree(from: entries)
                        let folder = try XCTUnwrap(root.children.first { $0.path == "folder" })
                        let first = entries[0]
                        let selection = ArchiveEditSelection(path: first.name, isDirectory: false, entries: [first])
                        switch operation {
                        case "remove_file": _ = try await session.remove([selection], progress: Progress())
                        case "remove_folder": _ = try await session.remove([ArchiveEditSelection(folder)], progress: Progress())
                        case "rename_file": _ = try await session.rename(selection, to: "renamed", progress: Progress())
                        case "rename_folder": _ = try await session.rename(ArchiveEditSelection(folder), to: "renamed-folder", progress: Progress())
                        case "move": _ = try await session.move([selection], to: "target", progress: Progress(), resolveConflict: { _ in .init(choice: .replace) })
                        case "invalid": _ = try await session.rename(selection, to: "../bad", progress: Progress())
                        case "collision": _ = try await session.rename(selection, to: "folder", progress: Progress())
                        case "folder": _ = try await session.createFolder(in: "target", baseName: "new", progress: Progress())
                        default:
                            let result = try await session.append(urls: [incoming], to: operation == "add" ? "" : "folder", progress: Progress(),
                                resolveConflict: { _ in .init(choice: operation == "skip" ? .skip : .replace) })
                            XCTAssertTrue(result.failures.isEmpty)
                        }
                        return Outcome(names: outputNames(archive), error: nil)
                    } catch {
                        return Outcome(names: outputNames(archive), error: Self.errorSignature(error))
                    }
                }
                outcomes.append(outcome)
                await session.close()
            }
            XCTAssertEqual(outcomes[0], outcomes[1], operation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.path))
        }
    }

    @MainActor func testImmediateAdvanceAndBuildCountersForZIPAndTar() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar, .tarGzip, .lha] {
            let fixture = try DeferredSaveFixture(format: format, behavior: .immediate)
            defer { fixture.document.close() }
            let session = try XCTUnwrap(fixture.document.session), trace = Trace()
            try await trace.observe {
                _ = await session.prepareNameIndex(generation: session.generation)
                let entries = await session.entries()
                let folder = try XCTUnwrap(EntryNode.tree(from: entries).children.first { $0.path == "folder" })
                _ = try await session.rename(ArchiveEditSelection(folder), to: "renamed", progress: Progress())
                try await checkIndex(session)
                _ = try await session.append(urls: [fixture.file("added")], to: "", progress: Progress())
                try await checkIndex(session)
                _ = try await session.createFolder(in: "", baseName: "new", progress: Progress())
                try await checkIndex(session)
                let current = await session.entries()
                let removed = try XCTUnwrap(current.first { $0.name == "b.txt" })
                _ = try await session.remove([.init(path: removed.name, isDirectory: false, entries: [removed])], progress: Progress())
                try await checkIndex(session)
            }
            XCTAssertEqual(trace.count(.nameIndexBuild), 1, "\(format)")
            XCTAssertEqual(trace.count(.nameIndexAdvance), 4, "\(format)")
        }
    }

    @MainActor func testDeletionWithoutIndexDoesNotBuildAndBadAdvanceRebuildsOnce() async throws {
        for folder in [false, true] {
            let fixture = try DeferredSaveFixture(behavior: .immediate)
            defer { fixture.document.close() }
            let session = try XCTUnwrap(fixture.document.session), trace = Trace()
            let selected = try await fixture.node(folder ? "folder" : "a.txt")
            try await trace.observe { _ = try await fixture.document.remove([selected], progress: Progress()) }
            XCTAssertEqual(trace.count(.nameIndexBuild), 0)
            XCTAssertNil(session.nameIndex(generation: session.generation, format: .zip))
        }
        let fixture = try DeferredSaveFixture(behavior: .immediate)
        defer { fixture.document.close() }
        let session = try XCTUnwrap(fixture.document.session)
        _ = await session.currentNameIndex()
        let selected = try await fixture.node("a.txt")
        try await ArchiveSession.nameIndexChangeForTesting.withValue({ change in
            var change = change; change.removed = []; return change
        }) { _ = try await session.remove([ArchiveEditSelection(selected)], progress: Progress()) }
        XCTAssertNil(session.nameIndex(generation: session.generation, format: .zip))
        let trace = Trace()
        try await trace.observe { _ = try await session.createFolder(in: "", baseName: "next", progress: Progress()) }
        XCTAssertEqual(trace.count(.nameIndexBuild), 1)
        try await checkIndex(session)
    }

    @MainActor func testDeferredSaveReusesProofAndInstallForEveryUpdaterFormat() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar, .tarGzip, .lha, .sevenZip] {
            let fixture = try DeferredSaveFixture(format: format)
            defer { fixture.document.close() }
            _ = try await fixture.document.rename(fixture.node("a.txt"), to: "renamed", progress: Progress())
            _ = try await fixture.document.append(urls: [fixture.file("added")], to: "", progress: Progress())
            _ = try await fixture.document.createFolder(in: "", baseName: "new", progress: Progress())
            _ = try await fixture.document.remove([fixture.node("b.txt")], progress: Progress())
            let trace = Trace(), slow = ArchiveTestCounter()
            try await trace.observe {
                try await ArchiveTestCounters.slowRepresentability.withValue(slow) {
                    try await fixture.save()
                    await fixture.document.waitForDeferredPreparationForTesting()
                }
            }
            XCTAssertEqual(trace.count(.representabilityDifferential), 1, "\(format)")
            XCTAssertEqual(trace.count(.planKeys), 0)
            XCTAssertEqual(trace.events.withLock { $0.filter { $0 == .fullValidation }.count }, 0)
            XCTAssertEqual(slow.value, 0)
            if format != .sevenZip {
                XCTAssertEqual(trace.events.withLock { $0.filter { $0 == .baseValidation }.count }, 0)
                XCTAssertEqual(trace.count(.validateRepresentability), 0)
            } else { XCTAssertEqual(trace.events.withLock { $0.filter { $0 == .baseValidation }.count }, 1) }
            try await checkIndex(try XCTUnwrap(fixture.document.session))
        }
    }

    @MainActor func testDeferredCyclesAndFallbackCorpusMatchDisabledIndex() async throws {
        for names in [["a", "b", "delete"], ["café", "cafe\u{301}", "delete"], ["K", "\u{212A}", "delete"],
                      ["same", "same", "delete"], ["./a", "b", "delete"], ["a//child", "b", "delete"]] {
            let encoded = String(data: try JSONSerialization.data(withJSONObject: names), encoding: .utf8)!
            let fixture = try ScenarioFixture(script: """
            with zipfile.ZipFile(p, 'w') as z:
                for n in \(encoded): z.writestr(n, b'x')
            """)
            try await compareDeferred(archive: fixture.archive, directory: fixture.root)
        }
        let directory = try ArchiveTestDirectory()
        let archive = try TarUpdateFixture.archive(directory.url, bytes: TarUpdateFixture.member("a") + TarUpdateFixture.member("b")
            + TarUpdateFixture.member("delete") + TarUpdateFixture.member("link", type: 49, body: Data(), link: "a") + Data(count: 1024))
        try await compareDeferred(archive: archive, directory: directory.url)
    }

    @MainActor private func compareDeferred(archive: URL, directory: URL) async throws {
        let original = try Data(contentsOf: archive), source = directory.appendingPathComponent("added")
        try Data([7]).write(to: source)
        let stamp = try ArchiveImportSourceStamp(source)
        var outcomes: [Outcome] = []
        for disabled in [true, false] {
            try original.write(to: archive)
            let session = try ArchiveSession(url: archive)
            let outcome = await ArchiveSession.nameIndexDisabledForTesting.withValue(disabled) {
                do {
                    let snapshot = await session.snapshot()
                    let editor = ArchivePendingEditor()
                    try await editor.install(base: snapshot.entries, generation: snapshot.generation, format: session.reservationFormat,
                        sessionID: ObjectIdentifier(session), index: session.nameIndex(generation: snapshot.generation, format: session.reservationFormat))
                    session.adoptNameIndex(validation: editor.validation, generation: snapshot.generation)
                    var pending = ArchivePendingChanges()
                    pending.renames[reference(snapshot.entries[0], generation: snapshot.generation)] = snapshot.entries[1].name
                    pending.renames[reference(snapshot.entries[1], generation: snapshot.generation)] = snapshot.entries[0].name
                    pending.removals.insert(reference(snapshot.entries[2], generation: snapshot.generation))
                    pending.additions = [.init(id: UUID(), path: "added", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)]
                    pending.createdFolders = [.init(id: UUID(), path: "new/")]
                    let projection = try ArchivePendingProjection(pending.projection(base: snapshot.entries, generation: snapshot.generation))
                    try XCTUnwrap(editor.validation).validate(pending, projection: projection)
                    let publication = ArchiveSavePublication(); defer { publication.finish() }
                    let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
                    XCTAssertNil(result.reloadFailure)
                    if !disabled, session.nameIndex(generation: session.generation, format: session.reservationFormat) != nil { try await checkIndex(session) }
                    return Outcome(names: outputNames(archive), error: nil)
                } catch { return Outcome(names: outputNames(archive), error: Self.errorSignature(error)) }
            }
            outcomes.append(outcome)
            await session.close()
        }
        XCTAssertEqual(outcomes[0], outcomes[1])
    }

    @MainActor func testRewriteFallbackDropsProofBeforeNextEdit() async throws {
        let fixture = try DeferredSaveFixture(behavior: .immediate)
        defer { fixture.document.close() }
        let session = try XCTUnwrap(fixture.document.session)
        _ = await session.currentNameIndex()
        try await ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
            throw UpdaterError.nonRelocatableEntry(index: 0, name: "a.txt", reason: "test")
        }) {
            let snapshot = await session.snapshot()
            var pending = ArchivePendingChanges()
            pending.outputEncryption = .init(password: "new-key")
            let publication = ArchiveSavePublication(); defer { publication.finish() }
            let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
            XCTAssertNil(result.reloadFailure)
        }
        XCTAssertNil(session.nameIndex(generation: session.generation, format: .zip))
        let trace = Trace()
        try await trace.observe { _ = try await session.createFolder(in: "", baseName: "after", progress: Progress()) }
        XCTAssertEqual(trace.count(.nameIndexBuild), 1)
        try await checkIndex(session)
    }

    func testAdvanceRejectsOrderKindAndDirtyNamesAndDowngradesUnrepresentableChange() throws {
        let base = [entry(0, "a"), entry(1, "b")]
        let index = try XCTUnwrap(ArchiveNameIndex.build(entries: base, generation: 0, format: .zip,
            provingRepresentability: true, checksCancellation: false))
        XCTAssertTrue(index.representable)
        XCTAssertNil(index.advancing(.init(mode: .rewrite(.zip)), previous: base, entries: base, generation: 1, format: .zip))
        XCTAssertNil(index.advancing(.init(mode: .inPlace), previous: base, entries: base.reversed(), generation: 1, format: .zip))
        XCTAssertNil(index.advancing(.init(renamed: [0: "./x"], mode: .inPlace), previous: base,
            entries: [entry(0, "./x"), base[1]], generation: 1, format: .zip))
        XCTAssertNil(index.advancing(.init(mode: .inPlace), previous: base,
            entries: [entry(0, "a", kind: .symlink), base[1]], generation: 1, format: .zip))
        let next = try XCTUnwrap(index.advancing(.init(appended: [("unsupported", false)], mode: .inPlace), previous: base,
            entries: base + [entry(2, "unsupported", kind: .other)], generation: 1, format: .zip))
        XCTAssertFalse(next.representable)
    }

    func testCachedReplayKeysScaleWithChangesAndMatchReference() throws {
        let base = (0..<20_000).map { entry($0, "f\($0)") }
        let index = try XCTUnwrap(ArchiveNameIndex.build(entries: base, generation: 0, format: .zip,
            provingRepresentability: true, checksCancellation: false))
        var pending = ArchivePendingChanges()
        pending.renames[reference(base[1], generation: 0)] = "renamed"
        pending.removals.insert(reference(base[4], generation: 0))
        pending.createdFolders = [.init(id: UUID(), path: "new/")]
        let keys = ArchiveTestCounter(), trace = Mutex<[ArchiveStageDiagnostics.Stage]>([])
        let plan = try ArchiveStageDiagnostics.observer.withValue({ event in
            if case .began(_, let stage) = event { trace.withLock { $0.append(stage) } }
        }) {
            try ArchiveTestCounters.keys.withValue(keys) {
                try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending, baseOccupancy: index.occupancy)
            }
        }
        XCTAssertLessThan(keys.value, 30)
        XCTAssertFalse(trace.withLock { $0.contains(.planKeys) })
        let expected = try ReferenceArchiveSaveReplayPlan(base: base, generation: 0, pending: pending)
        XCTAssertEqual(plan.projected, expected.projected)
        XCTAssertEqual(plan.edits.removals.map(\.index), expected.edits.removals.map(\.index))
        XCTAssertEqual(plan.edits.renames.map(\.path), expected.edits.renames.map(\.path))
        for path in ["../bad", "f0", "f0/child", "bad\0name", "cafe\u{301}", "valid"] {
            pending.renames[reference(base[1], generation: 0)] = path
            func failure(cached: Bool) -> String? {
                do {
                    _ = try ArchiveSaveReplayPlan(base: base, generation: 0, pending: pending,
                        baseOccupancy: cached ? index.occupancy : nil)
                    return nil
                } catch { return Self.errorSignature(error) }
            }
            XCTAssertEqual(failure(cached: true), failure(cached: false), path)
        }
    }

    @MainActor func testLHAInternalRewriteAndUnspecifiedReloadDiscardIndex() async throws {
        let directory = try ArchiveTestDirectory()
        let archive = try LHAUpdateFixture.frozen("sfx", at: directory.url)
        let session = try ArchiveSession(url: archive)
        let before = await session.currentNameIndex()
        XCTAssertNotNil(before)
        let result = try await session.createFolder(in: "", baseName: "new", progress: Progress())
        XCTAssertNil(result.reloadFailure)
        XCTAssertNil(session.nameIndex(generation: session.generation, format: .lha))
        _ = await session.currentNameIndex()
        try await session.reloadAfterMutation()
        XCTAssertNil(session.nameIndex(generation: session.generation, format: .lha))
        await session.close()
    }

    @MainActor func testGenerationProofAndInstallGuards() async throws {
        let fixture = try DeferredSaveFixture(behavior: .immediate)
        defer { fixture.document.close() }
        let session = try XCTUnwrap(fixture.document.session), snapshot = await session.snapshot()
        let weak = try XCTUnwrap(ArchiveNameIndex.build(entries: snapshot.entries, generation: snapshot.generation, format: .zip,
            provingRepresentability: false, checksCancellation: false))
        let strong = try XCTUnwrap(ArchiveNameIndex.build(entries: snapshot.entries, generation: snapshot.generation, format: .zip,
            provingRepresentability: true, checksCancellation: false))
        session.adoptNameIndex(strong); session.adoptNameIndex(weak)
        XCTAssertTrue(try XCTUnwrap(session.nameIndex(generation: snapshot.generation, format: .zip)).representable)
        XCTAssertNil(session.nameIndex(generation: snapshot.generation + 1, format: .zip))
        XCTAssertNil(session.nameIndex(generation: snapshot.generation, format: .tar))
        let trace = Trace(), editor = ArchivePendingEditor()
        try await trace.observe {
            try await editor.install(base: snapshot.entries, generation: snapshot.generation, index: strong)
        }
        XCTAssertEqual(trace.events.withLock { $0.filter { $0 == .baseValidation }.count }, 0)
        for candidate in [weak, .init(generation: 99, format: .zip, entryCount: snapshot.entries.count,
                                      containsHardLinks: false, occupancy: strong.occupancy, representable: true),
                          .init(generation: snapshot.generation, format: .tar, entryCount: snapshot.entries.count,
                                containsHardLinks: false, occupancy: strong.occupancy, representable: true),
                          .init(generation: snapshot.generation, format: .zip, entryCount: 99,
                                containsHardLinks: false, occupancy: strong.occupancy, representable: true),
                          .init(generation: snapshot.generation, format: .zip, entryCount: snapshot.entries.count,
                                containsHardLinks: true, occupancy: strong.occupancy, representable: true)] {
            let editor = ArchivePendingEditor(), fallback = Trace()
            try await fallback.observe { try await editor.install(base: snapshot.entries, generation: snapshot.generation, index: candidate) }
            XCTAssertEqual(fallback.events.withLock { $0.filter { $0 == .baseValidation }.count }, 1)
        }
        _ = try await session.createFolder(in: "", baseName: "next", progress: Progress())
        session.adoptNameIndex(strong)
        try await checkIndex(session)
    }

    private func outputNames(_ archive: URL) -> [Data] {
        do { return try ArchiveReader.open(url: archive, options: .kaitoFinder()).entries.map { Data($0.name.utf8) } }
        catch { XCTFail("Output reader failed: \(error)"); return [] }
    }

    private struct Outcome: Equatable { let names: [Data]; let error: String? }
    private static func errorSignature(_ error: any Error) -> String {
        String(reflecting: type(of: error)) + ":" + ArchiveErrorText.describe(error)
    }
    private final class Trace: Sendable {
        let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
        let events = Mutex<[ArchiveReservationDiagnostics.Event]>([])
        func count(_ stage: ArchiveStageDiagnostics.Stage) -> Int { stages.withLock { $0.filter { $0 == stage }.count } }
        func observe<T>(_ body: () async throws -> T) async rethrows -> T {
            try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { self.stages.withLock { $0.append(stage) } }
            }) {
                try await ArchiveReservationDiagnostics.observer.withValue({ event, _ in self.events.withLock { $0.append(event) } }, operation: body)
            }
        }
    }
}
