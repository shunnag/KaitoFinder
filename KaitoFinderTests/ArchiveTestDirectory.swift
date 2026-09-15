import Foundation
import AppKit
import CryptoKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

/// 原本だけでなく、外部ツールの相対パスと一時ファイルも fixture 内に閉じ込める。
nonisolated final class ArchiveTestDirectory: Sendable {
    let url: URL
    private let temporary: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("KaitoFinder-Test-" + UUID().uuidString)
        temporary = url.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    private enum Failure: Error { case commandFailed(Int32) }

    @discardableResult func run(_ tool: String, _ arguments: [String], allowed: [Int32] = [0]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw XCTSkip("Required fixture tool is unavailable: \(tool)")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = url
        process.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C", "TMPDIR": temporary.path]) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(allowed.contains(process.terminationStatus), text)
        // 生成失敗後の壊れた fixture を使って、二次的な失敗を積み重ねない。
        guard allowed.contains(process.terminationStatus) else { throw Failure.commandFailed(process.terminationStatus) }
        return text
    }
}

/// シーンごとの入力・出力を隔離し、外部コーパスを使わず実際の書庫を作る。
nonisolated final class ScenarioFixture {
    let directory: ArchiveTestDirectory
    let archive: URL
    var root: URL { directory.url }

    init(script: String = "with zipfile.ZipFile(p, 'w') as z: z.writestr('original.txt', b'original')",
         suffix: String = "zip") throws {
        directory = try ArchiveTestDirectory()
        archive = directory.url.appendingPathComponent("archive." + suffix)
        try Self.python(directory, archive: archive, script: script)
    }

    private static func python(_ directory: ArchiveTestDirectory, archive: URL, script: String) throws {
        try directory.run("/usr/bin/python3", ["-c",
            "import sys, zipfile, tarfile, io, stat, struct, os\np = sys.argv[1]\n" + script, archive.path])
    }

    func pythonArchive(_ name: String, script: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Self.python(directory, archive: url, script: script)
        return url
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ name: String, bytes: Data = Data("added".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    static func digest(_ url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }

    static func contents(_ url: URL) throws -> [String: Data] {
        let reader = try ArchiveReader.open(url: url)
        var result: [String: Data] = [:]
        for entry in reader.entries where entry.kind == .file {
            var bytes = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
            result[entry.name] = bytes
        }
        return result
    }

    static func files(under root: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        return try enumerator.compactMap { item in
            guard let url = item as? URL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url
        }
    }

    func extract(to destination: URL, session: ArchiveSession? = nil) async throws -> ExtractionResult {
        let source = try session ?? ArchiveSession(url: archive)
        return try await ExtractionService.extract(ExtractionSelection(entries: await source.entries()), from: source, to: destination)
    }
}

/// 固定 sleep に頼らず、最初の実書き込みを止めて競合する操作を再現する。
nonisolated final class ScenarioGate: Sendable {
    private let entered = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)
    var isEntered: Bool { entered.withLock { $0 } }
    func pauseOnce() {
        let first = entered.withLock { value in
            if value { return false }
            value = true
            return true
        }
        if first { XCTAssertEqual(semaphore.wait(timeout: .now() + 20), .success, "競合テストの解除待ちが時間切れ") }
    }
    func release() { semaphore.signal() }
}

extension XCTestCase {
    @MainActor func scenarioDocument(_ fixture: ScenarioFixture, url: URL? = nil) async throws
        -> (ArchiveDocument, ArchiveWindowController) {
        let document = ArchiveDocument(), source = url ?? fixture.archive
        try document.read(from: source, ofType: "public.zip-archive")
        document.fileURL = source
        let session = try XCTUnwrap(document.session)
        let controller = ArchiveWindowController()
        document.addWindowController(controller)
        controller.display(EntryNode.tree(from: await session.entries()), session: session,
                           materializationController: document.materializationController())
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            withExtendedLifetime(fixture) {}
        }
        return (document, controller)
    }

    @MainActor func scenarioWait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), "シーンの状態遷移が時間切れ", file: file, line: line)
        guard predicate() else { throw ScenarioTimeout.expired }
    }
}

private nonisolated enum ScenarioTimeout: Error { case expired }
