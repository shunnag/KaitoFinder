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
}
