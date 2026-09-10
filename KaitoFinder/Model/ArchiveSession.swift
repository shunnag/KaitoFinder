import Foundation
import KaitoKit
import Synchronization

/// スレッドセーフではない reader を所有し、値型の一覧だけを外へ渡す。
actor ArchiveSession {
    private var reader: ArchiveReader
    private var invalidated = false
    nonisolated private let capabilitiesStorage: Mutex<ArchiveCapabilities>
    nonisolated var capabilities: ArchiveCapabilities { capabilitiesStorage.withLock { $0 } }
    nonisolated private let generationStorage = Mutex<UInt64>(0)
    nonisolated var generation: UInt64 { generationStorage.withLock { $0 } }
    nonisolated let sourceURL: URL
    nonisolated let format: ArchiveFormat
    private(set) var quarantine: Data?

    init(url: URL) throws {
        sourceURL = url
        quarantine = try ExtractionQuarantine.read(from: url)
        reader = try ArchiveReader.open(url: url)
        format = reader.format
        capabilitiesStorage = Mutex(ArchiveCapabilities.inspect(url: url, format: reader.format))
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

    // 追加と fresh open は await を挟まず直列化し、promise の解決を割り込ませない。
    func append(urls: [URL], to folder: String, progress: Progress,
                didProcess: (@Sendable (Int) throws -> Void)? = nil,
                willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveImportResult {
        try requireCurrentReader()
        guard capabilities.canAppend else {
            throw ExtractionFailure.refused(capabilities.readOnlyReason ?? "この書庫は変更できません")
        }
        let plan = try ArchiveImportPlan.build(urls: urls, folder: folder, existing: reader.entries, progress: progress)
        var result = try ArchiveImportTransaction.run(plan: plan, archive: sourceURL, progress: progress,
                                                     didProcess: didProcess, willPublish: willPublish)
        if !result.addedPaths.isEmpty {
            // 公開済みの書き込みと表示の失敗を区別し、旧 byte に戻ったとは報告しない。
            do { try reloadAfterMutation() }
            catch { result.reloadFailure = String(describing: error) }
        }
        return result
    }

    // atomic replace 後はこの入口で reader と世代を一緒に更新する。
    // reopen() は旧 inode を保持するので、URL から開き直す。
    func reloadAfterMutation() throws {
        // 変更済みなら再オープンの失敗時も世代を進め、旧 reader への要求を拒否する。
        generationStorage.withLock { $0 += 1 }
        invalidated = true
        capabilitiesStorage.withLock { $0 = ArchiveCapabilities(refusal: .unavailable("変更後の書庫を読み直せませんでした")) }
        let replacement = try ArchiveReader.open(url: sourceURL)
        let updatedQuarantine = try ExtractionQuarantine.read(from: sourceURL)
        reader = replacement
        quarantine = updatedQuarantine
        let updatedCapabilities = ArchiveCapabilities.inspect(url: sourceURL, format: format)
        capabilitiesStorage.withLock { $0 = updatedCapabilities }
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
