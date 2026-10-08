import AppKit
import Darwin
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class DragInTests: XCTestCase {
    /// 既定の書庫（old.txt と sub/deep/old.txt を持つ ZIP）を書く script。
    private static let originalScript = "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('old.txt', 'original')\n z.writestr('sub/deep/old.txt', 'nested')"

    private final class AdditionProgressTrace: Sendable {
        struct Sample: Sendable { let slot: ArchiveWriteProgress.Slot; let completed: Int64; let total: Int64 }
        private let samples = Mutex<[Sample]>([])

        func record(_ slot: ArchiveWriteProgress.Slot, _ completed: Int64, _ total: Int64) {
            samples.withLock { $0.append(.init(slot: slot, completed: completed, total: total)) }
        }

        func assertStoppedAfterFirstItem(_ progress: Progress, file: StaticString = #filePath, line: UInt = #line) throws {
            let all = samples.withLock { $0 }
            XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 1, file: file, line: line)
            let firstSlotEnd = try XCTUnwrap(all.last { $0.slot == .addition(0) }, file: file, line: line)
            XCTAssertEqual(progress.completedUnitCount, firstSlotEnd.completed, file: file, line: line)
            let completed = [Int64(0)] + all.map(\.completed) + [progress.completedUnitCount]
            XCTAssertTrue(zip(completed, completed.dropFirst()).allSatisfy { $0 <= $1 }, file: file, line: line)
            XCTAssertTrue(all.allSatisfy { $0.completed <= $0.total }, file: file, line: line)
            XCTAssertLessThanOrEqual(progress.completedUnitCount, progress.totalUnitCount, file: file, line: line)
        }
    }

    func testAppendFilePreservesExistingBytesAndPassesUnzip() async throws {
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        XCTAssertTrue(session.capabilities.canEdit)
        XCTAssertNil(session.capabilities.readOnlyReason)
        let result = try await session.append(urls: [fixture.file("new.txt")], to: "", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["new.txt"])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertNil(result.reloadFailure)
        let bytes = try ArchiveOracle.contents(ArchiveReader.open(url: fixture.archive), including: .all)
        XCTAssertEqual(bytes, ["old.txt": Data("original".utf8), "sub/deep/old.txt": Data("nested".utf8), "new.txt": Data("added".utf8)])
        print(try fixture.directory.run(ExternalTool.unzip, ["-t", fixture.archive.path]))
    }

    func testAppendDirectoryPreservesSubtreeAndEmptyDirectoryUnderVirtualFolder() async throws {
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        _ = try fixture.file("tree/a.txt", bytes: Data("a".utf8))
        _ = try fixture.file("tree/deeper/b.txt", bytes: Data("b".utf8))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("tree/empty"), withIntermediateDirectories: true)
        _ = try await session.append(urls: [fixture.root.appendingPathComponent("tree")], to: "sub/deep", progress: Progress())
        let bytes = try ArchiveOracle.contents(ArchiveReader.open(url: fixture.archive), including: .all)
        XCTAssertEqual(bytes["sub/deep/tree/a.txt"], Data("a".utf8))
        XCTAssertEqual(bytes["sub/deep/tree/deeper/b.txt"], Data("b".utf8))
        XCTAssertEqual(bytes["sub/deep/tree/empty/"], Data())
        XCTAssertNil(bytes["tree/a.txt"])
        XCTAssertEqual(bytes.count, 7)
        print(try fixture.directory.run(ExternalTool.unzip, ["-t", fixture.archive.path]))
    }

    @MainActor func testDropTargetFolderFileEmptyAndVirtualRows() throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('real/', '')\n z.writestr('virtual/deep/a', 'a')")
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
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive)
        let result = try await session.append(urls: [fixture.file("old.txt"), fixture.file("sub"), fixture.file("safe.txt")], to: "", progress: Progress())
        XCTAssertEqual(result.failures.map(\.name), ["old.txt", "sub"])
        for failure in result.failures {
            XCTAssertEqual(failure.reason, String(localized: "同じ名前の項目が既にあります: \(failure.name)。",
                                                  bundle: Bundle(for: ArchiveDocument.self)))
        }
        XCTAssertTrue(result.addedPaths.isEmpty)
        XCTAssertEqual(session.generation, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    func testSameBatchNameCollisionAndUnicodeNormalizationAreRefused() async throws {
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive)
        let urls = try [fixture.file("one/café.txt"), fixture.file("two/cafe\u{301}.txt")]
        let result = try await session.append(urls: urls, to: "", progress: Progress())
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.addedPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    func testReadOnlyCPIOAcceptsConversionDropButRefusesAppendWithFormatReason() async throws {
        let fixture = try ScenarioFixture(script: "with tarfile.open(p, 'w') as t:\n i=tarfile.TarInfo('old'); i.size=1; t.addfile(i, io.BytesIO(b'x'))" + "\n" + ScenarioFixture.tarToReadOnlyCPIO, suffix: "cpio")
        let session = try ArchiveSession(url: fixture.archive)
        XCTAssertEqual(session.capabilities.refusal, .format("cpio"))
        let formatName = "cpio"
        XCTAssertEqual(session.capabilities.readOnlyReason, String(localized: "\(formatName)アーカイブは変更できません。"))
        XCTAssertTrue(ArchiveDropTarget.accepts(capabilities: session.capabilities, offersCopy: true, hasFiles: true, busy: false))
        let before = try Data(contentsOf: fixture.archive)
        do {
            _ = try await session.append(urls: [fixture.file("new")], to: "", progress: Progress())
            XCTFail("読み取り専用の cpio が変更できました")
        } catch { XCTAssertTrue(String(describing: error).contains("cpio")) }
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    private func gate(_ gate: UpdateGatekeeper, patch: String) async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('old.txt', 'original')\n" + patch)
        let before = try Data(contentsOf: fixture.archive)
        let capability = ArchiveCapabilities.inspect(url: fixture.archive, format: .zip)
        XCTAssertEqual(capability.refusal, .gatekeeper(gate, gate.reason))
        XCTAssertTrue(capability.readOnlyReason?.contains(gate.reason) == true)
        XCTAssertTrue(ArchiveDropTarget.accepts(capabilities: capability, offersCopy: true, hasFiles: true, busy: false))
        // KaitoKit の読み取りと、文書 open 時の検査も独立に通す。
        let session = try ArchiveSession(url: fixture.archive)
        XCTAssertEqual(session.capabilities.refusal, capability.refusal)
        let readable = try await session.extractionReader()
        XCTAssertEqual(readable.entries.map(\.name), ["old.txt"])
        if gate == .centralDirectoryOffset {
            // offset=1 の人工 fixture は一覧だけ読める。展開の既存の拒否も具体的に検査する。
            XCTAssertThrowsError(try ArchiveOracle.contents(readable, including: .all)) { error in
                XCTAssertEqual(error as? KaitoError, .malformed("ZIP local header overlaps the central directory"))
            }
        } else {
            XCTAssertEqual(try ArchiveOracle.contents(readable, including: .all), ["old.txt": Data("original".utf8)])
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
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        let oldReader = try await session.extractionReader()
        let payload = ArchiveEntryPayload(archiveURL: fixture.archive, generation: 0, entryIndex: 999,
                                          path: "old.txt", isDirectory: false)
        _ = try await session.append(urls: [fixture.file("new")], to: "", progress: Progress())
        XCTAssertEqual(session.generation, 1)
        // 対照群: reopen は実際に古い byte を返す。この差がない fixture では合格させない。
        XCTAssertNil(try ArchiveOracle.contents(oldReader.reopen(), including: .all)["new"])
        let fresh = try await session.extractionReader()
        XCTAssertEqual(try ArchiveOracle.contents(fresh, including: .all)["new"], Data("added".utf8))
        let resolved = try await session.resolveForExtraction([payload])
        XCTAssertEqual(resolved.selection.entries.map(\.name), ["old.txt"])
        XCTAssertEqual(try ArchiveOracle.contents(resolved.reader, including: .all)["old.txt"], Data("original".utf8))
    }

    func testCancellationPartwayPreservesOriginalBytesAndGeneration() async throws {
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive)
        let progress = Progress()
        let trace = AdditionProgressTrace()
        do {
            _ = try await ArchiveWriteProgress.didCreditForTesting.withValue(trace.record) {
                try await session.append(urls: [fixture.file("a"), fixture.file("b")], to: "", progress: progress,
                                         didProcess: { _ in progress.cancel() })
            }
            XCTFail("取消しが成功扱いです")
        } catch { XCTAssertTrue(error is CancellationError) }
        try trace.assertStoppedAfterFirstItem(progress)
        XCTAssertEqual(session.generation, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).contains { $0.hasPrefix(".KaitoFinder-add-") })
    }

    func testFailureAfterFirstItemLeavesOriginalUntouched() async throws {
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive), progress = Progress()
        let second = try fixture.file("b")
        let trace = AdditionProgressTrace()
        do {
            _ = try await ArchiveWriteProgress.didCreditForTesting.withValue(trace.record) {
                // バッチの先読みは didProcess(0) より前に b を読むことがある。willStart は b の最初の lstat・open より前に
                // 呼ばれるので、受け付けた項目がちょうど 1 つのあとの失敗をこれでも検査できる。
                try await ArchiveImportTransaction.willAddFileForTesting.withValue({ url in
                    if url == second {
                        do { try FileManager.default.removeItem(at: second) }
                        catch { XCTFail("Could not remove the second input: \(error)") }
                    }
                }) {
                    try await session.append(urls: [fixture.file("a"), second], to: "", progress: progress)
                }
            }
            XCTFail("消えた入力を追加しました")
        } catch { XCTAssertTrue(String(describing: error).contains("b:")) }
        try trace.assertStoppedAfterFirstItem(progress)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertEqual(session.generation, 0)
    }

    func testLocalDropOperationCoversMasksParentsSubtreesCapabilitiesAndBusyState() {
        typealias Row = ArchiveDropTarget.Row
        let writable = ArchiveCapabilities(mode: .inPlace), readOnly = ArchiveCapabilities(refusal: .format("RAR"))
        let x = Row(path: "a/x.txt", isDirectory: false), y = Row(path: "a/y.txt", isDirectory: false)
        let other = Row(path: "b/z.txt", isDirectory: false), directory = Row(path: "a", isDirectory: true)
        let cases: [(String, [Row], String, NSDragOperation, ArchiveCapabilities, Bool, ArchiveDropTarget.LocalOperation)] = [
            ("両方を許可する通常ドラッグ", [x], "b", [.move, .copy], writable, false, .move),
            ("移動だけ", [x], "b", .move, writable, false, .move),
            ("Option", [x], "b", .copy, writable, false, .copy),
            ("Option は同じ親でも copy 判定", [x, y], "a", .copy, writable, false, .copy),
            ("Option は部分木でも copy 経路", [directory], "a/deep", .copy, writable, false, .copy),
            ("全項目が同じ親", [x, y], "a", [.move, .copy], writable, false, .none),
            ("一項目だけ異なる親", [x, other], "a", [.move, .copy], writable, false, .move),
            ("自分自身", [directory], "a", [.move, .copy], writable, false, .none),
            ("自分の子孫", [other, directory], "a/deep", [.move, .copy], writable, false, .none),
            ("似た接頭辞は子孫でない", [directory], "another", [.move, .copy], writable, false, .move),
            ("ファイルは部分木判定しない", [Row(path: "a", isDirectory: false)], "a/deep", .move, writable, false, .move),
            ("root から root", [Row(path: "root.txt", isDirectory: false)], "", .move, writable, false, .none),
            ("root へ移動", [x], "", .move, writable, false, .move),
            ("正準等価の親", [Row(path: "café/x", isDirectory: false)], "cafe\u{301}", .move, writable, false, .none),
            ("正準等価の子孫", [Row(path: "café", isDirectory: true)], "cafe\u{301}/deep", .move, writable, false, .none),
            ("読み取り専用の移動", [x], "b", [.move, .copy], readOnly, false, .none),
            ("読み取り専用のコピー", [x], "b", .copy, readOnly, false, .none),
            ("移動の処理中", [x], "b", [.move, .copy], writable, true, .none),
            ("コピーの処理中", [x], "b", .copy, writable, true, .none),
            ("空の選択", [], "b", [.move, .copy], writable, false, .none),
            ("空のコピー選択", [], "b", .copy, writable, false, .none),
            ("許可なし", [x], "b", [], writable, false, .none),
            ("リンクだけ", [x], "b", .link, writable, false, .none),
            ("copy だけではない mask", [x], "b", [.copy, .link], writable, false, .none),
            ("全面書き直し形式", [x], "b", [.move, .copy], .init(mode: .rewrite(.tar)), false, .move)
        ]
        for (label, dragged, folder, mask, capabilities, busy, expected) in cases {
            XCTAssertEqual(ArchiveDropTarget.localOperation(dragged: dragged, target: folder, mask: mask,
                capabilities: capabilities, busy: busy), expected, label)
        }
    }

    func testDropRequiresCopyFilesAndIdleArchive() {
        let writable = ArchiveCapabilities(mode: .inPlace)
        XCTAssertTrue(ArchiveDropTarget.accepts(capabilities: writable, offersCopy: true, hasFiles: true, busy: false))
        XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: writable, offersCopy: false, hasFiles: true, busy: false))
        XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: writable, offersCopy: true, hasFiles: false, busy: false))
        XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: writable, offersCopy: true, hasFiles: true, busy: true))
    }

    func testEveryReadOnlyRefusalOffersConversionForFileDrops() {
        let refusals: [ArchiveCapabilities.Refusal] = [
            .format("RAR"), .gatekeeper(.sfxPrefix, "SFX"), .encrypted,
            .unrepresentable("symlink"), .unavailable("read-only volume")
        ]
        for refusal in refusals {
            let capability = ArchiveCapabilities(refusal: refusal)
            XCTAssertFalse(capability.canEdit)
            XCTAssertTrue(ArchiveDropTarget.accepts(capabilities: capability, offersCopy: true, hasFiles: true, busy: false))
            XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: capability, offersCopy: false, hasFiles: true, busy: false))
            XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: capability, offersCopy: true, hasFiles: false, busy: false))
            XCTAssertFalse(ArchiveDropTarget.accepts(capabilities: capability, offersCopy: true, hasFiles: true, busy: true))
        }
    }

    func testPromiseRepresentationTakesPriorityOverFileURL() {
        XCTAssertEqual(ArchiveIncomingRepresentation.choose(hasPromises: true, hasFileURLs: true), .promises)
        XCTAssertEqual(ArchiveIncomingRepresentation.choose(hasPromises: true, hasFileURLs: false), .promises)
        XCTAssertEqual(ArchiveIncomingRepresentation.choose(hasPromises: false, hasFileURLs: true), .fileURLs)
        XCTAssertEqual(ArchiveIncomingRepresentation.choose(hasPromises: false, hasFileURLs: false), .none)
    }

    @MainActor func testViewStateRestoresSelectionExpansionAndScrollAnchorByPath() throws {
        let fixture = try ScenarioFixture(script: Self.originalScript)
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
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
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
        let fixture = try ScenarioFixture(script: Self.originalScript), document = ArchiveDocument()
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
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        let source = PasteboardProbe()
        source.urls = [try fixture.file("pasted.txt")]
        let result = try await session.append(urls: ArchiveIncomingPasteboard.readPaste(source), to: "sub/deep", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["sub/deep/pasted.txt"])
        XCTAssertEqual(source.events, ["read URLs"])
        let reader = try await session.extractionReader()
        XCTAssertEqual(try ArchiveOracle.contents(reader, including: .all)["sub/deep/pasted.txt"], Data("added".utf8))
    }

    @MainActor func testNamedPasteboardFileURLAdapter() throws {
        let fixture = try ScenarioFixture(script: Self.originalScript)
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
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive), progress = Progress()
        do {
            _ = try await session.append(urls: [fixture.file("new")], to: "", progress: progress,
                                         willPublish: { progress.cancel() })
            XCTFail("公開直前の取消しを無視しました")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 1)
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount - 1)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertEqual(session.generation, 0)
    }

    func testFailureAfterStagedCommitStillLeavesOriginalUntouched() async throws {
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        let before = try Data(contentsOf: fixture.archive), progress = Progress()
        do {
            _ = try await session.append(urls: [fixture.file("new")], to: "", progress: progress,
                willPublish: { throw ExtractionFailure.refused("公開前の検証失敗") })
            XCTFail("公開前の失敗を無視しました")
        } catch { XCTAssertEqual(String(describing: error), "公開前の検証失敗") }
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 1)
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount - 1)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        XCTAssertEqual(session.generation, 0)
    }

    func testLeadingDotExistingEntryCollisionIsRefused() async throws {
        let fixture = try ScenarioFixture(script: "with zipfile.ZipFile(p, 'w') as z:\n z.writestr('./old.txt', 'original')")
        let session = try ArchiveSession(url: fixture.archive), before = try Data(contentsOf: fixture.archive)
        let result = try await session.append(urls: [fixture.file("old.txt")], to: "", progress: Progress())
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.addedPaths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
    }

    func testAppendPreservesArchiveQuarantinePermissionsAndExtendedAttributes() async throws {
        let fixture = try ScenarioFixture(script: Self.originalScript)
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
        let fixture = try ScenarioFixture(script: Self.originalScript), session = try ArchiveSession(url: fixture.archive)
        _ = try fixture.file("outside/secret", bytes: Data("outside".utf8))
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("tree"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.root.appendingPathComponent("tree/link").path, withDestinationPath: "../outside")
        let result = try await session.append(urls: [fixture.root.appendingPathComponent("tree")], to: "", progress: Progress())
        XCTAssertEqual(result.addedPaths, ["tree", "tree/link"])
        let entries = await session.entries()
        XCTAssertEqual(entries.first { $0.name == "tree/link" }?.kind, .symlink)
        XCTAssertFalse(entries.contains { $0.name.contains("secret") })
    }

}
