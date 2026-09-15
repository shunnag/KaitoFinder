import Foundation

nonisolated enum ArchiveAlertText {
    // 外部エラーや項目名を含む説明にも、表示言語に合う句点を一度だけ付ける。
    static func informativeText(_ text: String, bundle: Bundle = .main) -> String {
        var sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while sentence.last == "。" || sentence.last == "." { sentence.removeLast() }
        guard !sentence.isEmpty else { return "" }
        return String(localized: "\(sentence)。", bundle: bundle)
    }
}
