import Foundation
@_spi(Testing) import GyoshukuKit
@_spi(TarEditLayout) import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class CompressedTarRoutingTests: XCTestCase {
    func testFormatsFramingAndEveryPreferenceCombination() async throws {
        for format in CompressedTarFixture.formats {
            let directory = try ArchiveTestDirectory()
            let modern = try CompressedTarFixture.make(directory.url, format: format)
            let oldRoot = directory.url.appendingPathComponent("old")
            try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: false)
            let legacy = try CompressedTarFixture.legacy(oldRoot, format: format)
            let external = try CompressedTarFixture.compress(CompressedTarFixture.externalBytes, in: directory, format: format,
                arguments: format == .tarGzip ? ["-6"] : [])
            var fixtures = [(modern, false), (legacy, false), (external, true)]
            if format == .tarXZ {
                fixtures.append((try CompressedTarFixture.compress(CompressedTarFixture.externalBytes, in: directory, format: format,
                    arguments: ["--check=crc32", "--block-size=1MiB"], name: "crc32"), false))
            }
            for (fixture, firstEdit) in fixtures {
                for policy in 0..<4 {
                    let archive = directory.url.appendingPathComponent("edit-\(policy)." + CompressedTarFixture.suffix(format))
                    try? FileManager.default.removeItem(at: archive)
                    try FileManager.default.copyItem(at: fixture, to: archive)
                    var preferences = ArchivePreferences()
                    preferences.additionPosition = policy & 1 == 0 ? .end : .beginning
                    preferences.tarCarriedOwnerIDs = policy & 2 == 0 ? .keep : .reset
                    let options = preferences.writerOptions(for: format)
                    let session = try ArchiveSession(url: archive, writerOptions: { _ in options })
                    let capability = session.capabilities
                    XCTAssertEqual(capability.mode, .update(format))
                    XCTAssertNil(capability.rewriteNotice)
                    XCTAssertEqual(capability.compressedTarAssessment?.nextEditReencodesEverything, firstEdit)
                    XCTAssertEqual(capability.mode?.resolved(with: options), policy == 0 ? .update(format) : .rewrite(format))
                    for onSave in [false, true] {
                        let expected: String? = policy != 0
                            ? (onSave ? String(localized: "保存するとアーカイブ全体を再圧縮します") : String(localized: "編集するとアーカイブ全体を再圧縮します"))
                            : firstEdit ? (onSave ? String(localized: "最初の保存でアーカイブ全体を再圧縮します") : String(localized: "最初の編集でアーカイブ全体を再圧縮します")) : nil
                        XCTAssertEqual(capability.editNotice(options: options, onSave: onSave), expected)
                    }
                    let trace = CompressedTarTrace()
                    try await trace.observing {
                        let result = try await session.createFolder(in: "", baseName: "added", progress: Progress())
                        XCTAssertNil(result.reloadFailure)
                    }
                    trace.assertAdopted()
                    XCTAssertEqual(trace.stages.withLock { $0.filter { $0 == .updaterOpen || $0 == .rewriterOpen } }, [policy == 0 ? .updaterOpen : .rewriterOpen])
                    if policy == 0 {
                        let strategy = try XCTUnwrap(trace.strategies.withLock { $0.first })
                        if firstEdit { guard case .fullEncode = strategy else { return XCTFail("\(format): \(strategy)") } }
                        else { guard case .splice = strategy else { return XCTFail("\(format): \(strategy)") } }
                    } else { XCTAssertTrue(trace.strategies.withLock { $0.isEmpty }) }
                    await session.close()
                }
            }
        }
    }

    func testOnlyNamedCompressedFormatsUseTheAssessmentNotice() {
        for format: GyoshukuKit.ArchiveFormat in [.tar, .lha, .sevenZip, .zip] {
            XCTAssertNil(ArchiveCapabilities(mode: .update(format)).editNotice(options: .init(), onSave: false))
        }
        for format in CompressedTarFixture.formats {
            let capability = ArchiveCapabilities(mode: .update(format))
            XCTAssertEqual(capability.editNotice(options: .init(), onSave: false), String(localized: "編集するとアーカイブ全体を再圧縮します"))
            XCTAssertEqual(capability.editNotice(options: .init(), onSave: true), String(localized: "保存するとアーカイブ全体を再圧縮します"))
        }
    }

    func testMissingReaderRefusesAndMissingSnapshotFallsBackBeforeMutation() throws {
        for format in CompressedTarFixture.formats {
            let directory = try ArchiveTestDirectory(), archive = try CompressedTarFixture.make(directory.url, format: format)
            let entries = try ArchiveReader.open(url: archive).entries
            let openings = ArchiveTestCounter(), mutations = ArchiveTestCounter(), fallbacks = ArchiveTestCounter()
            XCTAssertThrowsError(try ArchiveImportTransaction.publish(archive: archive, mode: .update(format), options: .init(), progress: Progress(),
                willPublish: nil, expectedOutput: .init(existing: entries, mode: .update(format))) { _ in mutations.increment() }) {
                XCTAssertEqual($0 as? ArchiveEditError, .staleSelection)
            }
            XCTAssertEqual(mutations.value, 0)
            try ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallbacks.increment() }) {
                try ArchiveImportTransaction.publish(archive: archive, mode: .update(format), options: .init(), progress: Progress(),
                    willOpenUpdater: { openings.increment() }, willPublish: nil, sessionReader: ArchiveReader.open(url: archive),
                    expectedOutput: .init(existing: entries, mode: .update(format))) { _ in mutations.increment() }
            }
            XCTAssertEqual(openings.value, 1); XCTAssertEqual(mutations.value, 1); XCTAssertEqual(fallbacks.value, 1)
            try CompressedTarFixture.assertNoWork(directory.url)
        }
    }
}
