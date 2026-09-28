import AppKit
import XCTest
import CryptoKit
@testable import KaitoFinder

nonisolated enum LocalizationAcceptance {
    static let languages = ["ja", "en", "de", "fr", "es", "it", "pt-BR", "zh-Hans", "zh-Hant", "ko",
                            "th", "vi", "id", "ms", "hi", "ru", "nl", "pl", "tr", "sv", "da", "nb", "fi", "uk", "cs", "pt-PT"]

    static func sentenceEnding(_ language: String) -> String {
        if language == "th" { return "" }
        if language == "hi" { return "।" }
        return ["ja", "zh-Hans", "zh-Hant"].contains(language) ? "。" : "."
    }
    // AppKitがメニュータイトルで行う、改行しない空白の正規化だけを許容する。
    static func normalizedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\u{00a0}", with: " ")
    }
    static var root: URL {
        TestPaths.repositoryRoot
    }

    struct Catalog: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]
    }
    struct Entry: Decodable { let localizations: [String: Translation] }
    struct Translation: Decodable { let stringUnit: Unit }
    struct Unit: Decodable { let state: String; let value: String }

    static func catalog() throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf:
            root.appendingPathComponent("KaitoFinder/Resources/Localizable.xcstrings")))
    }

    static func bundle(_ language: String) throws -> Bundle {
        let app = Bundle(for: ArchiveDocument.self)
        let url = try XCTUnwrap(app.url(forResource: language, withExtension: "lproj"), language)
        return try XCTUnwrap(Bundle(url: url), language)
    }
}
