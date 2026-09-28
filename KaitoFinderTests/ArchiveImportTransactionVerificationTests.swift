import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveImportTransactionVerificationTests: XCTestCase {
    func testPasswordPublicationRejectsOnePlainFileForImmediateDeferredAndFallback() async throws {
        for deferred in [false, true] {
            for fallback in [false, true] {
                let directory = try ArchiveTestDirectory(), url = try archive(directory, format: .zip)
                let original = try Data(contentsOf: url), session = try ArchiveSession(url: url)
                let snapshot = try await session.deferredSnapshot(), options = WriterOptions(password: "new")
                let wrong = directory.url.appendingPathComponent("mixed.zip")
                let writer = try ArchiveWriter.create(url: wrong, options: options)
                try writer.add(data: Data(repeating: 42, count: 2048), as: "keep")
                try writer.add(data: Data([3]), as: "remove"); try writer.finish()
                let updater = try ArchiveUpdater.open(url: wrong)
                try updater.add(data: Data([2]), as: "second", modificationDate: nil, permissions: nil); try updater.commit()
                let incorrect = try Data(contentsOf: wrong), failures = Mutex<[ArchiveVerificationFailure]>([])
                do {
                    try await ArchiveVerificationFailure.observer.withValue({ value in failures.withLock { $0.append(value) } }) {
                        try await ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({
                            if fallback { throw UpdaterError.nonRelocatableEntry(index: 0, name: "keep", reason: "offset") }
                        }) {
                            try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in try incorrect.write(to: work) }) {
                                if deferred {
                                    var pending = ArchivePendingChanges(); pending.outputEncryption = .init(password: "new")
                                    let publication = ArchiveSavePublication(); defer { publication.finish() }
                                    _ = try await session.savePending(pending, baseGeneration: snapshot.generation,
                                        progress: Progress(), publication: publication)
                                } else { _ = try await session.updatePassword(.set, settings: .init(password: "new"), progress: Progress()) }
                            }
                        }
                    }
                    XCTFail("One plaintext file must fail verification")
                } catch { XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed) }
                XCTAssertEqual(failures.withLock { $0 }, [.encryption(index: 2, expected: "AES-256", actual: "none", isEncrypted: false)])
                XCTAssertEqual(try Data(contentsOf: url), original)
                XCTAssertTrue(session.capabilities.canEdit)
                XCTAssertFalse(session.hasKnownPassword)
                try ArchiveReencryptionTestSupport.assertNoWork(directory.url)
                await session.close()
            }
        }
    }

    private static let tarFormats: [GyoshukuKit.ArchiveFormat] = [.tar, .tarGzip, .tarBzip2, .tarXZ]

    private func archive(_ directory: ArchiveTestDirectory, format: GyoshukuKit.ArchiveFormat,
                         suffix: String? = nil) throws -> URL {
        let url = directory.url.appendingPathComponent("original." + (suffix ?? ArchiveCreationPlan.filenameExtension(for: format)))
        let writer = try ArchiveWriter.create(url: url, format: format)
        try writer.add(data: Data(repeating: 42, count: 2048), as: "keep")
        try writer.add(data: Data([2]), as: "second")
        try writer.add(data: Data([3]), as: "remove")
        try writer.finish()
        return url
    }

    private func removal(_ archive: URL) throws -> ArchiveEditPlan {
        let entries = try ArchiveReader.open(url: archive, options: .kaitoFinder()).entries
        return ArchiveEditPlan(removals: [.init(try XCTUnwrap(entries.first { $0.name == "remove" }))],
                               renames: [], existing: entries)
    }

    func testEveryTarSpellingUsesTarVerificationWithExpectedEntries() throws {
        for format in Self.tarFormats {
            for suffix in ArchiveCreationPlan.acceptedExtensions(for: format) {
                let directory = try ArchiveTestDirectory(), url = try archive(directory, format: format, suffix: suffix)
                let plan = try removal(url), verified = Mutex(false)
                try ArchiveImportTransaction.didVerifyForTesting.withValue({ work in
                    XCTAssertEqual(work.lastPathComponent, "archive." + ArchiveCreationPlan.filenameExtension(for: format))
                    let reader = try ArchiveReader.open(url: work, options: .kaitoFinderVerification())
                    XCTAssertEqual(reader.format, .tar, suffix)
                    XCTAssertEqual(reader.entries.map(\.name).sorted(), ["keep", "second"], suffix)
                    verified.withLock { $0 = true }
                }) {
                    _ = try ArchiveEditTransaction.run(plan: plan, archive: url, mode: .rewrite(format), progress: Progress())
                }
                XCTAssertTrue(verified.withLock { $0 }, suffix)
                XCTAssertEqual(try ArchiveReader.open(url: url).entries.map(\.name).sorted(), ["keep", "second"])
            }
        }
    }

    func testEveryTarSpellingRefusesTruncatedPayloadAndDroppedMemberBeforePublication() throws {
        for format in Self.tarFormats {
            for suffix in ArchiveCreationPlan.acceptedExtensions(for: format) {
                for damage in ["truncate", "drop"] {
                    let directory = try ArchiveTestDirectory(), url = try archive(directory, format: format, suffix: suffix)
                    let original = try Data(contentsOf: url), plan = try removal(url), injected = Mutex(false)
                    let codec: String
                    switch format {
                    case .tarGzip: codec = "gzip"
                    case .tarBzip2: codec = "bz2"
                    case .tarXZ: codec = "lzma"
                    default: codec = "tar"
                    }
                    XCTAssertThrowsError(try ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                        try directory.run(ExternalTool.python3, ["-c", #"""
                        import sys, pathlib, tarfile, io, gzip, bz2, lzma
                        p = pathlib.Path(sys.argv[1])
                        codec = {'gzip': gzip, 'bz2': bz2, 'lzma': lzma}.get(sys.argv[2])
                        raw = codec.decompress(p.read_bytes()) if codec else p.read_bytes()
                        source = tarfile.open(fileobj=io.BytesIO(raw), mode='r:')
                        members = source.getmembers()
                        assert [m.name for m in members] == ['keep', 'second']
                        if sys.argv[3] == 'truncate':
                            first = members[0]
                            raw = raw[:first.offset_data + first.size - 1]
                        else:
                            out = io.BytesIO()
                            with tarfile.open(fileobj=out, mode='w:') as target:
                                for member in members[1:]:
                                    target.addfile(member, source.extractfile(member))
                            raw = out.getvalue()
                        encoded = codec.compress(raw) if codec else raw
                        assert (codec.decompress(encoded) if codec else encoded) == raw
                        p.write_bytes(encoded)
                        """#, work.path, codec, damage])
                        if damage == "drop" {
                            let reader = try ArchiveReader.open(url: work, options: .kaitoFinderVerification())
                            XCTAssertEqual(reader.format, .tar)
                            XCTAssertEqual(reader.entries.map(\.name), ["second"])
                        }
                        injected.withLock { $0 = true }
                    }) {
                        try ArchiveEditTransaction.run(plan: plan, archive: url, mode: .rewrite(format), progress: Progress())
                    }, "\(suffix) \(damage)") { error in
                        XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed)
                    }
                    XCTAssertTrue(injected.withLock { $0 })
                    XCTAssertEqual(try Data(contentsOf: url), original, "\(suffix) \(damage)")
                    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
                        .contains { $0.hasPrefix(".KaitoFinder-add-") })
                }
            }
        }
    }

    func testWorkNameUsesOutputFormatInsteadOfInputSuffix() throws {
        let directory = try ArchiveTestDirectory(), url = try archive(directory, format: .zip)
        let plan = try removal(url), verified = Mutex(false)
        try ArchiveImportTransaction.didVerifyForTesting.withValue({ work in
            XCTAssertEqual(work.lastPathComponent, "archive.tar.gz")
            XCTAssertEqual(try ArchiveReader.open(url: work).format, .tar)
            verified.withLock { $0 = true }
        }) {
            _ = try ArchiveEditTransaction.run(plan: plan, archive: url, mode: .rewrite(.tarGzip), progress: Progress())
        }
        XCTAssertTrue(verified.withLock { $0 })
    }

    func testCorruptLastZIPLocalHeaderIsRefusedForUpdaterAndRewriter() throws {
        for mode: ArchiveCapabilities.Mode in [.inPlace, .rewrite(.zip)] {
            let directory = try ArchiveTestDirectory(), url = try archive(directory, format: .zip)
            let original = try Data(contentsOf: url), plan = try removal(url), injected = Mutex(false)
            XCTAssertThrowsError(try ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                var bytes = try Data(contentsOf: work)
                let offset = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x03, 0x04]), options: .backwards)?.lowerBound)
                bytes[offset + 26] = 0xff
                bytes[offset + 27] = 0xff
                try bytes.write(to: work)
                let lazy = try ArchiveReader.open(url: work, options: .kaitoFinder())
                XCTAssertEqual(lazy.entries.map(\.name).sorted(), ["keep", "second"])
                injected.withLock { $0 = true }
            }) {
                try ArchiveEditTransaction.run(plan: plan, archive: url, mode: mode, progress: Progress())
            }) { error in
                XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed)
            }
            XCTAssertTrue(injected.withLock { $0 })
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testFormatMismatchReportsEditedOutputFailureAndPreservesOriginal() throws {
        let directory = try ArchiveTestDirectory(), url = try archive(directory, format: .zip)
        let original = try Data(contentsOf: url), plan = try removal(url)
        XCTAssertThrowsError(try ArchiveImportTransaction.didCommitForTesting.withValue({ work in
            try ReleaseReviewFixtures.paxTar([("keep", "0", Data(repeating: 42, count: 2048)), ("second", "0", Data([2]))])
                .write(to: work)
            XCTAssertEqual(try ArchiveReader.open(url: work).format, .tar)
        }) {
            try ArchiveEditTransaction.run(plan: plan, archive: url, mode: .inPlace, progress: Progress())
        }) { error in
            XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed)
            XCTAssertEqual(ArchiveErrorText.describe(error), ArchivePublicationError.verificationFailed.message())
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private enum OutputDamage: CaseIterable, Sendable {
        case missing, duplicate, kind, size

        var members: [(String, Data)] {
            switch self {
            case .missing: [("a", Data("A".utf8))]
            case .duplicate: [("a", Data("A".utf8)), ("a", Data("A".utf8))]
            case .kind: [("a", Data("A".utf8)), ("renamed/", Data())]
            case .size: [("a", Data("A".utf8)), ("renamed", Data("longer".utf8))]
            }
        }
    }

    @MainActor func testWrongProjectionRefusesImmediateEditsAndDeferredSavesAndAllowsRetry() async throws {
        for behavior in [ArchivePreferences.SaveBehavior.immediate, .onSave] {
            for damage in OutputDamage.allCases {
                let fixture = try DeferredSaveFixture(behavior: behavior, files: [("a", "A"), ("b", "B")])
                let document = fixture.document, injected = Mutex(false)
                defer { document.close() }
                let selected = try await fixture.node("b")
                if behavior == .onSave {
                    _ = try await document.rename(selected, to: "renamed", progress: Progress())
                }
                do {
                    try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                        try ReleaseReviewFixtures.zip(damage.members).write(to: work)
                        // 壊れた構造ではなく、計画との不一致で拒否することを確かめる。
                        _ = try ArchiveReader.open(url: work, options: .kaitoFinderVerification())
                        injected.withLock { $0 = true }
                    }) {
                        if behavior == .onSave { try await fixture.save() }
                        else { _ = try await document.rename(selected, to: "renamed", progress: Progress()) }
                    }
                    XCTFail("Published \(damage) for \(behavior)")
                } catch {
                    let reported = error as NSError
                    let underlying = reported.userInfo[NSUnderlyingErrorKey] as? NSError ?? reported
                    let expected = ArchivePublicationError.verificationFailed as NSError
                    XCTAssertEqual(underlying.domain, expected.domain)
                    XCTAssertEqual(underlying.code, expected.code)
                    XCTAssertEqual(underlying.localizedDescription, expected.localizedDescription)
                }
                XCTAssertTrue(injected.withLock { $0 })
                XCTAssertEqual(try Data(contentsOf: fixture.archive), fixture.original)
                if behavior == .onSave {
                    XCTAssertTrue(document.isDocumentEdited)
                    XCTAssertFalse(document.pendingChanges.isEmpty)
                    try await fixture.save()
                } else {
                    _ = try await document.rename(selected, to: "renamed", progress: Progress())
                }
                XCTAssertEqual(try DeferredSaveFixture.contents(fixture.archive), ["a": Data("A".utf8), "renamed": Data("B".utf8)])
            }
        }
    }

    func testWorkIdentityIsCheckedAgainAfterVerification() throws {
        for mode: ArchiveCapabilities.Mode in [.inPlace, .rewrite(.tarGzip)] {
            for replace in [false, true] {
                let directory = try ArchiveTestDirectory(), url = try archive(directory, format: .zip)
                let original = try Data(contentsOf: url), plan = try removal(url), injected = Mutex(false)
                XCTAssertThrowsError(try ArchiveImportTransaction.didVerifyForTesting.withValue({ work in
                    let before = try ArchiveSetIdentity.capture(url: work)
                    if replace {
                        try Data(contentsOf: work).write(to: work, options: .atomic)
                    } else {
                        let handle = try FileHandle(forWritingTo: work)
                        defer { try? handle.close() }
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data([0]))
                    }
                    XCTAssertNotEqual(try ArchiveSetIdentity.capture(url: work), before)
                    injected.withLock { $0 = true }
                }) {
                    try ArchiveEditTransaction.run(plan: plan, archive: url, mode: mode, progress: Progress())
                }) { error in
                    XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed)
                }
                XCTAssertTrue(injected.withLock { $0 })
                XCTAssertEqual(try Data(contentsOf: url), original)
            }
        }
    }

    func testAdditionSizeChangesAfterPlanningAreAllowed() throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tarGzip] {
            let directory = try ArchiveTestDirectory(), url = try archive(directory, format: format)
            let entries = try ArchiveReader.open(url: url, options: .kaitoFinder()).entries
            let source = directory.url.appendingPathComponent("added")
            try Data([1]).write(to: source)
            let plan = try ArchiveImportPlan.build(urls: [source], folder: "", existing: entries, progress: Progress(), format: format)
            try Data(repeating: 7, count: 1234).write(to: source)
            _ = try ArchiveImportTransaction.run(plan: plan, archive: url,
                mode: format == .zip ? .inPlace : .rewrite(format), progress: Progress())
            XCTAssertEqual(try ArchiveReader.open(url: url).entries.first { $0.name == "added" }?.uncompressedSize, 1234)
        }
    }

    func testSharedProjectionUsesNFCMultisetsKindsSizesAndOnlyOmitsDirectoryRoot() throws {
        func entry(_ name: String, kind: EntryKind = .file, size: UInt64 = 1) -> ArchiveEntry {
            ArchiveEntry(index: 0, rawName: .init(bytes: Array(name.utf8)), name: name,
                pathComponents: ArchivePath.components(name), kind: kind, uncompressedSize: size, compressedSize: nil,
                modificationDate: nil, posixPermissions: nil, isEncrypted: false, solidGroup: -1, crc32: nil,
                methodDescription: "", formatSpecific: [:])
        }
        let a = entry("./cafe\u{301}"), b = entry("b", kind: .symlink), sidecar = entry("__MACOSX/._b", size: 80)
        let projection = ArchiveOutputProjection(projected: [entry("./", kind: .directory, size: 0), a, b, sidecar], mode: .rewrite(.zip))
        XCTAssertNoThrow(try projection.validate(entries: [sidecar, b, entry("café")]))
        XCTAssertThrowsError(try projection.validate(entries: [a, b]))
        XCTAssertThrowsError(try projection.validate(entries: [a, b, sidecar, a]))
        XCTAssertThrowsError(try projection.validate(entries: [entry("café", size: 2), b, sidecar]))
        for kind: EntryKind in [.file, .directory, .hardlink] {
            XCTAssertThrowsError(try projection.validate(entries: [a, entry("b", kind: kind), sidecar]))
        }
        XCTAssertThrowsError(try projection.validate(entries: [a, b, sidecar, entry(".")]))
        let duplicates = ArchiveOutputProjection(existing: [a, a], additions: [.init(adding: "café", kind: .file)], mode: .inPlace)
        XCTAssertNoThrow(try duplicates.validate(entries: [entry("café", size: 42), a, a]))
        XCTAssertThrowsError(try duplicates.validate(entries: [entry("café", size: 42), a]))
    }

    func testTarRootOmissionAndExposedAppleDoubleSurvivePublication() throws {
        let fixture = try ScenarioFixture(script: #"""
        sidecar = struct.pack('>II16sHIII', 0x00051607, 0x00020000, bytes(16), 1, 2, 38, 7) + b'sidecar'
        with tarfile.open(p, 'w') as t:
            root = tarfile.TarInfo('./'); root.type = tarfile.DIRTYPE; t.addfile(root)
            for name, payload in [('cafe\u0301', b'body'), ('__MACOSX/._cafe\u0301', sidecar), ('remove', b'x')]:
                member = tarfile.TarInfo(name); member.size = len(payload); t.addfile(member, io.BytesIO(payload))
        """#, suffix: "tar")
        let plan = try removal(fixture.archive)
        XCTAssertEqual(plan.existing.count, 4)
        XCTAssertTrue(try ArchiveReader.open(url: fixture.archive).entries.contains { $0.formatSpecific["fork"] == "resource" })
        _ = try ArchiveEditTransaction.run(plan: plan, archive: fixture.archive, mode: .rewrite(.tar), progress: Progress())
        let reader = try ArchiveReader.open(url: fixture.archive, options: .kaitoFinderVerification())
        XCTAssertEqual(reader.entries.map(\.name).sorted(), ["__MACOSX/._café", "café"])
        XCTAssertEqual(reader.entries.map(\.uncompressedSize), [4, 45])
    }

    func testZIPVerificationCostAt100kEntries() throws {
        let directory = try ArchiveTestDirectory(), url = directory.url.appendingPathComponent("100k.zip")
        try directory.run(ExternalTool.python3, ["-c", #"""
        import sys, zipfile
        with zipfile.ZipFile(sys.argv[1], 'w', compression=zipfile.ZIP_STORED) as archive:
            for i in range(100000):
                archive.writestr('entry-%06d' % i, b'x')
        """#, url.path])
        XCTAssertTrue(ReaderOptions.kaitoFinder().lazyLocalHeaders)
        XCTAssertFalse(ReaderOptions.kaitoFinderVerification().lazyLocalHeaders)
        func measured(_ eager: Bool) throws -> Double {
            let start = ContinuousClock.now
            let reader = try ArchiveReader.open(url: url, options: eager ? .kaitoFinderVerification() : .kaitoFinder())
            let duration = start.duration(to: .now).components
            XCTAssertEqual(reader.entries.count, 100_000)
            return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        }
        _ = try measured(false)
        _ = try measured(true)
        var lazy: [Double] = [], eager: [Double] = []
        for index in 0..<3 {
            if index.isMultiple(of: 2) { lazy.append(try measured(false)); eager.append(try measured(true)) }
            else { eager.append(try measured(true)); lazy.append(try measured(false)) }
        }
        let before = lazy.sorted()[1], after = eager.sorted()[1]
        print(String(format: "PROBE P0 ZIP entries=100000 warm median of 3: lazy=%.3f ms eager=%.3f ms extra=%.3f ms", before, after, after - before))
    }
}
