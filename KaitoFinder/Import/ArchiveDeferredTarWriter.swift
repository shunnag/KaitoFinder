import Foundation
import GyoshukuKit
import KaitoKit

/// 公開 add API は uid/gid を受け取れない。自分で生成した非圧縮 tar に記録値を渡し、
/// rewriter の tar carry（formatSpecific の uid/gid を使う）から目的形式へ書き出す。
/// 任意の入力 tar を解析・変更せず、原本にも staging の所有者にも触れない。
nonisolated enum ArchiveDeferredTarWriter {
    static func isNeeded(format: GyoshukuKit.ArchiveFormat, options: WriterOptions) -> Bool {
        guard options.preserveOwnerIDs else { return false }
        switch format {
        case .tar, .tarGzip, .tarBzip2, .tarXZ: return true
        default: return false
        }
    }

    static func write(source: URL, password: String?, output: URL, format: GyoshukuKit.ArchiveFormat,
                      options: WriterOptions, plan: ArchiveSaveReplayPlan, progress: Progress,
                      verifyAssembledInput: (ArchiveVolumeSet?) throws -> Void = { _ in }) throws {
        let intermediate = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".tar")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        var interimOptions = options
        // 生成物に uid/gid の pax 拡張が出ないことを保証する。全項目の記録値は後で設定する。
        interimOptions.preserveOwnerIDs = false
        let writer = try ArchiveRewriter.open(url: source, password: password, output: intermediate,
                                             format: .tar, options: interimOptions)
        try verifyAssembledInput(writer.volumeSet)
        try plan.replay(on: writer, progress: progress)
        try writer.commit { _, _ in try ArchiveImportPlan.checkCancellation(progress) }
        try applyOwners(to: intermediate, plan: plan, progress: progress)
        let final = try ArchiveRewriter.open(url: intermediate, output: output, format: format, options: options)
        try final.commit { _, _ in try ArchiveImportPlan.checkCancellation(progress) }
    }

    private static func applyOwners(to url: URL, plan: ArchiveSaveReplayPlan, progress: Progress) throws {
        var owners: [String: (UInt32, UInt32)] = [:]
        let additions = Dictionary(uniqueKeysWithValues: plan.additions.map { ($0.id, $0) })
        for entry in plan.projected {
            let value: (UInt32, UInt32)
            if let id = entry.pendingID {
                if let addition = additions[id], addition.sourceStamp.kind != .directory {
                    value = (addition.sourceStamp.userID, addition.sourceStamp.groupID)
                } else { value = (0, 0) } // 即時追加の明示 directory と同じ。
            } else {
                value = (UInt32(entry.formatSpecific["uid"] ?? "") ?? 0,
                         UInt32(entry.formatSpecific["gid"] ?? "") ?? 0)
            }
            owners[ArchiveEditPlan.key(entry.name)] = value
        }
        let entries = try ArchiveReader.open(url: url, options: .kaitoFinder()).entries
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        var offset: UInt64 = 0, index = 0
        while offset + 512 <= length {
            try ArchiveImportPlan.checkCancellation(progress)
            try file.seek(toOffset: offset)
            var header = try file.read(upToCount: 512) ?? Data()
            guard header.count == 512 else { throw ArchiveEditError.staleSelection }
            if header.allSatisfy({ $0 == 0 }) { break }
            let size = try number(header[124..<136])
            guard size <= length - offset - 512 else { throw ArchiveEditError.staleSelection }
            if header[156] != 0x78 { // 自分の writer が出す per-entry pax header は reader の一覧にない。
                guard entries.indices.contains(index),
                      let value = owners[ArchiveEditPlan.key(entries[index].name)] else { throw ArchiveEditError.staleSelection }
                writeNumber(UInt64(value.0), at: 108, width: 8, in: &header)
                writeNumber(UInt64(value.1), at: 116, width: 8, in: &header)
                header.replaceSubrange(148..<156, with: Data(repeating: 0x20, count: 8))
                let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
                writeNumber(checksum, at: 148, width: 7, in: &header)
                header[155] = 0x20
                try file.seek(toOffset: offset)
                try file.write(contentsOf: header)
                index += 1
            }
            offset += 512 + size + (512 - size % 512) % 512
        }
        guard index == entries.count else { throw ArchiveEditError.staleSelection }
    }

    private static func number(_ field: Data.SubSequence) throws -> UInt64 {
        if field.first! & 0x80 != 0 {
            var result: UInt64 = 0
            for (index, byte) in field.enumerated() {
                guard result <= UInt64.max >> 8 else { throw ArchiveEditError.staleSelection }
                result = result << 8 | UInt64(index == 0 ? byte & 0x7f : byte)
            }
            return result
        }
        let text = String(decoding: field.prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let result = UInt64(text, radix: 8) else { throw ArchiveEditError.staleSelection }
        return result
    }

    private static func writeNumber(_ value: UInt64, at offset: Int, width: Int, in header: inout Data) {
        let octal = Array(String(value, radix: 8).utf8)
        var field: Data
        if octal.count < width {
            field = Data(repeating: 0x30, count: width - 1 - octal.count) + Data(octal) + Data([0])
        } else {
            field = Data(count: width)
            for index in 0..<min(width, 8) { field[width - 1 - index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
            field[0] |= 0x80
        }
        header.replaceSubrange(offset..<(offset + width), with: field)
    }
}
