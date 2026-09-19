import AppKit
import Darwin
import Foundation
import KaitoKit

nonisolated struct ArchiveBatchPlan: Sendable {
    struct Item: Sendable {
        let archive: URL
        let destinationFolder: URL
    }

    static func destinationFolder(for archive: URL, base: URL, policy: ArchivePreferences.FolderPolicy,
                                  topLevelNames: Set<String>, exists: (URL) -> Bool) -> URL {
        guard !topLevelNames.isEmpty,
              policy == .always || (policy == .whenMultipleTopLevelItems && topLevelNames.count > 1) else {
            return base
        }
        let stem = ArchiveCreationPlan.archiveStem(for: archive)
        var candidate = base.appendingPathComponent(stem, isDirectory: true)
        var suffix = 2
        while exists(candidate) {
            candidate = base.appendingPathComponent("\(stem) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}

/// 文書やパネルを作らず、アーカイブ単位で認証・展開・結果を閉じる。
@MainActor final class ArchiveBatchExtractor {
    struct Failure: Sendable {
        let archive: URL
        let reason: String
    }

    struct Report: Sendable {
        // ゴミ箱への移動に失敗した場合も、展開自体が完了したアーカイブを含む。
        let extracted: [URL]
        let failures: [Failure]
        let cancelled: Bool
    }

    private let preferences: ArchivePreferences
    private let passwordPrompt: @MainActor (URL, ArchivePasswordChallenge) async throws -> String
    private let rememberedPassword: @Sendable (URL) async -> String?
    private let trash: @Sendable (URL) throws -> Void
    private let reveal: @Sendable ([URL]) -> Void
    private let currentArchive: @MainActor (URL?) -> Void

    init(preferences: ArchivePreferences,
         passwordPrompt: @escaping @MainActor (URL, ArchivePasswordChallenge) async throws -> String,
         rememberedPassword: @escaping @Sendable (URL) async -> String? = { _ in nil },
         trash: @escaping @Sendable (URL) throws -> Void = {
             try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
         },
         reveal: @escaping @Sendable ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
         currentArchive: @escaping @MainActor (URL?) -> Void = { _ in }) {
        self.preferences = preferences
        self.passwordPrompt = passwordPrompt
        self.rememberedPassword = rememberedPassword
        self.trash = trash
        self.reveal = reveal
        self.currentArchive = currentArchive
    }

    func run(archives: [URL], base: URL?, progress: Progress) async -> Report {
        progress.totalUnitCount = Int64(archives.count)
        progress.completedUnitCount = 0
        let operation = Task { await extractArchives(archives, base: base, progress: progress) }
        // Progressの取消しを、入力待ちと認証中のTaskにも届ける。
        let cancellation = Task {
            while !Task.isCancelled {
                if progress.isCancelled { operation.cancel(); return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { cancellation.cancel() }
        return await withTaskCancellationHandler {
            await operation.value
        } onCancel: {
            progress.cancel()
            operation.cancel()
        }
    }

    private func extractArchives(_ archives: [URL], base: URL?, progress: Progress) async -> Report {
        var extracted: [URL] = []
        var failures: [Failure] = []
        var revealedItems: [URL] = []
        defer { currentArchive(nil) }
        for archive in archives {
            if progress.isCancelled || Task.isCancelled { break }
            currentArchive(archive)
            let child = Progress(totalUnitCount: 1)
            progress.addChild(child, withPendingUnitCount: 1)
            defer {
                if !progress.isCancelled && !Task.isCancelled {
                    child.totalUnitCount = max(1, child.totalUnitCount)
                    child.completedUnitCount = child.totalUnitCount
                }
            }
            var session: ArchiveSession?
            var createdFolder: URL?
            var written: [ExtractionResult.WrittenItem] = []
            do {
                let stored = await rememberedPassword(archive)
                try Self.checkCancellation(progress)
                let opened = try await openSession(archive, password: stored, progress: progress)
                session = opened
                let prompt = passwordPrompt
                opened.setPasswordPrompt { challenge in
                    try Self.checkCancellation(progress)
                    let password = try await prompt(archive, challenge)
                    try Self.checkCancellation(progress)
                    return password
                }
                let snapshot = await opened.snapshot()
                let root = EntryNode.tree(from: snapshot.entries)
                let parent = base ?? archive.deletingLastPathComponent()
                guard parent.isFileURL else {
                    throw ExtractionFailure.refused(String(localized: "出力先はfile URLが必要です。"))
                }
                let item = ArchiveBatchPlan.Item(archive: archive, destinationFolder:
                    ArchiveBatchPlan.destinationFolder(for: archive, base: parent, policy: preferences.folderPolicy,
                        topLevelNames: Set(root.children.map(\.name)), exists: Self.exists))
                try Self.checkCancellation(progress)
                if item.destinationFolder != parent {
                    try await Self.createFolder(item.destinationFolder)
                    createdFolder = item.destinationFolder
                }
                let payloads = ArchiveEntryPayload.payloads(for: root.children, archiveURL: item.archive,
                                                           generation: snapshot.generation)
                let result = try await ExtractionService.extract(payloads, from: opened, to: item.destinationFolder,
                                                                 progress: child)
                written = result.written
                if result.cancelled { throw CancellationError() }
                try Self.checkCancellation(progress)
                try ArchiveCopyOut.check(result)
                await opened.close()
                try Self.checkCancellation(progress)
                session = nil
                // 成功した出力だけを一度に表示する。ゴミ箱への移動失敗でも出力は残っている。
                if let createdFolder { revealedItems.append(createdFolder) }
                else {
                    revealedItems.append(contentsOf: root.children.map {
                        item.destinationFolder.appendingPathComponent($0.name, isDirectory: $0.isDirectory)
                    })
                }
                createdFolder = nil
                written.removeAll()
                extracted.append(archive)
                if preferences.trashesArchiveAfterExtraction {
                    try Self.checkCancellation(progress)
                    try await Self.trashArchive(archive, expectedIdentity: opened.sourceIdentity, using: trash)
                }
            } catch {
                await session?.close()
                var cleanupReason: String?
                if error is CancellationError || progress.isCancelled || Task.isCancelled {
                    // 成功を確定する前なら、サービスの終了直後の取消しでも今回の出力を回収する。
                    cleanupReason = await Self.removeCancelledOutput(written)
                }
                if let createdFolder { await Self.removeEmptyFolder(createdFolder) }
                if progress.isCancelled || Task.isCancelled {
                    if let cleanupReason { failures.append(Failure(archive: archive, reason: cleanupReason)) }
                    break
                }
                var reason = error is CancellationError ? String(localized: "キャンセル") : ArchiveErrorText.describe(error)
                if let cleanupReason { reason += "\n" + cleanupReason }
                failures.append(Failure(archive: archive, reason: reason))
            }
        }
        if preferences.revealsExtractedItemsInFinder && !revealedItems.isEmpty {
            reveal(revealedItems)
        }
        return Report(extracted: extracted, failures: failures, cancelled: progress.isCancelled || Task.isCancelled)
    }

    private func openSession(_ archive: URL, password: String?, progress: Progress) async throws -> ArchiveSession {
        var candidate = password
        while true {
            try Self.checkCancellation(progress)
            do { return try await Self.openArchive(archive, password: candidate) }
            catch {
                try Self.checkCancellation(progress)
                guard let challenge = ArchivePasswordChallenge(error) else { throw error }
                candidate = try await passwordPrompt(archive, challenge)
            }
        }
    }

    nonisolated private static func checkCancellation(_ progress: Progress) throws {
        if progress.isCancelled || Task.isCancelled { throw CancellationError() }
    }

    @concurrent private static func openArchive(_ archive: URL, password: String?) async throws -> ArchiveSession {
        try Task.checkCancellation()
        // Servicesから渡されたフォルダも一項目の失敗として残し、後続の展開を続ける。
        guard try archive.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else {
            throw ExtractionFailure.refused(String(localized: "対応していないフォーマットです。"))
        }
        do { return try ArchiveSession(url: archive, password: password) }
        catch KaitoError.unsupportedFormat {
            throw ExtractionFailure.refused(String(localized: "対応していないフォーマットです。"))
        }
    }

    nonisolated private static func exists(_ url: URL) -> Bool {
        // 切れたリンクも予約済みの名前として扱う。
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    @concurrent private static func createFolder(_ url: URL) async throws {
        try Task.checkCancellation()
        // 確認後の競合でも既存フォルダを自分の作成物として回収しない。
        guard mkdir(url.path, 0o755) == 0 else { throw ExtractionFailure.system(errno) }
    }

    @concurrent private static func trashArchive(_ url: URL, expectedIdentity: [Int64],
                                                using trash: @Sendable (URL) throws -> Void) async throws {
        try Task.checkCancellation()
        guard try ArchiveImportTransaction.identity(url) == expectedIdentity else {
            throw ExtractionFailure.refused(String(localized: "展開中にアーカイブが変更されたため、ゴミ箱に入れませんでした。"))
        }
        try trash(url)
    }

    @concurrent private static func removeEmptyFolder(_ url: URL) async {
        // 再帰削除を避け、正常に展開できた項目や既存の出力を残す。
        _ = rmdir(url.path)
    }

    @concurrent private static func removeCancelledOutput(_ written: [ExtractionResult.WrittenItem]) async -> String? {
        let items = Dictionary(written.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first }).values
            .sorted { $0.url.pathComponents.count < $1.url.pathComponents.count }
        var reasons: [String] = []
        // 親から属性を戻す。アーカイブが指定した読み取り専用フォルダも回収できる。
        for item in items {
            let url = item.url
            var info = stat()
            if lstat(url.path, &info) == 0, item.matches(info), info.st_mode & S_IFMT == S_IFDIR,
               fchmodat(AT_FDCWD, url.path, 0o700, AT_SYMLINK_NOFOLLOW) != 0 {
                reasons.append(ExtractionFailure.system(errno).description)
            }
        }
        for item in items.reversed() {
            let url = item.url
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno != ENOENT { reasons.append(ExtractionFailure.system(errno).description) }
                continue
            }
            // 途中の親が差し替わっていても、展開時と異なる inode は削除しない。
            guard item.matches(info) else { continue }
            let status = info.st_mode & S_IFMT == S_IFDIR ? rmdir(url.path) : unlink(url.path)
            if status != 0, errno != ENOENT { reasons.append(ExtractionFailure.system(errno).description) }
        }
        guard !reasons.isEmpty else { return nil }
        return String(localized: "キャンセルしたアーカイブの出力を削除できませんでした: \(ArchiveFailureReport.describe(reasons, name: { _ in "" }, reason: { $0 }))。")
    }
}
