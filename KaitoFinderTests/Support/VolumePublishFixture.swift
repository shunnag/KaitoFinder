import CryptoKit
import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

/// Foundation は解決後にも /private を省くことがある。NOFOLLOW の試験には POSIX の実パスを渡す。
nonisolated func volumePublishTestURL(_ url: URL) throws -> URL {
    guard let path = realpath(url.path, nil) else { throw VolumePublishError.system(errno) }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}

nonisolated final class VolumePublishTestDisk: Sendable {
    let directory: ArchiveTestDirectory
    let image: URL
    private let mountLocation: Mutex<URL>
    var mount: URL { mountLocation.withLock { $0 } }
    let fileSystem: String
    private let attached = Mutex(false)

    init(_ fileSystem: String) throws {
        directory = try ArchiveTestDirectory()
        let base = try volumePublishTestURL(directory.url)
        image = base.appendingPathComponent("volume.dmg")
        mountLocation = Mutex(base.appendingPathComponent("mount"))
        self.fileSystem = fileSystem
        try command(["create", "-size", "128m", "-fs", fileSystem, "-volname", "KFPUBLISH", image.path])
        try attach()
        do {
            if fileSystem == "APFS" || fileSystem == "HFS+" {
                let trash = mount.appendingPathComponent(".Trashes", isDirectory: true)
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                guard chmod(trash.path, 0o1777) == 0 else { throw VolumePublishError.system(errno) }
                try FileManager.default.createDirectory(at: trash.appendingPathComponent(String(geteuid())),
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch { try? detach(); throw error }
    }
    private func command(_ arguments: [String]) throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        do { try process.run() } catch { throw XCTSkip("hdiutil を起動できません: \(error)") }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("hdiutil \(arguments.first ?? "") を実行できません: \(String(decoding: bytes, as: UTF8.self))")
        }
    }
    func attach(at location: URL? = nil) throws {
        try attached.withLock { attached in
            let destination = location ?? mount
            try command(["attach", "-nobrowse", "-mountpoint", destination.path, image.path])
            mountLocation.withLock { $0 = destination }
            attached = true
        }
    }
    func detach() throws {
        try attached.withLock { attached in
            guard attached else { return }
            try command(["detach", "-force", mount.path])
            attached = false
        }
    }
    func disableTrash() throws {
        let url = mount.appendingPathComponent(".Trashes")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try Data("Trash deliberately unavailable in this test".utf8).write(to: url)
    }
    deinit { try? detach() }
}

nonisolated final class VolumePublishFixture: Sendable {
    let directory: ArchiveTestDirectory
    let root: URL
    let index: RecoverableWorkIndex
    let oldBytes: Data
    let newBytes: Data
    let oldParts: [Data]
    let layout: ArchiveVolumeLayout?
    let expected: ArchiveSetIdentity?
    let plan: VolumePlan
    let newContents: Data
    let scheme: ArchiveVolumeSet.Scheme
    let readerOptions: ReaderOptions
    var gate: URL { root.appendingPathComponent(scheme.fileName(forVolumeAt: 0, count: 1)) }

    init(parent: URL? = nil, oldCount: Int = 3, newCount: Int = 5, compressed: Bool = false, encrypted: Bool = false) throws {
        let stem = encrypted ? "archive.7z" : (compressed ? "archive.tar.gz" : "archive.tar")
        readerOptions = .kaitoFinder(password: encrypted ? "round2-secret" : nil)
        scheme = .numbered(stem: stem, width: 3)
        let directory = try ArchiveTestDirectory()
        self.directory = directory
        let base = try volumePublishTestURL(parent ?? directory.url)
        let rootURL = base.appendingPathComponent("publish-" + UUID().uuidString, isDirectory: true)
        root = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        index = RecoverableWorkIndex(fileURL: try volumePublishTestURL(directory.url).appendingPathComponent("support/index.json"))
        let source = directory.url.appendingPathComponent(stem)
        func archive(_ byte: UInt8) throws -> Data {
            try? FileManager.default.removeItem(at: source)
            let writer = try ArchiveWriter.create(url: source, format: encrypted ? .sevenZip : (compressed ? .tarGzip : .tar),
                options: WriterOptions(password: encrypted ? "round2-secret" : nil, encryptsSevenZipHeaders: encrypted))
            try writer.add(data: Data(repeating: byte, count: 24 * 1024), as: "payload.bin")
            try writer.finish()
            return try Data(contentsOf: source)
        }
        oldBytes = try archive(0x31)
        newBytes = try archive(0x79)
        newContents = Data(repeating: 0x79, count: 24 * 1024)
        plan = try VolumePlan(totalLength: UInt64(newBytes.count), schedule: .uniform(size: UInt64((newBytes.count + newCount - 1) / newCount)), scheme: scheme)
        var parts: [Data] = []
        if oldCount > 0 {
            let oldPlan = try VolumePlan(totalLength: UInt64(oldBytes.count),
                schedule: .uniform(size: UInt64((oldBytes.count + oldCount - 1) / oldCount)), scheme: scheme)
            for volume in oldPlan.volumes {
                let data = oldBytes.subdata(in: Int(volume.offset)..<Int(volume.offset + volume.length))
                try data.write(to: rootURL.appendingPathComponent(volume.name))
                parts.append(data)
            }
            let oldLayout = ArchiveVolumeLayout(scheme: scheme, volumes: oldPlan.volumes.map {
                .init(url: rootURL.appendingPathComponent($0.name), length: $0.length)
            }, openedVolumeIndex: 0)
            layout = oldLayout
            expected = try ArchiveSetIdentity.capture(layout: oldLayout)
        } else { layout = nil; expected = nil }
        oldParts = parts
    }

    func target(consent: Bool = false) -> VolumeSetTarget {
        if let layout, let expected {
            return VolumeSetTarget(parent: root, layout: layout, expected: expected,
                schedule: .uniform(size: plan.largestVolume), allowHazardousVolume: consent)
        }
        return VolumeSetTarget(parent: root, newSetScheme: scheme, schedule: .uniform(size: plan.largestVolume), allowHazardousVolume: consent)
    }

    func begin(consent: Bool = false, operations: VolumePublishOperations = .init(), fault: @escaping @Sendable (VolumePublishStep) throws -> Void = { _ in }) throws -> VolumeSetPublication {
        let publication = try VolumeSetPublication.begin(target(consent: consent), estimatedOutputLength: UInt64(newBytes.count),
                                                        index: index, options: readerOptions, operations: operations, fault: fault)
        try newBytes.write(to: publication.workURL)
        return publication
    }

    var steps: [VolumePublishStep] {
        [.s5, .s6] + oldParts.indices.dropFirst().map { .retiredVolume($0) } + [.s7]
            + plan.volumes.indices.dropFirst().map { .placedVolume($0) } + [.s8, .s9, .s10, .s11]
    }

    func assertNoOrphans(expectedCount: Int, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = Set((0..<expectedCount).map { scheme.fileName(forVolumeAt: $0, count: max(1, expectedCount)) })
        let actual = Set(try VolumePublishDirectory(root).names().filter {
            guard case .numbered(let stem, _) = scheme,
                  let parsed = ArchiveVolumeSet.parse(fileName: $0),
                  case .numbered(let foundStem, _) = parsed.scheme else { return false }
            return foundStem == stem
        })
        XCTAssertEqual(actual, expected, "Unexpected/orphan numbered volumes", file: file, line: line)
    }

    func assertOld(file: StaticString = #filePath, line: UInt = #line) throws {
        try assertNoOrphans(expectedCount: oldParts.count, file: file, line: line)
        for (i, bytes) in oldParts.enumerated() {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(scheme.fileName(forVolumeAt: i, count: oldParts.count))),
                           bytes, file: file, line: line)
        }
        XCTAssertNil(try VolumePublishDirectory(root).info(scheme.fileName(forVolumeAt: oldParts.count, count: oldParts.count + 1)), file: file, line: line)
    }

    func assertNew(file: StaticString = #filePath, line: UInt = #line) throws {
        try assertNoOrphans(expectedCount: plan.volumes.count, file: file, line: line)
        let reader = try ArchiveReader.open(url: gate)
        XCTAssertEqual(reader.volumeSet?.volumes.count ?? 1, plan.volumes.count, file: file, line: line)
        XCTAssertEqual(reader.entries.map(\.name), ["payload.bin"], file: file, line: line)
        XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), newContents, file: file, line: line)
        var joined = Data()
        for volume in plan.volumes {
            let data = try Data(contentsOf: root.appendingPathComponent(volume.name))
            XCTAssertEqual(UInt64(data.count), volume.length, file: file, line: line)
            joined.append(data)
        }
        XCTAssertEqual(joined, newBytes, file: file, line: line)
        XCTAssertNil(try VolumePublishDirectory(root).info(plan.nextVolumeName), file: file, line: line)
    }

    func assertGateIsComplete(allowAbsent: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let parent = try VolumePublishDirectory(root)
        if try parent.info(gate.lastPathComponent) == nil {
            XCTAssertTrue(allowAbsent || oldParts.isEmpty, file: file, line: line)
            if !allowAbsent { try assertNoOrphans(expectedCount: 0, file: file, line: line) }
            return
        }
        var bytes = Data()
        for i in 0...128 {
            let name = scheme.fileName(forVolumeAt: i, count: 129)
            guard try parent.info(name) != nil else { break }
            bytes.append(try Data(contentsOf: root.appendingPathComponent(name)))
        }
        if !allowAbsent { try assertNoOrphans(expectedCount: bytes == oldBytes ? oldParts.count : plan.volumes.count, file: file, line: line) }
        XCTAssertTrue(bytes == oldBytes || bytes == newBytes, "gate から新旧混在の byte が見えました", file: file, line: line)
    }

    func assertRemoved(_ staging: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), file: file, line: line)
        XCTAssertTrue(try index.entries().isEmpty, file: file, line: line)
        XCTAssertFalse(try VolumePublishDirectory(root).names().contains { $0.hasPrefix(VolumePublishFS.stagingPrefix) }, file: file, line: line)
    }

    static func snapshot(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let directory = try VolumePublishDirectory(root)
        for name in try directory.names() {
            let info = try XCTUnwrap(directory.info(name))
            if info.st_mode & S_IFMT == S_IFDIR {
                result[name + "/"] = Data()
                for (path, data) in try snapshot(root.appendingPathComponent(name)) { result[name + "/" + path] = data }
            } else if info.st_mode & S_IFMT == S_IFREG {
                result[name] = try Data(contentsOf: root.appendingPathComponent(name))
            } else { result[name] = Data("nonregular".utf8) }
        }
        return result
    }
}
