import Darwin
import Foundation
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveImportSourceStampTests: XCTestCase {
    private func file(in directory: ArchiveTestDirectory, name: String = "source.xlsx") throws -> URL {
        let url = directory.url.appendingPathComponent(name)
        try Data("original".utf8).write(to: url)
        return url
    }

    private func attributes(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
        return info
    }

    private func setModificationTime(_ url: URL, seconds: Int, nanoseconds: Int) throws {
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: seconds, tv_nsec: nanoseconds)]
        guard utimensat(AT_FDCWD, url.path, &times, 0) == 0 else { throw ExtractionFailure.system(errno) }
    }

    private func assertRefuses(_ stamp: ArchiveImportSourceStamp, descriptor: Int32,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try stamp.verify(), file: file, line: line)
        XCTAssertThrowsError(try stamp.verify(descriptor: descriptor), file: file, line: line)
    }

    func testXattrOnlyChangeAllowsPathAndDescriptorVerification() throws {
        let directory = try ArchiveTestDirectory(), url = try file(in: directory)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let stamp = try ArchiveImportSourceStamp(url), before = try attributes(url)
        XCTAssertNil(stamp.hardLinkIdentity)

        XCTAssertEqual(setxattr(url.path, "com.example.test", "x", 1, 0, XATTR_NOFOLLOW), 0)

        let after = try attributes(url)
        XCTAssertNotEqual([before.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec],
                          [after.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec])
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_mode, after.st_mode)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
        XCTAssertEqual(try ArchiveImportSourceStamp(url), stamp)
        XCTAssertNoThrow(try stamp.verify())
        XCTAssertNoThrow(try stamp.verify(descriptor: handle.fileDescriptor))
    }

    func testHardLinkIdentityStillUsesDeviceAndInode() throws {
        let directory = try ArchiveTestDirectory(), url = try file(in: directory)
        let alias = directory.url.appendingPathComponent("alias.xlsx")
        XCTAssertEqual(link(url.path, alias.path), 0)
        let stamp = try ArchiveImportSourceStamp(url), info = try attributes(url)
        XCTAssertEqual(stamp.hardLinkIdentity, [Int64(info.st_dev), Int64(bitPattern: info.st_ino)])
        XCTAssertEqual(try ArchiveImportSourceStamp(alias).hardLinkIdentity, stamp.hardLinkIdentity)
        XCTAssertEqual(setxattr(alias.path, "com.example.test", "x", 1, 0, XATTR_NOFOLLOW), 0)
        XCTAssertEqual(try ArchiveImportSourceStamp(url).hardLinkIdentity, stamp.hardLinkIdentity)
        XCTAssertNoThrow(try stamp.verify())
    }

    func testSizeChangeIsRefusedEvenWithOriginalMtime() throws {
        let directory = try ArchiveTestDirectory(), url = try file(in: directory)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let stamp = try ArchiveImportSourceStamp(url), before = try attributes(url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try setModificationTime(url, seconds: before.st_mtimespec.tv_sec, nanoseconds: before.st_mtimespec.tv_nsec)
        let after = try attributes(url)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertNotEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        assertRefuses(stamp, descriptor: handle.fileDescriptor)
    }

    func testSameSizeContentWriteIsRefused() throws {
        let directory = try ArchiveTestDirectory(), url = try file(in: directory)
        try setModificationTime(url, seconds: 1_700_000_000, nanoseconds: 123_456_789)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let stamp = try ArchiveImportSourceStamp(url), before = try attributes(url)
        try handle.write(contentsOf: Data("modified".utf8))
        let after = try attributes(url)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertNotEqual(try Data(contentsOf: url), Data("original".utf8))
        assertRefuses(stamp, descriptor: handle.fileDescriptor)
    }

    func testMtimeSecondsAndNanosecondsChangesAreRefused() throws {
        let directory = try ArchiveTestDirectory(), url = try file(in: directory)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        for (seconds, nanoseconds) in [(1_700_000_001, 123_456_789), (1_700_000_000, 123_456_790)] {
            try setModificationTime(url, seconds: 1_700_000_000, nanoseconds: 123_456_789)
            let stamp = try ArchiveImportSourceStamp(url), before = try attributes(url)
            try setModificationTime(url, seconds: seconds, nanoseconds: nanoseconds)
            let after = try attributes(url)
            XCTAssertEqual(before.st_ino, after.st_ino)
            XCTAssertEqual(before.st_size, after.st_size)
            XCTAssertEqual(after.st_mtimespec.tv_sec, seconds)
            XCTAssertEqual(after.st_mtimespec.tv_nsec, nanoseconds)
            XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
            assertRefuses(stamp, descriptor: handle.fileDescriptor)
        }
    }

    func testReplacementInodeIsRefusedEvenWithOriginalContentAndMtime() throws {
        let directory = try ArchiveTestDirectory(), url = try file(in: directory)
        let original = try FileHandle(forReadingFrom: url)
        defer { try? original.close() }
        let stamp = try ArchiveImportSourceStamp(url), before = try attributes(url)
        let replacement = try file(in: directory, name: "replacement.xlsx")
        XCTAssertEqual(chmod(replacement.path, before.st_mode & 0o7777), 0)
        try setModificationTime(replacement, seconds: before.st_mtimespec.tv_sec, nanoseconds: before.st_mtimespec.tv_nsec)
        XCTAssertEqual(rename(replacement.path, url.path), 0)
        let after = try attributes(url), handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        XCTAssertNotEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(before.st_mode, after.st_mode)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
        assertRefuses(stamp, descriptor: handle.fileDescriptor)
        XCTAssertNoThrow(try stamp.verify(descriptor: original.fileDescriptor))
    }

    func testModeChangeIsStillRefused() throws {
        let directory = try ArchiveTestDirectory(), url = try file(in: directory)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let stamp = try ArchiveImportSourceStamp(url), before = try attributes(url)
        XCTAssertEqual(chmod(url.path, (before.st_mode & 0o7777) ^ 0o100), 0)
        assertRefuses(stamp, descriptor: handle.fileDescriptor)
    }
}
