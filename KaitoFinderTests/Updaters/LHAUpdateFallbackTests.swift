import AppKit
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class LHAUpdateFallbackTests: XCTestCase {
    func testStructuralNoticesAndFallbackDeleteOpenAndMutateExactlyOnce() throws {
        for name in LHAUpdateFixture.fallbacks {
            for deferred in [false, true] {
                let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.frozen(name, at: directory.url)
                let reader = try ArchiveReader.open(url: archive, options: .kaitoFinder()), entries = reader.entries
                let capability = ArchiveCapabilities.inspect(reader: reader, url: archive)
                XCTAssertEqual(capability.mode, .update(.lha), name)
                XCTAssertNotNil(capability.lhaRewriteReason, name)
                XCTAssertNil(capability.rewriteNotice)
                XCTAssertNil(capability.compressedTarAssessment)
                for onSave in [false, true] {
                    XCTAssertEqual(capability.editNotice(options: .init(), onSave: onSave), onSave
                        ? String(localized: "保存するとアーカイブ全体を再圧縮します")
                        : String(localized: "編集するとアーカイブ全体を再圧縮します"), name)
                }
                let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
                var pending = ArchivePendingChanges()
                pending.removals = [.init(index: 0, expectedName: entries[0].name, baseGeneration: 0)]
                let plan = try ArchiveSaveReplayPlan(base: entries, generation: 0, pending: pending, format: .lha)
                let openings = ArchiveTestCounter(), mutations = ArchiveTestCounter(), fallbacks = ArchiveTestCounter()
                let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([]), progress = Progress(totalUnitCount: 2)
                try ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallbacks.increment() }) {
                    try ArchiveStageDiagnostics.observer.withValue({ event in
                        if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
                    }) {
                        try ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                            try LHAUpdateFixture.assertWork(work, archive: archive, bytes: original, identity: identity)
                        }) {
                            try ArchiveImportTransaction.publish(archive: archive, mode: .update(.lha), options: .init(), progress: progress,
                                willOpenUpdater: { openings.increment() }, willPublish: nil, deferredPlan: deferred ? plan : nil,
                                expectedOutput: .init(plan: plan, mode: .update(.lha))) { editor in
                                    mutations.increment(); try plan.replay(on: editor, progress: progress)
                                }
                        }
                    }
                }
                XCTAssertEqual(openings.value, 1, name); XCTAssertEqual(mutations.value, 1, name); XCTAssertEqual(fallbacks.value, 1, name)
                XCTAssertEqual(stages.withLock { $0.filter { $0 == .updaterOpen || $0 == .rewriterOpen || $0 == .workCopy } }, [.updaterOpen, .rewriterOpen], name)
                XCTAssertEqual(stages.withLock { $0.filter { $0 == .mutate || $0 == .replay } }, [deferred ? .replay : .mutate])
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount, name)
                XCTAssertEqual(progress.totalUnitCount, Int64(entries.count + 1), name)
                let saved = try ArchiveReader.open(url: archive)
                try ArchiveOutputProjection(plan: plan, mode: .rewrite(.lha)).validate(saved, format: .lha)
                XCTAssertEqual(saved.entries.map(\.name), entries.dropFirst().map { $0.kind == .directory ? ArchiveEditPlan.key($0.name) + "/" : $0.name }, name)
                XCTAssertTrue(ArchiveCapabilities.inspect(reader: saved, url: archive).canEdit, name)
                // tl-S11 は reader に見えている範囲だけを照合する。
                for entry in saved.entries where entry.kind != .directory {
                    let old = try XCTUnwrap(entries.first { $0.name == entry.name })
                    XCTAssertEqual(try saved.read(entry), try reader.read(old), name)
                }
            }
        }
    }

    func testUTF8FirstRewriteRemovesNoticeAndNextEditUsesUpdater() async throws {
        for name in ["names-utf8-undeclared", "names-utf8-declared"] {
            for deferred in [false, true] {
                let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.frozen(name, at: directory.url)
                let session = try ArchiveSession(url: archive)
                XCTAssertNotNil(session.capabilities.lhaRewriteReason)
                for pass in 0..<2 {
                    let trace = LHAUpdateTrace(), progress = Progress()
                    try await trace.observing {
                        if deferred {
                            let snapshot = try await session.deferredSnapshot()
                            var pending = ArchivePendingChanges()
                            pending.createdFolders = [.init(id: UUID(), path: "new-\(pass)/", date: LHAUpdateFixture.date)]
                            let publication = ArchiveSavePublication(); defer { publication.finish() }
                            let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: progress, publication: publication)
                            XCTAssertNil(result.reloadFailure)
                        } else {
                            let result = try await session.createFolder(in: "", baseName: "new-\(pass)", progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        }
                    }
                    trace.assertRoute(pass == 0 ? [.updaterOpen, .rewriterOpen] : [.updaterOpen])
                    XCTAssertEqual(trace.fallbacks.withLock { $0.count }, pass == 0 ? 1 : 0)
                    XCTAssertNil(session.capabilities.lhaRewriteReason)
                    XCTAssertNil(session.capabilities.editNotice(options: .init(), onSave: deferred))
                    XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                    XCTAssertEqual(try ArchiveReader.open(url: archive).entries.first?.name, "資料.txt")
                }
                await session.close()
            }
        }
    }

    func testBeginningPlacementRewritesOnceAndPutsAdditionFirst() throws {
        let directory = try ArchiveTestDirectory(), archive = try LHAUpdateFixture.make(directory.url)
        let reader = try ArchiveReader.open(url: archive), capability = ArchiveCapabilities.inspect(reader: reader, url: archive)
        let options = WriterOptions(additionPlacement: .beginning), openings = ArchiveTestCounter(), mutations = ArchiveTestCounter()
        let mode = try XCTUnwrap(capability.mode?.resolved(with: options))
        XCTAssertEqual(mode, .rewrite(.lha))
        for onSave in [false, true] {
            XCTAssertEqual(capability.editNotice(options: options, onSave: onSave), onSave
                ? String(localized: "保存するとアーカイブ全体を再圧縮します") : String(localized: "編集するとアーカイブ全体を再圧縮します"))
        }
        let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([]), progress = Progress(totalUnitCount: 2)
        try ArchiveStageDiagnostics.observer.withValue({ event in
            if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
        }) {
            try ArchiveImportTransaction.publish(archive: archive, mode: mode, options: options, progress: progress,
                willOpenUpdater: { openings.increment() }, willPublish: nil,
                expectedOutput: .init(existing: reader.entries, additions: [.init(adding: "added/", kind: .directory)], mode: mode)) { editor in
                    mutations.increment(); try editor.addDirectory("added"); progress.completedUnitCount += 1
                }
        }
        XCTAssertEqual(openings.value, 1); XCTAssertEqual(mutations.value, 1)
        XCTAssertEqual(stages.withLock { $0.filter { $0 == .updaterOpen || $0 == .rewriterOpen } }, [.rewriterOpen])
        XCTAssertEqual(try ArchiveReader.open(url: archive).entries.first?.name, "added/")
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
    }

    @MainActor func testOpenDocumentUsesChangedPlacementOnNextEdit() async throws {
        let fixture = try DeferredSaveFixture(format: .lha, behavior: .immediate, files: [("keep", "original")])
        defer { fixture.document.close() }
        let session = try XCTUnwrap(fixture.document.session)
        for placement: ArchivePreferences.AdditionPosition in [.end, .beginning, .end] {
            fixture.store.preferences.additionPosition = placement
            let name = "added-\(UUID().uuidString)", source = try fixture.file(name)
            let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
            let result = try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
            }) { try await fixture.document.append(urls: [source], to: "", progress: Progress()) }
            XCTAssertNil(result.reloadFailure)
            XCTAssertEqual(stages.withLock { $0.filter { $0 == .updaterOpen || $0 == .rewriterOpen } }, [placement == .end ? .updaterOpen : .rewriterOpen])
            let entries = await session.entries()
            XCTAssertEqual(placement == .end ? entries.last?.name : entries.first?.name, name)
            XCTAssertEqual(session.capabilities.mode, .update(.lha))
        }
    }

    private func lha(_ payload: Data, name: String = "member.bin", method: String = "-lh0-", os: UInt8 = 0x6d) -> Data {
        func little<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        var crc: UInt16 = 0
        for byte in payload {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = crc >> 1 ^ (crc & 1 == 0 ? 0 : 0xa001) }
        }
        let filename = Data(name.utf8)
        var header = Data(count: 2) + Data(method.utf8)
        header += little(UInt32(payload.count)) + little(UInt32(payload.count)) + little(UInt32(1_700_000_000))
        header += Data([0x20, 2]) + little(crc) + Data([os])
        header += little(UInt16(filename.count + 3)) + Data([1]) + filename + little(UInt16(0))
        header.replaceSubrange(0..<2, with: little(UInt16(header.count)))
        return header + payload + Data([0])
    }

    private func macBinary() -> Data {
        var bytes = Data(count: 128)
        bytes[1] = 10
        bytes.replaceSubrange(2..<12, with: "member.bin".utf8)
        bytes.replaceSubrange(65..<73, with: "BINATEST".utf8)
        for (offset, payload) in [(83, Data("data fork".utf8)), (87, Data("resource fork".utf8))] {
            withUnsafeBytes(of: UInt32(payload.count).bigEndian) { bytes.replaceSubrange(offset..<(offset + 4), with: $0) }
            bytes += payload + Data(count: 128 - payload.count)
        }
        return bytes
    }

    @MainActor func testMacBinaryAndUnsupportedLHAAreReadOnlyAndShowTheProbeReason() async throws {
        let directory = try ArchiveTestDirectory(), controller = ArchiveWindowController()
        defer { controller.close() }
        for (bytes, reason, entriesAccepted) in [
            (lha(macBinary()), "MacBinary の envelope・resource fork を保持できないため再圧縮できません", true),
            (lha(Data("payload".utf8), method: "-pm2-"), "未対応の LHA 圧縮方式は再圧縮できません: -pm2-", false)
        ] {
            let archive = directory.url.appendingPathComponent(UUID().uuidString + ".lzh")
            try bytes.write(to: archive)
            let reader = try ArchiveReader.open(url: archive, options: .kaitoFinder())
            if entriesAccepted { XCTAssertNoThrow(try ArchiveRewriter.probe(entries: reader.entries, format: .lha)) }
            let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
            let capability = ArchiveCapabilities.inspect(reader: reader, url: archive)
            XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 }, before)
            XCTAssertFalse(capability.canEdit)
            XCTAssertEqual(capability.refusal, .unrepresentable("member.bin: " + reason))
            XCTAssertEqual(ArchiveCapabilities.inspect(url: archive, format: .lha).refusal, capability.refusal)
            let session = try ArchiveSession(url: archive), snapshot = await session.snapshot()
            XCTAssertEqual(session.capabilities.refusal, capability.refusal)
            let message = try XCTUnwrap(capability.readOnlyReason)
            XCTAssertTrue(message.contains("member.bin: " + reason))
            controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
            XCTAssertEqual(controller.capabilityNotice.stringValue, message)
            XCTAssertFalse(controller.capabilityNotice.isHidden)
            XCTAssertEqual(try Data(contentsOf: archive), bytes)
            await session.close()
        }
    }

    func testPlainMacLHAAndEmptyLHADirectoryStillPublish() async throws {
        for directoryEntry in [false, true] {
            let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("original.lzh")
            let bytes = lha(directoryEntry ? Data() : Data("payload".utf8), name: directoryEntry ? "directory/" : "member.bin",
                            method: directoryEntry ? "-lhd-" : "-lh0-")
            try bytes.write(to: archive)
            XCTAssertEqual(try ArchiveReader.open(url: archive).entries.first?.uncompressedSize, directoryEntry ? 0 : 7)
            let session = try ArchiveSession(url: archive)
            XCTAssertTrue(session.capabilities.canEdit)
            let result = try await session.createFolder(in: "", baseName: "added", progress: Progress())
            XCTAssertNil(result.reloadFailure)
            await session.close()
            let reader = try ArchiveReader.open(url: archive)
            XCTAssertEqual(reader.entries.count, 2)
            let carried = try XCTUnwrap(reader.entries.first { $0.name != "added/" })
            XCTAssertEqual(carried.kind, directoryEntry ? .directory : .file)
            XCTAssertEqual(carried.uncompressedSize, directoryEntry ? 0 : 7)
            if !directoryEntry { XCTAssertEqual(try reader.read(carried), Data("payload".utf8)) }
        }
    }

    func testNonemptyLHADirectoryCannotReachTheEditPath() throws {
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("original.lzh")
        try lha(Data("payload".utf8), name: "directory/", method: "-lhd-").write(to: archive)
        XCTAssertThrowsError(try ArchiveReader.open(url: archive)) {
            XCTAssertEqual($0 as? KaitoError, .malformed("LHA directory member has data"))
        }
    }
}
