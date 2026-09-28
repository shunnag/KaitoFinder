import Foundation
import KaitoKit
@testable import KaitoFinder

nonisolated func archiveColumnEntry(_ path: String, index: Int = 0, kind: EntryKind = .file,
                                    size: UInt64? = 10, compressed: UInt64? = 5, date: Date? = nil,
                                    permissions: UInt16? = nil, crc: UInt32? = nil, solidGroup: Int = -1,
                                    encrypted: Bool = false, method: String = "Stored") -> ArchiveEntry {
    ArchiveEntry(index: index, rawName: RawName(bytes: Array(path.utf8)), name: path,
                 pathComponents: path.split(separator: "/").map(String.init), kind: kind,
                 uncompressedSize: size, compressedSize: compressed, modificationDate: date,
                 posixPermissions: permissions, isEncrypted: encrypted, solidGroup: solidGroup,
                 crc32: crc, methodDescription: method, formatSpecific: [:])
}
