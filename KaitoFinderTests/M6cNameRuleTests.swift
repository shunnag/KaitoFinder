import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class M6cNameRuleTests: XCTestCase {
    private let files = [("man3/File::Spec.3pm", "manual"), ("Maildir/cur/msg:2,S", "message"),
                         ("other.txt", "other"), ("back\\slash.txt", "backslash")]
    private let tarFormats: [GyoshukuKit.ArchiveFormat] = [.tar, .tarGzip]
    private let behaviors: [ArchivePreferences.SaveBehavior] = [.immediate, .onSave]

    private func assertContents(_ url: URL, _ expected: [(String, String)],
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try DeferredSaveFixture.contents(url),
            Dictionary(uniqueKeysWithValues: expected.map { ($0.0, Data($0.1.utf8)) }), file: file, line: line)
        let entries = try ArchiveReader.open(url: url).entries
        XCTAssertEqual(Set(entries.map(\.name)).count, entries.count, file: file, line: line)
        for (name, _) in expected {
            let entry = try XCTUnwrap(entries.first { $0.name == name }, file: file, line: line)
            XCTAssertEqual(entry.rawName.bytes, Array(name.utf8), file: file, line: line)
        }
    }

    @MainActor func testTarDeletePreservesNameBytesInBothSaveModes() async throws {
        for format in tarFormats {
            for behavior in behaviors {
                let fixture = try DeferredSaveFixture(format: format, behavior: behavior, files: files)
                let document = fixture.document
                defer { document.close() }
                let session = try XCTUnwrap(document.session)
                XCTAssertTrue(session.capabilities.canEdit)
                XCTAssertEqual(session.capabilities.mode, format == .tar ? .update(.tar) : .rewrite(format))
                XCTAssertEqual(session.reservationFormat, format)
                let result = try await document.remove([fixture.node("other.txt")], progress: Progress())
                XCTAssertEqual(result.removedPaths, ["other.txt"])
                XCTAssertNil(result.reloadFailure)
                if behavior == .onSave {
                    XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
                    try await fixture.save()
                }
                try assertContents(fixture.archive, files.filter { $0.0 != "other.txt" })
            }
        }
    }

    @MainActor func testTarFolderAndLeafRenamesWorkInBothSaveModes() async throws {
        for format in tarFormats {
            for behavior in behaviors {
                let fixture = try DeferredSaveFixture(format: format, behavior: behavior, files: files)
                let document = fixture.document
                defer { document.close() }
                let folder = try await document.rename(fixture.node("man3"), to: "man3p", progress: Progress())
                XCTAssertEqual(folder.renamedPaths, ["man3p/File::Spec.3pm"])
                XCTAssertNil(folder.reloadFailure)
                let leaf = try await document.rename(fixture.node("other.txt"), to: "a:b", progress: Progress())
                XCTAssertEqual(leaf.renamedPaths, ["a:b"])
                XCTAssertNil(leaf.reloadFailure)
                let backslash = try await document.rename(fixture.node("back\\slash.txt"), to: "new\\name", progress: Progress())
                XCTAssertEqual(backslash.renamedPaths, ["new\\name"])
                if behavior == .onSave {
                    XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
                    try await fixture.save()
                }
                try assertContents(fixture.archive, [("man3p/File::Spec.3pm", "manual"),
                    ("Maildir/cur/msg:2,S", "message"), ("a:b", "other"), ("new\\name", "backslash")])
            }
        }
    }

    @MainActor func testTarImportsConflictsFoldersAndMovesUseTheSameRule() async throws {
        for format in tarFormats {
            for behavior in behaviors {
                let fixture = try DeferredSaveFixture(format: format, behavior: behavior, files: files)
                let document = fixture.document
                defer { document.close() }
                let source = try fixture.file("1:2 recipe.txt"), backslash = try fixture.file("disk\\file")
                let added = try await document.append(urls: [source, backslash], to: "", progress: Progress())
                XCTAssertTrue(added.failures.isEmpty)
                XCTAssertEqual(added.addedPaths, ["1:2 recipe.txt", "disk\\file"])
                let duplicate = try fixture.file("msg:2,S", contents: "replacement")
                let conflict = try await document.append(urls: [duplicate], to: "Maildir/cur", progress: Progress())
                XCTAssertTrue(conflict.addedPaths.isEmpty)
                XCTAssertEqual(conflict.failures.map(\.reason),
                    [String(localized: "同じ名前の項目が既にあります: \("Maildir/cur/msg:2,S")。")])
                var conflictPaths: [String] = []
                let skipped = try await document.append(urls: [duplicate], to: "Maildir/cur", progress: Progress(), resolveConflict: {
                    conflictPaths.append($0.path)
                    return .init(choice: .skip)
                })
                XCTAssertEqual(conflictPaths, ["Maildir/cur/msg:2,S"])
                XCTAssertTrue(skipped.addedPaths.isEmpty)
                XCTAssertTrue(skipped.failures.isEmpty)
                _ = try await document.createFolder(in: "", baseName: "dst:box", progress: Progress())
                _ = try await document.createFolder(in: "dst:box", baseName: "child\\box", progress: Progress())
                _ = try await document.move([fixture.node("man3")], to: "dst:box", progress: Progress())
                _ = try await document.move([fixture.node("Maildir/cur/msg:2,S")], to: "dst:box/child\\box",
                    progress: Progress(), resolveConflict: { _ in XCTFail("Unexpected conflict"); return .init(choice: .skip) })
                if behavior == .onSave { try await fixture.save() }
                try assertContents(fixture.archive, [("dst:box/man3/File::Spec.3pm", "manual"),
                    ("dst:box/child\\box/msg:2,S", "message"), ("other.txt", "other"),
                    ("back\\slash.txt", "backslash"), ("1:2 recipe.txt", "new"), ("disk\\file", "new")])
            }
        }
    }

    @MainActor func testZIPKeepsExistingRenameAndImportRefusalsInBothModes() async throws {
        for behavior in behaviors {
            let fixture = try DeferredSaveFixture(behavior: behavior), document = fixture.document
            defer { document.close() }
            for name in ["a:b", "a\\b"] {
                do {
                    _ = try await document.rename(fixture.node("a.txt"), to: name, progress: Progress())
                    XCTFail("ZIP accepted \(name)")
                } catch {
                    XCTAssertEqual(error as? ArchiveEditError, .invalidName(name))
                    XCTAssertEqual(ArchiveErrorText.describe(error), String(localized: "この名前には変更できません: \(name)。"))
                }
            }
            for name in ["1:2 recipe.txt", "disk\\file"] {
                let result = try await document.append(urls: [fixture.file(name)], to: "", progress: Progress())
                XCTAssertTrue(result.addedPaths.isEmpty)
                XCTAssertEqual(result.failures.map(\.reason), [String(localized: "安全でない追加先パスです: \(name)。")])
            }
            XCTAssertTrue(document.pendingChanges.isEmpty)
            XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
        }
    }

    @MainActor func testDeferredTarReservationsRetainCachedDeltaValidation() async throws {
        for format in tarFormats {
            let fixture = try DeferredSaveFixture(format: format, files: files), document = fixture.document
            defer { document.close() }
            _ = try await document.projectedEntries()
            XCTAssertNotNil(document.pendingEditor?.prepared?.occupancy)
            let source = try fixture.file("1:2 recipe.txt")
            let events = Mutex<[ArchiveReservationDiagnostics.Event]>([])
            try await ArchiveReservationDiagnostics.observer.withValue({ event, _ in events.withLock { $0.append(event) } }) {
                _ = try await document.rename(fixture.node("man3"), to: "man3p", progress: Progress())
                _ = try await document.rename(fixture.node("other.txt"), to: "a:b", progress: Progress())
                _ = try await document.createFolder(in: "", baseName: "new:folder\\name", progress: Progress())
                _ = try await document.append(urls: [source], to: "new:folder\\name", progress: Progress())
                _ = try await document.remove([fixture.node("a:b")], progress: Progress())
            }
            let counts = events.withLock { Dictionary($0.map { ($0, 1) }, uniquingKeysWith: +) }
            XCTAssertGreaterThanOrEqual(counts[.planning, default: 0], 3)
            XCTAssertGreaterThanOrEqual(counts[.projection, default: 0], 5)
            for event: ArchiveReservationDiagnostics.Event in [.baseValidation, .fullValidation, .replayPlan] {
                XCTAssertEqual(counts[event, default: 0], 0, "Unexpected \(event) for \(format)")
            }
            XCTAssertNotNil(document.pendingEditor?.prepared?.occupancy)
            XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
            try await fixture.save()
            try assertContents(fixture.archive, [("man3p/File::Spec.3pm", "manual"), ("Maildir/cur/msg:2,S", "message"),
                ("back\\slash.txt", "backslash"), ("new:folder\\name/1:2 recipe.txt", "new")])
        }
    }

    @MainActor func testEditIndexesAndRenameValidationUseTheOutputFormat() async throws {
        let entries = files.enumerated().map { archiveColumnEntry($0.element.0, index: $0.offset) }
        let strict = EntryNode.tree(from: entries, indexingEdits: true)
        XCTAssertNil(strict.editOccupancy)
        for format: GyoshukuKit.ArchiveFormat in [.tar, .tarGzip, .tarBzip2, .tarXZ] {
            let tree = await EntryNode.build(from: entries, format: format)
            XCTAssertNotNil(tree.editOccupancy)
            let selection = ArchiveEditSelection(try XCTUnwrap(tree.nodes(at: "man3").first))
            let validation = ArchiveRenameValidation(selection: selection, entries: entries, format: format, occupancy: tree.editOccupancy)
            let plan = try validation.plan(for: "man3p")
            XCTAssertEqual(plan.renames.map(\.path), ["man3p/File::Spec.3pm"])
            XCTAssertNoThrow(try plan.validate(entries: entries))
            let state = try await ArchiveReservationState.build(base: entries, generation: 0, changes: .init(),
                validation: .init(base: entries, format: format), staging: nil)
            XCTAssertNotNil(state.occupancy)
            let pending = ArchiveRenameValidation(selection: selection, entries: entries, state: state)
            XCTAssertEqual(try pending.plan(for: "new:folder\\name").renames.map(\.path), ["new:folder\\name/File::Spec.3pm"])
            XCTAssertThrowsError(try ArchiveRenameValidation(selection: selection, entries: entries).plan(for: "man3p"))
        }
    }

    func testStrictDefaultsAndUniversalPathChecksRemainUnchanged() throws {
        let formats: [GyoshukuKit.ArchiveFormat] = [.tar, .tarGzip, .tarBzip2, .tarXZ, .zip, .sevenZip, .lha]
        for name in ["a:b", "a\\b"] {
            XCTAssertThrowsError(try ArchiveEditPlan.leafName(name))
            XCTAssertThrowsError(try ArchiveEditPlan.normalizedPath(name, directory: false))
            XCTAssertThrowsError(try ArchiveImportPlan.path(name))
            for format in formats {
                if [.tar, .tarGzip, .tarBzip2, .tarXZ].contains(format) {
                    XCTAssertEqual(try ArchiveEditPlan.leafName(name, format: format), name)
                    XCTAssertEqual(try ArchiveImportPlan.path(name, format: format), name)
                } else {
                    XCTAssertThrowsError(try ArchiveEditPlan.leafName(name, format: format))
                    XCTAssertThrowsError(try ArchiveImportPlan.path(name, format: format))
                }
            }
        }
        for format in formats {
            for name in ["", ".", "..", "a/../b", "a/./b", "/a", "a//b", "a\0b"] {
                for directory in [false, true] {
                    XCTAssertThrowsError(try ArchiveEditPlan.normalizedPath(name, directory: directory, format: format))
                }
                XCTAssertThrowsError(try ArchiveImportPlan.path(name, format: format))
            }
            XCTAssertThrowsError(try ArchiveEditPlan.leafName("a/b", format: format))
            XCTAssertEqual(try ArchiveEditPlan.leafName("cafe\u{301}", format: format), "café")
            let limit = String(repeating: "a", count: Int(UInt16.max))
            XCTAssertEqual(try ArchiveEditPlan.normalizedPath(limit, directory: false, format: format).utf8.count, 65_535)
            XCTAssertThrowsError(try ArchiveEditPlan.normalizedPath(limit + "a", directory: false, format: format))
            XCTAssertThrowsError(try ArchiveEditPlan.normalizedPath(limit, directory: true, format: format))
            XCTAssertEqual(try ArchiveEditPlan.normalizedPath(String(limit.dropLast()), directory: true, format: format).utf8.count, 65_535)
        }
    }

    func testUnsafeBaseStillUsesFullValidation() throws {
        let entries = [archiveColumnEntry("bad/../path")]
        let validation = ArchiveReservationValidation(base: entries, format: .tar)
        XCTAssertNil(validation.context(for: .init()))
        let count = Mutex(0)
        try ArchiveReservationDiagnostics.observer.withValue({ event, _ in
            if event == .fullValidation { count.withLock { $0 += 1 } }
        }) {
            XCTAssertThrowsError(try validation.validate(.init(), projection: ArchivePendingProjection(entries))) {
                guard case RewriterError.unrepresentable = $0 else { return XCTFail("Unexpected refusal: \($0)") }
            }
        }
        XCTAssertEqual(count.withLock { $0 }, 1)
    }

    @MainActor func testTarSaveAsReplaysPendingPOSIXNames() async throws {
        let fixture = try DeferredSaveFixture(format: .tar, files: files), document = fixture.document
        defer { document.close() }
        _ = try await document.rename(fixture.node("other.txt"), to: "a:b", progress: Progress())
        _ = try await document.append(urls: [fixture.file("1:2 recipe.txt")], to: "", progress: Progress())
        let session = try XCTUnwrap(document.session)
        var existing = try await ArchiveCreationController.existingArchive(from: session, progress: Progress())
        existing.pending = try await ArchiveSaveReplayPlan.build(base: existing.entries, generation: document.generation,
            pending: document.pendingChanges, format: session.reservationFormat)
        let destination = fixture.directory.url.appendingPathComponent("saved.tar.gz")
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: [], destination: destination, format: .tarGzip, existing: existing),
                                               progress: Progress())
        try assertContents(destination, files.filter { $0.0 != "other.txt" } + [("a:b", "other"), ("1:2 recipe.txt", "new")])
        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
    }

    @MainActor func testSaveAsAndSplitConversionKeepUnrepresentableMessage() async throws {
        for format in tarFormats {
            for pending in [false, true] {
                let fixture = try DeferredSaveFixture(format: format, files: files), document = fixture.document
                defer { document.close() }
                let session = try XCTUnwrap(document.session)
                if pending { _ = try await document.rename(fixture.node("man3"), to: "man3p", progress: Progress()) }
                var existing = try await ArchiveCreationController.existingArchive(from: session, progress: Progress())
                if pending {
                    existing.pending = try await ArchiveSaveReplayPlan.build(base: existing.entries, generation: document.generation,
                        pending: document.pendingChanges, format: session.reservationFormat)
                }
                for outputFormat: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .lha] {
                    for split in [false, true] {
                        let destination = fixture.directory.url.appendingPathComponent("converted." + ArchiveCreationPlan.filenameExtension(for: outputFormat))
                        var plan = ArchiveCreationPlan(sources: [], destination: destination, format: outputFormat, existing: existing)
                        if split { plan.splitSchedule = .uniform(size: 65_536) }
                        XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: plan, progress: Progress())) { error in
                            guard case RewriterError.unrepresentable(let entry, let reason) = error else {
                                return XCTFail("Expected unrepresentable refusal, got \(error)")
                            }
                            XCTAssertEqual(entry, pending ? "man3p/File::Spec.3pm" : "man3/File::Spec.3pm")
                            XCTAssertEqual(reason, "出力名に空の要素・禁止文字・不正な相対パスが含まれています")
                            XCTAssertEqual(ArchiveErrorText.describe(error), String(localized: "書き直せない項目があります: \(entry)(\(reason))"))
                        }
                        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathExtension("001").path))
                        XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
                    }
                }
            }
        }
    }

    @MainActor func testExtractionKeepsColonBytesAndStrictOutputComponents() async throws {
        let fixture = try DeferredSaveFixture(format: .tar, behavior: .immediate, files: files), document = fixture.document
        defer { document.close() }
        let session = try XCTUnwrap(document.session), destination = fixture.directory.url.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let output = try ExtractionDestination(url: destination, quarantine: nil)
        XCTAssertThrowsError(try output.validate(["back\\slash.txt"]))
        let result = try await ExtractionService.extract(.init(entries: await session.entries()), from: session, to: destination)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("back\\slash.txt")), Data("backslash".utf8))
        for (name, contents) in files where !name.contains("\\") {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(name)), Data(contents.utf8))
        }
        let mailNames = try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("Maildir/cur").path)
        XCTAssertEqual(mailNames.map { Array($0.utf8) }, [Array("msg:2,S".utf8)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("back/slash.txt").path))
    }
}
