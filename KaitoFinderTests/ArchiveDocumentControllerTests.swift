import AppKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveDocumentControllerTests: XCTestCase {
    @MainActor func testSharedControllerIsInstalledAtLaunch() {
        XCTAssertTrue(NSDocumentController.shared is ArchiveDocumentController)
    }

    @MainActor func testTypeLookupAddsOnlyUnrecognizedSplitVolumeNames() throws {
        let directory = try ArchiveTestDirectory(), controller = NSDocumentController.shared
        for name in ["x.7z.001", "x.tar.gz.001", "x.zip.001", "x.7z.003", "x.z01", "x.ZX02"] {
            let url = directory.url.appendingPathComponent(name)
            try Data().write(to: url)
            let values = try url.resourceValues(forKeys: [.contentTypeKey])
            let systemType = try XCTUnwrap(values.contentType?.identifier, name)
            let systemClass = controller.documentClass(forType: systemType)
            let type = try controller.typeForContents(of: url)
            // .z01 は既存の ZIP 型への準拠で開ける。.ZX02 も環境で宣言済みなら置き換えない。
            if systemClass == ArchiveDocument.self {
                XCTAssertEqual(type, systemType, name)
                XCTAssertNotEqual(type, ArchiveDocumentController.splitVolumeType, name)
            } else {
                XCTAssertNil(systemClass, "\(name): \(systemType)")
                XCTAssertEqual(type, ArchiveDocumentController.splitVolumeType, name)
            }
            XCTAssertTrue(controller.documentClass(forType: type) == ArchiveDocument.self, name)
        }
        for (name, type) in [("a.zip", "public.zip-archive"), ("a.7z", "org.7-zip.7-zip-archive")] {
            let url = directory.url.appendingPathComponent(name)
            try Data().write(to: url)
            XCTAssertEqual(try controller.typeForContents(of: url), type)
        }
        let notes = directory.url.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: notes)
        XCTAssertNotEqual(try controller.typeForContents(of: notes), ArchiveDocumentController.splitVolumeType)
        XCTAssertTrue(controller.documentClass(forType: ArchiveDocumentController.splitVolumeType) == ArchiveDocument.self)
    }

    func testOpenableNamesUseKaitoKitParsingWithoutTreatingOrdinaryZIPAsSplit() {
        for name in ["a.7z.001", "a.tar.gz.003", "a.zip.0001", "a.1000", "a.z01", "a.Z99", "a.zx01", "a.Zx02"] {
            XCTAssertTrue(ArchiveSplitVolume.isOpenableName(name), name)
        }
        for name in ["notes.txt", "a.zip", "a.zipx", "a.000", "a.01", "a.００１", "a.z00", "a.z1", "a.zx1", ".001"] {
            XCTAssertFalse(ArchiveSplitVolume.isOpenableName(name), name)
        }
    }

    func testNumberedGateResolutionPreservesWidthAndFallsBackAfterWidthOverflow() throws {
        let directory = try ArchiveTestDirectory()
        for name in ["a.7z.001", "wide.tar.0001", "wide.tar.001", "overflow.zip.001"] {
            try Data().write(to: directory.url.appendingPathComponent(name))
        }
        for (member, gate) in [("a.7z.003", "a.7z.001"), ("a.7z.001", "a.7z.001"),
                               ("wide.tar.0003", "wide.tar.0001"), ("overflow.zip.1000", "overflow.zip.001"),
                               ("missing.tar.002", "missing.tar.002"), ("ordinary.zip", "ordinary.zip")] {
            XCTAssertEqual(ArchiveSplitVolume.gateURL(for: directory.url.appendingPathComponent(member)),
                           directory.url.appendingPathComponent(gate), member)
        }
        let gate = directory.url.appendingPathComponent("linked.tar.001")
        try FileManager.default.createSymbolicLink(atPath: gate.path, withDestinationPath: "missing")
        XCTAssertEqual(ArchiveSplitVolume.gateURL(for: directory.url.appendingPathComponent("linked.tar.002")), gate,
                       "入口の存在確認は symlink を辿らない lstat を使う")
    }

    func testNativeZIPGateResolutionAcceptsBothCasesAndLeavesMissingGateAlone() throws {
        let directory = try ArchiveTestDirectory()
        for (member, final) in [("lower.z01", "lower.zip"), ("upper.Z02", "upper.ZIP"),
                                ("other.z01", "other.ZIP"), ("alternate.Z01", "alternate.zip"),
                                ("extended.zx02", "extended.ZIPX"), ("upperx.ZX01", "upperx.zipx")] {
            let gate = directory.url.appendingPathComponent(final), bytes = Data(final.utf8)
            try bytes.write(to: gate)
            let resolved = ArchiveSplitVolume.gateURL(for: directory.url.appendingPathComponent(member))
            XCTAssertEqual(resolved.deletingPathExtension(), gate.deletingPathExtension())
            XCTAssertEqual(resolved.pathExtension.lowercased(), gate.pathExtension.lowercased())
            // 大小文字を区別しないボリュームでも、実際に最終巻へ到達したことを確かめる。
            XCTAssertEqual(try Data(contentsOf: resolved), bytes)
        }
        for name in ["missing.z01", "missing.zx02"] {
            let url = directory.url.appendingPathComponent(name)
            XCTAssertEqual(ArchiveSplitVolume.gateURL(for: url), url)
        }
    }

    @MainActor func testThreeVolumeSevenZipOpensAsReadOnlyArchiveDocument() async throws {
        let fixture = try SplitArchiveFixture(volumeCount: 3)
        XCTAssertEqual(fixture.volumes.count, 3)
        let (document, alreadyOpen) = try await open(fixture.archive, in: fixture.directory)
        XCTAssertFalse(alreadyOpen)
        XCTAssertEqual(document.fileURL, fixture.archive)
        XCTAssertEqual(document.fileType, ArchiveDocumentController.splitVolumeType)
        try await assertSplitContents(document, names: Set(fixture.contents.keys))
    }

    @MainActor func testLaterSevenZipVolumeReusesGateDocumentAndRecordsGateInRecents() async throws {
        let fixture = try SplitArchiveFixture(volumeCount: 3), later = fixture.volumes[2]
        let (document, alreadyOpen) = try await open(later, in: fixture.directory)
        XCTAssertFalse(alreadyOpen)
        XCTAssertEqual(document.fileURL, fixture.archive)
        try await assertSplitContents(document, names: Set(fixture.contents.keys))
        for url in [later, fixture.archive] {
            let (reopened, wasOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false)
            XCTAssertTrue(reopened === document)
            XCTAssertTrue(wasOpen)
        }
        // 履歴は /var と /private/var などを解決して保持するため、同じ実体の URL で比較する。
        let recentURLs = NSDocumentController.shared.recentDocumentURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL }
        XCTAssertTrue(recentURLs.contains(fixture.archive.resolvingSymlinksInPath().standardizedFileURL))
        XCTAssertFalse(recentURLs.contains(later.resolvingSymlinksInPath().standardizedFileURL))
    }

    @MainActor func testPlainTarHeaderAlignedSecondVolumeOpensWholeSetAndReusesDocument() async throws {
        // 各項目は header を含めて 10240 byte。第二巻だけでも最後の一項目として読める境界を選ぶ。
        let fixture = try SplitArchiveFixture(.tar, chunkSize: 30720)
        XCTAssertEqual(fixture.volumes.count, 2)
        let later = fixture.volumes[1], reader = try ArchiveReader.open(url: later)
        XCTAssertEqual(reader.entries.map(\.name), ["file3.txt"])
        let (document, _) = try await open(later, in: fixture.directory)
        XCTAssertEqual(document.fileURL, fixture.archive)
        try await assertSplitContents(document, names: Set(fixture.contents.keys))
        for url in [later, fixture.archive] {
            let (reopened, wasOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false)
            XCTAssertTrue(reopened === document)
            XCTAssertTrue(wasOpen)
        }
    }

    @MainActor func testNativeSplitZIPMemberOpensFinalZIPAndReusesDocument() async throws {
        // Python がない環境は ScenarioFixture のコマンド境界で XCTSkip になる。
        // ローカル header を第一巻、central directory と EOCD を最終巻に置く。
        let fixture = try ScenarioFixture(script: #"""
        with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_STORED) as z:
            z.writestr('note.txt', b'native split contents')
        with open(p, 'rb') as f:
            data = bytearray(f.read())
        end = data.rfind(b'PK\x05\x06')
        central = struct.unpack_from('<I', data, end + 16)[0]
        assert data[central:central + 4] == b'PK\x01\x02'
        struct.pack_into('<I', data, central + 42, 4)
        struct.pack_into('<HH', data, end + 4, 1, 1)
        struct.pack_into('<I', data, end + 16, 0)
        with open(os.path.splitext(p)[0] + '.z01', 'wb') as f:
            f.write(b'PK\x07\x08' + data[:central])
        with open(p, 'wb') as f:
            f.write(data[central:])
        """#)
        let member = fixture.archive.deletingPathExtension().appendingPathExtension("z01")
        let memberType = try NSDocumentController.shared.typeForContents(of: member)
        XCTAssertNotEqual(memberType, ArchiveDocumentController.splitVolumeType)
        XCTAssertTrue(NSDocumentController.shared.documentClass(forType: memberType) == ArchiveDocument.self)
        let (document, alreadyOpen) = try await open(member, in: fixture.directory)
        XCTAssertFalse(alreadyOpen)
        XCTAssertEqual(document.fileURL, fixture.archive)
        try await assertSplitContents(document, names: ["note.txt"], refusal: .nativeSplitArchive)
        XCTAssertEqual(try ScenarioFixture.contents(fixture.archive), ["note.txt": Data("native split contents".utf8)])
        for url in [member, fixture.archive] {
            let (reopened, wasOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false)
            XCTAssertTrue(reopened === document)
            XCTAssertTrue(wasOpen)
        }
    }

    @MainActor func testPanelDelegateRetainsNameFilterAndValidatesSelectedArchives() throws {
        let directory = try ArchiveTestDirectory(), panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        ArchiveOpenPanelDelegate.install(on: panel, bundle: Bundle(for: ArchiveDocument.self))
        XCTAssertTrue(panel.allowedContentTypes.isEmpty)
        let delegate = try XCTUnwrap(panel.delegate as? ArchiveOpenPanelDelegate)
        for name in ["x.7z.001", "x.tar.gz.003", "x.zip.001", "x.z01", "x.ZX02", "a.zip", "a.7z", "notes.txt"] {
            let url = directory.url.appendingPathComponent(name)
            try Data().write(to: url)
            XCTAssertEqual(delegate.panel(panel, shouldEnable: url), name != "notes.txt", name)
            if name == "notes.txt" {
                XCTAssertThrowsError(try delegate.panel(panel, validate: url)) { error in
                    XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
                    XCTAssertEqual((error as NSError).code, NSFileReadUnknownError)
                }
            } else {
                XCTAssertNoThrow(try delegate.panel(panel, validate: url), name)
            }
        }
        XCTAssertTrue(delegate.panel(panel, shouldEnable: directory.url))
        XCTAssertThrowsError(try delegate.panel(panel, validate: directory.url))
        let remote = try XCTUnwrap(URL(string: "https://example.com/archive.001"))
        XCTAssertFalse(delegate.panel(panel, shouldEnable: remote))
        XCTAssertThrowsError(try delegate.panel(panel, validate: remote))
    }

    @MainActor private func open(_ url: URL, in directory: ArchiveTestDirectory) async throws -> (ArchiveDocument, Bool) {
        let (opened, alreadyOpen) = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: false)
        addTeardownBlock { @MainActor in
            opened.close()
            if let document = opened as? ArchiveDocument {
                await document.undoCleanup?.value
                await document.materializationCleanup?.value
                await document.sessionCleanup?.value
            }
            withExtendedLifetime(directory) {}
        }
        return (try XCTUnwrap(opened as? ArchiveDocument), alreadyOpen)
    }

    @MainActor private func assertSplitContents(_ document: ArchiveDocument, names: Set<String>,
                                                refusal: ArchiveCapabilities.Refusal = .splitArchive,
                                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let session = try XCTUnwrap(document.session, file: file, line: line)
        let entries = await session.entries()
        XCTAssertEqual(Set(entries.map(\.name)), names, file: file, line: line)
        XCTAssertFalse(session.capabilities.canEdit, file: file, line: line)
        XCTAssertNil(session.capabilities.mode, file: file, line: line)
        XCTAssertEqual(session.capabilities.refusal, refusal, file: file, line: line)
        let reason = refusal == .nativeSplitArchive
            ? String(localized: "ZIP本来の分割アーカイブは変更できません。")
            : String(localized: "分割アーカイブは、設定で「保存時にまとめて書き込む」を選ぶと編集できます。")
        XCTAssertEqual(session.capabilities.readOnlyReason, reason, file: file, line: line)
    }
}
