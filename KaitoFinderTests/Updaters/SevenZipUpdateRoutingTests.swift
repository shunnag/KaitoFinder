import Foundation
import GyoshukuKit
@_spi(SevenZipEditLayout) import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class SevenZipUpdateRoutingTests: XCTestCase {
    func testSingleFileAssessmentPlacementAndNoticeTable() throws {
        for (fixture, updatable, solid, reencrypt) in [
            ("g_plain", true, false, true), ("z_default", true, true, true),
            ("bcj2", true, true, false), ("archive_properties", false, true, false),
            ("packpos16", false, true, false)] {
            for name in ["sample.7z", "sample.7Z", "no-extension"] {
                let directory = try ArchiveTestDirectory()
                let archive = try SevenZipUpdateFixture.frozen(fixture, at: directory.url, filename: name)
                let reader = try SevenZipUpdateFixture.reader(archive)
                for capability in [ArchiveCapabilities.inspect(reader: reader, url: archive),
                                   ArchiveCapabilities.inspect(url: archive, format: reader.format)] {
                    XCTAssertEqual(capability.mode, .update(.sevenZip), fixture)
                    let assessment = try XCTUnwrap(capability.sevenZipAssessment)
                    XCTAssertEqual(assessment.updatable, updatable, fixture)
                    XCTAssertEqual(assessment.hasSolidFolders, solid, fixture)
                    XCTAssertEqual(assessment.canReencrypt, reencrypt, fixture)
                    XCTAssertNil(capability.compressedTarAssessment)
                    for beginning in [false, true] {
                        let options = WriterOptions(additionPlacement: beginning ? .beginning : .end)
                        XCTAssertEqual(capability.mode?.resolved(with: options), beginning ? .rewrite(.sevenZip) : .update(.sevenZip))
                        for onSave in [false, true] {
                            let expected: String? = beginning || !updatable
                                ? (onSave ? String(localized: "保存するとアーカイブ全体を再圧縮します") : String(localized: "編集するとアーカイブ全体を再圧縮します"))
                                : solid ? String(localized: "ソリッドブロック内の項目を削除すると、そのブロックを再圧縮します") : nil
                            XCTAssertEqual(capability.editNotice(options: options, onSave: onSave), expected, fixture)
                        }
                    }
                }
            }
        }
        for onSave in [false, true] {
            XCTAssertEqual(ArchiveCapabilities(mode: .update(.sevenZip)).editNotice(options: .init(), onSave: onSave),
                onSave ? String(localized: "保存するとアーカイブ全体を再圧縮します") : String(localized: "編集するとアーカイブ全体を再圧縮します"))
        }
        let split = try SplitArchiveFixture(.sevenZip), reader = try ArchiveReader.open(url: split.archive, options: .kaitoFinder())
        XCTAssertEqual(ArchiveCapabilities.inspect(reader: reader, url: split.archive, allowsSplitSave: true).mode, .rewrite(.sevenZip))
    }

    func testReadOnlyNamesKeepTheRepresentabilityGate() throws {
        let directory = try ArchiveTestDirectory()
        for name in ["a:b", "a\\b"] {
            let archive = directory.url.appendingPathComponent(UUID().uuidString + ".7z")
            let writer = try ArchiveWriter.create(url: archive, format: .sevenZip)
            try writer.add(data: Data([1]), as: "a_b"); try writer.finish()
            var bytes = try Data(contentsOf: archive)
            let raw = Data("a_b".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
            let range = try XCTUnwrap(bytes.range(of: raw, options: .backwards))
            bytes.replaceSubrange(range, with: name.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
            func crc(_ data: Data) -> UInt32 {
                var value: UInt32 = .max
                for byte in data {
                    value ^= UInt32(byte)
                    for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 0 ? 0 : 0xedb88320) }
                }
                return ~value
            }
            func replaceCRC(at index: Int, _ value: UInt32) {
                bytes.replaceSubrange(index..<index + 4, with: (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
            }
            let offset = (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[12 + $1]) << ($1 * 8) }
            replaceCRC(at: 28, crc(Data(bytes.dropFirst(32 + Int(offset)))))
            replaceCRC(at: 8, crc(bytes.subdata(in: 12..<32)))
            try bytes.write(to: archive)
            let reader = try SevenZipUpdateFixture.reader(archive)
            let capability = ArchiveCapabilities.inspect(reader: reader, url: archive)
            XCTAssertFalse(capability.canEdit)
            do { try ArchiveRewriter.probe(reader: reader, format: .sevenZip); XCTFail("Expected refusal") }
            catch RewriterError.unrepresentable(let entry, let reason) {
                XCTAssertEqual(capability.refusal, .unrepresentable(entry + ": " + reason))
            }
        }
    }

    func testFallbackDeleteAndSaveOpenAndMutateExactlyOnce() throws {
        for name in SevenZipUpdateFixture.fallbacks {
            for deferred in [false, true] {
                let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.frozen(name, at: directory.url)
                let reader = try ArchiveReader.open(url: archive, options: .kaitoFinder()), entries = reader.entries
                let capability = ArchiveCapabilities.inspect(reader: reader, url: archive)
                XCTAssertEqual(capability.mode, .update(.sevenZip), name)
                XCTAssertNotNil(capability.sevenZipAssessment?.reason, name)
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
                let plan = try ArchiveSaveReplayPlan(base: entries, generation: 0, pending: pending, format: .sevenZip)
                let openings = ArchiveTestCounter(), mutations = ArchiveTestCounter(), fallbacks = ArchiveTestCounter()
                let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([]), progress = Progress(totalUnitCount: 2)
                try ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallbacks.increment() }) {
                    try ArchiveStageDiagnostics.observer.withValue({ event in
                        if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
                    }) {
                        try ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                            try SevenZipUpdateFixture.assertWork(work, archive: archive, bytes: original, identity: identity)
                        }) {
                            try ArchiveImportTransaction.publish(archive: archive, mode: .update(.sevenZip), options: .init(), progress: progress,
                                willOpenUpdater: { openings.increment() }, willPublish: nil, deferredPlan: deferred ? plan : nil,
                                expectedOutput: .init(plan: plan, mode: .update(.sevenZip))) { editor in
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
                try ArchiveOutputProjection(plan: plan, mode: .rewrite(.sevenZip)).validate(saved, format: .sevenZip)
                XCTAssertEqual(saved.entries.map(\.name), entries.dropFirst().map { $0.kind == .directory ? ArchiveEditPlan.key($0.name) + "/" : $0.name }, name)
                XCTAssertTrue(ArchiveCapabilities.inspect(reader: saved, url: archive).canEdit, name)
                for entry in saved.entries where entry.kind != .directory {
                    let old = try XCTUnwrap(entries.first { $0.name == entry.name })
                    XCTAssertEqual(try saved.read(entry), try reader.read(old), name)
                }
            }
        }
    }

    func testBeginningPlacementRewritesOnceAndPutsAdditionFirst() throws {
        let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.make(directory.url)
        let reader = try ArchiveReader.open(url: archive), capability = ArchiveCapabilities.inspect(reader: reader, url: archive)
        let options = WriterOptions(additionPlacement: .beginning), openings = ArchiveTestCounter(), mutations = ArchiveTestCounter()
        let mode = try XCTUnwrap(capability.mode?.resolved(with: options))
        XCTAssertEqual(mode, .rewrite(.sevenZip))
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
        let fixture = try DeferredSaveFixture(format: .sevenZip, behavior: .immediate, files: [("keep", "original")])
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
            XCTAssertEqual(session.capabilities.mode, .update(.sevenZip))
        }
    }
    #if DEBUG
    func testProbeEncryptionFixturesAndHeaderPolicy() async throws {
        defer { ArchiveProbeFixtures.removeAll() }
        let configuration = try ArchiveProbeConfiguration(environment: ["KAITOFINDER_PERFORMANCE_PROBES": "1",
            "KAITOFINDER_PROBE_ENTRIES": "4", "KAITOFINDER_PROBE_PAYLOAD_MIB": "1", "KAITOFINDER_PROBE_FORMATS": "7z"])
        XCTAssertEqual(ProbeArchiveEncryption(rawValue: "7z"), .sevenZip)
        XCTAssertNil(ProbeArchiveEncryption.sevenZip.zipMethod)
        XCTAssertNil(ProbeArchiveEncryption.sevenZip.zipEntryMethod)
        for kind in ArchiveProbeFixture.Kind.allCases {
            let fixture = try await ArchiveProbeFixtures.fixture(kind, format: .sevenZip, configuration: configuration, encryption: .sevenZip)
            let reader = try SevenZipUpdateFixture.reader(fixture.url, password: fixture.password)
            XCTAssertEqual(reader.format, .sevenZip)
            XCTAssertTrue(reader.entries.allSatisfy(\.isEncrypted))
            XCTAssertEqual(try XCTUnwrap(reader.sevenZipEditingSnapshot()).header.isEncrypted, kind == .payload)
            let plain = try await ArchiveProbeFixtures.fixture(kind, format: .sevenZip, configuration: configuration)
            XCTAssertNotEqual(fixture.url, plain.url)
        }
    }
    #endif

}
