import CryptoKit
import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

/// テストが書庫の中身と byte 列を照合するときの基準。項目は本番の読み出し経路（ExtractionService.consume）で読む。
nonisolated enum ArchiveOracle {
    /// `contents` が内容を返す項目。
    enum Inclusion {
        /// 通常ファイルだけ。
        case files
        /// ディレクトリ以外（シンボリックリンクを含む）。
        case nonDirectories
        /// ディレクトリを含むすべての項目（ディレクトリは空の Data）。
        case all

        func includes(_ kind: EntryKind) -> Bool {
            switch self {
            case .files: kind == .file
            case .nonDirectories: kind != .directory
            case .all: true
            }
        }
    }

    /// `url` を `options` で開き、項目の内容を名前ごとに返す。`password` を渡すと `options.password` を置き換える。
    /// `options` の既定は KaitoKit の既定値（AppleDouble は merge）。本番と同じ読み方は `.kaitoFinder()` を渡す。
    static func contents(_ url: URL, password: String? = nil, options: ReaderOptions = ReaderOptions(),
                         including inclusion: Inclusion = .files) throws -> [String: Data] {
        var options = options
        if let password { options.password = password }
        return try contents(ArchiveReader.open(url: url, options: options), including: inclusion)
    }

    /// 開いている `reader` の項目の内容を名前ごとに返す。
    static func contents(_ reader: ArchiveReader, including inclusion: Inclusion = .files) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for entry in reader.entries where inclusion.includes(entry.kind) {
            var bytes = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
            result[entry.name] = bytes
        }
        return result
    }

    /// file 全体の SHA-256。1 MiB ずつ読むので、大きな書庫もメモリへ丸ごと載せない。
    static func digest(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return Data(digest.finalize())
    }

    /// `root` の直下に、取り込み・作成の作業領域（`WorkAreaName.add` / `.new`）と GyoshukuKit の作業 file
    /// （`.gyoshuku-`）が残っていないことを確かめる。
    static func assertNoWorkFiles(in root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { name in workFilePrefixes.contains { name.hasPrefix($0) } },
                       names.description, file: file, line: line)
    }

    /// GyoshukuKit は作業 file の接頭辞を公開していないので、それだけは文字列で持つ。
    private static let workFilePrefixes = [WorkAreaName.add, WorkAreaName.new, ".gyoshuku-"]

    /// 項目の種類を名前ごとに返す。同じ名前の項目が複数あればテストを失敗にする。
    static func inventory(_ url: URL) throws -> [String: EntryKind] {
        let entries = try ArchiveReader.open(url: url).entries
        XCTAssertEqual(Set(entries.map(\.name)).count, entries.count, "Duplicate archive paths")
        return entries.reduce(into: [:]) { $0[$1.name] = $1.kind }
    }
}
