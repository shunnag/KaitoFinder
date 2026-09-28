import Foundation
import GyoshukuKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class CompressionThreadPreferenceTests: XCTestCase {
    func testAutomaticThreadsAndMemoryEstimates() {
        for (processors, memoryGiB, expected) in [(8, 8, 8), (16, 128, 8), (4, 2, 2), (2, 128, 2), (0, 0, 1)] {
            let hardware = ArchiveHardware(processors: processors, memory: UInt64(memoryGiB) << 30)
            XCTAssertEqual(hardware.automaticCompressionThreads, expected)
        }
        for (threads, memoryMiB) in [(1, 165), (2, 300), (4, 570), (8, 1110), (16, 2190)] {
            XCTAssertEqual(ArchiveHardware.estimatedLZMA2Memory(threads: threads), UInt64(memoryMiB) << 20)
        }
    }

    func testAllSevenFormatsOnlyChangeCompressionThreads() {
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
                        case .tar, .tarXZ:
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
            for format in ArchivePreferences.formats {
                let encryption = ArchiveEncryptionSettings(password: format == .zip || format == .sevenZip ? "x" : nil)
                let plan = controller.creationPlan(sources: [], destination: directory.url.appendingPathComponent("output"),
                                                   format: format, level: .maximum, encryption: encryption)
                XCTAssertEqual(plan.options.compressionThreads, threads == 0 ? nil : threads)
                XCTAssertEqual(plan.options.password, encryption.password)
                if format == .zip || format == .tarGzip { XCTAssertEqual(plan.options.deflateLevel, 9) }
                if format == .tarBzip2 { XCTAssertEqual(plan.options.bzip2Level, 9) }
            }
        }
        store.preferences.compressionThreads = 2
        let passwordOptions = ArchiveEncryptionSettings(password: "x")
            .applying(to: store.preferences.writerOptions(for: .zip), format: .zip)
        XCTAssertEqual(passwordOptions.compressionThreads, 2)
        XCTAssertEqual(passwordOptions.password, "x")
    }

    @MainActor func testOpenDocumentsReadThreadChangesWithoutReopening() throws {
        for behavior in ArchivePreferences.SaveBehavior.allCases {
            let fixture = try DeferredSaveFixture(behavior: behavior)
            defer { fixture.document.close() }
            let session = try XCTUnwrap(fixture.document.session)
            XCTAssertNil(session.writerOptions(.zip).compressionThreads)
            fixture.store.preferences.compressionThreads = 2
            XCTAssertEqual(session.writerOptions(.zip).compressionThreads, 2)
            fixture.store.preferences.compressionThreads = 0
            XCTAssertNil(session.writerOptions(.zip).compressionThreads)
            XCTAssertTrue(fixture.document.session === session)
        }
    }

    #if DEBUG
    @MainActor func testPasswordVerificationUsesConfiguredAndAutomaticThreads() async throws {
        let fixture = try DeferredSaveFixture(behavior: .immediate)
        defer { fixture.document.close() }
        let options = try XCTUnwrap(fixture.document.session).writerOptions
        let url = fixture.directory.url.appendingPathComponent("encrypted.zip")
        let writer = try ArchiveWriter.create(url: url, options: .init(compressionMethod: .stored,
            password: "known", zipEncryption: .aes256, compressionThreads: 1))
        for index in 0..<100 { try writer.add(data: Data([0x5a]), as: "entry-\(index)") }
        try writer.finish()
        for threads in [2, 0] {
            let session = try ArchiveSession(url: url, password: "known", writerOptions: options)
            fixture.store.preferences.compressionThreads = threads
            let counts = Mutex<[Int]>([])
            do {
                try await ArchivePasswordVerification.execution.withValue(.automatic) {
                    try await ArchivePasswordVerification.observer.withValue({ event in
                        if case .workers(let count) = event { counts.withLock { $0.append(count) } }
                    }) { _ = try await session.deferredSnapshot() }
                }
                XCTAssertEqual(counts.withLock { $0 }, [threads == 0 ? min(100, ArchiveHardware.current.automaticCompressionThreads) : 2])
                XCTAssertEqual(session.entryVerification?.indices, Set(0..<100))
            } catch {
                await session.close()
                throw error
            }
            await session.close()
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
