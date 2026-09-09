import Foundation
import KaitoKit

/// スレッドセーフではない reader を所有し、値型の一覧だけを外へ渡す。
actor ArchiveSession {
    private let reader: ArchiveReader
    nonisolated let sourceURL: URL
    nonisolated let quarantine: Data?

    init(url: URL) throws {
        sourceURL = url
        quarantine = try ExtractionQuarantine.read(from: url)
        reader = try ArchiveReader.open(url: url)
    }

    func extractionReader() throws -> sending ArchiveReader {
        try reader.reopen()
    }

    func entries() -> [ArchiveEntry] {
        reader.entries
    }
}
