import GyoshukuKit
import KaitoKit

/// 「フォルダ X へ移動する」の意味を一箇所で定義する。
/// 保存前モードでは同じ場所の選択も先に検証するため、mapSelection をスキップ判定より前に行う。
nonisolated enum ArchiveMovePlanning {
    static func build(_ selections: [ArchiveEditSelection], target: String, format: GyoshukuKit.ArchiveFormat,
                      mapSelection: (ArchiveEditSelection) throws -> ArchiveEditSelection,
                      info: (ArchiveEditSelection, String) throws -> ArchiveConflictItem) throws
        -> (moving: [ArchiveEditSelection], candidates: [ArchiveConflictResolution.Candidate]) {
        var moving: [ArchiveEditSelection] = [], candidates: [ArchiveConflictResolution.Candidate] = []
        for selection in selections {
            let mapped = try mapSelection(selection)
            let source = try ArchiveImportPlan.path(selection.path, format: format)
            if ArchivePath.components(source).dropLast().joined(separator: "/") == target { continue }
            if selection.isDirectory, target == source || ArchivePath.isDescendant(target, of: source) {
                throw ArchiveEditError.destinationInsideSource(source)
            }
            let leaf = ArchivePath.components(source).last!
            let destination = target.isEmpty ? leaf : target + "/" + leaf
            moving.append(mapped)
            candidates.append(.init(path: destination, info: try info(selection, source)))
        }
        return (moving, candidates)
    }
}
