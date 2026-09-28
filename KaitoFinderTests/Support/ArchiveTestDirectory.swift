import Foundation
import XCTest

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

    /// fixture の中を作業ディレクトリにし、`LC_ALL=C` と fixture 専用の `TMPDIR` で `tool` を実行する。
    @discardableResult func run(_ tool: String, _ arguments: [String], allowed: [Int32] = [0]) throws -> String {
        try Self.run(tool, arguments, in: url, environment: ["LC_ALL": "C", "TMPDIR": temporary.path], allowed: allowed)
    }

    /// `directory` を作業ディレクトリにして `tool` を実行し、標準出力と標準エラーをまとめて返す。
    /// `environment` はテストプロセスの環境へ上書きで足す。ツールがなければ XCTSkip にし、
    /// 終了状態が `allowed` になければ出力をメッセージに失敗を記録して投げる。
    @discardableResult static func run(_ tool: String, _ arguments: [String], in directory: URL,
                                       environment: [String: String] = [:], allowed: [Int32] = [0]) throws -> String {
        try ExternalTool.require(tool)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
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

/// fixture を作る外部ツールの path。Homebrew のツール（7zz・xz・zstd）は Apple silicon の既定の prefix
/// （/opt/homebrew）にある前提で、それ以外は macOS 付属のもの。別の場所に入れた環境ではここだけを変える。
/// `ArchiveTestDirectory.run` は実行できないツールを要求したテストを XCTSkip にする。
nonisolated enum ExternalTool {
    static let python3 = "/usr/bin/python3"
    static let zip = "/usr/bin/zip"
    static let unzip = "/usr/bin/unzip"
    static let ditto = "/usr/bin/ditto"
    static let bsdtar = "/usr/bin/bsdtar"
    static let tar = "/usr/bin/tar"
    static let gzip = "/usr/bin/gzip"
    static let bzip2 = "/usr/bin/bzip2"
    static let touch = "/usr/bin/touch"
    static let chmod = "/bin/chmod"
    static let hdiutil = "/usr/bin/hdiutil"
    static let sevenZip = "/opt/homebrew/bin/7zz"
    static let xz = "/opt/homebrew/bin/xz"
    static let zstd = "/opt/homebrew/bin/zstd"

    /// `tool` を実行できない環境では、テストを失敗ではなく XCTSkip にする。
    static func require(_ tool: String) throws {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw XCTSkip("Required fixture tool is unavailable: \(tool)")
        }
    }
}
