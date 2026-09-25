import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveErrorTextTests: XCTestCase {
    private func checkJapanese(_ cases: [(any Error, String)], file: StaticString = #filePath, line: UInt = #line) throws {
        let bundle = try LocalizationAcceptance.bundle("ja")
        for (error, expected) in cases {
            let text = ArchiveErrorText.describe(error, bundle: bundle)
            XCTAssertEqual(text, expected, file: file, line: line)
            XCTAssertFalse(text.hasSuffix("。") || text.hasSuffix("."), text, file: file, line: line)
        }
    }

    func testCancellationAndEveryKaitoErrorInJapanese() throws {
        try checkJapanese([
            (CancellationError(), "キャンセルされました"),
            (KaitoError.unsupportedFormat, "対応していないアーカイブ形式です"),
            (KaitoError.unsupportedMethod("zstd"), "対応していない圧縮方式です: zstd"),
            (KaitoError.malformed("EOCD がありません"), "アーカイブの構造が壊れています: EOCD がありません"),
            (KaitoError.truncated, "アーカイブが途中で切れています"),
            (KaitoError.passwordRequired, "パスワードが必要です"),
            (KaitoError.wrongPassword, "パスワードが正しくありません"),
            (KaitoError.checksumMismatch(entry: 3), "項目 3 のチェックサムが一致しません"),
            (KaitoError.limitExceeded("entry count"), "アーカイブが大きすぎるか複雑すぎるため、読み込みの上限を超えました(entry count)"),
            (KaitoError.io(EACCES), String(cString: strerror(EACCES))),
            (KaitoError.notFound("note.txt"), "見つかりません: note.txt")
        ])
    }

    func testEveryWriterErrorInJapanese() throws {
        try checkJapanese([
            (WriterError.invalidOption("level"), "書き込みオプションが不正です: level"),
            (WriterError.unsupportedOption("encryption"), "対応していない書き込みオプションです: encryption"),
            (WriterError.invalidPath("../note.txt"), "このパスは使えません: ../note.txt"),
            (WriterError.duplicatePath("note.txt"), "同じパスが重複しています: note.txt"),
            (WriterError.unsupportedFileType("socket"), "対応していないファイルの種類です: socket"),
            (WriterError.sourceChanged("note.txt"), "追加中にファイルが変更されました: note.txt"),
            (WriterError.invalidDate, "日付が不正です"),
            (WriterError.invalidState, "内部状態が不正です"),
            (WriterError.io(operation: "open", code: ENOENT), String(cString: strerror(ENOENT))),
            (WriterError.compression(-3), "圧縮に失敗しました(コード -3)"),
            (WriterError.sizeOverflow, "サイズが上限を超えています")
        ])
    }

    // P1-G の clone・snapshot・output と、従来の spool / crypto の処理名も表示しない。
    private static let writerIOOperations = [
        "AES CBC finish", "AES CBC update", "AES ECB", "chmod clone",
        "clear output flags", "clear snapshot flags", "clone output", "clone source",
        "close ZipCrypto spool", "configure LHA spool", "create", "create AES CBC",
        "create LHA spool", "create ZipCrypto spool", "create entry buffer", "derive ZIP key",
        "fstat after read", "fstat output", "fstat source", "lstat",
        "lstat output", "open archive", "open clone", "open output",
        "open source", "pread appended", "pread archive", "pwrite archive",
        "random", "read", "read LHA spool", "read ZipCrypto spool",
        "read quarantine", "read quarantine size", "readlink", "restore quarantine",
        "seek ZipCrypto spool", "source flags", "unlink LHA spool", "unlink ZipCrypto spool",
        "write ZipCrypto spool",
        "future internal operation /private/source.zip"
    ]

    func testEveryWriterIOOperationUsesTheSameOutOfSpaceMessage() {
        let expected = ArchiveErrorText.describe(CocoaError(.fileWriteOutOfSpace))
        for operation in Self.writerIOOperations {
            for code in [ENOSPC, EDQUOT] {
                XCTAssertEqual(ArchiveErrorText.describe(WriterError.io(operation: operation, code: code)), expected, operation)
            }
        }
    }

    func testWriterPermissionFailuresUsePermissionMessageWithoutInternalOperations() {
        let expected = ArchiveErrorText.describe(CocoaError(.fileWriteNoPermission))
        for operation in Self.writerIOOperations {
            for code in [EPERM, EACCES, EROFS] {
                XCTAssertEqual(ArchiveErrorText.describe(WriterError.io(operation: operation, code: code)), expected, operation)
            }
        }
    }

    func testOtherWriterIOFailuresKeepTheirCauseWithoutInternalOperations() {
        for operation in Self.writerIOOperations {
            for code in [EIO, ENOENT, EMFILE, Int32(-50)] {
                let text = ArchiveErrorText.describe(WriterError.io(operation: operation, code: code))
                XCTAssertEqual(text, String(cString: strerror(code)), operation)
                XCTAssertFalse(text.contains(operation))
            }
        }
    }

    func testImmutableArchiveRefusalUsesPermissionMessageAndKeepsTypedCause() throws {
        let directory = try ArchiveTestDirectory()
        defer { withExtendedLifetime(directory) {} }
        let archive = directory.url.appendingPathComponent("locked.zip")
        let original = ReleaseReviewFixtures.zip([("keep", Data([1]))])
        try original.write(to: archive)
        guard chflags(archive.path, UInt32(UF_IMMUTABLE)) == 0 else { throw ExtractionFailure.system(errno) }
        defer { XCTAssertEqual(chflags(archive.path, 0), 0) }
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted()
        XCTAssertThrowsError(try ArchiveUpdater.open(url: archive, output: directory.url.appendingPathComponent("output.zip"))) {
            XCTAssertEqual($0 as? WriterError, .io(operation: "source flags", code: EPERM))
            XCTAssertEqual(ArchiveErrorText.describe($0), ArchiveErrorText.describe(CocoaError(.fileWriteNoPermission)))
        }
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.url.path).sorted(), before)
    }

    func testEveryRewriterErrorInJapanese() throws {
        try checkJapanese([
            (RewriterError.unrepresentable(entry: "link", reason: "symlink"), "書き直せない項目があります: link(symlink)"),
            (RewriterError.password(entry: nil), "暗号化されたアーカイブです"),
            (RewriterError.password(entry: "note.txt"), "暗号化された項目があります: note.txt"),
            (RewriterError.invalidArchive("EOCD がありません"), "アーカイブが不正です: EOCD がありません"),
            (RewriterError.invalidState, "内部状態が不正です")
        ])
    }

    func testImportWriterFailuresUseReadableTextInEveryLanguage() throws {
        let errors: [WriterError] = [.duplicatePath("x"), .sourceChanged("x"), .io(operation: "open", code: EACCES), .compression(-3)]
        for language in LocalizationAcceptance.languages {
            let bundle = try LocalizationAcceptance.bundle(language)
            for error in errors {
                let text = ArchiveErrorText.describe(error, bundle: bundle)
                XCTAssertFalse(text.isEmpty, language)
                XCTAssertNotEqual(text, String(describing: error), language)
                for raw in ["WriterError", "duplicatePath(", "sourceChanged(", "io(operation:", "compression("] {
                    XCTAssertFalse(text.contains(raw), "\(language): \(text)")
                }
            }
        }
    }

    func testEveryUpdaterErrorInJapanese() throws {
        try checkJapanese([
            (UpdaterError.editingRefused(gatekeeper: .sfxPrefix, reason: "変更できません"), "変更できません"),
            (UpdaterError.invalidArchive("EOCD がありません"), "アーカイブが不正です: EOCD がありません"),
            (UpdaterError.invalidEntryIndex(4), "項目の番号が不正です: 4"),
            (UpdaterError.nonRelocatableEntry(index: 2, name: "link", reason: "offset"), "移動できない項目があります: link(offset)"),
            (UpdaterError.reencryptionFailed(index: 2, name: "file", reason: "CRC"), "暗号化を変更できない項目があります: file(CRC)"),
            (UpdaterError.sourceChanged, "アーカイブが変更されています。開き直してください"),
            (UpdaterError.invalidState, "内部状態が不正です")
        ])
    }

    func testExistingEditAndExtractionDescriptionsArePreserved() throws {
        let edits: [ArchiveEditError] = [
            .invalidName("../note.txt"), .collision("note.txt"), .sameLocation("note.txt"),
            .destinationInsideSource("folder"), .missingFolder("missing"), .indexMismatch(3),
            .staleSelection, .archiveChanged, .conflictingSelection
        ]
        for language in ["ja", "en"] {
            let bundle = try LocalizationAcceptance.bundle(language)
            for error in edits {
                XCTAssertEqual(ArchiveErrorText.describe(error, bundle: bundle), error.errorDescription)
            }
            for error in [ExtractionFailure.refused("展開できません。"), .system(EACCES)] {
                XCTAssertEqual(ArchiveErrorText.describe(error, bundle: bundle), error.description)
            }
            let refused = UpdaterError.editingRefused(gatekeeper: .trailingData, reason: "理由は変更しません。")
            XCTAssertEqual(ArchiveErrorText.describe(refused, bundle: bundle), "理由は変更しません。")
        }
    }

    private enum UnknownError: Error { case sample }

    func testOtherErrorsUseLocalizedDescription() throws {
        let bundle = try LocalizationAcceptance.bundle("ja")
        let errors: [any Error] = [
            CocoaError(.fileReadNoPermission), POSIXError(.ENOENT), UnknownError.sample,
            NSError(domain: "ArchiveErrorTextTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "外部の説明"])
        ]
        for error in errors {
            XCTAssertEqual(ArchiveErrorText.describe(error, bundle: bundle), error.localizedDescription)
        }
    }

    func testMalformedArchiveAndCapabilityNoticeDoNotExposeEnumDumps() throws {
        let bundle = try LocalizationAcceptance.bundle("ja")
        let text = ArchiveErrorText.describe(KaitoError.malformed("EOCD がありません"), bundle: bundle)
        XCTAssertFalse(text.contains("malformed("))
        XCTAssertFalse(text.contains("("))
        XCTAssertFalse(text.contains("\""))
        let reason = ArchiveErrorText.describe(RewriterError.invalidArchive("EOCD がありません"), bundle: bundle)
        let notice = try XCTUnwrap(ArchiveCapabilities(refusal: .unavailable(reason)).readOnlyReason)
        XCTAssertTrue(notice.contains("EOCD がありません"))
        XCTAssertFalse(notice.contains("invalidArchive"))
    }

    func testEnglishRenderingAndCallerPunctuation() throws {
        let bundle = try LocalizationAcceptance.bundle("en")
        let cases: [(any Error, String)] = [
            (CancellationError(), "Cancelled"),
            (KaitoError.unsupportedMethod("zstd"), "This compression method isn’t supported: zstd"),
            (KaitoError.checksumMismatch(entry: 3), "The checksum for item 3 doesn’t match"),
            (WriterError.compression(-3), "Compression failed (code -3)"),
            (RewriterError.invalidArchive("missing EOCD"), "The archive is invalid: missing EOCD"),
            (UpdaterError.reencryptionFailed(index: 0, name: "file", reason: "CRC"), "An item’s encryption cannot be changed: file (CRC)"),
            (UpdaterError.sourceChanged, "The archive has changed. Please reopen it")
        ]
        for (error, expected) in cases {
            let text = ArchiveErrorText.describe(error, bundle: bundle)
            XCTAssertEqual(text, expected)
            XCTAssertEqual(ArchiveAlertText.informativeText(text, bundle: bundle), expected + ".")
        }
    }

    func testAllErrorTextKeysHaveTwentySixTranslations() throws {
        let source = try String(contentsOf: LocalizationAcceptance.root.appendingPathComponent("KaitoFinder/UI/ArchiveErrorText.swift"),
                                encoding: .utf8)
        let catalog = try LocalizationAcceptance.catalog()
        let literals = try NSRegularExpression(pattern: #"String\(localized:\s*"((?:\\.|[^"\\])*)""#)
        let interpolation = try NSRegularExpression(pattern: #"\\\((?:[^()]|\([^()]*\))*\)"#)
        for match in literals.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            let literal = String(source[try XCTUnwrap(Range(match.range(at: 1), in: source))])
            let normalized = interpolation.stringByReplacingMatches(in: literal,
                range: NSRange(literal.startIndex..., in: literal), withTemplate: "%")
            let entry = try XCTUnwrap(catalog.strings.first {
                $0.key.replacingOccurrences(of: #"%(?:\d+\$)?(?:lld|d|@)"#, with: "%", options: .regularExpression) == normalized
            }?.value, literal)
            for language in LocalizationAcceptance.languages {
                let value = try XCTUnwrap(entry.localizations[language], "\(language): \(literal)").stringUnit.value
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    func testUserFacingCallSitesDoNotDescribeErrorEnumsDirectly() throws {
        let sources = [
            "UI/ArchiveCreationController.swift", "UI/ArchiveWindowController.swift", "Model/ArchiveCapabilities.swift",
            "Model/ArchiveMaterializationController.swift", "Import/ArchiveIncomingFiles.swift", "Extraction/ExtractionService.swift",
            "Extraction/ArchiveBatchExtraction.swift", "Import/ArchiveImportPlan.swift", "Import/ArchiveImportTransaction.swift",
            "Creation/ArchiveCreationTransaction.swift"
        ]
        for path in sources {
            let source = try String(contentsOf: LocalizationAcceptance.root.appendingPathComponent("KaitoFinder/" + path), encoding: .utf8)
            for line in source.split(separator: "\n") where !line.contains("NSLog(") {
                XCTAssertFalse(line.contains("String(describing: error)"), "\(path): \(line)")
                XCTAssertFalse(line.contains(#"\(error)"#), "\(path): \(line)")
            }
        }
    }
}
