import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class DragInTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let archive: URL
        init(script: String = "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('old.txt', 'original')\n z.writestr('sub/deep/old.txt', 'nested')") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("KaitoFinder-DragIn-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            archive = root.appendingPathComponent("archive.zip")
            try run("/usr/bin/python3", ["-c", "import sys, zipfile, tarfile, io, struct\np=sys.argv[1]\n" + script, archive.path])
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String, _ text: String = "added") throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }
        @discardableResult func run(_ tool: String, _ args: [String]) throws -> String {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, text)
            return text
        }
    }

    private func contents(_ reader: ArchiveReader) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for entry in reader.entries {
            var bytes = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
            result[entry.name] = bytes
        }
        return result
    }

    func testAppendFilePreservesExistingBytesAndPassesUnzip() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        XCTAssertTrue(session.capabilities.canAppend)
        XCTAssertFalse(session.capabilities.canDelete)
        XCTAssertFalse(session.capabilities.canRename)
        XCTAssertFalse(session.capabilities.canEditAttributes)
        XCTAssertNil(session.capabilities.readOnlyReason)
        let result = try await session.append(urls: [fixture.file("new.txt")], to: "", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["new.txt"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(result.reloadFailure)
        let bytes = try contents(ArchiveReader.open(url: fixture.archive))
        XCTAssertEqual(bytes, ["old.txt": Data("original".utf8), "sub/deep/old.txt": Data("nested".utf8), "new.txt": Data("added".utf8)])
        print(try fixture.run("/usr/bin/unzip", ["-t", fixture.archive.path]))
    }

    func testAppendDirectoryPreservesSubtreeAndEmptyDirectoryUnderVirtualFolder() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        _ = try fixture.file("tree/a.txt", "a")
        _ = try fixture.file("tree/deeper/b.txt", "b")
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("tree/empty"), withIntermediateDirectories: true)
        _ = try await session.append(urls: [fixture.root.appendingPathComponent("tree")], to: "sub/deep", progress: Progress())
        let bytes = try contents(ArchiveReader.open(url: fixture.archive))
        XCTAssertEqual(bytes["sub/deep/tree/a.txt"], Data("a".utf8))
        XCTAssertEqual(bytes["sub/deep/tree/deeper/b.txt"], Data("b".utf8))
        XCTAssertEqual(bytes["sub/deep/tree/empty/"], Data())
        XCTAssertNil(bytes["tree/a.txt"])
        XCTAssertEqual(bytes.count, 7)
        print(try fixture.run("/usr/bin/unzip", ["-t", fixture.archive.path]))
    }

    @MainActor func testDropTargetFolderFileEmptyAndVirtualRows() throws {
        let fixture = try Fixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('real/', '')\n z.writestr('virtual/deep/a', 'a')")
        let root = EntryNode.tree(from: try ArchiveReader.open(url: fixture.archive).entries)
        let real = try XCTUnwrap(root.children.first { $0.path == "real" })
        let virtual = try XCTUnwrap(root.children.first { $0.path == "virtual" }?.children.first)
        let file = try XCTUnwrap(virtual.children.first)
        XCTAssertFalse(real.isVirtual)
        XCTAssertTrue(virtual.isVirtual)
        XCTAssertTrue(ArchiveDropTarget.node(for: real, in: root) === real)
        XCTAssertTrue(ArchiveDropTarget.node(for: file, in: root) === virtual)
        XCTAssertTrue(ArchiveDropTarget.node(for: virtual, in: root) === virtual)
        XCTAssertNil(ArchiveDropTarget.node(for: nil, in: root))
        XCTAssertEqual(ArchiveDropTarget.folder(for: .init(real)), "real")
        XCTAssertEqual(ArchiveDropTarget.folder(for: .init(virtual)), "virtual/deep")
        XCTAssertEqual(ArchiveDropTarget.folder(for: .init(file)), "virtual/deep")
        XCTAssertEqual(ArchiveDropTarget.folder(for: nil), "")
        XCTAssertEqual(ArchiveDropTarget.folder(for: .init(path: "root.txt", isDirectory: false)), "")
    }

    func testCollisionRefusesWholeDropAndReportsEveryConflictingItem() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive)
        let result = try await session.append(urls: [fixture.file("old.txt"), fixture.file("sub"), fixture.file("safe.txt")], to: "", progress: Progress())
        XCTAssertEqual(result.failures.map(\.name), ["old.txt", "sub"])
        XCTAssertTrue(result.failures.allSatisfy { $0.reason.contains("同じ名前") })
        XCTAssertTrue(result.addedPaths.isEmpty)
        XCTAssertEqual(session.generation, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    func testSameBatchNameCollisionAndUnicodeNormalizationAreRefused() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive)
        let urls = try [fixture.file("one/café.txt"), fixture.file("two/cafe\u{301}.txt")]
        let result = try await session.append(urls: urls, to: "", progress: Progress())
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.addedPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    func testNonZIPCapabilityRefusesDropAndAppendWithFormatReason() async throws {
        let fixture = try Fixture(script: "with tarfile.open(p, 'w') as t:\n i=tarfile.TarInfo('old'); i.size=1; t.addfile(i, io.BytesIO(b'x'))")
        let session = try ArchiveSession(url: fixture.archive)
        XCTAssertEqual(session.capabilities.refusal, .format("TAR"))
        XCTAssertEqual(session.capabilities.readOnlyReason, "TAR 書庫は変更できません")
        XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: session.capabilities, offersCopy: true, hasFiles: true, busy: false))
        let before = try Data(contentsOf: fixture.archive)
        do {
            _ = try await session.append(urls: [fixture.file("new")], to: "", progress: Progress())
            XCTFail("非 ZIP が変更できました")
        } catch { XCTAssertTrue(String(describing: error).contains("TAR")) }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    private func gate(_ gate: UpdateGatekeeper, patch: String) async throws {
        let fixture = try Fixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('old.txt', 'original')\n" + patch)
        let before = try Data(contentsOf: fixture.archive)
        let capability = ArchiveCapabilities.inspect(url: fixture.archive, format: .zip)
        XCTAssertEqual(capability.refusal, .gatekeeper(gate, gate.reason))
        XCTAssertTrue(capability.readOnlyReason?.contains(gate.reason) == true)
        XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: capability, offersCopy: true, hasFiles: true, busy: false))
        // KaitoKit の読み取りと、文書 open 時の検査も独立に通す。
        let session = try ArchiveSession(url: fixture.archive)
        XCTAssertEqual(session.capabilities.refusal, capability.refusal)
        let readable = try await session.extractionReader()
        XCTAssertEqual(readable.entries.map(\.name), ["old.txt"])
        if gate == .centralDirectoryOffset {
            // offset=1 の人工 fixture は一覧だけ読める。展開の既存の拒否も具体的に検査する。
            XCTAssertThrowsError(try contents(readable)) { error in
                XCTAssertEqual(error as? KaitoError, .malformed("ZIP local header overlaps the central directory"))
            }
        } else {
            XCTAssertEqual(try contents(readable), ["old.txt": Data("original".utf8)])
        }
        do {
            _ = try await session.append(urls: [fixture.file("new")], to: "", progress: Progress())
            XCTFail("門番を通過しました")
        } catch { XCTAssertTrue(String(describing: error).contains(gate.reason)) }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    func testSFXGatekeeperReasonAtOpen() async throws {
        try await gate(.sfxPrefix, patch: "b=open(p,'rb').read(); prefix=bytearray(128); prefix[:2]=b'MZ'; struct.pack_into('<I',prefix,60,64); prefix[64:68]=bytes.fromhex('50450000'); open(p,'wb').write(prefix+b)")
    }
    func testTrailingDataGatekeeperReasonAtOpen() async throws {
        try await gate(.trailingData, patch: "with open(p,'ab') as f: f.write(b'trailing')")
    }
    func testTruncatedCentralDirectoryOffsetGatekeeperReasonAtOpen() async throws {
        try await gate(.centralDirectoryOffset, patch: "b=bytearray(open(p,'rb').read()); e=b.rfind(b'PK\\x05\\x06'); struct.pack_into('<I',b,e+16,1); open(p,'wb').write(b)")
    }

    func testAppendFreshOpenSeesNewInodeAndOldPromiseResolvesByPath() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let oldReader = try await session.extractionReader()
        let payload = ArchiveEntryPayload(archiveURL: fixture.archive, generation: 0, entryIndex: 999,
                                          path: "old.txt", isDirectory: false)
        _ = try await session.append(urls: [fixture.file("new")], to: "", progress: Progress())
        XCTAssertEqual(session.generation, 1)
        // 対照群: reopen は実際に古い byte を返す。この差がない fixture では合格させない。
        XCTAssertNil(try contents(oldReader.reopen())["new"])
        let fresh = try await session.extractionReader()
        XCTAssertEqual(try contents(fresh)["new"], Data("added".utf8))
        let resolved = try await session.resolveForExtraction([payload])
        XCTAssertEqual(resolved.selection.entries.map(\.name), ["old.txt"])
        XCTAssertEqual(try contents(resolved.reader)["old.txt"], Data("original".utf8))
    }

    func testCancellationPartwayPreservesOriginalBytesAndGeneration() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive)
        let progress = Progress()
        do {
            _ = try await session.append(urls: [fixture.file("a"), fixture.file("b")], to: "", progress: progress,
                                         didProcess: { _ in progress.cancel() })
            XCTFail("取消しが成功扱いです")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(progress.completedUnitCount, 1)
        XCTAssertEqual(session.generation, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".KaitoFinder-add-") })
    }

    func testFailureAfterFirstItemLeavesOriginalUntouched() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive), progress = Progress()
        let second = try fixture.file("b")
        do {
            _ = try await session.append(urls: [fixture.file("a"), second], to: "", progress: progress,
                didProcess: { _ in try FileManager.default.removeItem(at: second) })
            XCTFail("消えた入力を追加しました")
        } catch { XCTAssertTrue(String(describing: error).contains("b:")) }
        XCTAssertEqual(progress.completedUnitCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertEqual(session.generation, 0)
    }

    func testDropRequiresCopyAndIdleWritableArchive() {
        let writable = ArchiveCapabilities(refusal: nil)
        XCTAssertTrue(ArchiveDropTarget.accepts(capabilities: writable, offersCopy: true, hasFiles: true, busy: false))
        XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: writable, offersCopy: false, hasFiles: true, busy: false))
        XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: writable, offersCopy: true, hasFiles: false, busy: false))
        XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: writable, offersCopy: true, hasFiles: true, busy: true))
    }

    func testPromiseRepresentationTakesPriorityOverFileURL() {
        XCTAssertEqual(ArchiveIncomingRepresentation.choose(hasPromises: true, hasFileURLs: true), .promises)
        XCTAssertEqual(ArchiveIncomingRepresentation.choose(hasPromises: true, hasFileURLs: false), .promises)
        XCTAssertEqual(ArchiveIncomingRepresentation.choose(hasPromises: false, hasFileURLs: true), .fileURLs)
        XCTAssertEqual(ArchiveIncomingRepresentation.choose(hasPromises: false, hasFileURLs: false), .none)
    }

    @MainActor func testViewStateRestoresSelectionExpansionAndScrollAnchorByPath() throws {
        let fixture = try Fixture()
        let entries = try ArchiveReader.open(url: fixture.archive).entries
        let old = EntryNode.tree(from: entries), new = EntryNode.tree(from: entries)
        let state = ArchiveViewState(selectedPaths: ["sub/deep/old.txt"], expandedPaths: ["sub", "sub/deep"], topPath: "sub/deep")
        let resolved = state.resolve(in: new)
        XCTAssertEqual(resolved.selected.map(\.path), ["sub/deep/old.txt"])
        XCTAssertEqual(resolved.expanded.map(\.path), ["sub", "sub/deep"])
        XCTAssertEqual(resolved.top?.path, "sub/deep")
        XCTAssertFalse(old.children[1] === new.children[1])
    }

    func testUnsafeDestinationAndMissingFolderLeaveArchiveUntouched() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive)
        for path in ["../escape", "/absolute", "sub/../escape", "missing", "old.txt"] {
            do {
                _ = try await session.append(urls: [fixture.file("new")], to: path, progress: Progress())
                XCTFail("不正な追加先を受理しました: \(path)")
            } catch { }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    @MainActor func testDocumentAppendInvalidatesMaterializationCache() async throws {
        let fixture = try Fixture(), document = ArchiveDocument()
        try document.read(from: fixture.archive, ofType: "zip")
        let controller = try XCTUnwrap(document.materializationController())
        let session = try XCTUnwrap(document.session)
        let payload = ArchiveEntryPayload(archiveURL: fixture.archive, generation: 0, entryIndex: 0, path: "old.txt", isDirectory: false)
        let entries = await session.entries()
        let entry = try XCTUnwrap(entries.first)
        let preview = ArchivePreviewItem(payload: payload, capability: EntryReadCapability(entry: entry, isDirectory: false, format: .zip), requiresProgress: false)
        controller.setSelection([preview])
        controller.display(index: 0) { _ in }
        await controller.task?.value
        XCTAssertNotNil(controller.cachedItem(for: payload)?.previewItemURL)
        _ = try await document.append(urls: [fixture.file("new")], to: "", progress: Progress())
        XCTAssertEqual(document.generation, 1)
        XCTAssertNil(controller.cachedItem(for: payload))
        XCTAssertFalse(controller === document.materializationController())
        await document.materializationCleanup?.value
        document.close()
    }
    @MainActor private final class PasteboardProbe: ArchivePasteboardSource {
        var events: [String] = []
        var promises = true
        var files = true
        var urls: [URL] = []
        var hasPromises: Bool { events.append("promise types"); return promises }
        var hasFileURLs: Bool { events.append("URL types"); return files }
        func readPromises() -> [String] { events.append("read promises"); return ["promised"] }
        func readFileURLs() -> [URL] { events.append("read URLs"); return urls }
    }

    @MainActor func testPasteValidationNeverReadsObjectsAndDropReadsPromiseFirst() {
        let source = PasteboardProbe()
        XCTAssertTrue(ArchiveIncomingPasteboard.canPaste(source))
        XCTAssertEqual(source.events, ["URL types"])
        source.events = []
        XCTAssertEqual(ArchiveIncomingPasteboard.representation(source), .promises)
        XCTAssertEqual(source.events, ["promise types"])
        source.events = []
        guard case .promises(let values) = ArchiveIncomingPasteboard.readDrop(source) else { return XCTFail("promise を選びませんでした") }
        XCTAssertEqual(values, ["promised"])
        XCTAssertEqual(source.events, ["promise types", "read promises"])
        source.events = []
        _ = ArchiveIncomingPasteboard.readPaste(source)
        XCTAssertEqual(source.events, ["read URLs"])
    }

    @MainActor func testPasteAddsFileURLsToDisplayedFolderWithoutUsingSelection() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let source = PasteboardProbe()
        source.urls = [try fixture.file("pasted.txt")]
        let result = try await session.append(urls: ArchiveIncomingPasteboard.readPaste(source), to: "sub/deep", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["sub/deep/pasted.txt"])
        XCTAssertEqual(source.events, ["read URLs"])
        let reader = try await session.extractionReader()
        XCTAssertEqual(try contents(reader)["sub/deep/pasted.txt"], Data("added".utf8))
    }

    @MainActor func testNamedPasteboardFileURLAdapter() throws {
        let fixture = try Fixture()
        let pasteboard = NSPasteboard(name: .init("KaitoFinder-DragIn-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.setString("probe", forType: .string) else {
            throw XCTSkip("この実行環境では名前付き pasteboard サービスへ書き込めません")
        }
        let url = try fixture.file("paste.txt")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([url as NSURL]))
        let source = AppKitArchivePasteboard(pasteboard: pasteboard)
        XCTAssertTrue(ArchiveIncomingPasteboard.canPaste(source))
        XCTAssertEqual(ArchiveIncomingPasteboard.readPaste(source), [url])
    }

    func testCancellationAfterStagedCommitStillLeavesOriginalUntouched() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive), progress = Progress()
        do {
            _ = try await session.append(urls: [fixture.file("new")], to: "", progress: progress,
                                         willPublish: { progress.cancel() })
            XCTFail("公開直前の取消しを無視しました")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(progress.completedUnitCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertEqual(session.generation, 0)
    }

    func testFailureAfterStagedCommitStillLeavesOriginalUntouched() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive), progress = Progress()
        do {
            _ = try await session.append(urls: [fixture.file("new")], to: "", progress: progress,
                willPublish: { throw ExtractionFailure.refused("公開前の検証失敗") })
            XCTFail("公開前の失敗を無視しました")
        } catch { XCTAssertEqual(String(describing: error), "公開前の検証失敗") }
        XCTAssertEqual(progress.completedUnitCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertEqual(session.generation, 0)
    }

    func testLeadingDotExistingEntryCollisionIsRefused() async throws {
        let fixture = try Fixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('./old.txt', 'original')")
        let session = try ArchiveSession(url: fixture.archive), before = try Data(contentsOf: fixture.archive)
        let result = try await session.append(urls: [fixture.file("old.txt")], to: "", progress: Progress())
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.addedPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    func testAppendPreservesArchiveQuarantinePermissionsAndExtendedAttributes() async throws {
        let fixture = try Fixture()
        let quarantine = Data("0083;00000001;KaitoFinderTests;append".utf8)
        try ExtractionQuarantine.apply(quarantine, to: fixture.archive)
        XCTAssertEqual(chmod(fixture.archive.path, 0o640), 0)
        let attribute = Data("metadata".utf8)
        XCTAssertEqual(attribute.withUnsafeBytes {
            setxattr(fixture.archive.path, "com.shunnag.KaitoFinderTests", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }, 0)
        let before = try FileManager.default.attributesOfItem(atPath: fixture.archive.path)
        let session = try ArchiveSession(url: fixture.archive)
        _ = try await session.append(urls: [fixture.file("new")], to: "", progress: Progress())
        XCTAssertEqual(try ExtractionQuarantine.read(from: fixture.archive), quarantine)
        let after = try FileManager.default.attributesOfItem(atPath: fixture.archive.path)
        XCTAssertEqual(after[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(after[.creationDate] as? Date, before[.creationDate] as? Date)
        var data = Data(count: attribute.count)
        let count = data.withUnsafeMutableBytes {
            getxattr(fixture.archive.path, "com.shunnag.KaitoFinderTests", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        XCTAssertEqual(count, attribute.count)
        XCTAssertEqual(data, attribute)
    }

    func testDirectorySymlinkIsStoredWithoutFollowingItsSubtree() async throws {
        let fixture = try Fixture(), session = try ArchiveSession(url: fixture.archive)
        _ = try fixture.file("outside/secret", "outside")
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("tree"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("tree/link").path, withDestinationPath: "../outside")
        let result = try await session.append(urls: [fixture.root.appendingPathComponent("tree")], to: "", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["tree", "tree/link"])
        let entries = await session.entries()
        XCTAssertEqual(entries.first { $0.name == "tree/link" }?.kind, .symlink)
        XCTAssertFalse(entries.contains { $0.name.contains("secret") })
    }

}
