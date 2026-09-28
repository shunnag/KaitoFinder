import Foundation

/// Finderの項目数表記を、表示の更新と文字列テストで共有する。
nonisolated enum ArchiveStatusBarText {
    static func text(totalCount: Int, totalSize: UInt64?, filteredCount: Int? = nil,
                     selectedCount: Int = 0, selectedSize: UInt64? = nil, bundle: Bundle = .main,
                     locale: Locale = .current) -> String {
        func size(_ bytes: UInt64?) -> String {
            guard let bytes, let signed = Int64(exactly: bytes) else { return String(localized: "—", bundle: bundle) }
            return ByteCountFormatter.string(fromByteCount: signed, countStyle: .file)
        }
        if selectedCount > 0 {
            // 選択数とサイズの引数番号を、すべての言語で揃える。
            return String(format: String(localized: "%1$lld項目を選択中(%3$@)", bundle: bundle),
                          locale: locale, Int64(selectedCount), Int64(filteredCount ?? totalCount), size(selectedSize))
        }
        // 数値の挿入にもロケールを渡し、件数の桁区切りをFinderと揃える。
        if let filteredCount {
            return String(format: String(localized: "%lld/%lld項目", bundle: bundle), locale: locale,
                          Int64(filteredCount), Int64(totalCount))
        }
        return String(format: String(localized: "%lld項目、%@", bundle: bundle), locale: locale,
                      Int64(totalCount), size(totalSize))
    }
}
