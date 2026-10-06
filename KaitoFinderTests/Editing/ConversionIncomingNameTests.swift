import AppKit
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ConversionIncomingNameTests: XCTestCase {
    func testUndecidedFormatRestoresFilesystemLeavesAndNormalizesNFC() throws {
        for (path, expected) in [("tar/x\\y", "x\\y"), ("a:b", "a:b"), ("dir/é", "é"), ("dir/e\u{301}", "é")] {
            let leaf = try XCTUnwrap(ArchiveIncomingFiles.restoredLeaf(originalPath: path, format: nil))
            XCTAssertEqual(Array(leaf.utf8), Array(expected.utf8))
        }
        XCTAssertNil(try ArchiveIncomingFiles.restoredLeaf(originalPath: "", format: nil))
        for path in ["..", ".", "a\u{0}"] {
            XCTAssertThrowsError(try ArchiveIncomingFiles.restoredLeaf(originalPath: path, format: nil)) { error in
                XCTAssertEqual(ArchiveErrorText.describe(error), String(localized: "安全でない追加先パスです: \(path)。"))
            }
        }
    }

    func testKnownFormatKeepsExistingZIPRefusals() throws {
        for name in ["x\\y", "a:b"] {
            XCTAssertThrowsError(try ArchiveIncomingFiles.restoredLeaf(originalPath: "tar/" + name, format: .zip)) { error in
                XCTAssertEqual(ArchiveErrorText.describe(error), String(localized: "安全でない追加先パスです: \(name)。"))
            }
            XCTAssertEqual(try ArchiveIncomingFiles.restoredLeaf(originalPath: "tar/" + name, format: .tar), name)
        }
        XCTAssertEqual(try ArchiveIncomingFiles.restoredLeaf(originalPath: "dir/plain.txt", format: .zip), "plain.txt")
    }

    @MainActor private func assertConversion(format: GyoshukuKit.ArchiveFormat) async throws {
        let directory = try ArchiveTestDirectory(), defaults = try ArchivePreferencesTestDefaults()
        let creator = ArchiveCreationController(store: ArchivePreferencesStore(defaults: defaults.defaults))
        let tarBzip2 = directory.url.appendingPathComponent("original.tar.bz2")
        try Data("original content".utf8).write(to: directory.url.appendingPathComponent("old.txt"))
        try directory.run(ExternalTool.tar, ["--no-mac-metadata", "--no-xattrs", "-cjf", tarBzip2.path, "old.txt"])
        // ArchiveCreationTests の変換 fixture を、編集非対応の外側の圧縮で包む。
        let archive = directory.url.appendingPathComponent("original.tar.zst")
        try directory.run(ExternalTool.python3, ["-c", "import bz2, struct, sys; raw=bz2.decompress(open(sys.argv[1], 'rb').read()); open(sys.argv[2], 'wb').write(bytes.fromhex('28b52ffda0') + struct.pack('<I',len(raw)) + struct.pack('<I',(len(raw)<<3)|1)[:3] + raw)", tarBzip2.path, archive.path])
        let original = try Data(contentsOf: archive), session = try ArchiveSession(url: archive)
        XCTAssertFalse(session.capabilities.canEdit)
        let existing = try await ArchiveCreationController.existingArchive(from: session, progress: Progress())
        let names = ["x\\y", "a:b"]
        let sources = try names.map { name in
            let url = directory.url.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            return url
        }
        let destination = directory.url.appendingPathComponent("converted." + ArchiveCreationPlan.filenameExtension(for: format))
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.url.path))
        var choseFormat = false
        creator.destinationHandler = { save, _ in
            choseFormat = true
            save.formatPopup.selectItem(at: try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: format)))
            save.changeFormat(save.formatPopup)
            XCTAssertEqual(save.controller.format, format)
            XCTAssertNil(save.splitControls)
            return destination
        }
        defer {
            for document in NSDocumentController.shared.documents where document.fileURL == destination { document.close() }
        }
        if format == .tar {
            try await creator.createAndOpen(sources: sources, existing: existing)
            try await scenarioWait { NSDocumentController.shared.documents.contains { $0.fileURL == destination } }
            let reader = try ArchiveReader.open(url: destination)
            XCTAssertEqual(Set(reader.entries.map { Data($0.name.utf8) }), Set((["old.txt"] + names).map { Data($0.utf8) }))
            for entry in reader.entries {
                XCTAssertEqual(try reader.read(entry), Data((entry.name == "old.txt" ? "original content" : entry.name).utf8))
            }
        } else {
            do {
                try await creator.createAndOpen(sources: sources, existing: existing)
                XCTFail("ZIP must reject both incoming leaves after the format choice")
            } catch {
                guard case ExtractionFailure.refused = error else { return XCTFail("Unexpected error: \(error)") }
                let reason = ArchiveErrorText.describe(error)
                for name in names { XCTAssertTrue(reason.contains(String(localized: "安全でない追加先パスです: \(name)。")), reason) }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.url.path)), before)
        }
        XCTAssertTrue(choseFormat)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).contains { $0.hasPrefix(".KaitoFinder-new-") })
        XCTAssertEqual(try Data(contentsOf: archive), original)
    }

    @MainActor func testReadOnlyConversionAcceptsBothLeavesAfterChoosingTar() async throws { try await assertConversion(format: .tar) }
    @MainActor func testReadOnlyConversionRefusesBothLeavesAfterChoosingZIPWithoutPublishing() async throws { try await assertConversion(format: .zip) }
}
