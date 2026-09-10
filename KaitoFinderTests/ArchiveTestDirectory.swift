import Foundation
import XCTest

/// 原本だけでなく、外部ツールの相対パスと一時ファイルも fixture 内に閉じ込める。
nonisolated final class ArchiveTestDirectory {
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
