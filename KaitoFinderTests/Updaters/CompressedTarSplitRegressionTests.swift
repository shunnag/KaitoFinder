import AppKit
import Foundation
import GyoshukuKit
@_spi(TarEditLayout) import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class CompressedTarSplitRegressionTests: XCTestCase {
    @MainActor func testNumberedSetsStillRewriteInBothSaveModes() async throws {
        try await checkNumberedSets(controlledCoordination: false)
    }

    @MainActor func testNumberedSetRoutingAndPublicationWithControlledCoordination() async throws {
        try await checkNumberedSets(controlledCoordination: true)
    }

    @MainActor private func checkNumberedSets(controlledCoordination: Bool) async throws {
        for behavior: ArchivePreferences.SaveBehavior in [.immediate, .onSave] {
            let fixture = try DeferredSplitSaveFixture(format: .tarGzip, behavior: behavior)
            defer { fixture.document.close() }
            fixture.document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
            if controlledCoordination {
                // Exercise the actual producer, verification and publisher without requiring Foundation's coordination service.
                fixture.document.splitSaveHooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
            }
            let session = try XCTUnwrap(fixture.document.session)
            XCTAssertEqual(session.capabilities.mode, .rewrite(.tarGzip))
            XCTAssertTrue(session.capabilities.splitSave)
            XCTAssertNil(try CompressedTarFixture.open(fixture.gate).tarEditingSnapshot())
            let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([]), compressedCommits = ArchiveTestCounter()
            try await ArchiveImportTransaction.didCommitCompressedTarUpdaterForTesting.withValue({ _ in compressedCommits.increment() }) {
                try await ArchiveStageDiagnostics.observer.withValue({ event in
                    if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
                }) {
                    _ = try await fixture.document.rename(fixture.node("file0.txt"), to: "renamed.txt", progress: Progress())
                    if behavior == .onSave { try await fixture.save() }
                }
            }
            XCTAssertEqual(compressedCommits.value, 0)
            XCTAssertFalse(stages.withLock { $0.contains(.updaterOpen) })
            let reader = try ArchiveReader.open(url: fixture.gate)
            let layout = try XCTUnwrap(reader.volumeSet)
            var joined = Data()
            for volume in layout.volumes { joined.append(try Data(contentsOf: volume.url)) }
            let whole = fixture.directory.url.appendingPathComponent("joined.tar.gz"); try joined.write(to: whole)
            let saved = try ArchiveReader.open(url: whole)
            var expected = fixture.contents; expected["renamed.txt"] = expected.removeValue(forKey: "file0.txt")
            XCTAssertEqual(try DeferredSaveFixture.contents(whole), expected)
            XCTAssertEqual(saved.entries.map(\.name), reader.entries.map(\.name))
            XCTAssertEqual(fixture.document.session?.capabilities.mode, .rewrite(.tarGzip))
        }
    }
}
