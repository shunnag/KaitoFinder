import Foundation
import GyoshukuKit
import Synchronization
import XCTest
@testable import KaitoFinder

/// 各テスト専用の永続ドメインを使い、実際の利用者の設定を変更しない。
nonisolated final class ArchivePreferencesTestDefaults {
    let name = "KaitoFinder-PreferencesTests-" + UUID().uuidString
    let defaults: UserDefaults
    init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: name)) }
    deinit { defaults.removePersistentDomain(forName: name) }
}

nonisolated final class ArchivePreferencesTests: XCTestCase {
    @MainActor func testEmptyStoreUsesDefaults() throws {
        let suite = try ArchivePreferencesTestDefaults()
        let value = ArchivePreferencesStore(defaults: suite.defaults).preferences
        XCTAssertEqual(value.defaultFormat, .zip)
        XCTAssertEqual(value.zipMethod, .deflate)
        XCTAssertEqual(value.zipLevel, 6)
        XCTAssertTrue(value.zipSkipsCompressedTypes)
        XCTAssertEqual(value.tarGzipLevel, 6)
        XCTAssertFalse(value.tarPreservesOwnerIDs)
        XCTAssertEqual(value.extractionDestination, .sameFolder)
        XCTAssertEqual(value.folderPolicy, .whenMultipleTopLevelItems)
        XCTAssertFalse(value.trashesArchiveAfterExtraction)
        XCTAssertFalse(value.revealsExtractedItemsInFinder)
        XCTAssertFalse(value.showsHiddenFiles)
        XCTAssertTrue(value.showsWelcomeWindowAtLaunch)
        XCTAssertEqual(value.openingBehavior, .system)
        XCTAssertTrue(value.excludesDSStore)
        XCTAssertFalse(value.excludesHiddenFiles)
        XCTAssertTrue(suite.defaults.persistentDomain(forName: suite.name)?.isEmpty ?? true)
    }

    @MainActor func testStoreRoundTripsEveryField() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        for (index, format) in ArchivePreferences.formats.enumerated() {
            let value = ArchivePreferences(defaultFormat: format, zipMethod: index.isMultiple(of: 2) ? .stored : .deflate,
                                           zipLevel: 1 + index * 2, zipSkipsCompressedTypes: !index.isMultiple(of: 2),
                                           tarGzipLevel: 9 - index * 2, tarPreservesOwnerIDs: index.isMultiple(of: 2),
                                           extractionDestination: index.isMultiple(of: 2) ? .ask : .sameFolder,
                                           folderPolicy: [.always, .whenMultipleTopLevelItems, .never][index % 3],
                                           trashesArchiveAfterExtraction: index.isMultiple(of: 2),
                                           revealsExtractedItemsInFinder: !index.isMultiple(of: 2),
                                           showsHiddenFiles: index.isMultiple(of: 2),
                                           showsWelcomeWindowAtLaunch: !index.isMultiple(of: 2),
                                           openingBehavior: ArchivePreferences.OpeningBehavior.allCases[index % 3],
                                           excludesDSStore: !index.isMultiple(of: 2), excludesHiddenFiles: index.isMultiple(of: 2))
            store.preferences = value
            let reopened = ArchivePreferencesStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite.name)))
            XCTAssertEqual(reopened.preferences, value)
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveCreationFormat"), ["zip", "tar", "tar.gz", "7z", "lzh"][index])
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveZipMethod"), value.zipMethod.rawValue)
            XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveZipLevel"), value.zipLevel)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveZipSkipsCompressedTypes"), value.zipSkipsCompressedTypes)
            XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveTarGzipLevel"), value.tarGzipLevel)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveTarPreservesOwnerIDs"), value.tarPreservesOwnerIDs)
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveExtractionDestination"), value.extractionDestination.rawValue)
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveFolderPolicy"), value.folderPolicy.rawValue)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveTrashesArchiveAfterExtraction"), value.trashesArchiveAfterExtraction)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveRevealsExtractedItems"), value.revealsExtractedItemsInFinder)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveShowsHiddenFiles"), value.showsHiddenFiles)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveShowsWelcomeAtLaunch"), value.showsWelcomeWindowAtLaunch)
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveOpeningBehavior"), value.openingBehavior.rawValue)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveExcludesDSStore"), value.excludesDSStore)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveExcludesHiddenFiles"), value.excludesHiddenFiles)
        }
    }

    @MainActor func testInvalidStoredValuesFallBackToDefaults() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let corrupt: [String: Any] = [
            "ArchiveCreationFormat": "rar", "ArchiveZipMethod": "bzip2", "ArchiveZipLevel": 42,
            "ArchiveZipSkipsCompressedTypes": "broken", "ArchiveTarGzipLevel": -1,
            "ArchiveTarPreservesOwnerIDs": "yes", "ArchiveExtractionDestination": "desktop",
            "ArchiveFolderPolicy": "sometimes", "ArchiveTrashesArchiveAfterExtraction": Data([0xff]),
            "ArchiveRevealsExtractedItems": "true", "ArchiveShowsHiddenFiles": "broken", "ArchiveShowsWelcomeAtLaunch": "broken",
            "ArchiveExcludesDSStore": "broken", "ArchiveExcludesHiddenFiles": "broken", "ArchiveOpeningBehavior": "replace"
        ]
        for (key, value) in corrupt { suite.defaults.set(value, forKey: key) }
        XCTAssertEqual(store.preferences, ArchivePreferences())
        // 保存済みの不正値は既定に戻す。スライダーの入力を丸める規則とは別に検証する。
        let invalidValues: [Any] = [0, -10, 42, 2.5, "9", "broken", true, Date(), Data([0])]
        for invalid in invalidValues {
            for key in ["ArchiveZipLevel", "ArchiveTarGzipLevel"] { suite.defaults.set(invalid, forKey: key) }
            XCTAssertEqual(store.preferences.zipLevel, 6, "\(invalid)")
            XCTAssertEqual(store.preferences.tarGzipLevel, 6, "\(invalid)")
        }
        for level in 1...9 {
            suite.defaults.set(level, forKey: "ArchiveZipLevel")
            suite.defaults.set(level, forKey: "ArchiveTarGzipLevel")
            XCTAssertEqual(store.preferences.zipLevel, level)
            XCTAssertEqual(store.preferences.tarGzipLevel, level)
        }
    }

    @MainActor func testStorePostsDidChangeSynchronouslyAfterSaving() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let calls = Mutex(0)
        let suiteName = suite.name
        let value = ArchivePreferences(defaultFormat: .tarGzip, zipMethod: .stored, zipLevel: 9,
                                       zipSkipsCompressedTypes: false, tarGzipLevel: 1, tarPreservesOwnerIDs: true,
                                       extractionDestination: .ask, folderPolicy: .never, trashesArchiveAfterExtraction: true,
                                       revealsExtractedItemsInFinder: true)
        XCTAssertEqual(ArchivePreferencesStore.didChange.rawValue, "ArchivePreferencesDidChange")
        let token = NotificationCenter.default.addObserver(forName: ArchivePreferencesStore.didChange,
                                                           object: store, queue: nil) { notification in
            XCTAssertTrue(notification.object as AnyObject? === store)
            MainActor.assumeIsolated {
                let defaults = UserDefaults(suiteName: suiteName)!
                XCTAssertEqual(ArchivePreferencesStore(defaults: defaults).preferences, value)
            }
            calls.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        store.preferences = value
        XCTAssertEqual(calls.withLock { $0 }, 1)
        store.preferences = value
        XCTAssertEqual(calls.withLock { $0 }, 2)
    }

    private func assertOptions(_ actual: WriterOptions, _ expected: WriterOptions,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.compressionMethod, expected.compressionMethod, file: file, line: line)
        XCTAssertEqual(actual.deflateLevel, expected.deflateLevel, file: file, line: line)
        XCTAssertEqual(actual.useCompressionHeuristic, expected.useCompressionHeuristic, file: file, line: line)
        XCTAssertEqual(actual.preserveOwnerIDs, expected.preserveOwnerIDs, file: file, line: line)
        XCTAssertEqual(actual.preserveMacOSMetadata, expected.preserveMacOSMetadata, file: file, line: line)
    }

    @MainActor func testWriterOptionsMatchEachFormatAndKeepFixedEncodersDefault() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.zipMethod = .stored
        for heuristic in [true, false] {
            store.preferences.zipSkipsCompressedTypes = heuristic
            assertOptions(store.preferences.writerOptions(for: .zip),
                          WriterOptions(compressionMethod: .stored, useCompressionHeuristic: heuristic))
        }
        store.preferences.zipMethod = .deflate
        store.preferences.zipLevel = 9
        assertOptions(store.preferences.writerOptions(for: .zip), WriterOptions(deflateLevel: 9, useCompressionHeuristic: false))
        store.preferences.tarGzipLevel = 1
        for owners in [false, true] {
            store.preferences.tarPreservesOwnerIDs = owners
            assertOptions(store.preferences.writerOptions(for: .tarGzip), WriterOptions(deflateLevel: 1, preserveOwnerIDs: owners))
            assertOptions(store.preferences.writerOptions(for: .tar), WriterOptions(preserveOwnerIDs: owners))
            assertOptions(store.preferences.writerOptions(for: .zip), WriterOptions(deflateLevel: 9, useCompressionHeuristic: false))
            for format in [GyoshukuKit.ArchiveFormat.sevenZip, .lha] {
                assertOptions(store.preferences.writerOptions(for: format), WriterOptions())
            }
        }
    }
}
