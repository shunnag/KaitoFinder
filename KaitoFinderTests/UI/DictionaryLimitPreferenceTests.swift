import AppKit
import CryptoKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class DictionaryLimitPreferenceTests: XCTestCase {
    @MainActor func testDictionaryLimitPersistsAndRejectsInvalidValues() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        XCTAssertEqual(store.preferences.dictionaryLimitGiB, 1)
        XCTAssertEqual(ArchivePreferencesStore.Key.dictionaryLimit, "ArchiveExtractionDictionaryLimitGiB")
        for value in ArchivePreferences.dictionaryLimitChoices {
            store.preferences.dictionaryLimitGiB = value
            XCTAssertEqual(ArchivePreferencesStore(defaults: suite.defaults).preferences.dictionaryLimitGiB, value)
            XCTAssertEqual(suite.defaults.integer(forKey: ArchivePreferencesStore.Key.dictionaryLimit), value)
        }
        for value in [0, 2, 4, 16, Int.max, Int.min] {
            store.preferences.dictionaryLimitGiB = value
            XCTAssertEqual(store.preferences.dictionaryLimitGiB, 1)
        }
        for value: Any in [0, 2, 4, 16, true, false, 1.5, "8", Data([0])] {
            suite.defaults.set(value, forKey: ArchivePreferencesStore.Key.dictionaryLimit)
            XCTAssertEqual(store.preferences.dictionaryLimitGiB, 1, "\(value)")
            XCTAssertEqual(ArchivePreferencesStore.storedDictionaryLimitGiB(defaults: suite.defaults), 1)
        }
    }

    func testReaderOptionsApplyLargeDictionaryOnlyWithEnoughPhysicalMemory() throws {
        let suite = try ArchivePreferencesTestDefaults()
        suite.defaults.set(8, forKey: ArchivePreferencesStore.Key.dictionaryLimit)
        for memory in [UInt64(16) << 30, UInt64(31) << 30, UInt64(32) << 30, UInt64(128) << 30] {
            let hardware = ArchiveHardware(processors: 8, memory: memory, automaticThreads: 8)
            let expected = memory < 32 << 30 ? ArchivePreferences.defaultDictionarySize : UInt64(8) << 30
            XCTAssertEqual(ArchivePreferencesStore.effectiveDictionarySize(defaults: suite.defaults, hardware: hardware), expected)
            for options in [ReaderOptions.kaitoFinder(defaults: suite.defaults, hardware: hardware),
                            ReaderOptions.kaitoFinderVerification(defaults: suite.defaults, hardware: hardware)] {
                XCTAssertEqual(options.limits.maxDictionarySize, expected, "memory=\(memory)")
                XCTAssertEqual(options.limits.maxEntrySize, .max)
                XCTAssertEqual(options.limits.maxTotalUncompressedSize, .max)
            }
        }
        suite.defaults.removeObject(forKey: ArchivePreferencesStore.Key.dictionaryLimit)
        let hardware = ArchiveHardware(processors: 8, memory: 128 << 30, automaticThreads: 8)
        XCTAssertEqual(ReaderOptions.kaitoFinder(defaults: suite.defaults, hardware: hardware).limits.maxDictionarySize,
                       ArchivePreferences.defaultDictionarySize)
    }

    @MainActor func testDictionaryLimitPopupUsesHardwareAndPersistsSelection() throws {
        _ = NSApplication.shared
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.dictionaryLimitGiB = 8
        let small = PreferencesViewModel(store: store, hardware: .init(processors: 8, memory: 16 << 30, automaticThreads: 8))
        XCTAssertEqual(small.dictionaryLimitTitles, ["1 GiB"])
        XCTAssertEqual(small.dictionaryLimitIndex, 0)
        small.selectDictionaryLimit(at: 1)
        XCTAssertEqual(small.dictionaryLimitIndex, 0)

        let hardware = ArchiveHardware(processors: 8, memory: 32 << 30, automaticThreads: 8)
        let controller = PreferencesWindowController(store: store, hardware: hardware)
        defer { controller.close() }
        XCTAssertEqual(controller.dictionaryLimitPopup.itemTitles, ["1 GiB", "8 GiB"])
        XCTAssertEqual(controller.dictionaryLimitPopup.indexOfSelectedItem, 1)
        XCTAssertEqual(controller.dictionaryLimitPopup.accessibilityLabel(), String(localized: "展開の辞書上限:"))
        XCTAssertEqual(controller.dictionaryLimitPopup.toolTip, controller.viewModel.dictionaryLimitNote)
        controller.dictionaryLimitPopup.selectItem(at: 0)
        XCTAssertTrue(controller.dictionaryLimitPopup.sendAction(controller.dictionaryLimitPopup.action,
                                                                 to: controller.dictionaryLimitPopup.target))
        XCTAssertEqual(store.preferences.dictionaryLimitGiB, 1)
        store.preferences.dictionaryLimitGiB = 8
        XCTAssertEqual(controller.dictionaryLimitPopup.indexOfSelectedItem, 1)
        controller.viewModel.selectDictionaryLimit(at: -1)
        controller.viewModel.selectDictionaryLimit(at: 2)
        XCTAssertEqual(store.preferences.dictionaryLimitGiB, 8)
    }

    func testLargeDictionaryForcesExtractionAndPasswordVerificationSerial() throws {
        let fixture = try ScenarioFixture(script: ScenarioFixture.zipScript(count: 80, size: 131072))
        let entries = try ArchiveReader.open(url: fixture.archive).entries
        let hardware = ArchiveHardware(processors: 8, memory: 128 << 30, automaticThreads: 8)
        XCTAssertEqual(ExtractionExecution.automatic.workerCount(entries: entries, hasSources: false, hardware: hardware), 8)
        XCTAssertEqual(ExtractionExecution.automatic.workerCount(entries: entries, hasSources: false, hardware: hardware,
                                                                 dictionarySize: UInt64(8) << 30), 1)
        XCTAssertEqual(ExtractionExecution.parallel(workers: 8).workerCount(entries: entries, hasSources: false,
                                                                            dictionarySize: UInt64(8) << 30), 1)
        XCTAssertEqual(ArchivePasswordVerification.workerCount(entries: entries, requested: 8, hasPassword: true), 8)
        XCTAssertEqual(ArchivePasswordVerification.workerCount(entries: entries, requested: 8, hasPassword: true,
                                                               dictionarySize: UInt64(8) << 30), 1)
    }

    func testActualRAR5VersionOneUsesConfiguredDictionaryLimit() throws {
        guard ArchiveHardware.current.dictionaryLimitChoices.contains(8) else {
            throw XCTSkip("requires at least 32 GiB of physical memory")
        }
        guard let path = TestEnvironment.value(.rar5Version1Archive),
              let expectedSHA256 = TestEnvironment.value(.rar5Version1SHA256) else {
            throw XCTSkip("set KAITOFINDER_RAR5_V1_ARCHIVE and KAITOFINDER_RAR5_V1_SHA256")
        }
        let suite = try ArchivePreferencesTestDefaults()
        suite.defaults.set(8, forKey: ArchivePreferencesStore.Key.dictionaryLimit)
        let options = ReaderOptions.kaitoFinder(defaults: suite.defaults)
        XCTAssertEqual(options.limits.maxDictionarySize, UInt64(8) << 30)
        let reader = try ArchiveReader.open(url: URL(fileURLWithPath: path), options: options)
        let entry = try XCTUnwrap(reader.entries.first { $0.kind == .file })
        let stream = try reader.stream(entry)
        var hash = SHA256()
        var count: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let read = try buffer.withUnsafeMutableBytes { storage in
                try stream.read(into: storage)
            }
            if read == 0 { break }
            buffer.withUnsafeBytes { storage in
                hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: storage[..<read]))
            }
            count += UInt64(read)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(count, 5 << 30)
        XCTAssertEqual(digest, expectedSHA256.lowercased())
        print("KAITOFINDER-RAR5-V1 bytes=\(count) sha256=\(digest)")
    }
}
