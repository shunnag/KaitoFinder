import Foundation
import KaitoKit

/// スレッドセーフではない reader を所有し、値型の一覧だけを外へ渡す。
actor ArchiveSession {
    private let reader: ArchiveReader

    init(url: URL) throws {
        reader = try ArchiveReader.open(url: url)
    }

    func entries() -> [ArchiveEntry] {
        reader.entries
    }
}
