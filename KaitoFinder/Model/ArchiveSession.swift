import Foundation
import KaitoKit
import Synchronization

/// スレッドセーフではない reader を所有し、値型の一覧だけを外へ渡す。
actor ArchiveSession {
    private var reader: ArchiveReader
    private var invalidated = false
    nonisolated private let generationStorage = Mutex<UInt64>(0)
    nonisolated var generation: UInt64 { generationStorage.withLock { $0 } }
    nonisolated let sourceURL: URL
    private(set) var quarantine: Data?

    init(url: URL) throws {
        sourceURL = url
        quarantine = try ExtractionQuarantine.read(from: url)
        reader = try ArchiveReader.open(url: url)
    }

    func extractionReader() throws -> sending ArchiveReader {
        try requireCurrentReader()
        return try reader.reopen()
    }

    func extractionSnapshot() throws -> sending (reader: ArchiveReader, quarantine: Data?) {
        try requireCurrentReader()
        return (try reader.reopen(), quarantine)
    }

    private func requireCurrentReader() throws {
        guard !invalidated else { throw ExtractionFailure.refused("変更後の書庫を読み直せませんでした") }
    }

    // 将来の atomic replace 後はこの入口で reader と世代を一緒に更新する。
    // reopen() は旧 inode を保持するので、URL から開き直す。
    func reloadAfterMutation() throws {
        // 変更済みなら再オープンの失敗時も世代を進め、旧 reader への要求を拒否する。
        generationStorage.withLock { $0 += 1 }
        invalidated = true
        let replacement = try ArchiveReader.open(url: sourceURL)
        let updatedQuarantine = try ExtractionQuarantine.read(from: sourceURL)
        reader = replacement
        quarantine = updatedQuarantine
        invalidated = false
    }

    func snapshot() -> (entries: [ArchiveEntry], generation: UInt64) {
        (invalidated ? [] : reader.entries, generation)
    }

    // 解決と reopen の間に await を挟まず、同じ世代の reader と一覧を渡す。
    func resolveForExtraction(_ payloads: [ArchiveEntryPayload]) throws
        -> sending (reader: ArchiveReader, selection: ExtractionSelection, quarantine: Data?) {
        try requireCurrentReader()
        var selected: [Int: ArchiveEntry] = [:]
        for payload in payloads {
            guard payload.archiveURL == sourceURL else {
                throw ExtractionFailure.refused("選択した項目の書庫が一致しません")
            }
            for entry in try payload.resolve(in: reader.entries, generation: generation) {
                selected[entry.index] = entry
            }
        }
        return (try reader.reopen(), ExtractionSelection(entries: Array(selected.values)), quarantine)
    }

    func entries() -> [ArchiveEntry] {
        invalidated ? [] : reader.entries
    }
}
