import AppKit
import XCTest
import CryptoKit
@testable import KaitoFinder

nonisolated enum LocalizationAcceptance {
    static let languages = ["ja", "en", "de", "fr", "es", "it", "pt-BR", "zh-Hans", "zh-Hant", "ko"]
    // AppKitがメニュータイトルで行う、改行しない空白の正規化だけを許容する。
    static func normalizedTitle(_ title: String) -> String {
        title.replacingOccurrences(of: "\u{00a0}", with: " ")
    }
    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
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

nonisolated final class WordingAcceptanceTests: XCTestCase {

    func testPasswordWordingHasTenTranslationsAndRetiresEveryOldRefusalTranslation() throws {
        let catalog = try LocalizationAcceptance.catalog()
        let keys = [
            "パスワードを設定…",
            "パスワードを変更…",
            "パスワードを削除",
            "パスワード:",
            "確認:",
            "新しいパスワード:",
            "暗号化",
            "方式:",
            "AES-256(推奨)",
            "ZipCrypto(互換性優先、安全性は低い)",
            "ファイル名も暗号化",
            "パスワードを入力してください。",
            "パスワードが一致しません。",
            "tar と LHA は暗号化できません",
            "この形式は暗号化できません。別名で保存で ZIP か 7z にしてください。",
            "“%@”のパスワードを削除しますか？",
            "アーカイブは暗号化されていない状態で書き直されます。",
            "暗号化されたアーカイブを変更するにはパスワードが必要です。",
            "パスワードの設定を取り消す",
            "パスワードの変更を取り消す",
            "パスワードの削除を取り消す",
        ]
        for key in keys {
            let entry = try XCTUnwrap(catalog.strings[key], key)
            XCTAssertEqual(Set(entry.localizations.keys), Set(LocalizationAcceptance.languages), key)
        }
        // 廃止した文言自体をソースへ残さず、10 言語すべての復活を検出する。
        let retiredDigests: Set<String> = [
            "aececabd9ae30032d4096b26744c35b27684ab7723f0b80410e1ceb4dff53da5",
            "65f720b2103c624b5af0443bc4e20a564da27aee9d45ed1d0840a97ded0ba930",
            "4187d12effa79e8ecf70f289e115edb1d0bd20add5f882c165d5dd15a982f1c9",
            "64e8a6b7304dfa8180f9d56490b67270828ca779ee4d9c3dd5499b7251ddf15b",
            "b501c50d95a02a9e1a3a77bbcada0e020e8a22c1cd58d523c9973a56b359e2cd",
            "0592f5b8e139a0bbcf1e9137f6956be03b1e10e6a41f13c0252cd09c4117b5d2",
            "4c732318dd66cb8fa418740a83484275f00928291691d00f83c2f024dec7d2d5",
            "c1a4c79c4fb8ba509111e02b5d38c5af76d80bbbbeb30a78e7c77f13d9ed29ca",
            "aafa46a7bb91bf00abcf75b1f1d7104a914db9413004a39494805909bf1153a3",
            "68365b7ce5bcb0ea0df60f1e7488bcf43809cc267677196e32a16febdea0fccd",
        ]
        for (key, entry) in catalog.strings {
            for (language, translation) in entry.localizations {
                let digest = SHA256.hash(data: Data(translation.stringUnit.value.utf8)).map { String(format: "%02x", $0) }.joined()
                XCTAssertFalse(retiredDigests.contains(digest), "\(language): \(key)")
            }
        }
    }

    func testEnglishDevelopmentFallbackKeepsAllTenLocalizations() {
        XCTAssertEqual(Bundle.main.infoDictionary?["CFBundleDevelopmentRegion"] as? String, "en")
        XCTAssertTrue(Set(LocalizationAcceptance.languages).isSubset(of: Set(Bundle.main.localizations)))
    }

    private func texts(_ language: String) throws -> [(key: String, value: String)] {
        try LocalizationAcceptance.catalog().strings.sorted { $0.key < $1.key }.map { key, entry in
            (key, try XCTUnwrap(entry.localizations[language], "\(language): \(key)").stringUnit.value)
        }
    }

    func testCatalogHasTenNonemptyTranslationsWithMatchingOrderedFormatSpecifiers() throws {
        let catalog = try LocalizationAcceptance.catalog()
        XCTAssertEqual(catalog.sourceLanguage, "ja")
        XCTAssertFalse(catalog.strings.isEmpty)
        let formats = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:lld|d|@)"#)
        func specifiers(_ text: String) -> [String] {
            formats.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range, in: text)!])
            }
        }
        for (key, entry) in catalog.strings {
            XCTAssertEqual(Set(entry.localizations.keys), Set(LocalizationAcceptance.languages), key)
            for language in LocalizationAcceptance.languages {
                let unit = try XCTUnwrap(entry.localizations[language], "\(language): \(key)").stringUnit
                XCTAssertFalse(unit.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): \(key)")
                XCTAssertEqual(unit.state, "translated", "\(language): \(key)")
                XCTAssertEqual(specifiers(unit.value), specifiers(key), "\(language): \(key)")
                if language == "ja" { XCTAssertEqual(unit.value, key) }
            }
        }
    }

    private func checkNameQuotes(_ language: String, opening: String, closing: String) throws {
        for (key, text) in try texts(language) where key.contains("“%@”") {
            XCTAssertTrue(text.contains(opening + "%@" + closing), "\(language): \(key): \(text)")
        }
    }

    func testJapaneseStyle() throws {
        let spacing = try NSRegularExpression(pattern:
            #"[\p{Han}\p{Hiragana}\p{Katakana}] [A-Za-z]|[A-Za-z] [\p{Han}\p{Hiragana}\p{Katakana}]"#)
        // 数値と単位の間、および取り消しの区切りの空白は、この正規表現に該当しない。
        for allowed in ["4 GiB", "取り消す — %@", "やり直す — %@", "SFX ZIP"] {
            XCTAssertNil(spacing.firstMatch(in: allowed, range: NSRange(allowed.startIndex..., in: allowed)))
        }
        for (key, text) in try texts("ja") {
            XCTAssertFalse(text.contains("書庫"), key)
            XCTAssertFalse(text.contains("／"), key)
            XCTAssertFalse(text.contains("「%@」"), key)
            // Wave A の指定ラベルは、形式名・ファイル名を区切る空白も仕様どおりに保つ。
            if ![".DS_Store を含めない", "7z と LHA の圧縮レベルは固定です", "tar と LHA は暗号化できません",
                  "この形式は暗号化できません。別名で保存で ZIP か 7z にしてください。"].contains(key) {
                XCTAssertNil(spacing.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), key)
            }
        }
        try checkNameQuotes("ja", opening: "“", closing: "”")
    }

    func testEnglishStyle() throws {
        try checkNameQuotes("en", opening: "“", closing: "”")
        let strings = try LocalizationAcceptance.catalog().strings
        for (key, value) in ["アーカイブを展開…": "Expand Archives…", "すべて展開…": "Expand All…",
                             "選択した項目を展開…": "Extract Selected Items…", "項目を展開中…": "Extracting…"] {
            XCTAssertEqual(strings[key]?.localizations["en"]?.stringUnit.value, value, key)
        }
    }

    func testGermanStyle() throws {
        try checkNameQuotes("de", opening: "„", closing: "“")
        let formal = try NSRegularExpression(pattern: #"\b(Sie|Ihnen|Ihr)\b"#)
        for (key, text) in try texts("de") {
            if key.hasSuffix("…") { XCTAssertTrue(text.hasSuffix("\u{00a0}…"), key) }
            XCTAssertNil(formal.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), key)
        }
    }

    func testFrenchStyle() throws {
        try checkNameQuotes("fr", opening: "«\u{00a0}", closing: "\u{00a0}»")
        let spacing = try NSRegularExpression(pattern: "(?<!\u{00a0}):|«(?!\u{00a0})|(?<!\u{00a0})»")
        for (key, text) in try texts("fr") {
            XCTAssertNil(spacing.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), key)
        }
    }

    func testSpanishStyle() throws {
        try checkNameQuotes("es", opening: "“", closing: "”")
        for (key, text) in try texts("es") where key.contains("アーカイブ") {
            XCTAssertTrue(text.lowercased().contains("comprimid"), "\(key): \(text)")
        }
    }

    func testItalianStyle() throws {
        try checkNameQuotes("it", opening: "“", closing: "”")
        try checkVocabulary("it", archive: "Archivio", item: "elemento", expand: "Espandi")
    }

    func testBrazilianPortugueseStyle() throws {
        try checkNameQuotes("pt-BR", opening: "“", closing: "”")
        try checkVocabulary("pt-BR", archive: "Arquivo comprimido", item: "item", expand: "Expandir")
    }

    func testSimplifiedChineseStyle() throws {
        try checkNameQuotes("zh-Hans", opening: "“", closing: "”")
        try checkVocabulary("zh-Hans", archive: "归档", item: "项目", expand: "解压缩")
    }

    func testTraditionalChineseStyle() throws {
        try checkNameQuotes("zh-Hant", opening: "「", closing: "」")
        try checkVocabulary("zh-Hant", archive: "封存檔", item: "項目", expand: "解壓縮")
        for (key, text) in try texts("zh-Hant") where key.hasSuffix("…") {
            XCTAssertTrue(text.hasSuffix("⋯"), key)
            XCTAssertFalse(text.contains("…"), key)
        }
    }

    func testKoreanStyle() throws {
        try checkNameQuotes("ko", opening: "‘", closing: "’")
        try checkVocabulary("ko", archive: "아카이브", item: "항목", expand: "압축 해제")
        let singleParticles = try NSRegularExpression(pattern: #"%@’?[을를이가](?!\()"#)
        for (key, text) in try texts("ko") {
            XCTAssertNil(singleParticles.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), key)
        }
    }

    private func checkVocabulary(_ language: String, archive: String, item: String, expand: String) throws {
        let strings = try LocalizationAcceptance.catalog().strings
        for (key, expected) in ["アーカイブ": archive, "項目": item, "展開": expand] {
            XCTAssertEqual(strings[key]?.localizations[language]?.stringUnit.value, expected, "\(language): \(key)")
        }
    }

    func testEveryLanguageUsesTheSpecifiedItemCountAndCommandEllipsis() throws {
        let counts = ["ja": "%lld / %lld項目", "en": "%lld / %lld items", "de": "%lld / %lld Objekte",
                      "fr": "%lld / %lld éléments", "es": "%lld / %lld ítems", "it": "%lld / %lld elementi",
                      "pt-BR": "%lld / %lld itens", "zh-Hans": "%lld / %lld 项目", "zh-Hant": "%lld / %lld 項目",
                      "ko": "%lld / %lld개 항목"]
        let strings = try LocalizationAcceptance.catalog().strings
        for language in LocalizationAcceptance.languages {
            XCTAssertEqual(strings["%lld / %lld項目"]?.localizations[language]?.stringUnit.value, counts[language], language)
            for (key, text) in try texts(language) where key.hasSuffix("…") {
                let ending = language == "zh-Hant" ? "⋯" : language == "de" ? "\u{00a0}…" : "…"
                XCTAssertTrue(text.hasSuffix(ending), "\(language): \(key)")
                XCTAssertFalse(text.contains("..."), "\(language): \(key)")
            }
        }
    }

    func testServicesMenusHaveTenLocalizations() throws {
        let titles = [
            "ja": ["KaitoFinderで圧縮", "KaitoFinderで展開"],
            "en": ["Compress with KaitoFinder", "Expand with KaitoFinder"],
            "de": ["Mit KaitoFinder komprimieren", "Mit KaitoFinder entpacken"],
            "fr": ["Compresser avec KaitoFinder", "Décompresser avec KaitoFinder"],
            "es": ["Comprimir con KaitoFinder", "Descomprimir con KaitoFinder"],
            "it": ["Comprimi con KaitoFinder", "Espandi con KaitoFinder"],
            "pt-BR": ["Comprimir com KaitoFinder", "Expandir com KaitoFinder"],
            "zh-Hans": ["使用KaitoFinder压缩", "使用KaitoFinder解压缩"],
            "zh-Hant": ["使用KaitoFinder壓縮", "使用KaitoFinder解壓縮"],
            "ko": ["KaitoFinder로 압축", "KaitoFinder로 압축 해제"]
        ]
        for language in LocalizationAcceptance.languages {
            let expected = try XCTUnwrap(titles[language])
            let url = LocalizationAcceptance.root.appendingPathComponent("KaitoFinder/Resources/\(language).lproj/ServicesMenu.strings")
            let services = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            XCTAssertEqual(services, ["KaitoFinderで圧縮": expected[0], "KaitoFinderで展開": expected[1]], language)
        }
    }

    func testBuiltAppContainsAllTenLocalizationFoldersAndTranslatedResources() throws {
        let app = Bundle(for: ArchiveDocument.self)
        let resources = try XCTUnwrap(app.resourceURL)
        for language in LocalizationAcceptance.languages {
            let folder = resources.appendingPathComponent("\(language).lproj", isDirectory: true)
            var directory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), language)
            XCTAssertTrue(directory.boolValue, language)
            let bundle = try LocalizationAcceptance.bundle(language)
            XCTAssertNotNil(bundle.url(forResource: "Localizable", withExtension: "strings"), language)
            XCTAssertNotNil(bundle.url(forResource: "ServicesMenu", withExtension: "strings"), language)
            for (key, value) in try texts(language) {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: "Localizable"), value, "\(language): \(key)")
            }
            let source = LocalizationAcceptance.root.appendingPathComponent("KaitoFinder/Resources/\(language).lproj/ServicesMenu.strings")
            let expected = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as? [String: String])
            for (key, value) in expected {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: "ServicesMenu"), value, language)
            }
        }
    }

    @MainActor func testJapaneseMenuCorrectionsAndNamedProgressTitle() throws {
        let bundle = try LocalizationAcceptance.bundle("ja")
        let menu = AppDelegate().makeMenu(bundle: bundle)
        let appMenu = try XCTUnwrap(menu.items.first?.submenu)
        for title in ["KaitoFinderを非表示", "ほかを非表示", "すべてを表示", "サービス"] {
            XCTAssertNotNil(appMenu.item(withTitle: title), title)
        }
        XCTAssertNil(appMenu.item(withTitle: "KaitoFinderを隠す"))
        XCTAssertNil(appMenu.item(withTitle: "ほかを隠す"))
        XCTAssertEqual(ArchiveProgressOperation.expandingArchive("旅行の写真.zip").title(bundle: bundle), "“旅行の写真.zip”を展開中…")
    }

    @MainActor func testAlertPunctuationInEveryLanguage() throws {
        for language in LocalizationAcceptance.languages {
            let bundle = try LocalizationAcceptance.bundle(language)
            let period = ["ja", "zh-Hans", "zh-Hant"].contains(language) ? "。" : "."
            let reason = String(localized: "このアーカイブは変更できません。", bundle: bundle)
            var alerts = [
                ArchiveWindowController.makeDeletionConfirmation(bundle: bundle),
                ArchiveWindowController.makeFailureAlert(reason, bundle: bundle),
                ArchiveWindowController.makeImportFailureAlert(reason, added: true, bundle: bundle),
                ArchiveWindowController.makeEditFailureAlert(reason, published: true, bundle: bundle)
            ]
            for challenge in [ArchivePasswordChallenge.required, .incorrect] {
                for name in [nil, "旅行の写真.zip"] as [String?] {
                    alerts.append(ArchivePasswordPrompt(challenge: challenge, archiveName: name, bundle: bundle).alert)
                }
            }
            alerts.append(try XCTUnwrap(ArchiveBatchExtractionController.failureAlert(for: .init(extracted: [], failures: [
                .init(archive: URL(fileURLWithPath: "/tmp/example.zip"), reason: reason)
            ], cancelled: false), bundle: bundle)))
            for alert in alerts {
                XCTAssertFalse(alert.messageText.hasSuffix("."), "\(language): \(alert.messageText)")
                XCTAssertFalse(alert.messageText.hasSuffix("。"), "\(language): \(alert.messageText)")
                XCTAssertTrue(alert.informativeText.hasSuffix(period), "\(language): \(alert.informativeText)")
                XCTAssertFalse(alert.informativeText.hasSuffix(period + period), language)
            }
        }
    }

    @MainActor func testStandardMenusHaveLocalizedTitlesActionsShortcutsAndApplicationBindings() throws {
        let application = NSApplication.shared
        let previousServices = application.servicesMenu
        let previousWindows = application.windowsMenu
        let previousHelp = application.helpMenu
        defer {
            application.servicesMenu = previousServices
            application.windowsMenu = previousWindows
            application.helpMenu = previousHelp
        }
        let appBundle = Bundle(for: ArchiveDocument.self)
        for language in LocalizationAcceptance.languages {
            let bundle = try XCTUnwrap(Bundle(url: XCTUnwrap(appBundle.url(forResource: language, withExtension: "lproj"))))
            let delegate = AppDelegate(), menu = delegate.makeMenu(bundle: bundle)
            func title(_ key: String.LocalizationValue) -> String {
                LocalizationAcceptance.normalizedTitle(String(localized: key, bundle: bundle))
            }
            func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
                menu.items.first { LocalizationAcceptance.normalizedTitle($0.title) == LocalizationAcceptance.normalizedTitle(title) }
            }
            func index(_ menu: NSMenu, _ title: String) -> Int {
                item(menu, title).map { menu.index(of: $0) } ?? -1
            }
            let submenus = menu.items.compactMap(\.submenu)
            XCTAssertEqual(submenus.map { LocalizationAcceptance.normalizedTitle($0.title) },
                           ["KaitoFinder", title("ファイル"), title("編集"), title("表示"), title("ウインドウ"), title("ヘルプ")])
            let app = try XCTUnwrap(submenus.first)
            XCTAssertEqual(app.items.map { LocalizationAcceptance.normalizedTitle($0.title) },
                           [title("KaitoFinderについて"), "", title("設定…"), "", title("サービス"), "",
                                                  title("KaitoFinderを非表示"), title("ほかを非表示"), title("すべてを表示"), "", title("KaitoFinderを終了")])
            for index in [1, 3, 5, 9] { XCTAssertTrue(app.items[index].isSeparatorItem) }
            let services = try XCTUnwrap(item(app, title("サービス"))?.submenu)
            XCTAssertEqual(LocalizationAcceptance.normalizedTitle(services.title), title("サービス"))
            // テスト host では起動時に据えたメニューを AppKit が保持し、言語ごとの再構築では差し替わらない。
            // 結び付けの存在だけを確かめる(実アプリでは同一性を lldb で確認済み)。
            XCTAssertNotNil(application.servicesMenu)
            func check(_ item: NSMenuItem?, _ action: Selector, _ key: String,
                       _ modifiers: NSEvent.ModifierFlags = [.command]) throws {
                let item = try XCTUnwrap(item)
                XCTAssertEqual(item.action, action, item.title)
                XCTAssertEqual(item.keyEquivalent, key, item.title)
                XCTAssertEqual(item.keyEquivalentModifierMask, modifiers, item.title)
                XCTAssertNil(item.target, item.title)
            }
            try check(item(app, title("KaitoFinderを非表示")), #selector(NSApplication.hide(_:)), "h")
            try check(item(app, title("ほかを非表示")), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
            try check(item(app, title("すべてを表示")), #selector(NSApplication.unhideAllApplications(_:)), "")
            try check(item(app, title("KaitoFinderを終了")), #selector(NSApplication.terminate(_:)), "q")

            let file = try XCTUnwrap(item(menu, title("ファイル"))?.submenu)
            let recent = try XCTUnwrap(item(file, title("最近使った項目を開く")))
            XCTAssertEqual(file.index(of: recent), index(file, title("開く…")) + 1)
            let recentMenu = try XCTUnwrap(recent.submenu)
            let clear = try XCTUnwrap(recentMenu.items.last)
            XCTAssertEqual(LocalizationAcceptance.normalizedTitle(clear.title), title("メニューを消去"))
            try check(clear, #selector(NSDocumentController.clearRecentDocuments(_:)), "")
            try check(item(file, title("開く")), #selector(ArchiveWindowController.openEntry(_:)), "o")

            let edit = try XCTUnwrap(item(menu, title("編集"))?.submenu)
            let selectAll = try XCTUnwrap(item(edit, title("すべてを選択")))
            try check(selectAll, #selector(NSText.selectAll(_:)), "a")
            XCTAssertEqual(edit.index(of: selectAll), index(edit, title("ペースト")) + 1)
            XCTAssertEqual(index(edit, title("削除")), edit.index(of: selectAll) + 1)

            let window = try XCTUnwrap(item(menu, title("ウインドウ"))?.submenu)
            XCTAssertNotNil(application.windowsMenu)
            let welcome = try XCTUnwrap(item(window, title("ようこそKaitoFinderへ")))
            XCTAssertEqual(welcome.action, #selector(AppDelegate.showWelcome(_:)))
            XCTAssertTrue(welcome.target === delegate)
            XCTAssertEqual(welcome.keyEquivalent, "1")
            XCTAssertEqual(welcome.keyEquivalentModifierMask, [.command, .shift])
            if language == "ja" { XCTAssertEqual(welcome.title, "ようこそKaitoFinderへ") }
            let bringAll = try XCTUnwrap(item(window, title("すべてを手前に移動")))
            try check(bringAll, #selector(NSApplication.arrangeInFront(_:)), "")
            XCTAssertEqual(window.index(of: bringAll), index(window, title("拡大/縮小")) + 1)

            let helpMenu = try XCTUnwrap(item(menu, title("ヘルプ"))?.submenu)
            XCTAssertTrue(application.helpMenu === helpMenu)
            let help = try XCTUnwrap(item(helpMenu, title("KaitoFinderヘルプ")))
            XCTAssertEqual(help.action, #selector(AppDelegate.showHelp(_:)))
            XCTAssertTrue(help.target === delegate)
            XCTAssertEqual(help.keyEquivalent, "")
        }
    }
}
