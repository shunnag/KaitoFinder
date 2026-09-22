import Darwin
import Foundation
import GyoshukuKit
import XCTest
@testable import KaitoFinder

/// 内容を持つ五巻のセット。外部コマンドに依存せず、途中の巻だけの変更を再現する。
nonisolated struct SplitArchiveFixture: Sendable {
    let directory: ArchiveTestDirectory
    let volumes: [URL]
    let contents: [String: Data]
    var archive: URL { volumes[0] }
    var nextVolume: URL { archive.deletingPathExtension().appendingPathExtension("006") }

    init(_ format: GyoshukuKit.ArchiveFormat = .sevenZip) throws {
        directory = try ArchiveTestDirectory()
        let whole = directory.url.appendingPathComponent("archive." + ArchiveCreationPlan.filenameExtension(for: format))
        let writer = try ArchiveWriter.create(url: whole, format: format)
        var seed: UInt64 = 0x12345678
        var files: [String: Data] = [:]
        for index in 0..<4 {
            let data = Data((0..<9728).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                return UInt8(truncatingIfNeeded: seed >> 32)
            })
            let name = "file\(index).txt"
            files[name] = data
            try writer.add(data: data, as: name)
        }
        try writer.finish()
        contents = files
        let bytes = try Data(contentsOf: whole), chunkSize = (bytes.count + 4) / 5
        var parts: [URL] = []
        for offset in stride(from: 0, to: bytes.count, by: chunkSize) {
            let volume = whole.appendingPathExtension(String(format: "%03d", parts.count + 1))
            try bytes.subdata(in: offset..<min(offset + chunkSize, bytes.count)).write(to: volume)
            parts.append(volume)
        }
        volumes = parts
        XCTAssertEqual(volumes.count, 5)
        try FileManager.default.removeItem(at: whole)
    }

    static func touch(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
        let times = [timeval(tv_sec: info.st_atimespec.tv_sec, tv_usec: 0),
                     timeval(tv_sec: info.st_mtimespec.tv_sec + 60, tv_usec: 0)]
        guard times.withUnsafeBufferPointer({ utimes(url.path, $0.baseAddress) }) == 0 else {
            throw ExtractionFailure.system(errno)
        }
    }

    static func changeByte(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let byte = try XCTUnwrap(try handle.read(upToCount: 1)?.first)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data([byte ^ 0xff]))
        try touch(url)
    }

    static func replace(_ url: URL) throws {
        try Data(contentsOf: url).write(to: url, options: .atomic)
    }
}
