import Darwin
import Foundation
import GyoshukuKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveBatchExtractionTests: XCTestCase {
    private final class Fixture {
        let directory: ArchiveTestDirectory
        let password = "batch-fixture-password"
        let secret = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) }) + Data("秘密\0\n".utf8)

        init() throws { directory = try ArchiveTestDirectory() }

        func folder(_ name: String) throws -> URL {
            let url = directory.url.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        }

        func archive(_ name: String, files: [String: Data], format: GyoshukuKit.ArchiveFormat = .zip,
                     parent: URL? = nil) throws -> URL {
            let inputs = try folder("inputs-" + UUID().uuidString)
            for (path, data) in files {
                let file = inputs.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
            }
            let names = Set(files.keys.map { String($0.split(separator: "/")[0]) }).sorted()
            let destination = (parent ?? directory.url).appendingPathComponent(name)
            return try ArchiveCreationTransaction.run(plan: ArchiveCreationPlan(
                sources: names.map { inputs.appendingPathComponent($0) }, destination: destination, format: format,
                options: WriterOptions(compressionMethod: .stored)), progress: Progress())
        }

        func encryptedArchive(_ name: String = "secret.zip", headers: Bool = false,
                              publicEntry: Bool = false) throws -> URL {
            let inputs = try folder("encrypted-" + UUID().uuidString)
            let source = inputs.appendingPathComponent("secret.bin")
            try secret.write(to: source)
            let archive = directory.url.appendingPathComponent(name)
            if headers {
                try directory.run("/opt/homebrew/bin/7zz", ["a", "-bd", "-y", "-p" + password, "-mhe=on", archive.path, source.path])
            } else {
                if publicEntry {
                    let file = inputs.appendingPathComponent("public.txt")
                    try Data("public".utf8).write(to: file)
                    try directory.run("/usr/bin/zip", ["-q", "-j", archive.path, file.path])
                }
                try directory.run("/usr/bin/zip", ["-q", "-j", "-P", password, archive.path, source.path])
            }
            return archive
        }

        func corruptPayload() throws -> URL {
            let archive = try archive("bad-payload.zip", files: ["broken.txt": Data("damage this payload".utf8)])
            var bytes = try Data(contentsOf: archive)
            // 一覧は読めるまま、最初の無圧縮エントリのCRCだけを不一致にする。
            XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
            let nameLength = Int(bytes[26]) | Int(bytes[27]) << 8
            let extraLength = Int(bytes[28]) | Int(bytes[29]) << 8
            bytes[30 + nameLength + extraLength] ^= 0xff
            try bytes.write(to: archive)
            return archive
        }
    }

    @MainActor private func extractor(_ policy: ArchivePreferences.FolderPolicy = .always) -> ArchiveBatchExtractor {
        ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: policy), passwordPrompt: { _, _ in
            XCTFail("暗号化していないアーカイブは入力を求めない")
            throw CancellationError()
        })
    }

    private func assertContents(_ root: URL, _ expected: [String: Data],
                                file: StaticString = #filePath, line: UInt = #line) throws {
        for (path, bytes) in expected {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes, path, file: file, line: line)
        }
    }

    private func assertAbsent(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        var info = stat()
        XCTAssertNotEqual(lstat(url.path, &info), 0, url.lastPathComponent, file: file, line: line)
        XCTAssertEqual(errno, ENOENT, file: file, line: line)
    }

    func testDestinationFolderPoliciesForSingleAndMultipleTopLevelNames() throws {
        let directory = try ArchiveTestDirectory(), base = directory.url
        let archive = base.appendingPathComponent("photos.zip")
        let cases: [(ArchivePreferences.FolderPolicy, Set<String>, String?)] = [
            (.always, ["docs"], "photos"), (.always, ["x.txt", "y.txt"], "photos"),
            (.whenMultipleTopLevelItems, ["docs"], nil), (.whenMultipleTopLevelItems, ["x.txt", "y.txt"], "photos"),
            (.never, ["docs"], nil), (.never, ["x.txt", "y.txt"], nil),
            (.always, [], "photos"), (.whenMultipleTopLevelItems, [], nil), (.never, [], nil)
        ]
        for (policy, names, folder) in cases {
            let result = ArchiveBatchPlan.destinationFolder(for: archive, base: base, policy: policy,
                                                            topLevelNames: names, exists: { _ in false })
            XCTAssertEqual(result, folder.map { base.appendingPathComponent($0, isDirectory: true) } ?? base)
        }
    }

    func testDestinationFolderUsesFinderSuffixesAndPreservesExistingFolders() throws {
        let directory = try ArchiveTestDirectory(), base = directory.url, archive = base.appendingPathComponent("photos.zip")
        let first = base.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        let sentinel = first.appendingPathComponent("keep.txt"), bytes = Data("keep".utf8)
        try bytes.write(to: sentinel)
        let second = ArchiveBatchPlan.destinationFolder(for: archive, base: base, policy: .always,
            topLevelNames: ["a"], exists: { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(second.lastPathComponent, "photos 2")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let third = ArchiveBatchPlan.destinationFolder(for: archive, base: base, policy: .whenMultipleTopLevelItems,
            topLevelNames: ["a", "b"], exists: { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(third.lastPathComponent, "photos 3")
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    }

    func testArchiveStemStripsArchiveAndCompoundExtensionsAndKeepsPhotoExtension() throws {
        let directory = try ArchiveTestDirectory()
        for (name, stem) in [("sample.zip", "sample"), ("sample.tar.gz", "sample"), ("sample.7z", "sample"),
                             ("sample.lzh", "sample"), ("photo.jpg.zip", "photo.jpg"), ("sample.tgz", "sample"),
                             ("sample.TAR.GZ", "sample"), ("sample.tar.bz2", "sample")] {
            let archive = directory.url.appendingPathComponent(name)
            XCTAssertEqual(ArchiveCreationPlan.archiveStem(for: archive), stem)
            XCTAssertEqual(ArchiveCreationPlan.conversionName(for: archive, format: .sevenZip), stem + ".7z")
            XCTAssertEqual(ArchiveBatchPlan.destinationFolder(for: archive, base: directory.url, policy: .always,
                topLevelNames: ["file"], exists: { _ in false }).lastPathComponent, stem)
        }
    }

    @MainActor func testMixedZIPAndTarGzipBatchUsesEachArchiveFolderAndTopLevelShape() async throws {
        let fixture = try Fixture(), other = try fixture.folder("other")
        let a = ["docs/a.txt": Data("first\0日本語".utf8), "docs/b.bin": fixture.secret]
        let b = ["x.txt": Data("x".utf8), "y.txt": Data("y".utf8)]
        let c = ["images/photo.jpg": Data([0, 1, 254, 255])]
        let zipA = try fixture.archive("zipA.zip", files: a)
        let zipB = try fixture.archive("zipB.zip", files: b)
        let tgzC = try fixture.archive("tgzC.tar.gz", files: c, format: .tarGzip, parent: other)
        let archives = [zipA, zipB, tgzC], originals = try archives.map { try Data(contentsOf: $0) }
        let progress = Progress()
        let report = await extractor(.whenMultipleTopLevelItems).run(archives: archives, base: nil, progress: progress)
        XCTAssertEqual(report.extracted, archives)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(progress.totalUnitCount, 3)
        XCTAssertEqual(progress.completedUnitCount, 3)
        XCTAssertEqual(progress.fractionCompleted, 1)
        try assertContents(fixture.directory.url, a)
        try assertContents(fixture.directory.url.appendingPathComponent("zipB"), b)
        try assertContents(other, c)
        assertAbsent(fixture.directory.url.appendingPathComponent("zipA"))
        assertAbsent(other.appendingPathComponent("tgzC"))
        for (archive, bytes) in zip(archives, originals) { XCTAssertEqual(try Data(contentsOf: archive), bytes) }
    }

    @MainActor func testChosenBaseAlwaysCreatesUniqueFolderAndNeverUsesSourceFolder() async throws {
        let fixture = try Fixture(), base = try fixture.folder("chosen"), bytes = Data("contents".utf8)
        let archive = try fixture.archive("photos.zip", files: ["photo.jpg": bytes])
        let existing = base.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        try bytes.write(to: existing.appendingPathComponent("keep"))
        let report = await extractor().run(archives: [archive], base: base, progress: Progress())
        XCTAssertTrue(report.failures.isEmpty)
        try assertContents(base, ["photos/keep": bytes, "photos 2/photo.jpg": bytes])
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: base.appendingPathComponent("photos 2").path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.uint16Value & 0o777, 0o755 & ~ExtractionPermissions.processMask)
        assertAbsent(fixture.directory.url.appendingPathComponent("photo.jpg"))
    }

    @MainActor func testNeverCreatesWrapperEvenWithMultipleTopLevelFiles() async throws {
        let fixture = try Fixture(), base = try fixture.folder("chosen")
        let bytes = ["x.txt": Data("x".utf8), "y.txt": fixture.secret]
        let archive = try fixture.archive("flat.zip", files: bytes)
        let report = await extractor(.never).run(archives: [archive], base: base, progress: Progress())
        XCTAssertEqual(report.extracted, [archive])
        XCTAssertTrue(report.failures.isEmpty)
        try assertContents(base, bytes)
        assertAbsent(base.appendingPathComponent("flat"))
    }

    @MainActor func testEncryptedZIPPromptsForItsURLAndExtractsExactBytes() async throws {
        let fixture = try Fixture(), archive = try fixture.encryptedArchive(publicEntry: true)
        let next = try fixture.archive("next.zip", files: ["next.txt": Data("next".utf8)])
        var requested: [URL] = [], challenges: [ArchivePasswordChallenge] = []
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always), passwordPrompt: { url, challenge in
            XCTAssertTrue(Thread.isMainThread)
            requested.append(url)
            challenges.append(challenge)
            return fixture.password
        })
        let report = await engine.run(archives: [archive, next], base: nil, progress: Progress())
        XCTAssertEqual(report.extracted, [archive, next])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(requested, [archive])
        XCTAssertEqual(challenges, [.required])
        try assertContents(fixture.directory.url.appendingPathComponent("secret"),
                           ["secret.bin": fixture.secret, "public.txt": Data("public".utf8)])
        try assertContents(fixture.directory.url.appendingPathComponent("next"), ["next.txt": Data("next".utf8)])
    }

    @MainActor func testEncryptedZIPWrongThenRightPasswordRetriesTwice() async throws {
        let fixture = try Fixture(), archive = try fixture.encryptedArchive()
        let next = try fixture.archive("next.zip", files: ["next.txt": Data("next".utf8)])
        var requested: [URL] = [], challenges: [ArchivePasswordChallenge] = []
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always), passwordPrompt: { url, challenge in
            requested.append(url)
            challenges.append(challenge)
            return challenges.count == 1 ? "incorrect" : fixture.password
        })
        let report = await engine.run(archives: [archive, next], base: nil, progress: Progress())
        XCTAssertEqual(report.extracted, [archive, next])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(requested, [archive, archive])
        XCTAssertEqual(challenges, [.required, .incorrect])
        try assertContents(fixture.directory.url.appendingPathComponent("secret"), ["secret.bin": fixture.secret])
        try assertContents(fixture.directory.url.appendingPathComponent("next"), ["next.txt": Data("next".utf8)])
    }

    @MainActor func testPasswordPromptCancellationSkipsOnlyThatArchiveAndRemovesEmptyFolder() async throws {
        let fixture = try Fixture(), encrypted = try fixture.encryptedArchive(publicEntry: true)
        let bytes = Data("next archive".utf8), next = try fixture.archive("next.zip", files: ["next.txt": bytes])
        var requested: [URL] = []
        let progress = Progress()
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always), passwordPrompt: { url, _ in
            requested.append(url)
            throw CancellationError()
        })
        let report = await engine.run(archives: [encrypted, next], base: nil, progress: progress)
        XCTAssertEqual(requested, [encrypted])
        XCTAssertFalse(report.cancelled)
        XCTAssertEqual(report.extracted, [next])
        XCTAssertEqual(report.failures.map(\.archive), [encrypted])
        XCTAssertTrue(try XCTUnwrap(report.failures.first).reason.contains(String(localized: "キャンセル")))
        assertAbsent(fixture.directory.url.appendingPathComponent("secret"))
        try assertContents(fixture.directory.url.appendingPathComponent("next"), ["next.txt": bytes])
        XCTAssertEqual(progress.completedUnitCount, 2)
    }

    @MainActor func testRememberedPasswordExtractsWithoutPrompting() async throws {
        let fixture = try Fixture(), archive = try fixture.encryptedArchive(), password = fixture.password
        let requested = Mutex<[URL]>([])
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always), passwordPrompt: { _, _ in
            XCTFail("記憶した正しいパスワードでは入力を求めない")
            throw CancellationError()
        }, rememberedPassword: { url in
            requested.withLock { $0.append(url) }
            return password
        })
        let report = await engine.run(archives: [archive], base: nil, progress: Progress())
        XCTAssertEqual(requested.withLock { $0 }, [archive])
        XCTAssertEqual(report.extracted, [archive])
        XCTAssertTrue(report.failures.isEmpty)
        try assertContents(fixture.directory.url.appendingPathComponent("secret"), ["secret.bin": fixture.secret])
    }

    @MainActor func testIncorrectRememberedPasswordFallsBackToPrompt() async throws {
        let fixture = try Fixture(), archive = try fixture.encryptedArchive()
        var challenges: [ArchivePasswordChallenge] = []
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always), passwordPrompt: { _, challenge in
            challenges.append(challenge)
            return fixture.password
        }, rememberedPassword: { _ in "incorrect remembered value" })
        let report = await engine.run(archives: [archive], base: nil, progress: Progress())
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(challenges, [.incorrect])
        try assertContents(fixture.directory.url.appendingPathComponent("secret"), ["secret.bin": fixture.secret])
    }

    @MainActor func testEncryptedSevenZipHeadersRetryAtOpenAndRememberedPasswordWorks() async throws {
        let fixture = try Fixture(), archive = try fixture.encryptedArchive("locked.7z", headers: true)
        var challenges: [ArchivePasswordChallenge] = [], requested: [URL] = []
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always), passwordPrompt: { url, challenge in
            requested.append(url)
            challenges.append(challenge)
            return challenges.count == 1 ? "incorrect" : fixture.password
        })
        let report = await engine.run(archives: [archive], base: nil, progress: Progress())
        XCTAssertEqual(report.extracted, [archive])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(requested, [archive, archive])
        XCTAssertEqual(challenges, [.required, .incorrect])
        try assertContents(fixture.directory.url.appendingPathComponent("locked"), ["secret.bin": fixture.secret])
        let password = fixture.password
        let remembered = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always), passwordPrompt: { _, _ in
            XCTFail("ヘッダーの解除にも記憶したパスワードを使う")
            throw CancellationError()
        }, rememberedPassword: { _ in password })
        let repeated = await remembered.run(archives: [archive], base: nil, progress: Progress())
        XCTAssertTrue(repeated.failures.isEmpty)
        try assertContents(fixture.directory.url.appendingPathComponent("locked 2"), ["secret.bin": fixture.secret])
    }

    @MainActor func testCorruptHeaderAndPayloadFailuresAreIsolatedAndEmptyFolderIsRemoved() async throws {
        let fixture = try Fixture(), bytes = Data("complete".utf8)
        let first = try fixture.archive("first.zip", files: ["first.txt": bytes])
        let badHeader = fixture.directory.url.appendingPathComponent("bad-header.zip")
        try Data("not an archive".utf8).write(to: badHeader)
        let badPayload = try fixture.corruptPayload(), last = try fixture.archive("last.zip", files: ["last.txt": bytes])
        let report = await extractor().run(archives: [first, badHeader, badPayload, last], base: nil, progress: Progress())
        XCTAssertEqual(report.extracted, [first, last])
        XCTAssertEqual(report.failures.map(\.archive), [badHeader, badPayload])
        XCTAssertTrue(report.failures.allSatisfy { !$0.reason.isEmpty })
        XCTAssertFalse(report.cancelled)
        try assertContents(fixture.directory.url, ["first/first.txt": bytes, "last/last.txt": bytes])
        assertAbsent(fixture.directory.url.appendingPathComponent("bad-header"))
        assertAbsent(fixture.directory.url.appendingPathComponent("bad-payload"))
    }

    @MainActor func testTrashRunsOnceForEachSuccessfulArchiveAndNeverForFailures() async throws {
        let fixture = try Fixture(), bytes = Data("data".utf8)
        let first = try fixture.archive("first.zip", files: ["a": bytes]), bad = try fixture.corruptPayload()
        let last = try fixture.archive("last.zip", files: ["b": bytes]), trashed = Mutex<[URL]>([])
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always, trashesArchiveAfterExtraction: true),
            passwordPrompt: { _, _ in throw CancellationError() }, trash: { url in trashed.withLock { $0.append(url) } })
        let report = await engine.run(archives: [first, bad, last], base: nil, progress: Progress())
        XCTAssertEqual(trashed.withLock { $0 }, [first, last])
        XCTAssertEqual(report.extracted, [first, last])
        XCTAssertEqual(report.failures.map(\.archive), [bad])
        try assertContents(fixture.directory.url, ["first/a": bytes, "last/b": bytes])
    }

    @MainActor func testTrashFailureIsReportedButExtractionAndFollowingArchiveAreKept() async throws {
        let fixture = try Fixture(), bytes = Data("retained".utf8)
        let first = try fixture.archive("first.zip", files: ["a": bytes])
        let next = try fixture.archive("next.zip", files: ["b": bytes]), trashed = Mutex<[URL]>([])
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always, trashesArchiveAfterExtraction: true),
            passwordPrompt: { _, _ in throw CancellationError() }, trash: { url in
                trashed.withLock { $0.append(url) }
                if url == first { throw CocoaError(.fileWriteNoPermission) }
            })
        let report = await engine.run(archives: [first, next], base: nil, progress: Progress())
        XCTAssertEqual(trashed.withLock { $0 }, [first, next])
        XCTAssertEqual(report.extracted, [first, next])
        XCTAssertEqual(report.failures.map(\.archive), [first])
        XCTAssertFalse(try XCTUnwrap(report.failures.first).reason.isEmpty)
        try assertContents(fixture.directory.url, ["first/a": bytes, "next/b": bytes])
    }

    @MainActor func testCancelProgressFromSecondPasswordPromptStopsBatchWithoutPartialOutput() async throws {
        let fixture = try Fixture(), bytes = Data("first complete".utf8)
        let first = try fixture.archive("first.zip", files: ["a": bytes]), second = try fixture.encryptedArchive(publicEntry: true)
        let last = try fixture.archive("last.zip", files: ["b": bytes]), progress = Progress()
        var requested: [URL] = []
        let trashed = Mutex<[URL]>([])
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always, trashesArchiveAfterExtraction: true),
            passwordPrompt: { url, _ in requested.append(url); progress.cancel(); return fixture.password },
            trash: { url in trashed.withLock { $0.append(url) } })
        let report = await engine.run(archives: [first, second, last], base: nil, progress: progress)
        XCTAssertTrue(report.cancelled)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.extracted, [first])
        XCTAssertEqual(requested, [second])
        XCTAssertEqual(trashed.withLock { $0 }, [first])
        try assertContents(fixture.directory.url, ["first/a": bytes])
        assertAbsent(fixture.directory.url.appendingPathComponent("secret"))
        assertAbsent(fixture.directory.url.appendingPathComponent("last"))
    }

    @MainActor func testCancellationDuringWritingRemovesOnlyCurrentArchiveOutput() async throws {
        for policy in [ArchivePreferences.FolderPolicy.always, .never] {
            let fixture = try Fixture(), bytes = Data("complete".utf8), base = try fixture.folder("out")
            let first = try fixture.archive("first.zip", files: ["first.txt": bytes])
            let middle = try fixture.archive("middle.zip", files: Dictionary(uniqueKeysWithValues:
                (0..<12).map { ((policy == .always ? "sub/" : "") + "part-\($0).txt", bytes) }))
            let last = try fixture.archive("last.zip", files: ["last.txt": bytes])
            try bytes.write(to: base.appendingPathComponent("sentinel"))
            let progress = Progress(), interrupted = Mutex(false)
            // 子の進捗通知中に同期的に止め、完了済みの葉がある途中の状態を確実に作る。
            let observation = progress.observe(\.fractionCompleted, options: [.new]) { value, _ in
                if !value.isCancelled && value.fractionCompleted > 0.45 && value.fractionCompleted < 0.65 {
                    interrupted.withLock { $0 = true }
                    value.cancel()
                }
            }
            let report = await extractor(policy).run(archives: [first, middle, last], base: base, progress: progress)
            observation.invalidate()
            XCTAssertTrue(interrupted.withLock { $0 })
            XCTAssertTrue(report.cancelled)
            XCTAssertEqual(report.extracted, [first])
            XCTAssertTrue(report.failures.isEmpty)
            let firstPath = policy == .always ? "first/first.txt" : "first.txt"
            try assertContents(base, [firstPath: bytes, "sentinel": bytes])
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: base.path)),
                           [policy == .always ? "first" : "first.txt", "sentinel"])
        }
    }

    @MainActor func testEmptyBatchAndPrecancelledProgressDoNotPromptOrTrash() async throws {
        let fixture = try Fixture(), archive = try fixture.encryptedArchive()
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(trashesArchiveAfterExtraction: true),
            passwordPrompt: { _, _ in XCTFail("入力は不要"); throw CancellationError() },
            rememberedPassword: { _ in XCTFail("原本を開く前に停止する"); return nil },
            trash: { _ in XCTFail("原本は移動しない") })
        let empty = await engine.run(archives: [], base: nil, progress: Progress())
        XCTAssertTrue(empty.extracted.isEmpty)
        XCTAssertTrue(empty.failures.isEmpty)
        XCTAssertFalse(empty.cancelled)
        let progress = Progress()
        progress.cancel()
        let cancelled = await engine.run(archives: [archive], base: nil, progress: progress)
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertTrue(cancelled.extracted.isEmpty)
        XCTAssertTrue(cancelled.failures.isEmpty)
        assertAbsent(fixture.directory.url.appendingPathComponent("secret"))
    }

    @MainActor func testRevealRunsOnceAfterBatchWithCreatedFoldersAndUnwrappedTopLevelItems() async throws {
        let fixture = try Fixture(), base = try fixture.folder("chosen"), bytes = Data("contents".utf8)
        let single = try fixture.archive("single.zip", files: ["docs/readme.txt": bytes])
        let multiple = try fixture.archive("multiple.zip", files: ["a.txt": bytes, "b.txt": bytes])
        let flat = try fixture.archive("flat.zip", files: ["photo.jpg": bytes])
        let existing = base.appendingPathComponent("multiple", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let revealed = Mutex<[[URL]]>([])
        var current: [URL?] = []
        let progress = Progress()
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(revealsExtractedItemsInFinder: true),
            passwordPrompt: { _, _ in throw CancellationError() }, reveal: { urls in
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
                revealed.withLock { $0.append(urls) }
            }, currentArchive: { current.append($0) })
        let report = await engine.run(archives: [single, multiple, flat], base: base, progress: progress)
        XCTAssertEqual(report.extracted, [single, multiple, flat])
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(revealed.withLock { $0 }, [[base.appendingPathComponent("docs", isDirectory: true),
            base.appendingPathComponent("multiple 2", isDirectory: true), base.appendingPathComponent("photo.jpg")]])
        XCTAssertEqual(current, [single, multiple, flat, nil])
    }

    @MainActor func testRevealIncludesSuccessfulOutputWhenTrashFailsAndExcludesExtractionFailures() async throws {
        let fixture = try Fixture(), bytes = Data("contents".utf8)
        let first = try fixture.archive("first.zip", files: ["a": bytes])
        let bad = try fixture.corruptPayload()
        let last = try fixture.archive("last.zip", files: ["b": bytes])
        let revealed = Mutex<[[URL]]>([])
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always,
            trashesArchiveAfterExtraction: true, revealsExtractedItemsInFinder: true),
            passwordPrompt: { _, _ in throw CancellationError() }, trash: { archive in
                if archive == first { throw CocoaError(.fileWriteNoPermission) }
            }, reveal: { urls in revealed.withLock { $0.append(urls) } })
        let report = await engine.run(archives: [first, bad, last], base: nil, progress: Progress())
        XCTAssertEqual(report.extracted, [first, last])
        XCTAssertEqual(report.failures.map(\.archive), [first, bad])
        XCTAssertEqual(revealed.withLock { $0 }, [[fixture.directory.url.appendingPathComponent("first", isDirectory: true),
            fixture.directory.url.appendingPathComponent("last", isDirectory: true)]])
    }

    @MainActor func testRevealNeverPolicySelectsAllTopLevelItemsAndDefaultPreferenceDoesNotReveal() async throws {
        let fixture = try Fixture(), bytes = Data("contents".utf8)
        let archive = try fixture.archive("flat.zip", files: ["a.txt": bytes, "nested/b.txt": bytes])
        let revealed = Mutex<[[URL]]>([])
        for enabled in [false, true] {
            let base = try fixture.folder(enabled ? "enabled" : "disabled")
            let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .never,
                revealsExtractedItemsInFinder: enabled), passwordPrompt: { _, _ in throw CancellationError() },
                reveal: { urls in revealed.withLock { $0.append(urls) } })
            let report = await engine.run(archives: [archive], base: base, progress: Progress())
            XCTAssertEqual(report.extracted, [archive])
            XCTAssertTrue(report.failures.isEmpty)
            let calls = revealed.withLock { $0 }
            if enabled {
                XCTAssertEqual(calls.count, 1)
                XCTAssertEqual(Set(try XCTUnwrap(calls.first)), [base.appendingPathComponent("a.txt"),
                    base.appendingPathComponent("nested", isDirectory: true)])
            } else { XCTAssertTrue(calls.isEmpty) }
        }
    }

    @MainActor func testRevealAfterCancellationContainsOnlyCompletedArchives() async throws {
        let fixture = try Fixture(), base = try fixture.folder("out"), bytes = Data("complete".utf8)
        let first = try fixture.archive("first.zip", files: ["first.txt": bytes])
        let cancelled = try fixture.encryptedArchive(publicEntry: true)
        let last = try fixture.archive("last.zip", files: ["last.txt": bytes])
        let revealed = Mutex<[[URL]]>([]), progress = Progress()
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(folderPolicy: .always,
            revealsExtractedItemsInFinder: true), passwordPrompt: { _, _ in progress.cancel(); throw CancellationError() },
            reveal: { urls in revealed.withLock { $0.append(urls) } })
        let report = await engine.run(archives: [first, cancelled, last], base: base, progress: progress)
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.extracted, [first])
        XCTAssertEqual(revealed.withLock { $0 }, [[base.appendingPathComponent("first", isDirectory: true)]])
        assertAbsent(base.appendingPathComponent("secret"))
        assertAbsent(base.appendingPathComponent("last"))
    }

    @MainActor func testRevealIsNotCalledForEmptyPrecancelledOrEntirelyFailedBatch() async throws {
        let fixture = try Fixture(), failed = try fixture.corruptPayload()
        let engine = ArchiveBatchExtractor(preferences: ArchivePreferences(revealsExtractedItemsInFinder: true),
            passwordPrompt: { _, _ in throw CancellationError() }, reveal: { _ in XCTFail("成功した出力がない場合はFinderを開かない") })
        let empty = await engine.run(archives: [], base: nil, progress: Progress())
        XCTAssertTrue(empty.extracted.isEmpty)
        let progress = Progress()
        progress.cancel()
        let cancelled = await engine.run(archives: [failed], base: nil, progress: progress)
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertTrue(cancelled.extracted.isEmpty)
        let report = await engine.run(archives: [failed], base: nil, progress: Progress())
        XCTAssertTrue(report.extracted.isEmpty)
        XCTAssertEqual(report.failures.map(\.archive), [failed])
    }

}
