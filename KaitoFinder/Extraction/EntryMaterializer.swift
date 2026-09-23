import Foundation
import Darwin
import KaitoKit

/// ファイル属性だけでなく、一時コピーの出自を文書の再オープンにも引き継ぐ。
nonisolated enum ArchiveTemporaryCopy {
    private static let attribute = "com.shunnag.KaitoFinder.temporaryCopy"

    static func mark(descriptor: Int32) throws {
        var value: UInt8 = 1
        guard fsetxattr(descriptor, attribute, &value, 1, 0, 0) == 0 else {
            throw ExtractionFailure.system(errno)
        }
    }

    static func contains(_ url: URL) -> Bool {
        var value: UInt8 = 0
        return getxattr(url.path, attribute, &value, 1, 0, XATTR_NOFOLLOW) == 1 && value == 1
    }
}

/// 文書ごとに一つ所有する。公開したコピーも文書の終了時に回収する。
actor EntryMaterializer {
    private let session: ArchiveSession
    private let temporaryDirectory: ExtractionTemporaryDirectory
    private var documentDirectory: URL?
    private var closed = false

    init(session: ArchiveSession, temporaryDirectory: ExtractionTemporaryDirectory = ExtractionTemporaryDirectory()) {
        self.session = session
        self.temporaryDirectory = temporaryDirectory
    }

    func materialize(_ payload: ArchiveEntryPayload, progress: Progress,
                     didWrite: (@Sendable (Int) -> Void)? = nil) async throws -> URL {
        if closed || progress.isCancelled || Task.isCancelled { throw CancellationError() }
        if documentDirectory == nil { documentDirectory = try temporaryDirectory.create() }
        return try await Self.extract(payload, session: session, documentDirectory: documentDirectory!,
                                      progress: progress, didWrite: didWrite)
    }

    @concurrent private static func extract(_ payload: ArchiveEntryPayload, session: ArchiveSession,
                                            documentDirectory: URL, progress: Progress,
                                            didWrite: (@Sendable (Int) -> Void)?) async throws -> URL {
        let entries: [KaitoKit.ArchiveEntry]
        if session.usesPendingReading {
            guard let snapshot = session.pendingReadSnapshot else { throw ArchiveEntryPayload.staleSelection }
            entries = try snapshot.resolve(payload)
        } else {
            let snapshot = await session.snapshot()
            entries = try payload.resolve(in: snapshot.entries, generation: snapshot.generation)
        }
        let capability = EntryReadCapability(entry: entries.first, isDirectory: payload.isDirectory, format: session.format)
        if let refusal = capability.refusal { throw refusal }
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
                throw ExtractionFailure.refused(String(localized: "単一ファイルを展開できませんでした"))
            }
            return written.url
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// controller が要求を drain してから呼ぶ。大きな木の削除も UI actor では行わない。
    func close() async {
        closed = true
        guard let directory = documentDirectory else { return }
        documentDirectory = nil
        await Self.removeDocumentDirectory(directory)
    }

    @concurrent private static func removeDocumentDirectory(_ directory: URL) async {
        do {
            try ExtractionTemporaryDirectory(root: directory).sweepOnLaunch()
            try FileManager.default.removeItem(at: directory)
        } catch { NSLog("文書の一時コピーを削除できません: %@", String(describing: error)) }
    }

    /// main actor に戻る直前の取消しでも、公開されなかった完成ファイルを回収する。
    @concurrent static func discard(_ url: URL) async {
        do { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        catch { NSLog("一時コピーを削除できません: %@", String(describing: error)) }
    }
}
