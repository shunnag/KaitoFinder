import Foundation
import KaitoKit
@testable import KaitoFinder

/// テスト用の合成 ArchiveEntry。rawName は `path` の UTF-8 byte 列。`pathComponents` を省くと `path` を "/" で区切る
/// （空の成分は落とし "." は残す。本番の分け方が要るときは `ArchivePath.components(path)` を渡す）。
nonisolated func archiveColumnEntry(_ path: String, index: Int = 0, kind: EntryKind = .file,
                                    size: UInt64? = 10, compressed: UInt64? = 5, date: Date? = nil,
                                    permissions: UInt16? = nil, crc: UInt32? = nil, solidGroup: Int = -1,
                                    encrypted: Bool = false, method: String = "Stored", pathComponents: [String]? = nil,
                                    incomplete: Bool = false, formatSpecific: [String: String] = [:]) -> ArchiveEntry {
    ArchiveEntry(index: index, rawName: RawName(bytes: Array(path.utf8)), name: path,
                 pathComponents: pathComponents ?? path.split(separator: "/").map(String.init), kind: kind,
                 uncompressedSize: size, compressedSize: compressed, modificationDate: date,
                 posixPermissions: permissions, isEncrypted: encrypted, solidGroup: solidGroup,
                 crc32: crc, methodDescription: method, formatSpecific: formatSpecific, isIncomplete: incomplete)
}
