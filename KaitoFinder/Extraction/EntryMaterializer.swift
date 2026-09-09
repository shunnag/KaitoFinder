import Foundation

/// 文書ごとに一つ所有する。一時コピーは外部アプリのため次回起動の sweep まで保持する。
actor EntryMaterializer {
    private let session: ArchiveSession
    private let temporaryDirectory: ExtractionTemporaryDirectory
    private var documentDirectory: URL?

    init(session: ArchiveSession, temporaryDirectory: ExtractionTemporaryDirectory = ExtractionTemporaryDirectory()) {
        self.session = session
        self.temporaryDirectory = temporaryDirectory
    }

    func materialize(_ payload: ArchiveEntryPayload, progress: Progress,
                     didWrite: (@Sendable (Int) -> Void)? = nil) async throws -> URL {
        if progress.isCancelled || Task.isCancelled { throw CancellationError() }
        if documentDirectory == nil { documentDirectory = try temporaryDirectory.create() }
        return try await Self.extract(payload, session: session, documentDirectory: documentDirectory!,
                                      progress: progress, didWrite: didWrite)
    }

    @concurrent private static func extract(_ payload: ArchiveEntryPayload, session: ArchiveSession,
                                            documentDirectory: URL, progress: Progress,
                                            didWrite: (@Sendable (Int) -> Void)?) async throws -> URL {
        let snapshot = await session.snapshot()
        let entries = try payload.resolve(in: snapshot.entries, generation: snapshot.generation)
        let capability = EntryReadCapability(entry: entries.first, isDirectory: payload.isDirectory, format: session.format)
        if let reason = capability.reason { throw ExtractionFailure.refused(reason) }
        let leaf = try ExtractionPath.components(payload.path).last!
        // 同名 entry と取消し直後の再要求は別の領域に置き、古い worker の掃除と競合させない。
        let directory = try ExtractionTemporaryDirectory(root: documentDirectory).create()
        let url = directory.appendingPathComponent(leaf)
        do {
            let result = try await ExtractionService.extract([payload], from: session, to: url,
                progress: progress, promisedItem: payload, readOnly: true, didWrite: didWrite)
            try ArchiveCopyOut.check(result)
            if progress.isCancelled || Task.isCancelled { throw CancellationError() }
            guard result.written.count == 1, let written = result.written.first else {
                throw ExtractionFailure.refused("単一ファイルを取り出せませんでした")
            }
            return written.url
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// main actor に戻る直前の取消しでも、公開されなかった完成ファイルを回収する。
    @concurrent static func discard(_ url: URL) async {
        do { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        catch { NSLog("一時コピーを削除できません: %@", String(describing: error)) }
    }
}
