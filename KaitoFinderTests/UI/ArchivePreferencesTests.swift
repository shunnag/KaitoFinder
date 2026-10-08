import Foundation
import GyoshukuKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePreferencesTests: XCTestCase {
    @MainActor func testListSizesPersistAndInvalidValuesUseDefaults() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        XCTAssertEqual(store.preferences.listIconSize, .small)
        XCTAssertEqual(store.preferences.listTextSize, 13)
        XCTAssertEqual(ArchivePreferences.ListIconSize.small.pointSize, 16)
        XCTAssertEqual(ArchivePreferences.ListIconSize.large.pointSize, 32)
        for icon in ArchivePreferences.ListIconSize.allCases {
            for size in ArchivePreferences.listTextSizeRange {
                store.preferences.listIconSize = icon
                store.preferences.listTextSize = size
                let reopened = ArchivePreferencesStore(defaults: suite.defaults)
                XCTAssertEqual(reopened.preferences.listIconSize, icon)
                XCTAssertEqual(reopened.preferences.listTextSize, size)
                XCTAssertEqual(suite.defaults.string(forKey: "ArchiveListIconSize"), icon.rawValue)
                XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveListTextSize"), size)
            }
        }
        for value: Any in ["huge", 32, true, Data([0])] {
            suite.defaults.set(value, forKey: "ArchiveListIconSize")
            XCTAssertEqual(store.preferences.listIconSize, .small)
        }
        for value: Any in [9, 17, -1, 13.5, "13", true, Data([0])] {
            suite.defaults.set(value, forKey: "ArchiveListTextSize")
            XCTAssertEqual(store.preferences.listTextSize, 13)
        }
        for value in [9, 17, Int.max, Int.min] {
            store.preferences.listTextSize = value
            XCTAssertEqual(store.preferences.listTextSize, 13)
        }
    }

    @MainActor func testFolderOpeningPersistsAndUnknownValuesUseEnter() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        for mode in ArchivePreferences.FolderOpening.allCases {
            store.preferences.folderOpening = mode
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveFolderOpening"), mode.rawValue)
            XCTAssertEqual(ArchivePreferencesStore(defaults: suite.defaults).preferences.folderOpening, mode)
        }
        for value: Any in ["unknown", 17, true, Data([0])] {
            suite.defaults.set(value, forKey: "ArchiveFolderOpening")
            XCTAssertEqual(store.preferences.folderOpening, .enter)
        }
    }

    @MainActor func testEmptyStoreUsesDefaults() throws {
        let suite = try ArchivePreferencesTestDefaults()
        let value = ArchivePreferencesStore(defaults: suite.defaults).preferences
        XCTAssertEqual(value.defaultFormat, .zip)
        XCTAssertEqual(value.compressionThreads, 0)
        XCTAssertEqual(value.powerPolicy, .reduceInLowPowerMode)
        XCTAssertEqual(value.zipMethod, .deflate)
        XCTAssertEqual(value.zipLevel, 6)
        XCTAssertTrue(value.zipSkipsCompressedTypes)
        XCTAssertEqual(value.tarGzipLevel, 6)
        XCTAssertEqual(value.tarBzip2Level, 9)
        XCTAssertFalse(value.tarPreservesOwnerIDs)
        XCTAssertEqual(value.additionPosition, .end)
        XCTAssertEqual(value.tarCarriedOwnerIDs, .keep)
        XCTAssertEqual(value.extractionDestination, .sameFolder)
        XCTAssertEqual(value.folderPolicy, .whenMultipleTopLevelItems)
        XCTAssertFalse(value.trashesArchiveAfterExtraction)
        XCTAssertFalse(value.revealsExtractedItemsInFinder)
        XCTAssertFalse(value.keepsFoldersOnTop)
        XCTAssertFalse(value.showsHiddenFiles)
        XCTAssertTrue(value.showsWelcomeWindowAtLaunch)
        XCTAssertTrue(value.renamesOnClick)
        XCTAssertEqual(value.openingBehavior, .system)
        XCTAssertEqual(value.folderOpening, .enter)
        XCTAssertEqual(value.saveBehavior, .immediate)
        XCTAssertTrue(value.excludesDSStore)
        XCTAssertFalse(value.excludesHiddenFiles)
        XCTAssertTrue(suite.defaults.persistentDomain(forName: suite.name)?.isEmpty ?? true)
    }

    @MainActor func testStoreRoundTripsEveryField() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        for (index, format) in ArchivePreferences.formats.enumerated() {
            let value = ArchivePreferences(defaultFormat: format, compressionThreads: index, powerPolicy: ArchivePreferences.PowerPolicy.allCases[index % 3], zipMethod: index.isMultiple(of: 2) ? .stored : .deflate,
                                           zipLevel: 1 + index % 9, zipSkipsCompressedTypes: !index.isMultiple(of: 2),
                                           tarGzipLevel: 9 - index % 9, tarBzip2Level: 1 + index % 9, tarPreservesOwnerIDs: index.isMultiple(of: 2),
                                           extractionDestination: index.isMultiple(of: 2) ? .ask : .sameFolder,
                                           folderPolicy: [.always, .whenMultipleTopLevelItems, .never][index % 3],
                                           trashesArchiveAfterExtraction: index.isMultiple(of: 2),
                                           revealsExtractedItemsInFinder: !index.isMultiple(of: 2),
                                           keepsFoldersOnTop: !index.isMultiple(of: 2),
                                           showsHiddenFiles: index.isMultiple(of: 2),
                                           showsWelcomeWindowAtLaunch: !index.isMultiple(of: 2),
                                           renamesOnClick: index.isMultiple(of: 2),
                                           saveBehavior: index.isMultiple(of: 2) ? .onSave : .immediate,
                                           openingBehavior: ArchivePreferences.OpeningBehavior.allCases[index % 3],
                                           excludesDSStore: !index.isMultiple(of: 2), excludesHiddenFiles: index.isMultiple(of: 2))
            store.preferences = value
            let reopened = ArchivePreferencesStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite.name)))
            XCTAssertEqual(reopened.preferences, value)
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveCreationFormat"), ArchiveCreationPlan.filenameExtension(for: format))
            XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveCompressionThreads"), value.compressionThreads)
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveZipMethod"), value.zipMethod.rawValue)
            XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveZipLevel"), value.zipLevel)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveZipSkipsCompressedTypes"), value.zipSkipsCompressedTypes)
            XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveTarGzipLevel"), value.tarGzipLevel)
            XCTAssertEqual(suite.defaults.integer(forKey: "ArchiveTarBzip2Level"), value.tarBzip2Level)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveTarPreservesOwnerIDs"), value.tarPreservesOwnerIDs)
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveExtractionDestination"), value.extractionDestination.rawValue)
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveFolderPolicy"), value.folderPolicy.rawValue)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveTrashesArchiveAfterExtraction"), value.trashesArchiveAfterExtraction)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveRevealsExtractedItems"), value.revealsExtractedItemsInFinder)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveShowsHiddenFiles"), value.showsHiddenFiles)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveShowsWelcomeAtLaunch"), value.showsWelcomeWindowAtLaunch)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveRenamesOnClick"), value.renamesOnClick)
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveSaveBehavior"), value.saveBehavior.rawValue)
            XCTAssertEqual(suite.defaults.string(forKey: "ArchiveOpeningBehavior"), value.openingBehavior.rawValue)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveExcludesDSStore"), value.excludesDSStore)
            XCTAssertEqual(suite.defaults.bool(forKey: "ArchiveExcludesHiddenFiles"), value.excludesHiddenFiles)
        }
    }

    @MainActor func testInvalidStoredValuesFallBackToDefaults() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let corrupt: [String: Any] = [
            "ArchiveCreationFormat": "rar", "ArchiveZipMethod": "unknown", "ArchiveZipLevel": 42,
            "ArchiveZipSkipsCompressedTypes": "broken", "ArchiveTarGzipLevel": -1,
            "ArchiveTarPreservesOwnerIDs": "yes", "ArchiveExtractionDestination": "desktop",
            "ArchiveFolderPolicy": "sometimes", "ArchiveTrashesArchiveAfterExtraction": Data([0xff]),
            "ArchiveRevealsExtractedItems": "true", "ArchiveShowsHiddenFiles": "broken", "ArchiveShowsWelcomeAtLaunch": "broken",
            "ArchiveExcludesDSStore": "broken", "ArchiveExcludesHiddenFiles": "broken", "ArchiveOpeningBehavior": "replace",
            "ArchiveRenamesOnClick": "false", "ArchiveSaveBehavior": "sometimes", "ArchiveFolderOpening": "unknown"
        ]
        for (key, value) in corrupt { suite.defaults.set(value, forKey: key) }
        XCTAssertEqual(store.preferences, ArchivePreferences())
        // 保存済みの不正値は既定に戻す。スライダーの入力を丸める規則とは別に検証する。
        let invalidValues: [Any] = [0, -10, 42, 2.5, "9", "broken", true, Date(), Data([0])]
        for invalid in invalidValues {
            for key in ["ArchiveZipLevel", "ArchiveTarGzipLevel", "ArchiveTarBzip2Level"] { suite.defaults.set(invalid, forKey: key) }
            XCTAssertEqual(store.preferences.zipLevel, 6, "\(invalid)")
            XCTAssertEqual(store.preferences.tarGzipLevel, 6, "\(invalid)")
            XCTAssertEqual(store.preferences.tarBzip2Level, 9, "\(invalid)")
        }
        for level in 1...9 {
            suite.defaults.set(level, forKey: "ArchiveZipLevel")
            suite.defaults.set(level, forKey: "ArchiveTarGzipLevel")
            suite.defaults.set(level, forKey: "ArchiveTarBzip2Level")
            XCTAssertEqual(store.preferences.zipLevel, level)
            XCTAssertEqual(store.preferences.tarGzipLevel, level)
            XCTAssertEqual(store.preferences.tarBzip2Level, level)
        }
    }

    @MainActor func testCompressionThreadsRoundTripAndRejectInvalidValues() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let key = ArchivePreferencesStore.Key.compressionThreads
        XCTAssertEqual(key, "ArchiveCompressionThreads")
        XCTAssertEqual(ArchivePreferences.compressionThreadRange, WriterOptions.compressionThreadsRange)
        XCTAssertEqual(store.preferences.compressionThreads, 0)
        for threads in [0, 1, 7, 18, 36, 65, WriterOptions.compressionThreadsRange.upperBound] {
            store.preferences.compressionThreads = threads
            XCTAssertEqual(ArchivePreferencesStore(defaults: suite.defaults).preferences.compressionThreads, threads)
            XCTAssertEqual(suite.defaults.integer(forKey: key), threads)
        }
        let invalidValues: [Any] = [WriterOptions.compressionThreadsRange.upperBound + 1, -1, true, false, 1.5, "7", "broken", Date(), Data([0]), Int.max, Int.min]
        for invalid in invalidValues {
            suite.defaults.set(invalid, forKey: key)
            XCTAssertEqual(store.preferences.compressionThreads, 0, "\(invalid)")
        }
        suite.defaults.removeObject(forKey: key)
        XCTAssertEqual(store.preferences.compressionThreads, 0)
        suite.defaults.set(NSNumber(value: 7.0), forKey: key)
        XCTAssertEqual(store.preferences.compressionThreads, 7)
        for invalid in [-1, WriterOptions.compressionThreadsRange.upperBound + 1, Int.min, Int.max] {
            store.preferences.compressionThreads = invalid
            XCTAssertEqual(store.preferences.compressionThreads, 0)
            XCTAssertEqual(suite.defaults.integer(forKey: key), 0)
        }
    }

    @MainActor func testPowerPolicyPersistsAndInvalidValuesUseLowPowerDefault() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let key = ArchivePreferencesStore.Key.powerPolicy
        XCTAssertEqual(key, "ArchiveCompressionPowerPolicy")
        XCTAssertEqual(store.preferences.powerPolicy, .reduceInLowPowerMode)
        for policy in ArchivePreferences.PowerPolicy.allCases {
            store.preferences.powerPolicy = policy
            let reopened = ArchivePreferencesStore(defaults: suite.defaults).preferences
            XCTAssertEqual(reopened.powerPolicy, policy)
            XCTAssertEqual(suite.defaults.string(forKey: key), policy.rawValue)
            for format in ArchivePreferences.formats {
                XCTAssertEqual(reopened.writerOptions(for: format).powerPolicy, policy.writerPolicy)
                XCTAssertNil(reopened.writerOptions(for: format).compressionThreads)
            }
        }
        for invalid: Any in ["unknown", 7, true, Data([0])] {
            suite.defaults.set(invalid, forKey: key)
            XCTAssertEqual(store.preferences.powerPolicy, .reduceInLowPowerMode)
        }
        suite.defaults.removeObject(forKey: key)
        XCTAssertEqual(store.preferences.powerPolicy, .reduceInLowPowerMode)
    }

    @MainActor func testStorePostsDidChangeSynchronouslyAfterSaving() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let calls = Mutex(0)
        let suiteName = suite.name
        let value = ArchivePreferences(defaultFormat: .tarGzip, compressionThreads: 7, zipMethod: .stored, zipLevel: 9,
                                       zipSkipsCompressedTypes: false, tarGzipLevel: 1, tarPreservesOwnerIDs: true,
                                       extractionDestination: .ask, folderPolicy: .never, trashesArchiveAfterExtraction: true,
                                       revealsExtractedItemsInFinder: true)
        XCTAssertEqual(ArchivePreferencesStore.didChange.rawValue, "ArchivePreferencesDidChange")
        let token = NotificationCenter.default.addObserver(forName: ArchivePreferencesStore.didChange,
                                                           object: store, queue: nil) { notification in
            XCTAssertTrue(notification.object as AnyObject? === store)
            MainActor.assumeIsolated {
                let defaults = UserDefaults(suiteName: suiteName)!
                XCTAssertEqual(defaults.integer(forKey: "ArchiveCompressionThreads"), 7)
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
        XCTAssertEqual(actual.bzip2Level, expected.bzip2Level, file: file, line: line)
        XCTAssertEqual(actual.useCompressionHeuristic, expected.useCompressionHeuristic, file: file, line: line)
        XCTAssertEqual(actual.additionPlacement, expected.additionPlacement, file: file, line: line)
        XCTAssertEqual(actual.carriedTarOwnerIDs, expected.carriedTarOwnerIDs, file: file, line: line)
        XCTAssertEqual(actual.preserveOwnerIDs, expected.preserveOwnerIDs, file: file, line: line)
        XCTAssertEqual(actual.preserveMacOSMetadata, expected.preserveMacOSMetadata, file: file, line: line)
        XCTAssertEqual(actual.compressionThreads, expected.compressionThreads, file: file, line: line)
        XCTAssertEqual(actual.powerPolicy, expected.powerPolicy, file: file, line: line)
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
        store.preferences.tarBzip2Level = 8
        for owners in [false, true] {
            store.preferences.tarPreservesOwnerIDs = owners
            assertOptions(store.preferences.writerOptions(for: .tarGzip), WriterOptions(deflateLevel: 1, preserveOwnerIDs: owners))
            assertOptions(store.preferences.writerOptions(for: .tar), WriterOptions(preserveOwnerIDs: owners))
            assertOptions(store.preferences.writerOptions(for: .tarXZ), WriterOptions(preserveOwnerIDs: owners))
            assertOptions(store.preferences.writerOptions(for: .tarBzip2), WriterOptions(bzip2Level: 8, preserveOwnerIDs: owners))
            assertOptions(store.preferences.writerOptions(for: .zip), WriterOptions(deflateLevel: 9, useCompressionHeuristic: false))
            for format in [GyoshukuKit.ArchiveFormat.sevenZip, .lha] {
                assertOptions(store.preferences.writerOptions(for: format), WriterOptions())
            }
        }
    }
}
