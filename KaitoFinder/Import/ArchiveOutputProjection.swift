import Foundation
import GyoshukuKit
import KaitoKit

nonisolated struct ArchiveOutputProjection: Sendable {
    struct Entry: Sendable {
        let name: String
        var kind: EntryKind
        var size: UInt64?
        let isAddition: Bool
        var hardLinkIdentity: [Int64]?

        init(_ entry: ArchiveEntry, name: String? = nil, hardLinkIdentity: [Int64]? = nil) {
            self.name = name ?? entry.name
            kind = entry.kind
            size = entry.uncompressedSize
            isAddition = entry.pendingID != nil
            self.hardLinkIdentity = hardLinkIdentity
        }

        init(adding name: String, kind: EntryKind) {
            self.name = name
            self.kind = kind
            size = nil
            isAddition = true
        }

        init(adding item: ArchiveImportPlan.Item) throws {
            // 追加元のサイズは予約後に変わり得る。種類だけを照合する。
            let stamp = try ArchiveImportSourceStamp(item.url)
            self.init(adding: item.path, kind: item.isDirectory ? .directory : stamp.kind)
            hardLinkIdentity = stamp.hardLinkIdentity
        }
    }

    let entries: [Entry]

    init(projected: [ArchiveEntry], mode: ArchiveCapabilities.Mode) {
        self.init(existing: projected, mode: mode)
    }

    init(plan: ArchiveSaveReplayPlan, mode: ArchiveCapabilities.Mode) {
        let identities = Dictionary(uniqueKeysWithValues: plan.additions.compactMap { addition in
            addition.stagedStamp.hardLinkIdentity.map { (addition.id, $0) }
        })
        self.init(existing: plan.edits.existing, removing: plan.edits.removals.map(\.index), renaming: plan.edits.renames,
                  additions: plan.projected.filter { $0.pendingID != nil }.map {
                      Entry($0, hardLinkIdentity: $0.pendingID.flatMap { identities[$0] })
                  }, mode: mode)
    }

    init(existing: [ArchiveEntry], removing: [Int] = [], renaming: [ArchiveEditPlan.Rename] = [],
         additions: [Entry] = [], mode: ArchiveCapabilities.Mode) {
        let removed = Set(removing)
        // 保存時の循環改名は、最後の名前だけを照合する。
        let names = renaming.reduce(into: [Int: String]()) { $0[$1.entry.index] = $1.path }
        let format: GyoshukuKit.ArchiveFormat?
        switch mode { case .inPlace: format = nil; case .rewrite(let output): format = output }
        let isTar = format.map { [.tar, .tarGzip, .tarBzip2, .tarXZ].contains($0) } ?? false
        var dataTargets: [Int: Int] = [:]
        if format != nil {
            // 削除された参照先も含め、rewriter と同じ順で最終データ項目を解決する。
            for entry in existing where entry.kind == .hardlink {
                if let target = entry.formatSpecific["hardLinkTargetIndex"].flatMap(Int.init),
                   target >= 0, target < entry.index, existing.indices.contains(target),
                   existing[target].kind == .file || dataTargets[target] != nil {
                    dataTargets[entry.index] = dataTargets[target] ?? target
                }
            }
        }
        var addedFiles: Set<[Int64]> = []
        let added = additions.map { entry in
            var entry = entry
            // tar writer は追加元の同じ inode を二度目から hard link にする。
            if isTar, entry.kind == .file, let identity = entry.hardLinkIdentity,
               !addedFiles.insert(identity).inserted { entry.kind = .hardlink }
            return entry
        }
        entries = existing.compactMap { entry -> Entry? in
            guard !removed.contains(entry.index) else { return nil }
            var expected = Entry(entry, name: names[entry.index])
            guard format != nil, !expected.isAddition else { return expected }
            switch entry.kind {
            case .directory:
                if ArchiveEditPlan.key(expected.name).isEmpty { return nil }
                expected.size = 0
            case .hardlink:
                if let direct = entry.formatSpecific["hardLinkTargetIndex"].flatMap(Int.init),
                   let data = dataTargets[entry.index] {
                    // tar で直接の参照先が残る場合だけ link を保ち、それ以外は各々を実体化する。
                    expected.kind = isTar && !removed.contains(direct) ? .hardlink : .file
                    expected.size = expected.kind == .hardlink ? 0 : existing[data].uncompressedSize
                }
            case .symlink:
                if isTar { expected.size = 0 }
                else if let target = entry.formatSpecific["linkPath"] { expected.size = UInt64(target.utf8.count) }
            case .file, .other: break
            }
            return expected
        } + added
    }

    private struct Shape: Hashable {
        let key: String
        let kind: EntryKind

        init(name: String, kind: EntryKind) {
            key = ArchiveEditPlan.key(name)
            self.kind = kind
        }
    }

    private struct Sized: Hashable {
        let shape: Shape
        let size: UInt64?
    }

    func validate(_ reader: ArchiveReader, format: GyoshukuKit.ArchiveFormat? = nil) throws {
        if validationFailure(reader, format: format) != nil { throw VolumePublishError.validationFailed }
    }

    func validationFailure(_ reader: ArchiveReader, format: GyoshukuKit.ArchiveFormat? = nil) -> ArchiveVerificationFailure? {
        if let format {
            let expected: KaitoKit.ArchiveFormat
            switch format {
            case .zip: expected = .zip
            case .tar, .tarGzip, .tarBzip2, .tarXZ: expected = .tar
            case .sevenZip: expected = .sevenZip
            case .lha: expected = .lha
            }
            guard reader.format == expected else {
                return .format(expected: String(describing: expected), actual: String(describing: reader.format))
            }
        }
        return validationFailure(entries: reader.entries)
    }

    func validate(entries actual: [ArchiveEntry]) throws {
        if validationFailure(entries: actual) != nil { throw VolumePublishError.validationFailed }
    }

    func validationFailure(entries actual: [ArchiveEntry]) -> ArchiveVerificationFailure? {
        var carried: [Sized: Int] = [:], added: [Shape: Int] = [:]
        for entry in entries {
            let shape = Shape(name: entry.name, kind: entry.kind)
            // .expose の AppleDouble も通常の項目として数える。
            if entry.isAddition { added[shape, default: 0] += 1 }
            else { carried[Sized(shape: shape, size: entry.size), default: 0] += 1 }
        }
        // 不一致のときだけ残りの期待値を走査する。辞書の列挙順に依存しない診断にする。
        func firstRemaining(key: String? = nil) -> ArchiveVerificationFailure.Entry? {
            for (index, entry) in entries.enumerated() {
                let shape = Shape(name: entry.name, kind: entry.kind)
                if let key, shape.key != key { continue }
                if entry.isAddition ? added[shape] != nil : carried[Sized(shape: shape, size: entry.size)] != nil {
                    return .init(index: index, name: entry.name, kind: String(describing: entry.kind), size: entry.size)
                }
            }
            return nil
        }
        // 同名項目も件数を保つ。サイズ既知の項目から消費し、追加だけサイズを問わない。
        for entry in actual {
            let shape = Shape(name: entry.name, kind: entry.kind)
            let sized = Sized(shape: shape, size: entry.uncompressedSize)
            if let count = carried[sized] {
                if count == 1 { carried.removeValue(forKey: sized) }
                else { carried[sized] = count - 1 }
            } else if let count = added[shape] {
                if count == 1 { added.removeValue(forKey: shape) }
                else { added[shape] = count - 1 }
            } else {
                return .projection(expected: firstRemaining(key: shape.key) ?? firstRemaining(),
                    actual: .init(index: entry.index, name: entry.name, kind: String(describing: entry.kind), size: entry.uncompressedSize))
            }
        }
        guard carried.isEmpty, added.isEmpty else { return .projection(expected: firstRemaining(), actual: nil) }
        return nil
    }
}
