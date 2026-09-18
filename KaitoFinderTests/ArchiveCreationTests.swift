import CryptoKit
import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveCreationTests: XCTestCase {
    @MainActor func testPendingRegistryTracksCreationUntilSuccessOrFailure() async throws {
        enum Failure: Error { case injected }
        for fail in [false, true] {
            let fixture = try Fixture(), output = fixture.output(), file = fixture.directory.url.appendingPathComponent("pending.json")
            try Data("[]".utf8).write(to: file)
            let registry = PendingWorkRegistry(fileURL: file), gate = ScenarioGate()
            let plan = ArchiveCreationPlan(sources: fixture.sources, destination: output, format: .zip)
            defer { gate.release() }
            let task = Task.detached {
                try ArchiveCreationTransaction.run(plan: plan, progress: Progress(), willPublish: {
                    gate.pauseOnce()
                    if fail { throw Failure.injected }
                }, registry: registry)
            }
            try await scenarioWait { gate.isEntered }
            let entries = try PendingWorkRegistryTests.entries(in: file)
            XCTAssertEqual(entries.count, 1)
            let work = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fixture.directory.url, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".KaitoFinder-new-") })
            XCTAssertEqual((entries.first?["path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                           work.resolvingSymlinksInPath().path)
            XCTAssertNotNil(entries.first?["device"])
            XCTAssertNotNil(entries.first?["inode"])
            gate.release()
            do {
                let result = try await task.value
                XCTAssertEqual(result, output)
                XCTAssertFalse(fail)
                try assertContents(output, Fixture.contents)
            } catch {
                XCTAssertTrue(fail)
                guard case Failure.injected = error else { return XCTFail("Unexpected error: \(error)") }
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
            XCTAssertTrue(try PendingWorkRegistryTests.entries(in: file).isEmpty)
        }
    }

    func testRegistryWriteFailureDoesNotPreventCreation() throws {
        let fixture = try Fixture(), output = fixture.output(), blocker = fixture.directory.url.appendingPathComponent("registry-parent")
        try Data("not a directory".utf8).write(to: blocker)
        let registry = PendingWorkRegistry(fileURL: blocker.appendingPathComponent("pending.json"))
        XCTAssertThrowsError(try registry.register(fixture.directory.url.appendingPathComponent(".KaitoFinder-new-probe")))
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: output, format: .zip),
                                               progress: Progress(), registry: registry)
        try assertContents(output, Fixture.contents)
        try assertNoWorkDirectory(fixture.directory.url)
    }

    private enum ExpectedEntry: Equatable {
        case file(Data), directory
    }

    private final class Fixture {
        let directory: ArchiveTestDirectory
        let sources: [URL]
        static let contents: [String: ExpectedEntry] = [
            "a.txt": .file(Data("first\0日本語\n".utf8)),
            "b.bin": .file(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })),
            "Docs": .directory,
            "Docs/Sub": .directory,
            "Docs/Sub/note.txt": .file(Data("nested contents".utf8)),
            "Docs/Empty": .directory
        ]

        init() throws {
            directory = try ArchiveTestDirectory()
            let inputs = directory.url.appendingPathComponent("inputs", isDirectory: true)
            for (name, entry) in Self.contents {
                let url = inputs.appendingPathComponent(name)
                switch entry {
                case .directory:
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                case .file(let data):
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url)
                }
            }
            sources = ["a.txt", "b.bin", "Docs"].map { inputs.appendingPathComponent($0) }
        }

        func output(_ format: GyoshukuKit.ArchiveFormat = .zip) -> URL {
            directory.url.appendingPathComponent("created." + ArchiveCreationPlan.filenameExtension(for: format))
        }
    }

    private func digest(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }

    private func assertNoWorkDirectory(_ parent: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".KaitoFinder-new-") || $0.hasPrefix(".gyoshuku-rewrite-") },
                       names.description, file: file, line: line)
    }

    private func assertContents(_ archive: URL, _ expected: [String: ExpectedEntry],
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let reader = try ArchiveReader.open(url: archive)
        var actual: [String: ExpectedEntry] = [:]
        for entry in reader.entries {
            // 7z の directory は末尾 / を持たない。名前を揃え、種別は別に検査する。
            let name = entry.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            XCTAssertNil(actual[name], "Duplicate entry: \(name)", file: file, line: line)
            XCTAssertFalse(entry.isEncrypted, file: file, line: line)
            if entry.kind == .directory { actual[name] = .directory }
            else {
                XCTAssertEqual(entry.kind, .file, file: file, line: line)
                var bytes = Data()
                try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
                actual[name] = .file(bytes)
            }
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
        XCTAssertEqual(reader.entries.count, expected.count, file: file, line: line)
    }

    private func assertCreation(_ format: GyoshukuKit.ArchiveFormat,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try Fixture(), destination = fixture.output(format), progress = Progress()
        let result = try ArchiveCreationTransaction.run(
            plan: .init(sources: fixture.sources, destination: destination, format: format), progress: progress)
        XCTAssertEqual(result, destination, file: file, line: line)
        try assertContents(result, Fixture.contents, file: file, line: line)
        XCTAssertEqual(progress.totalUnitCount, Int64(Fixture.contents.count + 1), file: file, line: line)
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount, file: file, line: line)
        let names = Set(Fixture.contents.keys)
        switch format {
        case .tar, .tarGzip, .tarBzip2, .tarXZ:
            let listing: String
            if format == .tarGzip {
                XCTAssertEqual(try Data(contentsOf: result).prefix(2), Data([0x1f, 0x8b]), file: file, line: line)
                listing = try fixture.directory.run("/usr/bin/tar", ["-tzf", result.path])
            } else { listing = try fixture.directory.run("/usr/bin/bsdtar", ["-tf", result.path]) }
            let listed = Set(listing.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
            XCTAssertEqual(listed, names, file: file, line: line)
        case .sevenZip:
            let listing = try fixture.directory.run("/opt/homebrew/bin/7zz", ["l", result.path])
            for name in names { XCTAssertTrue(listing.contains(name), listing, file: file, line: line) }
        case .zip, .lha: break
        }
        try assertNoWorkDirectory(fixture.directory.url, file: file, line: line)
    }

    func testCreateZIPRoundTripsEveryEntryAndContent() throws { try assertCreation(.zip) }
    func testCreateTarRoundTripsAndBSDTarLists() throws { try assertCreation(.tar) }
    func testCreateTarGzipHasGzipMagicRoundTripsAndTarLists() throws { try assertCreation(.tarGzip) }
    func testCreateTarBzip2RoundTripsAndBSDTarLists() throws { try assertCreation(.tarBzip2) }
    func testCreateTarXZRoundTripsAndBSDTarLists() throws { try assertCreation(.tarXZ) }
    func testCreateSevenZipRoundTripsAndSevenZipLists() throws { try assertCreation(.sevenZip) }
    func testCreateLHARoundTripsEveryEntryAndContent() throws { try assertCreation(.lha) }

    func testLHASymlinkFailureUsesLocalizedWriterDescription() throws {
        let fixture = try Fixture(), folder = fixture.sources[2], destination = fixture.output(.lha)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link").path,
                                                   withDestinationPath: "Sub/note.txt")
        XCTAssertThrowsError(try ArchiveCreationTransaction.run(
            plan: .init(sources: [folder], destination: destination, format: .lha), progress: Progress())) { error in
            let reason = ArchiveErrorText.describe(error)
            XCTAssertFalse(reason.contains("unsupportedFileType("), reason)
            XCTAssertTrue(reason.contains(ArchiveErrorText.describe(WriterError.unsupportedFileType("Docs/link"))), reason)
            XCTAssertTrue(reason.hasPrefix("Docs/link: "), reason)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoWorkDirectory(fixture.directory.url)
    }

    @MainActor func testCreationStoredZIPPreferencesStoreEveryEntryWithoutCompression() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.zipMethod = .stored
        store.preferences.zipSkipsCompressedTypes = false
        let fixture = try Fixture(), controller = ArchiveCreationController(store: store)
        let plan = controller.creationPlan(sources: fixture.sources, destination: fixture.output(), format: .zip)
        let result = try ArchiveCreationTransaction.run(plan: plan, progress: Progress())
        let reader = try ArchiveReader.open(url: result)
        XCTAssertEqual(reader.entries.count, Fixture.contents.count)
        for entry in reader.entries { XCTAssertEqual(entry.compressedSize, entry.uncompressedSize, entry.name) }
        try assertContents(result, Fixture.contents)
    }

    @MainActor func testCreationDeflateLevelNinePreferencesCompress200KiBMoreThanStored() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let directory = try ArchiveTestDirectory(), controller = ArchiveCreationController(store: store)
        let source = directory.url.appendingPathComponent("repeated.txt"), bytes = Data(repeating: 0x61, count: 200 * 1024)
        try bytes.write(to: source)
        var sizes: [UInt64] = []
        for method in [ArchivePreferences.ZipMethod.stored, .deflate] {
            // 同じ controller でも、保存を確定するたびに現在の設定から plan を作る。
            store.preferences.zipMethod = method
            store.preferences.zipLevel = 9
            let destination = directory.url.appendingPathComponent(method.rawValue + ".zip")
            let plan = controller.creationPlan(sources: [source], destination: destination, format: .zip)
            XCTAssertEqual(plan.options.deflateLevel, 9)
            let result = try ArchiveCreationTransaction.run(plan: plan, progress: Progress())
            let entry = try XCTUnwrap(ArchiveReader.open(url: result).entries.first)
            XCTAssertEqual(entry.uncompressedSize, UInt64(bytes.count))
            sizes.append(try XCTUnwrap(entry.compressedSize))
            try assertContents(result, ["repeated.txt": .file(bytes)])
        }
        XCTAssertEqual(sizes[0], UInt64(bytes.count))
        XCTAssertLessThan(sizes[1], sizes[0])
    }

    @MainActor func testConversionUsesCurrentZIPPreferences() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let fixture = try Fixture(), controller = ArchiveCreationController(store: store)
        let original = try ArchiveCreationTransaction.run(
            plan: .init(sources: fixture.sources, destination: fixture.output(.tar), format: .tar), progress: Progress())
        let reader = try ArchiveReader.open(url: original)
        store.preferences.zipMethod = .stored
        let plan = controller.creationPlan(sources: [], destination: fixture.output(), format: .zip,
                                           existing: .init(url: original, password: nil, entries: reader.entries))
        let result = try ArchiveCreationTransaction.run(plan: plan, progress: Progress())
        for entry in try ArchiveReader.open(url: result).entries {
            XCTAssertEqual(entry.compressedSize, entry.uncompressedSize, entry.name)
        }
        try assertContents(result, Fixture.contents)
    }

    func testDefaultNamesPreserveFolderAndFileNamesForEveryFormat() {
        let folder = URL(fileURLWithPath: "/tmp/Docs", isDirectory: true), photo = URL(fileURLWithPath: "/tmp/a.jpg")
        let formats: [(GyoshukuKit.ArchiveFormat, String)] = [(.zip, "zip"), (.tar, "tar"), (.tarGzip, "tar.gz"), (.tarBzip2, "tar.bz2"), (.tarXZ, "tar.xz"), (.sevenZip, "7z"), (.lha, "lzh")]
        for (format, suffix) in formats {
            XCTAssertEqual(ArchiveCreationPlan.defaultName(for: [folder], format: format), "Docs." + suffix)
            XCTAssertEqual(ArchiveCreationPlan.defaultName(for: [photo], format: format), "a.jpg." + suffix)
            XCTAssertEqual(ArchiveCreationPlan.defaultName(for: [folder, photo], format: format), String(localized: "アーカイブ") + "." + suffix)
        }
    }

    func testConversionNamesRemoveTheWholeArchiveExtension() {
        for suffix in ["zip", "tar", "tar.gz", "tar.bz2", "tar.xz", "tgz", "7z", "lzh"] {
            let source = URL(fileURLWithPath: "/tmp/original.photos." + suffix)
            XCTAssertEqual(ArchiveCreationPlan.conversionName(for: source, format: .sevenZip), "original.photos.7z")
        }
    }

    func testAcceptedExtensionsMatchEachFormatIgnoringCase() {
        let formats: [(GyoshukuKit.ArchiveFormat, [String])] = [
            (.zip, ["zip"]), (.tar, ["tar"]), (.tarGzip, ["tar.gz", "tgz"]),
            (.tarBzip2, ["tar.bz2", "tbz2", "tbz"]), (.tarXZ, ["tar.xz", "txz"]),
            (.sevenZip, ["7z"]), (.lha, ["lzh", "lha"])
        ]
        for (format, accepted) in formats {
            XCTAssertEqual(ArchiveCreationPlan.acceptedExtensions(for: format), accepted)
            for suffix in ["zip", "tar", "tar.gz", "tgz", "7z", "lzh", "lha", "gz", "tar.bz2", "tbz2", "tbz", "tar.xz", "txz", "xz", "bz2"] {
                for name in ["result." + suffix, "result." + suffix.uppercased()] {
                    XCTAssertEqual(ArchiveCreationPlan.hasAcceptedExtension(URL(fileURLWithPath: "/tmp/" + name), for: format),
                                   accepted.contains(suffix), "\(format): \(name)")
                }
            }
            for name in ["result", "resulttar.gz", "result.", "result.tar.gz.bak"] {
                XCTAssertFalse(ArchiveCreationPlan.hasAcceptedExtension(URL(fileURLWithPath: "/tmp/" + name), for: format),
                               "\(format): \(name)")
            }
        }
    }

    func testTarGzipCreationRefusesPlainGzipDestinationBeforeImport() throws {
        let fixture = try Fixture(), destination = fixture.directory.url.appendingPathComponent("result.gz")
        let list = ".tar.gz, .tgz"
        for sources in [fixture.sources, [fixture.directory.url.appendingPathComponent("missing.txt")]] {
            XCTAssertThrowsError(try ArchiveCreationTransaction.run(
                plan: .init(sources: sources, destination: destination, format: .tarGzip), progress: Progress())) {
                guard case ExtractionFailure.refused(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
                XCTAssertEqual(reason, String(localized: "この形式のファイル名は次の拡張子で終わる必要があります: \(list)"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            try assertNoWorkDirectory(fixture.directory.url)
        }
    }

    func testUnquarantinedSourcesRemoveEvenTheReplacedDestinationsQuarantine() throws {
        let fixture = try Fixture(), output = fixture.output()
        for source in fixture.sources { try ExtractionQuarantine.apply(nil, to: source) }
        try Data("old destination".utf8).write(to: output)
        try ExtractionQuarantine.apply(Data("0081;12345678;OldDestination;".utf8), to: output)
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: output, format: .zip), progress: Progress())
        XCTAssertNil(try ExtractionQuarantine.read(from: output))
    }

    func testFirstQuarantinedSourceValueIsPropagatedExactly() throws {
        let fixture = try Fixture(), output = fixture.output()
        let expected = Data("0081;12345678;CreationTests;".utf8)
        try ExtractionQuarantine.apply(nil, to: fixture.sources[0])
        try ExtractionQuarantine.apply(expected, to: fixture.sources[1])
        try ExtractionQuarantine.apply(Data("0081;87654321;LaterSource;".utf8), to: fixture.sources[2])
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: output, format: .zip), progress: Progress())
        XCTAssertEqual(try ExtractionQuarantine.read(from: output), expected)
    }

    func testNestedFileQuarantinePropagatesFromAnUnquarantinedFolder() throws {
        for quarantine in [Data("0081;12345678;Probe;".utf8), nil] as [Data?] {
            let fixture = try Fixture(), output = fixture.output(), folder = fixture.sources[2]
            let file = folder.appendingPathComponent("Sub/note.txt")
            try ExtractionQuarantine.apply(nil, to: folder)
            try ExtractionQuarantine.apply(quarantine, to: file)
            XCTAssertNil(try ExtractionQuarantine.read(from: folder))
            _ = try ArchiveCreationTransaction.run(
                plan: .init(sources: [folder], destination: output, format: .zip), progress: Progress())
            XCTAssertEqual(try ExtractionQuarantine.read(from: output), quarantine)
        }
    }

    func testSourceQuarantineReadDoesNotFollowSymlinks() throws {
        let fixture = try Fixture(), output = fixture.output()
        let target = fixture.sources[0], link = fixture.directory.url.appendingPathComponent("link.txt")
        try ExtractionQuarantine.apply(Data("0081;12345678;Target;".utf8), to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(try ExtractionQuarantine.read(from: link))
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: [link], destination: output, format: .zip), progress: Progress())
        XCTAssertNil(try ExtractionQuarantine.read(from: output))
        XCTAssertEqual(try ArchiveReader.open(url: output).entries.first?.kind, .symlink)
    }

    func testConversionPropagatesTheOriginalArchiveQuarantine() throws {
        let fixture = try Fixture(), archive = fixture.output(), output = fixture.output(.sevenZip)
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: archive, format: .zip), progress: Progress())
        let quarantine = Data("0081;12345678;OriginalArchive;".utf8)
        try ExtractionQuarantine.apply(quarantine, to: archive)
        let before = try digest(archive)
        let existing = ArchiveCreationPlan.Existing(url: archive, password: nil, entries: try ArchiveReader.open(url: archive).entries)
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: [], destination: output, format: .sevenZip, existing: existing), progress: Progress())
        XCTAssertEqual(try ExtractionQuarantine.read(from: output), quarantine)
        XCTAssertEqual(try ExtractionQuarantine.read(from: archive), quarantine)
        XCTAssertEqual(try digest(archive), before)
        try assertContents(output, Fixture.contents)
        try assertNoWorkDirectory(fixture.directory.url)
    }

    func testTarBzip2ConversionAddsTwoFilesAndPreservesSourceSHA256() throws {
        let fixture = try Fixture(), archive = fixture.directory.url.appendingPathComponent("original.tar.bz2")
        let old = fixture.directory.url.appendingPathComponent("old.txt"), original = Data("original content".utf8)
        try original.write(to: old)
        try fixture.directory.run("/usr/bin/tar", ["--no-mac-metadata", "--no-xattrs", "-cjf", archive.path, "old.txt"])
        let reader = try ArchiveReader.open(url: archive)
        XCTAssertEqual(reader.format, .tar)
        let before = try digest(archive), progress = Progress(), output = fixture.output()
        let existing = ArchiveCreationPlan.Existing(url: archive, password: nil, entries: reader.entries)
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: Array(fixture.sources.prefix(2)), destination: output,
                                                          format: .zip, existing: existing), progress: progress)
        try assertContents(output, ["old.txt": .file(original), "a.txt": Fixture.contents["a.txt"]!, "b.bin": Fixture.contents["b.bin"]!])
        XCTAssertEqual(progress.totalUnitCount, Int64(2 + reader.entries.count + 1))
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        XCTAssertEqual(try digest(archive), before)
        try assertNoWorkDirectory(fixture.directory.url)
    }

    private func encryptedZIP(in directory: ArchiveTestDirectory) throws -> URL {
        let archive = directory.url.appendingPathComponent("encrypted.zip")
        try Data("first secret".utf8).write(to: directory.url.appendingPathComponent("first.txt"))
        try Data("second secret".utf8).write(to: directory.url.appendingPathComponent("second.txt"))
        try directory.run("/usr/bin/zip", ["-q", "-P", "creation-test-password", archive.path, "first.txt", "second.txt"])
        return archive
    }

    func testEncryptedZIPConvertsToUnencryptedSevenZipWithPassword() throws {
        let fixture = try Fixture(), archive = try encryptedZIP(in: fixture.directory), output = fixture.output(.sevenZip)
        let before = try digest(archive), entries = try ArchiveReader.open(url: archive).entries
        XCTAssertTrue(entries.allSatisfy(\.isEncrypted))
        let existing = ArchiveCreationPlan.Existing(url: archive, password: "creation-test-password", entries: entries)
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: [fixture.sources[0]], destination: output,
                                                          format: .sevenZip, existing: existing), progress: Progress())
        try assertContents(output, ["first.txt": .file(Data("first secret".utf8)), "second.txt": .file(Data("second secret".utf8)),
                                    "a.txt": Fixture.contents["a.txt"]!])
        XCTAssertEqual(try digest(archive), before)
        try assertNoWorkDirectory(fixture.directory.url)
    }

    private func assertPasswordFailure(_ password: String?, challenge: ArchivePasswordChallenge) throws {
        let fixture = try Fixture(), archive = try encryptedZIP(in: fixture.directory), output = fixture.output(.sevenZip)
        let before = try digest(archive)
        let existing = ArchiveCreationPlan.Existing(url: archive, password: password, entries: try ArchiveReader.open(url: archive).entries)
        let plan = ArchiveCreationPlan(sources: [fixture.sources[0]], destination: output, format: .sevenZip, existing: existing)
        for oldOutput in [nil, Data("pre-existing destination".utf8)] as [Data?] {
            if let oldOutput { try oldOutput.write(to: output) }
            XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: plan, progress: Progress())) {
                XCTAssertEqual(ArchivePasswordChallenge($0), challenge)
            }
            if let oldOutput { XCTAssertEqual(try Data(contentsOf: output), oldOutput) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
            XCTAssertEqual(try digest(archive), before)
            try assertNoWorkDirectory(fixture.directory.url)
        }
    }

    func testMissingConversionPasswordThrowsRequiredAndPublishesNothing() throws { try assertPasswordFailure(nil, challenge: .required) }
    func testWrongConversionPasswordThrowsIncorrectAndPublishesNothing() throws { try assertPasswordFailure("incorrect", challenge: .incorrect) }

    func testPreparedPasswordPromptsVerifiesAllEntriesAndReusesVerifiedPassword() async throws {
        let directory = try ArchiveTestDirectory(), archive = try encryptedZIP(in: directory)
        let session = try ArchiveSession(url: archive), challenges = Mutex<[ArchivePasswordChallenge]>([])
        session.setPasswordPrompt { challenge in
            let attempt = challenges.withLock { $0.append(challenge); return $0.count }
            return attempt == 1 ? "incorrect" : "creation-test-password"
        }
        let password = try await session.preparedPassword()
        let cached = try await session.preparedPassword()
        XCTAssertEqual(password, "creation-test-password")
        XCTAssertEqual(cached, password)
        XCTAssertEqual(challenges.withLock { $0 }, [.required, .incorrect])
        await session.close()
    }

    func testPreparedPasswordCancellationKeepsOriginalUnchanged() async throws {
        let directory = try ArchiveTestDirectory(), archive = try encryptedZIP(in: directory)
        let before = try digest(archive), session = try ArchiveSession(url: archive)
        session.setPasswordPrompt { _ in throw CancellationError() }
        do { _ = try await session.preparedPassword(); XCTFail("Password cancellation was ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        let retained = await session.password
        XCTAssertNil(retained)
        XCTAssertEqual(try digest(archive), before)
        try assertNoWorkDirectory(directory.url)
        await session.close()
    }

    func testCancellationAtPublishPreservesDestinationAndRemovesTemporaryFilesForEveryFormat() throws {
        let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha]
        for format in formats {
            let fixture = try Fixture(), output = fixture.output(format)
            for before in [nil, Data("original destination".utf8)] as [Data?] {
                if let before { try before.write(to: output) }
                let progress = Progress()
                XCTAssertThrowsError(try ArchiveCreationTransaction.run(
                    plan: .init(sources: fixture.sources, destination: output, format: format), progress: progress,
                    willPublish: { progress.cancel() })) { XCTAssertTrue($0 is CancellationError) }
                if let before { XCTAssertEqual(try Data(contentsOf: output), before) }
                else { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
                try assertNoWorkDirectory(fixture.directory.url)
            }
        }
    }

    func testConversionCancellationAtPublishPreservesBothArchives() throws {
        let fixture = try Fixture(), source = fixture.output(), output = fixture.output(.tarGzip)
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: source, format: .zip), progress: Progress())
        let before = try digest(source), oldOutput = Data("destination to preserve".utf8), progress = Progress()
        try oldOutput.write(to: output)
        let existing = ArchiveCreationPlan.Existing(url: source, password: nil, entries: try ArchiveReader.open(url: source).entries)
        XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: .init(sources: [], destination: output, format: .tarGzip,
                                                                           existing: existing), progress: progress,
                                                                willPublish: { progress.cancel() })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(try digest(source), before)
        XCTAssertEqual(try Data(contentsOf: output), oldOutput)
        try assertNoWorkDirectory(fixture.directory.url)
    }

    func testSuccessfulCreationReplacesDestinationOnlyAfterPrivateWorkIsComplete() throws {
        let fixture = try Fixture(), output = fixture.output(.tarGzip), before = Data("replace these bytes".utf8)
        let parent = fixture.directory.url, progress = Progress()
        try before.write(to: output)
        let result = try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: output, format: .tarGzip),
                                                        progress: progress, willPublish: {
            XCTAssertEqual(try Data(contentsOf: output), before)
            let work = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasPrefix(".KaitoFinder-new-") })
            let attributes = try FileManager.default.attributesOfItem(atPath: work.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), ["archive.tar.gz"])
            XCTAssertEqual(try ArchiveReader.open(url: work.appendingPathComponent("archive.tar.gz")).format, .tar)
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount - 1)
        })
        XCTAssertEqual(result, output)
        XCTAssertNotEqual(try Data(contentsOf: result), before)
        try assertContents(result, Fixture.contents)
        try assertNoWorkDirectory(parent)
    }

    func testPublishSystemFailurePreservesDestinationDirectory() throws {
        let fixture = try Fixture(), output = fixture.output()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let marker = output.appendingPathComponent("keep.txt"), before = Data("untouched".utf8)
        try before.write(to: marker)
        XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: output, format: .zip), progress: Progress())) {
            guard case ExtractionFailure.system(let code) = $0 else { return XCTFail("Unexpected error: \($0)") }
            XCTAssertEqual(code, EISDIR)
        }
        XCTAssertEqual(try Data(contentsOf: marker), before)
        try assertNoWorkDirectory(fixture.directory.url)
    }

    func testPublishHookFailurePreservesDestination() throws {
        enum Failure: Error { case injected }
        let fixture = try Fixture(), output = fixture.output(), before = Data("untouched".utf8)
        try before.write(to: output)
        XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: output, format: .zip),
                                                               progress: Progress(), willPublish: { throw Failure.injected })) {
            guard case Failure.injected = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: output), before)
        try assertNoWorkDirectory(fixture.directory.url)
    }

    func testConversionCollisionsAreAllRefusedBeforeAnyWrite() throws {
        let fixture = try Fixture(), archive = fixture.output(), output = fixture.output(.sevenZip)
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: archive, format: .zip), progress: Progress())
        let original = try digest(archive), before = Data("existing destination".utf8)
        try before.write(to: output)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.url.path).sorted()
        let existing = ArchiveCreationPlan.Existing(url: archive, password: nil, entries: try ArchiveReader.open(url: archive).entries)
        XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: output,
                                                                           format: .sevenZip, existing: existing), progress: Progress(),
                                                                willPublish: { XCTFail("Collision reached publication") })) {
            guard case ExtractionFailure.refused(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
            for name in ["a.txt", "b.bin", "Docs"] { XCTAssertTrue(reason.contains(name), reason) }
        }
        XCTAssertEqual(try digest(archive), original)
        XCTAssertEqual(try Data(contentsOf: output), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.url.path).sorted(), files)
        try assertNoWorkDirectory(fixture.directory.url)
    }

    func testInvalidSourcesAreAllReportedWithoutCreatingOutput() throws {
        let fixture = try Fixture(), output = fixture.output()
        let sources = ["missing-one.txt", "missing-two.txt"].map { fixture.directory.url.appendingPathComponent($0) }
        XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: .init(sources: sources, destination: output, format: .zip), progress: Progress())) {
            guard case ExtractionFailure.refused(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
            for source in sources { XCTAssertTrue(reason.contains(source.lastPathComponent), reason) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try assertNoWorkDirectory(fixture.directory.url)
    }

    func testCreationCannotReplaceAnySourceThroughItsPathOrHardLink() throws {
        let fixture = try Fixture(), source = fixture.directory.url.appendingPathComponent("original.zip")
        let hardLink = fixture.directory.url.appendingPathComponent("hard-link.zip")
        try Data("original source contents".utf8).write(to: source)
        try FileManager.default.linkItem(at: source, to: hardLink)
        let before = try digest(source)
        for destination in [source, hardLink] {
            XCTAssertThrowsError(try ArchiveCreationTransaction.run(
                plan: .init(sources: [fixture.sources[0], source], destination: destination, format: .zip, existing: nil),
                progress: Progress())) {
                guard case ExtractionFailure.refused(let reason) = $0 else { return XCTFail("Unexpected error: \($0)") }
                XCTAssertEqual(reason, String(localized: "作成元の項目とは別の保存先を選んでください。"))
            }
            XCTAssertEqual(try digest(source), before)
            XCTAssertEqual(try digest(hardLink), before)
            try assertNoWorkDirectory(fixture.directory.url)
        }
    }

    func testConversionCannotReplaceOriginalThroughItsPathOrFileAliases() throws {
        let fixture = try Fixture(), archive = fixture.output(), alias = fixture.directory.url.appendingPathComponent("alias.zip")
        let hardLink = fixture.directory.url.appendingPathComponent("hard-link.zip")
        _ = try ArchiveCreationTransaction.run(plan: .init(sources: fixture.sources, destination: archive, format: .zip), progress: Progress())
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: archive)
        try FileManager.default.linkItem(at: archive, to: hardLink)
        let before = try digest(archive)
        let existing = ArchiveCreationPlan.Existing(url: archive, password: nil, entries: try ArchiveReader.open(url: archive).entries)
        for output in [archive, alias, hardLink] {
            XCTAssertThrowsError(try ArchiveCreationTransaction.run(plan: .init(sources: [], destination: output, format: .zip, existing: existing), progress: Progress())) {
                guard case ExtractionFailure.refused = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
        XCTAssertEqual(try digest(archive), before)
        XCTAssertEqual(try digest(hardLink), before)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), archive.path)
        try assertNoWorkDirectory(fixture.directory.url)
    }
}
