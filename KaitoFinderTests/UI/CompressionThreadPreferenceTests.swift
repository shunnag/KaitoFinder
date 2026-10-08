import Foundation
@testable import GyoshukuKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class CompressionThreadPreferenceTests: XCTestCase {
    func testAutomaticThreadsAndMemoryEstimates() {
        for expected in [1, 18, 36, 72, 128] {
            let hardware = ArchiveHardware(processors: expected, memory: 128 << 30, automaticThreads: expected)
            XCTAssertEqual(hardware.automaticCompressionThreads(), expected)
            WriterOptions.$testingAutomaticThreads.withValue({ _ in expected }) {
                XCTAssertEqual(ArchiveHardware.current.automaticCompressionThreads(), expected)
            }
        }
        for (threads, memoryMiB) in [(1, 165), (2, 300), (4, 570), (8, 1110), (16, 2190)] {
            XCTAssertEqual(ArchiveHardware.estimatedLZMA2Memory(threads: threads), UInt64(memoryMiB) << 20)
        }
    }

    @MainActor func testAutomaticTitleAndPowerPolicySelectionWithoutWindow() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let policies = ArchivePreferences.PowerPolicy.allCases
        for language in ["ja", "en"] {
            let bundle = try LocalizationAcceptance.bundle(language)
            let model = PreferencesViewModel(store: store,
                hardware: .init(processors: 36, memory: 128 << 30), bundle: bundle)
            for (index, policy) in policies.enumerated() {
                model.selectPowerPolicy(at: index)
                XCTAssertEqual(model.powerPolicyIndex, index)
                XCTAssertEqual(store.preferences.powerPolicy, policy)
                let expected = [18, 9, 36][index]
                WriterOptions.$testingAutomaticThreads.withValue({ actual in
                    XCTAssertEqual(actual, policy.writerPolicy)
                    return expected
                }) {
                    XCTAssertEqual(model.compressionThreadTitles[0], language == "ja" ? "自動（\(expected)）" : "Automatic (\(expected))")
                    XCTAssertTrue(model.memoryNote.text.contains(ByteCountFormatter.string(
                        fromByteCount: Int64(ArchiveHardware.estimatedLZMA2Memory(threads: expected)), countStyle: .memory)))
                }
            }
            XCTAssertEqual(model.powerPolicyTitles, language == "ja"
                ? ["低電力モードで並列数を減らす", "低電力モードや高温時に並列数を減らす", "常にすべてのコアを使う"]
                : ["Reduce threads in Low Power Mode", "Reduce threads in Low Power Mode or when hot", "Always use all cores"])
            let before = store.preferences
            model.selectPowerPolicy(at: -1)
            model.selectPowerPolicy(at: policies.count)
            XCTAssertEqual(store.preferences, before)
        }
        for (processors, saved) in [(18, 0), (36, 0), (72, 128), (36, 1024)] {
            store.preferences.compressionThreads = saved
            let model = PreferencesViewModel(store: store,
                hardware: .init(processors: processors, memory: 128 << 30, automaticThreads: processors))
            XCTAssertEqual(model.compressionThreadChoices, Array(0...max(processors, saved)))
            XCTAssertEqual(model.compressionThreadIndex, saved)
            model.selectCompressionThreads(at: processors)
            XCTAssertEqual(store.preferences.compressionThreads, processors)
        }
    }

    func testPowerPolicyCatalogHasSettingsTranslations() throws {
        let catalog = try LocalizationAcceptance.catalog()
        for key in ["電力の使用方針:", "低電力モードで並列数を減らす", "低電力モードや高温時に並列数を減らす", "常にすべてのコアを使う"] {
            let entry = try XCTUnwrap(catalog.strings[key])
            for language in LocalizationAcceptance.languages {
                let unit = try XCTUnwrap(entry.localizations[language]?.stringUnit)
                XCTAssertEqual(unit.state, "translated")
                XCTAssertFalse(unit.value.isEmpty)
                if language == "ja" { XCTAssertEqual(unit.value, key) }
            }
        }
    }

    func testAllThirteenFormatsOnlyChangeCompressionThreads() {
        for position in ArchivePreferences.AdditionPosition.allCases {
            for owners in ArchivePreferences.CarriedOwnerIDPolicy.allCases {
                for method in [ArchivePreferences.ZipMethod.deflate, .stored] {
                    var preferences = ArchivePreferences(zipMethod: method, zipLevel: 2, zipSkipsCompressedTypes: false,
                        tarGzipLevel: 4, tarBzip2Level: 1, tarPreservesOwnerIDs: true,
                        additionPosition: position, tarCarriedOwnerIDs: owners)
                    let placement: AdditionPlacement = position == .end ? .end : .beginning
                    let carried: CarriedOwnerIDs = owners == .keep ? .keep : .reset
                    for format in ArchivePreferences.formats {
                        let expected: WriterOptions = switch format {
                        case .zip:
                            WriterOptions(compressionMethod: method == .stored ? .stored : .deflate,
                                          deflateLevel: 2, useCompressionHeuristic: false, additionPlacement: .end)
                        case .tar, .tarXZ, .tarZstd, .tarLzip, .tarLZMA, .tarLZ4, .tarBrotli, .tarCompress:
                            WriterOptions(preserveOwnerIDs: true, additionPlacement: placement, carriedTarOwnerIDs: carried)
                        case .tarGzip:
                            WriterOptions(deflateLevel: 4, preserveOwnerIDs: true,
                                          additionPlacement: placement, carriedTarOwnerIDs: carried)
                        case .tarBzip2:
                            WriterOptions(bzip2Level: 1, preserveOwnerIDs: true,
                                          additionPlacement: placement, carriedTarOwnerIDs: carried)
                        case .sevenZip, .lha:
                            WriterOptions(additionPlacement: placement)
                        }
                        for threads in [0, 3] {
                            preferences.compressionThreads = threads
                            let actual = preferences.writerOptions(for: format)
                            XCTAssertEqual(actual.compressionThreads, threads == 0 ? nil : threads)
                            XCTAssertEqual(actual.compressionMethod, expected.compressionMethod)
                            XCTAssertEqual(actual.deflateLevel, expected.deflateLevel)
                            XCTAssertEqual(actual.bzip2Level, expected.bzip2Level)
                            XCTAssertEqual(actual.useCompressionHeuristic, expected.useCompressionHeuristic)
                            XCTAssertEqual(actual.preserveOwnerIDs, expected.preserveOwnerIDs)
                            XCTAssertEqual(actual.preserveMacOSMetadata, expected.preserveMacOSMetadata)
                            XCTAssertEqual(actual.password, expected.password)
                            XCTAssertEqual(actual.zipEncryption, expected.zipEncryption)
                            XCTAssertEqual(actual.encryptsSevenZipHeaders, expected.encryptsSevenZipHeaders)
                            XCTAssertEqual(actual.additionPlacement, expected.additionPlacement)
                            XCTAssertEqual(actual.carriedTarOwnerIDs, expected.carriedTarOwnerIDs)
                        }
                    }
                }
            }
        }
    }

    @MainActor func testCreationLevelAndEncryptionKeepThreads() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let controller = ArchiveCreationController(store: store)
        let directory = try ArchiveTestDirectory()
        for threads in [0, 2, 7] {
            store.preferences.compressionThreads = threads
            store.preferences.powerPolicy = .alwaysUseAllCores
            for format in ArchivePreferences.formats {
                let encryption = ArchiveEncryptionSettings(password: format == .zip || format == .sevenZip ? "x" : nil)
                let plan = controller.creationPlan(sources: [], destination: directory.url.appendingPathComponent("output"),
                                                   format: format, level: .maximum, encryption: encryption)
                XCTAssertEqual(plan.options.compressionThreads, threads == 0 ? nil : threads)
                XCTAssertEqual(plan.options.powerPolicy, .alwaysUseAllCores)
                XCTAssertEqual(plan.options.password, encryption.password)
                if format == .zip || format == .tarGzip { XCTAssertEqual(plan.options.deflateLevel, 9) }
                if format == .tarBzip2 { XCTAssertEqual(plan.options.bzip2Level, 9) }
            }
        }
        store.preferences.compressionThreads = 2
        let passwordOptions = ArchiveEncryptionSettings(password: "x")
            .applying(to: store.preferences.writerOptions(for: .zip), format: .zip)
        XCTAssertEqual(passwordOptions.compressionThreads, 2)
        XCTAssertEqual(passwordOptions.powerPolicy, .alwaysUseAllCores)
        XCTAssertEqual(passwordOptions.password, "x")
    }

    @MainActor func testOpenDocumentsReadThreadChangesWithoutReopening() throws {
        for behavior in ArchivePreferences.SaveBehavior.allCases {
            let fixture = try DeferredSaveFixture(behavior: behavior)
            defer { fixture.document.close() }
            let session = try XCTUnwrap(fixture.document.session)
            XCTAssertNil(session.writerOptions(.zip).compressionThreads)
            fixture.store.preferences.compressionThreads = 2
            fixture.store.preferences.powerPolicy = .alwaysUseAllCores
            XCTAssertEqual(session.writerOptions(.zip).compressionThreads, 2)
            XCTAssertEqual(session.writerOptions(.zip).powerPolicy, .alwaysUseAllCores)
            fixture.store.preferences.compressionThreads = 0
            fixture.store.preferences.powerPolicy = .reduceInLowPowerModeOrThermalPressure
            XCTAssertNil(session.writerOptions(.zip).compressionThreads)
            XCTAssertEqual(session.writerOptions(.zip).powerPolicy, .reduceInLowPowerModeOrThermalPressure)
            XCTAssertTrue(fixture.document.session === session)
        }
    }

    #if DEBUG
    @MainActor func testDeferredUpdaterPreparationReceivesPowerPolicy() async throws {
        let directory = try ArchiveTestDirectory()
        let url = directory.url.appendingPathComponent("prepare.zip")
        let writer = try ArchiveWriter.create(url: url, options: .init(compressionThreads: 1))
        try writer.add(data: Data([0x5a]), as: "entry")
        try writer.finish()
        for policy in ArchivePreferences.PowerPolicy.allCases {
            let preferences = ArchivePreferences(powerPolicy: policy)
            let session = try ArchiveSession(url: url, writerOptions: { preferences.writerOptions(for: $0) })
            let policies = Mutex<[CompressionPowerPolicy]>([])
            await WriterOptions.$testingAutomaticThreads.withValue({ actual in
                policies.withLock { $0.append(actual) }
                return 36
            }) { await session.prepareDeferredEditing() }
            XCTAssertEqual(policies.withLock { $0 }, [policy.writerPolicy])
            await session.close()
        }
    }

    @MainActor func testPasswordVerificationUsesConfiguredAndAutomaticThreads() async throws {
        let fixture = try DeferredSaveFixture(behavior: .immediate)
        defer { fixture.document.close() }
        let options = try XCTUnwrap(fixture.document.session).writerOptions
        let url = fixture.directory.url.appendingPathComponent("encrypted.zip")
        let writer = try ArchiveWriter.create(url: url, options: .init(compressionMethod: .stored,
            password: "known", zipEncryption: .aes256, compressionThreads: 1))
        for index in 0..<100 { try writer.add(data: Data([0x5a]), as: "entry-\(index)") }
        try writer.finish()
        for (index, policy) in ArchivePreferences.PowerPolicy.allCases.enumerated() {
            fixture.store.preferences.powerPolicy = policy
            for threads in [2, 0] {
                let session = try ArchiveSession(url: url, password: "known", writerOptions: options)
                fixture.store.preferences.compressionThreads = threads
                let counts = Mutex<[Int]>([]), resolvedPolicies = Mutex<[CompressionPowerPolicy]>([])
                let automatic = [18, 9, 36][index]
                do {
                    try await WriterOptions.$testingAutomaticThreads.withValue({ policy in
                        resolvedPolicies.withLock { $0.append(policy) }
                        return automatic
                    }) {
                        try await ArchivePasswordVerification.execution.withValue(.automatic) {
                            try await ArchivePasswordVerification.observer.withValue({ event in
                                if case .workers(let count) = event { counts.withLock { $0.append(count) } }
                            }) { _ = try await session.preparedPassword() }
                        }
                    }
                    XCTAssertEqual(counts.withLock { $0 }, [threads == 0 ? automatic : 2])
                    XCTAssertEqual(resolvedPolicies.withLock { $0 }, threads == 0 ? [policy.writerPolicy] : [])
                    XCTAssertEqual(session.entryVerification?.indices, Set(0..<100))
                } catch {
                    await session.close()
                    throw error
                }
                await session.close()
            }
        }
    }
    #endif

    @MainActor func testSerialAndParallelCompressionProduceIdenticalBytes() throws {
        let directory = try ArchiveTestDirectory()
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.tarBzip2Level = 1
        store.preferences.zipSkipsCompressedTypes = false
        let controller = ArchiveCreationController(store: store)
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tarGzip, .tarBzip2] {
            let source = directory.url.appendingPathComponent("payload.txt")
            let size = format == .tarBzip2 ? 2_000_000 : 3 * 1024 * 1024
            try Data(repeating: 0x61, count: size).write(to: source)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source.path)
            var outputs: [Data] = []
            for threads in [1, 4] {
                store.preferences.compressionThreads = threads
                let output = directory.url.appendingPathComponent("output-\(threads)." + ArchiveCreationPlan.filenameExtension(for: format))
                let plan = controller.creationPlan(sources: [source], destination: output, format: format)
                XCTAssertEqual(plan.options.compressionThreads, threads)
                let writer = try ArchiveWriter.create(url: output, format: format, options: plan.options)
                try writer.add(contentsOf: source, as: "payload.txt")
                try writer.finish()
                outputs.append(try Data(contentsOf: output))
            }
            XCTAssertFalse(outputs[0].isEmpty)
            XCTAssertEqual(outputs[0], outputs[1], "\(format)")
        }
    }
}
