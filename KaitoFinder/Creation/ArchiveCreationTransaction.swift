import Darwin
import Foundation
import GyoshukuKit
import KaitoKit

/// 原本を更新する publish とは別の境界。最後の rename が成功するまで保存先に触れない。
nonisolated enum ArchiveCreationTransaction {
    static func run(plan: ArchiveCreationPlan, progress: Progress,
                    willPublish: (@Sendable () throws -> Void)? = nil) throws -> URL {
        let imported = try ArchiveImportPlan.build(urls: plan.sources, folder: "",
                                                  existing: plan.existing?.entries ?? [], progress: progress,
                                                  options: plan.importOptions)
        guard imported.failures.isEmpty else {
            throw ExtractionFailure.refused(imported.failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n"))
        }
        try ArchiveImportPlan.checkCancellation(progress)
        guard plan.destination.isFileURL, !plan.destination.path.contains("\0") else {
            throw WriterError.invalidPath(plan.destination.absoluteString)
        }
        if let existing = plan.existing, isSameFile(existing.url, plan.destination) {
            throw ExtractionFailure.refused(String(localized: "元のアーカイブとは別の保存先を選んでください。"))
        }
        progress.totalUnitCount = Int64(imported.items.count + (plan.existing?.entries.count ?? 0) + 1)
        progress.completedUnitCount = 0
        let directory = plan.destination.deletingLastPathComponent()
            .appendingPathComponent(".KaitoFinder-new-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        // KaitoKit は gzip の中身が tar かどうかを名前でも判定する。仮出力にも本当の拡張子を付ける。
        let output = directory.appendingPathComponent("archive." + ArchiveCreationPlan.filenameExtension(for: plan.format))
        do {
            if let existing = plan.existing {
                let rewriter = try ArchiveRewriter.open(url: existing.url, password: existing.password,
                                                        output: output, format: plan.format, options: plan.options)
                try add(imported.items, progress: progress, directory: rewriter.addDirectory,
                        file: rewriter.add(contentsOf:as:))
                try ArchiveImportPlan.checkCancellation(progress)
                try rewriter.commit { _, _ in
                    progress.completedUnitCount += 1
                    try ArchiveImportPlan.checkCancellation(progress)
                }
            } else {
                let writer = try ArchiveWriter.create(url: output, format: plan.format, options: plan.options)
                try add(imported.items, progress: progress, directory: writer.addDirectory,
                        file: writer.add(contentsOf:as:))
                try ArchiveImportPlan.checkCancellation(progress)
                try writer.finish()
            }
        } catch RewriterError.password {
            // RewriterError は二種類の認証失敗をまとめる。入力した鍵の有無から UI の型へ戻す。
            throw plan.existing?.password == nil ? KaitoError.passwordRequired : KaitoError.wrongPassword
        }
        var quarantine: Data?
        for source in plan.sources + (plan.existing.map { [$0.url] } ?? []) {
            try ArchiveImportPlan.checkCancellation(progress)
            let value = try ExtractionQuarantine.read(from: source)
            if quarantine == nil { quarantine = value }
        }
        try ExtractionQuarantine.apply(quarantine, to: output)
        _ = try ArchiveReader.open(url: output, options: ReaderOptions(password: plan.options.password))
        try willPublish?()
        try ArchiveImportPlan.checkCancellation(progress)
        guard rename(output.path, plan.destination.path) == 0 else { throw ExtractionFailure.system(errno) }
        // rewriter が省く root directory record も含め、公開後は必ず完了を示す。
        progress.completedUnitCount = progress.totalUnitCount
        return plan.destination
    }

    private static func isSameFile(_ source: URL, _ destination: URL) -> Bool {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        if source == destination { return true }
        // 大文字・小文字だけが違う名前や hard link でも、原本を保存先にはしない。
        var original = stat(), output = stat()
        return lstat(source.path, &original) == 0 && lstat(destination.path, &output) == 0
            && original.st_dev == output.st_dev && original.st_ino == output.st_ino
    }

    private static func add(_ items: [ArchiveImportPlan.Item], progress: Progress,
                            directory: (String) throws -> Void, file: (URL, String) throws -> Void) throws {
        for item in items {
            try ArchiveImportPlan.checkCancellation(progress)
            // writer の再帰追加を使わず、ディレクトリも一項目ずつ扱う。
            do {
                if item.isDirectory { try directory(item.path) }
                else { try file(item.url, item.path) }
            } catch is CancellationError { throw CancellationError() }
            catch let error as RewriterError { throw error }
            catch { throw ExtractionFailure.refused("\(item.path): \(error)") }
            progress.completedUnitCount += 1
        }
    }
}
