import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveImportConflictTests: XCTestCase {
    @MainActor func testReplacementRequiresMatchingUpdaterEntriesBeforeRemovingAnything() async throws {
        let fixture = try ScenarioFixture(), source = try fixture.file("original.txt")
        let before = try ScenarioFixture.digest(fixture.archive)
        let entries = try ArchiveReader.open(url: fixture.archive).entries
        let originalPlan = try await ArchiveImportPlan.resolving(urls: [source], folder: "", existing: entries,
            archive: fixture.archive, generation: 0, progress: Progress(), options: .init(), resolver: { _ in .init(choice: .replace) })
        for expected in [nil, []] as [[ArchiveEntry]?] {
            var plan = originalPlan
            plan.expectedEntries = expected
            XCTAssertThrowsError(try ArchiveImportTransaction.run(plan: plan, archive: fixture.archive, mode: .inPlace, progress: Progress())) {
                XCTAssertEqual($0 as? ArchiveEditError, .staleSelection)
            }
            XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        }
    }

    @MainActor func testEncryptedZIPAndSevenZipKeepProtectionAfterReplacingEveryFile() async throws {
        let fixture = try ScenarioFixture(), old = try fixture.file("old/report.txt")
        let incoming = try fixture.file("new/report.txt", bytes: Data("replacement".utf8))
        for format in [GyoshukuKit.ArchiveFormat.zip, .sevenZip] {
            let archive = fixture.root.appendingPathComponent("protected." + ArchiveCreationPlan.filenameExtension(for: format))
            let encryption = ArchiveEncryptionSettings(password: "test-key", encryptsSevenZipHeaders: format == .sevenZip)
            _ = try ArchiveCreationTransaction.run(plan: .init(sources: [old], destination: archive, format: format,
                options: encryption.applying(to: WriterOptions(), format: format)), progress: Progress())
            let session = try ArchiveSession(url: archive, password: "test-key")
            _ = try await session.append(urls: [incoming], to: "", progress: Progress(), resolveConflict: { _ in .init(choice: .replace) })
            let reader = try ArchiveReader.open(url: archive, options: .init(password: "test-key"))
            let entry = try XCTUnwrap(reader.entries.first)
            XCTAssertEqual(reader.entries.count, 1)
            XCTAssertTrue(entry.isEncrypted)
            var bytes = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
            XCTAssertEqual(bytes, Data("replacement".utf8))
            let settings = await session.encryptionSettings()
            XCTAssertEqual(settings.password, encryption.password)
            XCTAssertEqual(settings.zipEncryption, encryption.zipEncryption)
            XCTAssertEqual(settings.encryptsSevenZipHeaders, encryption.encryptsSevenZipHeaders)
        }
    }

    @MainActor func testReplacementResolvesLeadingDotAndCanonicalEquivalentArchiveNames() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('./cafe\\u0301.txt', b'old'); z.writestr('./keep', b'keep')")
        let source = try fixture.file("café.txt"), session = try ArchiveSession(url: fixture.archive)
        _ = try await session.append(urls: [source], to: "", progress: Progress(), resolveConflict: { conflict in
            XCTAssertEqual(conflict.path, "café.txt")
            XCTAssertEqual(conflict.existing.size, 3)
            return .init(choice: .replace)
        })
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), ["café.txt": Data("added".utf8), "./keep": Data("keep".utf8)])
    }

    @MainActor func testReplaceAcrossEveryWritableFormatComparesMetadataAndPreservesOtherFiles() async throws {
        let fixture = try ScenarioFixture()
        let old = try fixture.file("old/report.txt", bytes: Data("old".utf8))
        let incoming = try fixture.file("new/report.txt", bytes: Data("new contents".utf8))
        let keep = try fixture.file("keep.txt", bytes: Data("keep".utf8))
        for format in ArchivePreferences.formats {
            let archive = fixture.root.appendingPathComponent("replace." + ArchiveCreationPlan.filenameExtension(for: format))
            _ = try ArchiveCreationTransaction.run(plan: .init(sources: [old, keep], destination: archive, format: format), progress: Progress())
            let session = try ArchiveSession(url: archive), before = try ScenarioFixture.digest(archive)
            var conflicts = 0
            let result = try await session.append(urls: [incoming], to: "", progress: Progress(), resolveConflict: { conflict in
                conflicts += 1
                XCTAssertEqual(conflict.path, "report.txt")
                XCTAssertEqual(conflict.existing.size, 3)
                XCTAssertEqual(conflict.incoming.size, 12)
                XCTAssertNotNil(conflict.incoming.modificationDate)
                XCTAssertEqual(try ScenarioFixture.digest(archive), before, "確認時点では原本を書き換えない")
                return .init(choice: .replace)
            })
            XCTAssertEqual(conflicts, 1)
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertNil(result.reloadFailure)
            XCTAssertEqual(result.addedPaths, ["report.txt"])
            XCTAssertEqual(try ScenarioFixture.contents(archive), ["report.txt": Data("new contents".utf8), "keep.txt": Data("keep".utf8)])
            XCTAssertEqual(session.generation, 1)
            XCTAssertEqual(try ArchiveReader.open(url: archive).entries.filter { $0.name == "report.txt" }.count, 1)
        }
    }

    @MainActor func testThousandConflictsMixSkipAndReplaceAllAsOneUndoableOperation() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            for i in range(1000): z.writestr(f'target/item-{i:04}.txt', b'old')
            z.writestr('keep.txt', b'keep')
        """)
        var sources: [URL] = []
        for index in 0..<1000 { sources.append(try fixture.file(String(format: "in/item-%04d.txt", index), bytes: Data("new \(index)".utf8))) }
        sources.append(try fixture.file("in/extra.txt"))
        let (document, _) = try await scenarioDocument(fixture), before = try ScenarioFixture.digest(fixture.archive)
        var asked: [String] = []
        let result = try await document.append(urls: sources, to: "target", progress: Progress(), resolveConflict: { conflict in
            asked.append(conflict.path)
            return asked.count == 1 ? .init(choice: .skip) : .init(choice: .replace, applyToRemaining: true)
        })
        XCTAssertEqual(asked, ["target/item-0000.txt", "target/item-0001.txt"])
        XCTAssertEqual(result.addedPaths.count, 1000)
        let contents = try ScenarioFixture.contents(fixture.archive)
        XCTAssertEqual(contents["target/item-0000.txt"], Data("old".utf8))
        for index in 1..<1000 { XCTAssertEqual(contents[String(format: "target/item-%04d.txt", index)], Data("new \(index)".utf8)) }
        XCTAssertEqual(contents["target/extra.txt"], Data("added".utf8))
        XCTAssertEqual(contents["keep.txt"], Data("keep".utf8))
        XCTAssertEqual(document.generation, 1)
        document.undo(nil)
        await document.undoTask?.value
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        XCTAssertFalse(document.undoManager?.canUndo == true)
        document.redo(nil)
        await document.undoTask?.value
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), contents)
        try fixture.directory.run("/usr/bin/unzip", ["-tqq", fixture.archive.path])
    }

    @MainActor func testCancelAfterAcceptingOneReplacementLeavesWholeBatchAndUndoUntouched() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('a', b'a'); z.writestr('b', b'b')")
        let sources = try [fixture.file("in/a"), fixture.file("in/b"), fixture.file("in/new")]
        let (document, _) = try await scenarioDocument(fixture), before = try ScenarioFixture.digest(fixture.archive)
        do {
            _ = try await document.append(urls: sources, to: "", progress: Progress(), resolveConflict: { conflict in
                if conflict.path == "b" { throw CancellationError() }
                return .init(choice: .replace)
            })
            XCTFail("キャンセルが無視された")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertFalse(document.undoManager?.canUndo == true)
    }

    @MainActor func testSkippingEveryConflictDoesNotRewriteOrCreateUndo() async throws {
        let fixture = try ScenarioFixture(), source = try fixture.file("original.txt")
        let (document, _) = try await scenarioDocument(fixture), before = try ScenarioFixture.digest(fixture.archive)
        let result = try await document.append(urls: [source, source], to: "", progress: Progress(), resolveConflict: { _ in
            .init(choice: .skip, applyToRemaining: true)
        })
        XCTAssertTrue(result.addedPaths.isEmpty && result.failures.isEmpty)
        XCTAssertEqual(document.generation, 0)
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        XCTAssertFalse(document.undoManager?.canUndo == true)
    }

    @MainActor func testSameBatchUnicodeEquivalentNamesCompareBothSourcesAndKeepOneRecord() async throws {
        let fixture = try ScenarioFixture(), first = try fixture.file("one/café.txt", bytes: Data("one".utf8))
        let second = try fixture.file("two/cafe\u{301}.txt", bytes: Data("second".utf8))
        let session = try ArchiveSession(url: fixture.archive)
        var asked = false
        let result = try await session.append(urls: [first, second], to: "", progress: Progress(), resolveConflict: { conflict in
            asked = true
            XCTAssertEqual(conflict.existing.size, 3)
            XCTAssertEqual(conflict.incoming.size, 6)
            guard case .file(let prior) = conflict.existing.source else { XCTFail("追加操作の入力同士を比較していない"); return .init(choice: .skip) }
            XCTAssertEqual(prior, first)
            return .init(choice: .replace)
        })
        XCTAssertTrue(asked)
        XCTAssertEqual(result.addedPaths, ["café.txt"])
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive)["café.txt"], Data("second".utf8))
        XCTAssertEqual(try ArchiveReader.open(url: fixture.archive).entries.count, 2)
    }

    @MainActor func testFolderAndTypeConflictsRequireTheirOwnDecisionAndReplaceEntireVirtualSubtree() async throws {
        let fixture = try ScenarioFixture(script: """
        with zipfile.ZipFile(p, 'w') as z:
            z.writestr('a.txt', b'old')
            z.writestr('tree/old/deep.txt', b'deep')
            z.writestr('treeish/keep.txt', b'keep')
            z.writestr('folder', b'file')
        """)
        let sources = try [fixture.file("in/a.txt"), fixture.file("in/tree", bytes: Data("tree as file".utf8)), fixture.folder("in/folder")]
        _ = try fixture.file("in/folder/child.txt")
        _ = try fixture.folder("in/folder/empty")
        let session = try ArchiveSession(url: fixture.archive)
        var asked: [String] = []
        _ = try await session.append(urls: sources, to: "", progress: Progress(), resolveConflict: { conflict in
            asked.append(conflict.path)
            XCTAssertEqual(conflict.allowsBatchChoice, conflict.path == "a.txt")
            return .init(choice: .replace, applyToRemaining: true)
        })
        XCTAssertEqual(asked, ["a.txt", "tree", "folder"])
        let contents = try ScenarioFixture.contents(fixture.archive)
        XCTAssertNil(contents["tree/old/deep.txt"])
        XCTAssertEqual(contents["tree"], Data("tree as file".utf8))
        XCTAssertEqual(contents["treeish/keep.txt"], Data("keep".utf8))
        XCTAssertEqual(contents["folder/child.txt"], Data("added".utf8))
        XCTAssertTrue(try ArchiveReader.open(url: fixture.archive).entries.contains { $0.name == "folder/empty/" })
    }

    @MainActor func testChangedSourceDuringConfirmationOrCompressionRefusesReplacement() async throws {
        for changeDuringConfirmation in [true, false] {
            let fixture = try ScenarioFixture(), source = try fixture.file("in/original.txt")
            let session = try ArchiveSession(url: fixture.archive), before = try ScenarioFixture.digest(fixture.archive)
            do {
                _ = try await session.append(urls: [source], to: "", progress: Progress(), resolveConflict: { _ in
                    if changeDuringConfirmation { try Data("changed before write".utf8).write(to: source) }
                    return .init(choice: .replace)
                }, didProcess: { _ in
                    if !changeDuringConfirmation { try Data("changed during write".utf8).write(to: source) }
                })
                XCTFail("確認した入力を変更したのに公開された")
            } catch { XCTAssertTrue(String(describing: error).contains("追加元が変更")) }
            XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
            XCTAssertEqual(session.generation, 0)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".KaitoFinder-add-") })
        }
    }

    @MainActor func testArchiveMutationWhileAwaitingDecisionCannotReuseOldConsent() async throws {
        let fixture = try ScenarioFixture(), source = try fixture.file("original.txt"), extra = try fixture.file("extra.txt")
        let session = try ArchiveSession(url: fixture.archive)
        do {
            _ = try await session.append(urls: [source], to: "", progress: Progress(), resolveConflict: { _ in
                _ = try await session.append(urls: [extra], to: "", progress: Progress())
                return .init(choice: .replace)
            })
            XCTFail("別の世代への同意を流用した")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .staleSelection) }
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), ["original.txt": Data("original".utf8), "extra.txt": Data("added".utf8)])
        XCTAssertEqual(session.generation, 1)
    }

    @MainActor func testCancellationBeforePublicationRestoresOriginalAfterStagedReplacement() async throws {
        let fixture = try ScenarioFixture(), source = try fixture.file("original.txt"), progress = Progress()
        let (document, _) = try await scenarioDocument(fixture), before = try ScenarioFixture.digest(fixture.archive)
        do {
            _ = try await document.append(urls: [source], to: "", progress: progress,
                resolveConflict: { _ in .init(choice: .replace) }, willPublish: { progress.cancel() })
            XCTFail("公開前のキャンセルが無視された")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try ScenarioFixture.digest(fixture.archive), before)
        XCTAssertEqual(document.generation, 0)
        XCTAssertFalse(document.undoManager?.canUndo == true)
    }
}
