import AppKit
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class EditPlacementPreferencesTests: XCTestCase {
    @MainActor func testRoundTripAndUnknownValuesUseEndAndKeep() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        XCTAssertEqual(store.preferences.additionPosition, .end); XCTAssertEqual(store.preferences.tarCarriedOwnerIDs, .keep)
        for position in ArchivePreferences.AdditionPosition.allCases {
            for owners in ArchivePreferences.CarriedOwnerIDPolicy.allCases {
                store.preferences.additionPosition = position; store.preferences.tarCarriedOwnerIDs = owners
                let reopened = ArchivePreferencesStore(defaults: suite.defaults).preferences
                XCTAssertEqual(reopened.additionPosition, position); XCTAssertEqual(reopened.tarCarriedOwnerIDs, owners)
                XCTAssertEqual(suite.defaults.string(forKey: "ArchiveAdditionPlacement"), position.rawValue)
                XCTAssertEqual(suite.defaults.string(forKey: "ArchiveTarCarriedOwnerIDs"), owners.rawValue)
            }
        }
        suite.defaults.set("unknown", forKey: "ArchiveAdditionPlacement")
        suite.defaults.set("unknown", forKey: "ArchiveTarCarriedOwnerIDs")
        XCTAssertEqual(store.preferences.additionPosition, .end); XCTAssertEqual(store.preferences.tarCarriedOwnerIDs, .keep)
    }

    func testEveryFormatOptionAndRouteCombination() {
        for position in ArchivePreferences.AdditionPosition.allCases {
            for owners in ArchivePreferences.CarriedOwnerIDPolicy.allCases {
                var preferences = ArchivePreferences()
                preferences.additionPosition = position; preferences.tarCarriedOwnerIDs = owners
                preferences.tarPreservesOwnerIDs = true; preferences.zipLevel = 1; preferences.tarBzip2Level = 2
                for format in ArchivePreferences.formats {
                    let options = preferences.writerOptions(for: format)
                    let tar = [.tar, .tarGzip, .tarBzip2, .tarXZ].contains(format)
                    XCTAssertEqual(options.additionPlacement, format == .zip || position == .end ? .end : .beginning)
                    XCTAssertEqual(options.carriedTarOwnerIDs, tar && owners == .reset ? .reset : .keep)
                    XCTAssertEqual(options.preserveOwnerIDs, tar)
                    if format == .sevenZip || format == .lha {
                        XCTAssertEqual(options.deflateLevel, WriterOptions().deflateLevel)
                        XCTAssertEqual(options.bzip2Level, WriterOptions().bzip2Level)
                    }
                    let mode = ArchiveCapabilities.Mode.update(format)
                    XCTAssertEqual(mode.outputFormat, format)
                    XCTAssertEqual(mode.resolved(with: options), options.additionPlacement == .beginning || (tar && owners == .reset) ? .rewrite(format) : mode)
                    XCTAssertEqual(ArchiveCapabilities.Mode.rewrite(format).resolved(with: options), .rewrite(format))
                    XCTAssertEqual(ArchiveCapabilities.Mode.inPlace.resolved(with: options), .inPlace)
                }
            }
        }
        XCTAssertEqual(ArchiveCapabilities.Mode.inPlace.outputFormat, .zip)
    }

    @MainActor func testOpenDocumentUsesNewSettingsOnTheNextEdit() async throws {
        let fixture = try DeferredSaveFixture(format: .tar, behavior: .immediate, files: [("keep", "original")])
        defer { fixture.document.close() }
        // writer の既定 0/0 ではなく、変更しない member に元からあった値を確かめる。
        fixture.document.close()
        let archive = try TarUpdateFixture.archive(fixture.directory.url, bytes: TarUpdateFixture.bytes, name: "owners.tar")
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: fixture.store)
        try document.read(from: archive, ofType: "public.data"); defer { document.close() }
        document.fileURL = archive; document.fileType = "public.data"
        let session = try XCTUnwrap(document.session)
        XCTAssertEqual(session.capabilities.mode, .update(.tar)); XCTAssertNil(session.capabilities.rewriteNotice)
        for policy in 0..<3 {
            fixture.store.preferences.additionPosition = policy == 1 ? .beginning : .end
            fixture.store.preferences.tarCarriedOwnerIDs = policy == 2 ? .reset : .keep
            let source = try fixture.file("added-\(policy)")
            let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
            let result = try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
            }) { try await document.append(urls: [source], to: "", progress: Progress()) }
            XCTAssertNil(result.reloadFailure)
            XCTAssertEqual(stages.withLock { $0.filter { $0 == .updaterOpen || $0 == .rewriterOpen } }, [policy == 0 ? .updaterOpen : .rewriterOpen])
            let entries = try ArchiveReader.open(url: archive).entries
            XCTAssertEqual(policy == 1 ? entries.first?.name : entries.last?.name, "added-\(policy)")
            XCTAssertEqual(entries.first { $0.name == "keep" }?.formatSpecific["uid"], policy == 2 ? "0" : "501")
            XCTAssertEqual(entries.first { $0.name == "keep" }?.formatSpecific["gid"], policy == 2 ? "0" : "20")
            XCTAssertEqual(session.capabilities.mode, .update(.tar)); XCTAssertNil(session.capabilities.rewriteNotice)
        }
    }

    func testRewriterEndAndLegacyBeginningAcrossFormats() throws {
        for format in ArchivePreferences.formats where format != .zip {
            for placement: AdditionPlacement in [.end, .beginning] {
                let directory = try ArchiveTestDirectory()
                let url = directory.url.appendingPathComponent("input." + ArchiveCreationPlan.filenameExtension(for: format))
                let writer = try ArchiveWriter.create(url: url, format: format)
                try writer.add(data: Data("original".utf8), as: "original"); try writer.finish()
                let source = directory.url.appendingPathComponent("added"); try Data("added".utf8).write(to: source)
                let output = directory.url.appendingPathComponent("output." + ArchiveCreationPlan.filenameExtension(for: format))
                let rewriter = try ArchiveRewriter.open(url: url, output: output, format: format, options: .init(additionPlacement: placement))
                try rewriter.add(contentsOf: source, as: "added"); try rewriter.commit()
                XCTAssertEqual(try ArchiveReader.open(url: output).entries.map(\.name), placement == .end ? ["original", "added"] : ["added", "original"])
            }
        }
    }
}
