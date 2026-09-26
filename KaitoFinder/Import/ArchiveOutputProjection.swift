import Foundation
import GyoshukuKit
import KaitoKit

nonisolated struct ArchiveOutputProjection: Sendable {
    enum ExpectedZipEncryption: String, Sendable {
        case none, zipCrypto = "ZipCrypto", aes256 = "AES-256"

        init(_ options: WriterOptions) {
            self = options.password == nil ? .none : options.zipEncryption == .zipCrypto ? .zipCrypto : .aes256
        }
    }

    struct Entry: Sendable {
        let name: String
        var kind: EntryKind
        var size: UInt64?
        let isAddition: Bool
        var hardLinkIdentity: [Int64]?
        var hardLinkTarget: String?

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
    let zipEncryption: ExpectedZipEncryption?
    private let mode: ArchiveCapabilities.Mode
    private let existing: [ArchiveEntry]
    private let removing: [Int]
    private let renaming: [ArchiveEditPlan.Rename]
    private let additions: [Entry]

    func resolving(_ mode: ArchiveCapabilities.Mode) -> Self {
        guard mode != self.mode else { return self }
        return Self(existing: existing, removing: removing, renaming: renaming, additions: additions,
                    mode: mode, zipEncryption: zipEncryption)
    }

    init(projected: [ArchiveEntry], mode: ArchiveCapabilities.Mode, zipEncryption: ExpectedZipEncryption? = nil) {
        self.init(existing: projected, mode: mode, zipEncryption: zipEncryption)
    }

    init(plan: ArchiveSaveReplayPlan, mode: ArchiveCapabilities.Mode, zipEncryption: ExpectedZipEncryption? = nil) {
        let identities = Dictionary(uniqueKeysWithValues: plan.additions.compactMap { addition in
            addition.stagedStamp.hardLinkIdentity.map { (addition.id, $0) }
        })
        self.init(existing: plan.edits.existing, removing: plan.edits.removals.map(\.index), renaming: plan.edits.renames,
                  additions: plan.projected.filter { $0.pendingID != nil }.map {
                      Entry($0, hardLinkIdentity: $0.pendingID.flatMap { identities[$0] })
                  }, mode: mode, zipEncryption: zipEncryption)
    }

    init(existing: [ArchiveEntry], removing: [Int] = [], renaming: [ArchiveEditPlan.Rename] = [],
         additions: [Entry] = [], mode: ArchiveCapabilities.Mode, zipEncryption: ExpectedZipEncryption? = nil) {
        self.zipEncryption = zipEncryption
        self.mode = mode
        self.existing = existing
        self.removing = removing
        self.renaming = renaming
        self.additions = additions
        let removed = Set(removing)
        // 保存時の循環改名は、最後の名前だけを照合する。
        let names = renaming.reduce(into: [Int: String]()) { $0[$1.entry.index] = $1.path }
        let format: GyoshukuKit.ArchiveFormat?
        switch mode { case .inPlace: format = nil; case .rewrite(let output), .update(let output): format = output }
        let updates: Bool
        if case .update = mode { updates = true } else { updates = false }
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
        var addedFiles: [[Int64]: String] = [:]
        let added = additions.map { entry in
            var entry = entry
            if isTar, entry.kind == .symlink || entry.kind == .directory { entry.size = 0 }
            // tar writer は追加元の同じ inode を二度目から hard link にする。
            if isTar, entry.kind == .file, let identity = entry.hardLinkIdentity {
                if let target = addedFiles[identity] {
                    entry.kind = .hardlink
                    entry.size = 0
                    entry.hardLinkTarget = target
                } else { addedFiles[identity] = entry.name }
            }
            return entry
        }
        var holders: [Int: Int] = [:]
        for target in dataTargets.values where !removed.contains(target) { holders[target] = target }
        entries = existing.compactMap { entry -> Entry? in
            guard !removed.contains(entry.index) else { return nil }
            var expected = Entry(entry, name: names[entry.index])
            guard format != nil, !expected.isAddition else { return expected }
            if updates {
                if entry.kind == .hardlink, let direct = entry.formatSpecific["hardLinkTargetIndex"].flatMap(Int.init),
                   let data = dataTargets[entry.index] {
                    let target: Int?
                    if !removed.contains(direct) { target = direct }
                    else if let holder = holders[data] { target = holder }
                    else {
                        target = nil
                        expected.kind = .file
                        expected.size = existing[data].uncompressedSize
                        holders[data] = entry.index
                    }
                    if let target { expected.hardLinkTarget = names[target] ?? existing[target].name }
                }
                return expected
            }
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
        try validateMode()
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
        try validateMode()
        if validationFailure(entries: actual) != nil { throw VolumePublishError.validationFailed }
    }

    func validationFailure(entries actual: [ArchiveEntry]) -> ArchiveVerificationFailure? {
        if case .update = mode { return orderedValidationFailure(actual) }
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
            if let zipEncryption {
                let expected: ExpectedZipEncryption = entry.kind == .file ? zipEncryption : .none
                guard entry.isEncrypted == (expected != .none), entry.formatSpecific["encryption"] == expected.rawValue else {
                    return .encryption(index: entry.index, expected: expected.rawValue,
                        actual: entry.formatSpecific["encryption"], isEncrypted: entry.isEncrypted)
                }
            }
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

    private func validateMode() throws {
        if case .update(let format) = mode, ![.tar, .tarGzip, .tarBzip2, .tarXZ, .lha].contains(format) {
            throw ArchiveEditError.staleSelection
        }
    }

    private func orderedValidationFailure(_ actual: [ArchiveEntry]) -> ArchiveVerificationFailure? {
        func detail(_ index: Int, _ entry: Entry) -> ArchiveVerificationFailure.Entry {
            .init(index: index, name: entry.name, kind: String(describing: entry.kind), size: entry.size)
        }
        for index in 0..<max(entries.count, actual.count) {
            let expected = entries.indices.contains(index) ? entries[index] : nil
            let found = actual.indices.contains(index) ? actual[index] : nil
            guard let expected, let found,
                  Shape(name: expected.name, kind: expected.kind) == Shape(name: found.name, kind: found.kind),
                  expected.size == nil || expected.size == found.uncompressedSize else {
                return .projection(expected: expected.map { detail(index, $0) },
                                   actual: found.map { detail(index, Entry($0)) })
            }
            if expected.kind == .hardlink, let target = expected.hardLinkTarget {
                let actualTarget = found.formatSpecific["hardLinkTargetIndex"].flatMap(Int.init)
                    .flatMap { actual.indices.contains($0) ? actual[$0] : nil }
                guard actualTarget.map({ ArchiveEditPlan.key($0.name) }) == ArchiveEditPlan.key(target) else {
                    return .hardLink(index: index, expected: .init(index: index, name: target, kind: "target", size: nil),
                                     actual: actualTarget.map { detail($0.index, Entry($0)) })
                }
            }
        }
        return nil
    }
}
