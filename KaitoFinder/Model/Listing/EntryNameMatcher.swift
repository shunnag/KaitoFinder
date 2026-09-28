import Foundation

nonisolated struct EntryNameMatcher: Sendable {
    let query: String
    private let foldedQuery: [UInt8]?
    private let rejectsASCIINames: Bool

    #if DEBUG
    nonisolated static let decidedWithoutFoundationForTesting = TaskLocal<ArchiveTestCounter?>(wrappedValue: nil)
    #endif

    init(query: String) {
        self.query = query
        foldedQuery = !query.isEmpty && query.utf8.allSatisfy { (0x20...0x7e).contains($0) }
            ? query.utf8.map(Self.fold) : nil
        rejectsASCIINames = query.unicodeScalars.contains { scalar in
            guard scalar.properties.generalCategory == .otherLetter else { return false }
            switch scalar.value {
            case 0x3040...0x30ff, 0x3400...0x4dbf, 0x4e00...0x9fff, 0xac00...0xd7a3,
                 0xf900...0xfaff, 0xff66...0xff9f, 0x20000...0x3134f: return true
            default: return false
            }
        }
    }

    func matches(_ name: String) -> Bool {
        let decision = name.utf8.withContiguousStorageIfAvailable { bytes -> Bool? in
            // 後続の結合文字でも結果が変わるため、名前全体を先に調べる。
            guard bytes.allSatisfy({ (0x20...0x7e).contains($0) }) else { return nil }
            guard let foldedQuery else { return rejectsASCIINames ? false : nil }
            guard bytes.count >= foldedQuery.count else { return false }
            for start in 0...(bytes.count - foldedQuery.count) {
                var offset = 0
                while offset < foldedQuery.count, Self.fold(bytes[start + offset]) == foldedQuery[offset] {
                    offset += 1
                }
                if offset == foldedQuery.count { return true }
            }
            return false
        }
        if let available = decision, let result = available {
            #if DEBUG
            Self.decidedWithoutFoundationForTesting.get()?.increment()
            #endif
            return result
        }
        return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }

    private static func fold(_ byte: UInt8) -> UInt8 { (0x41...0x5a).contains(byte) ? byte | 0x20 : byte }
}
