import Darwin
import Foundation
import GyoshukuKit
import KaitoKit

nonisolated struct ArchiveImportResult: Sendable {
    let addedPaths: [String]
    let failures: [ArchiveImportPlan.Failure]
    var reloadFailure: String?
}

/// session の actor 内だけで実行する。書庫の原本へ書くのは最後の rename 一回だけ。
nonisolated enum ArchiveImportTransaction {
    // phase hook は同じ worker 上で呼び、取消し・障害の境界を XCTest で再現する。
    static func run(plan: ArchiveImportPlan, archive: URL, progress: Progress,
                    didProcess: (@Sendable (Int) throws -> Void)? = nil,
                    willPublish: (@Sendable () throws -> Void)? = nil) throws -> ArchiveImportResult {
        guard plan.failures.isEmpty, !plan.items.isEmpty else {
            return ArchiveImportResult(addedPaths: [], failures: plan.failures)
        }
        try ArchiveImportPlan.checkCancellation(progress)
        let original = try identity(archive)
        let directory = archive.deletingLastPathComponent().appendingPathComponent(".KaitoFinder-add-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = directory.appendingPathComponent("archive.zip")
        try FileManager.default.copyItem(at: archive, to: work)
        let updater = try ArchiveUpdater.open(url: work)
        progress.totalUnitCount = Int64(plan.items.count + 1)
        progress.completedUnitCount = 0
        for (index, item) in plan.items.enumerated() {
            try ArchiveImportPlan.checkCancellation(progress)
            // add(contentsOf:) のディレクトリ再帰は使わず、一項目ごとに取消しを確認する。
            do {
                if item.isDirectory { try updater.addDirectory(item.path) }
                else { try updater.add(contentsOf: item.url, as: item.path) }
            }
            catch { throw ExtractionFailure.refused("\(item.path): \(error)") }
            progress.completedUnitCount += 1
            try didProcess?(index)
        }
        try ArchiveImportPlan.checkCancellation(progress)
        // commit の属性復元が失敗しても、変わるのは作業コピーだけ。
        try updater.commit()
        _ = try ArchiveReader.open(url: work)
        try willPublish?()
        try ArchiveImportPlan.checkCancellation(progress)
        guard try identity(archive) == original else {
            throw ExtractionFailure.refused("処理中に書庫が別の操作で変更されました")
        }
        // copyItem と updater が保持した属性も含め、同一ボリュームで一括公開する。
        // ここが取消しの境界。成功後に取消しとして返してはならない。
        guard rename(work.path, archive.path) == 0 else { throw ExtractionFailure.system(errno) }
        progress.completedUnitCount += 1
        return ArchiveImportResult(addedPaths: plan.items.map(\.path), failures: [])
    }

    private static func identity(_ url: URL) throws -> [Int64] {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ExtractionFailure.refused("書庫の原本を確認できません")
        }
        return [Int64(info.st_dev), Int64(bitPattern: info.st_ino), info.st_size, Int64(info.st_mode),
                Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }
}
