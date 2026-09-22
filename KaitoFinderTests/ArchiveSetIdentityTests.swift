import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveSetIdentityTests: XCTestCase {
    private func layout(_ lengths: [UInt64], scheme: ArchiveVolumeSet.Scheme = .numbered(stem: "archive.7z", width: 3),
                        openedIndex: Int = 0) -> ArchiveVolumeLayout {
        let parent = URL(fileURLWithPath: "/archive-layout", isDirectory: true)
        return ArchiveVolumeLayout(scheme: scheme, volumes: lengths.enumerated().map { index, length in
            .init(url: parent.appendingPathComponent(scheme.fileName(forVolumeAt: index, count: lengths.count)), length: length)
        }, openedVolumeIndex: openedIndex)
    }

    func testUniformAndUnevenSchedules() {
        XCTAssertEqual(layout([10, 10, 10, 3]).schedule, .uniform(size: 10))
        XCTAssertEqual(layout([10, 10, 10, 10]).schedule, .uniform(size: 10))
        XCTAssertEqual(layout([50, 10, 10]).schedule, .uneven([50, 10, 10]))
        XCTAssertEqual(layout([10, 20, 10]).schedule, .uneven([10, 20, 10]))
        XCTAssertEqual(layout([10, 10, 11]).schedule, .uneven([10, 10, 11]))
        XCTAssertEqual(layout([10, 10, 0]).schedule, .uneven([10, 10, 0]))
        XCTAssertEqual(layout([0, 0]).schedule, .uneven([0, 0]))
    }

    func testNumberedNamesKeepWidthAndOverflowAfter999() {
        let ordinary = layout([10, 10, 3])
        XCTAssertEqual(ordinary.gateURL, ordinary.volumes[0].url)
        XCTAssertEqual(ordinary.nextVolumeName, "archive.7z.004")
        let overflow = layout(Array(repeating: 10, count: 999))
        XCTAssertEqual(overflow.volumes.last?.url.lastPathComponent, "archive.7z.999")
        XCTAssertEqual(overflow.nextVolumeName, "archive.7z.1000")
        XCTAssertEqual(overflow.fileName(forVolumeAt: 1000, count: 1001), "archive.7z.1001")
        XCTAssertEqual(layout([10, 3], scheme: .numbered(stem: "a.tar", width: 4)).nextVolumeName, "a.tar.0003")
    }

    func testZIPGateOpenedIndexAndNextNumberedName() {
        for (prefix, last) in [("z", "zip"), ("ZX", "ZIPX")] {
            let split = layout([10, 10, 3], scheme: .zipSpanned(stem: "a", volumePrefix: prefix, lastExtension: last),
                               openedIndex: 1)
            XCTAssertEqual(split.openedVolumeIndex, 1)
            XCTAssertEqual(split.gateURL.lastPathComponent, "a." + last)
            XCTAssertEqual(split.nextVolumeName, "a." + prefix + "03")
            XCTAssertEqual(split.fileName(forVolumeAt: 2, count: 4), "a." + prefix + "03")
            XCTAssertEqual(split.fileName(forVolumeAt: 3, count: 4), "a." + last)
            let overflow = layout(Array(repeating: 10, count: 100),
                                  scheme: .zipSpanned(stem: "a", volumePrefix: prefix, lastExtension: last))
            XCTAssertEqual(overflow.nextVolumeName, "a." + prefix + "100")
        }
        let mixed = ArchiveVolumeLayout(scheme: .zipSpanned(stem: "a", volumePrefix: "Z", lastExtension: "ZIP"),
            volumes: ["a.Z01", "a.z02", "a.ZIP"].map { .init(url: URL(fileURLWithPath: "/" + $0), length: 10) },
            openedVolumeIndex: 2)
        XCTAssertEqual(mixed.fileName(forVolumeAt: 1, count: 4), "a.z02")
        XCTAssertEqual(mixed.fileName(forVolumeAt: 1, count: 2), "a.ZIP")
        XCTAssertEqual(mixed.nextVolumeName, "a.Z03")
    }

    func testReaderSnapshotMatchesDiskAndLayoutPreservesAssembly() throws {
        let fixture = try SplitArchiveFixture(), reader = try ArchiveReader.open(url: fixture.archive)
        let set = try XCTUnwrap(reader.volumeSet), layout = ArchiveVolumeLayout(volumeSet: set)
        XCTAssertEqual(layout.scheme, set.scheme)
        XCTAssertEqual(layout.volumes.map(\.url), fixture.volumes)
        XCTAssertEqual(layout.volumes.map(\.length), set.volumes.map(\.length))
        XCTAssertEqual(layout.gateURL, set.volumes[set.gateIndex].url)
        XCTAssertEqual(layout.openedVolumeIndex, set.openedVolumeIndex)
        for index in 0...set.volumes.count {
            XCTAssertEqual(layout.fileName(forVolumeAt: index, count: 7), set.fileName(forVolumeAt: index, count: 7))
        }
        XCTAssertEqual(try ArchiveSetIdentity.capture(layout: layout), ArchiveSetIdentity(volumeSet: set))
    }

    func testIdentityUsesParentVolumeUUIDAndIgnoresOnlyModeForUndo() throws {
        let directory = try ArchiveTestDirectory(), url = directory.url.appendingPathComponent("archive.zip")
        try Data("archive bytes".utf8).write(to: url)
        let before = try ArchiveSetIdentity.capture(url: url)
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        let uuid = try? directory.url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        XCTAssertEqual(before.volumes[0].volumeUUID, uuid ?? String(UInt32(bitPattern: info.st_dev)))
        XCTAssertEqual(before.volumes[0].fileName, "archive.zip")
        XCTAssertEqual(before.volumes[0].inode, info.st_ino)
        XCTAssertEqual(before.volumes[0].size, UInt64(info.st_size))
        XCTAssertNil(before.nextVolumeName)
        XCTAssertEqual(chmod(url.path, (info.st_mode & 0o777) ^ 0o100), 0)
        let changedMode = try ArchiveSetIdentity.capture(url: url)
        XCTAssertNotEqual(before, changedMode)
        XCTAssertTrue(before.contentEquals(changedMode))
        XCTAssertTrue(changedMode.contentEquals(before))
        try SplitArchiveFixture.touch(url)
        XCTAssertFalse(before.contentEquals(try ArchiveSetIdentity.capture(url: url)))
        let alias = directory.url.appendingPathComponent("alias.zip")
        XCTAssertEqual(link(url.path, alias.path), 0)
        XCTAssertFalse(try ArchiveSetIdentity.capture(url: url).contentEquals(ArchiveSetIdentity.capture(url: alias)))
    }

    private func assertIdentityRefusal(_ body: () throws -> ArchiveSetIdentity,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case ExtractionFailure.refused(let reason) = error else {
                return XCTFail("Expected identity refusal: \(error)", file: file, line: line)
            }
            XCTAssertEqual(reason, String(localized: "アーカイブの原本を確認できません。"), file: file, line: line)
        }
    }

    func testCaptureRejectsMissingFilesDirectoriesAndSymlinks() throws {
        let directory = try ArchiveTestDirectory(), missing = directory.url.appendingPathComponent("missing")
        let link = directory.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        for url in [directory.url, missing, link] { assertIdentityRefusal { try ArchiveSetIdentity.capture(url: url) } }
        let fixture = try SplitArchiveFixture(), reader = try ArchiveReader.open(url: fixture.archive)
        let layout = ArchiveVolumeLayout(volumeSet: try XCTUnwrap(reader.volumeSet))
        let second = fixture.volumes[1]
        try FileManager.default.removeItem(at: second)
        assertIdentityRefusal { try ArchiveSetIdentity.capture(layout: layout) }
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        assertIdentityRefusal { try ArchiveSetIdentity.capture(layout: layout) }
        try FileManager.default.removeItem(at: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: fixture.volumes[0])
        assertIdentityRefusal { try ArchiveSetIdentity.capture(layout: layout) }
    }

    func testNextVolumeMustBeAbsentEvenWhenItIsADanglingSymlinkOrDirectory() throws {
        let fixture = try SplitArchiveFixture(), reader = try ArchiveReader.open(url: fixture.archive)
        let layout = ArchiveVolumeLayout(volumeSet: try XCTUnwrap(reader.volumeSet))
        XCTAssertEqual(layout.nextVolumeURL, fixture.nextVolume)
        for kind in 0..<3 {
            switch kind {
            case 0: try Data().write(to: fixture.nextVolume)
            case 1: try FileManager.default.createDirectory(at: fixture.nextVolume, withIntermediateDirectories: false)
            default: try FileManager.default.createSymbolicLink(atPath: fixture.nextVolume.path, withDestinationPath: "missing")
            }
            assertIdentityRefusal { try ArchiveSetIdentity.capture(layout: layout) }
            try FileManager.default.removeItem(at: fixture.nextVolume)
        }
    }

    func testSingleByteChangeInThirdVolumeRefusesSessionExtraction() async throws {
        for format in [GyoshukuKit.ArchiveFormat.sevenZip, .tar] {
            let fixture = try SplitArchiveFixture(format), session = try ArchiveSession(url: fixture.archive)
            let before = await session.sourceIdentity
            try SplitArchiveFixture.changeByte(fixture.volumes[2])
            let after = try ArchiveSetIdentity.capture(layout: XCTUnwrap(session.volumeLayout))
            XCTAssertEqual(before.volumes[2].size, after.volumes[2].size)
            XCTAssertEqual(before.volumes[2].inode, after.volumes[2].inode)
            XCTAssertNotEqual(before, after)
            do { _ = try await session.extractionSnapshot(); XCTFail("Changed third volume must invalidate the reader") }
            catch { XCTAssertEqual(error as? ArchiveEditError, .archiveChanged) }
            await session.close()
        }
    }

    func testReplacementOfSecondVolumeAndAppearanceOfSixthVolumeRefuseSessionExtraction() async throws {
        for replacesVolume in [true, false] {
            let fixture = try SplitArchiveFixture(), session = try ArchiveSession(url: fixture.archive)
            let before = await session.sourceIdentity
            if replacesVolume {
                try SplitArchiveFixture.replace(fixture.volumes[1])
                let after = try ArchiveSetIdentity.capture(layout: XCTUnwrap(session.volumeLayout))
                XCTAssertNotEqual(before.volumes[1].inode, after.volumes[1].inode)
            } else {
                try Data().write(to: fixture.nextVolume)
            }
            do { _ = try await session.extractionSnapshot(); XCTFail("Changed set must invalidate the reader") }
            catch { XCTAssertEqual(error as? ArchiveEditError, .archiveChanged) }
            await session.close()
        }
    }

    func testAssemblySnapshotDetectsVolumeReplacementBeforeDiskCapture() throws {
        let fixture = try SplitArchiveFixture(), reader = try ArchiveReader.open(url: fixture.archive)
        let set = try XCTUnwrap(reader.volumeSet), assembled = ArchiveSetIdentity(volumeSet: set)
        try SplitArchiveFixture.replace(fixture.volumes[1])
        let captured = try ArchiveSetIdentity.capture(layout: ArchiveVolumeLayout(volumeSet: set))
        XCTAssertNotEqual(assembled, captured, "Session open must refuse this mismatch even with identical bytes")
        XCTAssertFalse(assembled.contentEquals(captured))
        XCTAssertEqual(ArchiveSetIdentity(volumeSet: try XCTUnwrap(reader.reopen().volumeSet)), assembled)
    }

    func testReloadRecapturesWholeSetAndQuarantineComesFromFirstMarkedVolume() async throws {
        let fixture = try SplitArchiveFixture(.tar)
        for volume in fixture.volumes { try ExtractionQuarantine.apply(nil, to: volume) }
        let expected = Data("0081;12345678;SecondVolume;".utf8)
        try ExtractionQuarantine.apply(expected, to: fixture.volumes[1])
        try ExtractionQuarantine.apply(Data("0081;87654321;LaterVolume;".utf8), to: fixture.volumes[2])
        let session = try ArchiveSession(url: fixture.archive)
        let quarantine = await session.quarantine
        XCTAssertEqual(quarantine, expected)
        let output = fixture.directory.url.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let result = try await ExtractionService.extract(ExtractionSelection(entries: await session.entries()),
                                                          from: session, to: output)
        XCTAssertTrue(result.failures.isEmpty)
        for (name, data) in fixture.contents {
            let extracted = output.appendingPathComponent(name)
            XCTAssertEqual(try Data(contentsOf: extracted), data)
            XCTAssertEqual(try ExtractionQuarantine.read(from: extracted), expected)
        }
        try SplitArchiveFixture.touch(fixture.volumes[2])
        try await session.reloadAfterMutation()
        let identity = await session.sourceIdentity
        XCTAssertEqual(identity, try ArchiveSetIdentity.capture(layout: XCTUnwrap(session.volumeLayout)))
        XCTAssertEqual(session.capabilities.refusal, .splitArchive)
        let reloadedQuarantine = await session.quarantine
        XCTAssertEqual(reloadedQuarantine, expected)
        _ = try await session.extractionSnapshot()
        await session.close()
    }

    func testAppLaunchRaisesDescriptorBudgetAndRepeatedAdjustmentNeverLowersIt() {
        var before = rlimit(), after = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &before), 0)
        XCTAssertGreaterThanOrEqual(before.rlim_cur, min(before.rlim_max, rlim_t(10240)))
        AppDelegate.raiseFileDescriptorLimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &after), 0)
        XCTAssertGreaterThanOrEqual(after.rlim_cur, before.rlim_cur)
        XCTAssertEqual(after.rlim_max, before.rlim_max)
    }
}
