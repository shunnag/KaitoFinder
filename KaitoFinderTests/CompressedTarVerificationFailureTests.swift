import Darwin
import Foundation
@_spi(Testing) import GyoshukuKit
@_spi(TarEditLayout) import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class CompressedTarVerificationFailureTests: XCTestCase {
    private func assertUnchanged(_ session: ArchiveSession, archive: URL, bytes: Data,
                                 identity: ArchiveFileIdentity, entries: [ArchiveEntry], generation: UInt64) async throws {
        XCTAssertEqual(try Data(contentsOf: archive), bytes)
        XCTAssertEqual(try ArchiveFileIdentity.capture(url: archive), identity)
        let current = await session.entries()
        XCTAssertEqual(current, entries); XCTAssertEqual(session.generation, generation)
        XCTAssertTrue(session.capabilities.canEdit)
        try CompressedTarFixture.assertNoWork(archive.deletingLastPathComponent())
    }

    func testUpdaterSelfChecksAndIndependentK5FaultsNeverPublish() async throws {
        for format in CompressedTarFixture.formats {
            let directory = try ArchiveTestDirectory(), archive = try CompressedTarFixture.make(directory.url, format: format, large: true)
            let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
            let faults: [CompressedTarUpdater.Fault] = format == .tarGzip
                ? [.trailerCRC, .missingDictionaryProtection, .flipEncodedByte, .shiftLedger]
                : format == .tarBzip2 ? [.dropBzip2Stream, .flipEncodedByte, .shiftLedger]
                : [.xzIndexLength, .dropXZBlock, .flipEncodedByte, .shiftLedger]
            for skipsSelfCheck in [false, true] {
                // shiftLedger changes GK's internal image ledger, which is not part of K5's public segment list.
                let selected = skipsSelfCheck ? faults.filter { $0 != .shiftLedger } + [.flipReusedByte] : faults + [.flipReusedByte]
                for fault in selected {
                    let session = try ArchiveSession(url: archive), entries = await session.entries(), trace = CompressedTarTrace()
                    let reasons = Mutex<[ArchiveVerificationFailure]>([])
                    do {
                        try await trace.observing {
                            try await ArchiveVerificationFailure.observer.withValue({ failure in reasons.withLock { $0.append(failure) } }) {
                                try await CompressedTarUpdater.$testingSkipsSelfCheck.withValue(skipsSelfCheck) {
                                    try await CompressedTarUpdater.$testingFault.withValue(fault) {
                                        _ = try await session.rename(TarUpdateFixture.selection(entries[0]), to: "other", progress: Progress())
                                    }
                                }
                            }
                        }
                        XCTFail("Published \(format)/\(fault)/skip=\(skipsSelfCheck)")
                    } catch { XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed, "\(format)/\(fault): \(error)") }
                    XCTAssertEqual(reasons.withLock { $0.count }, 1)
                    if !skipsSelfCheck && fault != .flipReusedByte {
                        guard case .updaterVerification = reasons.withLock({ $0.first }) else { return XCTFail("GK self-check did not reject \(fault)") }
                    }
                    XCTAssertEqual(trace.fullVerifications.value, 0); XCTAssertEqual(trace.rewrites.value, 0)
                    XCTAssertTrue(trace.adoptions.withLock { $0.isEmpty })
                    try await assertUnchanged(session, archive: archive, bytes: original, identity: identity, entries: entries, generation: 0)
                    await session.close()
                }
            }
        }
    }

    func testWorkReplacementAndMtimeChangesRejectTheCommitIdentity() async throws {
        for format in CompressedTarFixture.formats {
            for replace in [false, true] {
                let directory = try ArchiveTestDirectory(), archive = try CompressedTarFixture.make(directory.url, format: format)
                let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
                let session = try ArchiveSession(url: archive), entries = await session.entries(), trace = CompressedTarTrace()
                do {
                    try await trace.observing {
                        try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                            if replace { try Data(contentsOf: work).write(to: work, options: .atomic) }
                            else { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: work.path) }
                        }) { _ = try await session.createFolder(in: "", baseName: "new", progress: Progress()) }
                    }
                    XCTFail("Changed work identity was published")
                } catch { XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed) }
                XCTAssertFalse(trace.stages.withLock { $0.contains(.verificationOpen) })
                XCTAssertEqual(trace.fullVerifications.value, 0)
                try await assertUnchanged(session, archive: archive, bytes: original, identity: identity, entries: entries, generation: 0)
                await session.close()
            }
        }
    }

    func testSameInodeSameSizeRestoredMtimeSourceMutationIsRejected() async throws {
        for format in CompressedTarFixture.formats {
            let directory = try ArchiveTestDirectory(), archive = try CompressedTarFixture.make(directory.url, format: format, large: true)
            var times = [timeval(tv_sec: 1_700_000_000, tv_usec: 0), timeval(tv_sec: 1_700_000_000, tv_usec: 0)]
            XCTAssertEqual(utimes(archive.path, &times), 0)
            let base = try XCTUnwrap(CompressedTarFixture.open(archive).tarEditingSnapshot())
            let session = try ArchiveSession(url: archive), entries = await session.entries(), identity = try ArchiveFileIdentity.capture(url: archive)
            let chunk = try XCTUnwrap(base.chunkMap?.chunks.first { $0.imageRange.count > 100_000 })
            let offset = chunk.compressedRange.lowerBound + UInt64(chunk.compressedRange.count / 2)
            let handle = try FileHandle(forUpdating: archive)
            var byte = try CompressedTarFixture.bytes(base.archive, range: offset..<(offset + 1)); byte[0] ^= 1
            XCTAssertEqual(byte.withUnsafeBytes { pwrite(handle.fileDescriptor, $0.baseAddress!, 1, off_t(offset)) }, 1)
            try handle.close(); XCTAssertEqual(utimes(archive.path, &times), 0)
            XCTAssertTrue(base.archiveIsUnchanged())
            let changed = try Data(contentsOf: archive)
            do { _ = try await session.createFolder(in: "", baseName: "new", progress: Progress()); XCTFail("Source mutation was ignored") }
            catch { XCTAssertEqual(error as? UpdaterError, .sourceChanged) }
            try await assertUnchanged(session, archive: archive, bytes: changed, identity: identity, entries: entries, generation: 0)
            await session.close()
        }
    }

    func testCancellationDuringMutationCommitAndK5PreservesOriginal() async throws {
        for format in CompressedTarFixture.formats {
            for stage: ArchiveStageDiagnostics.Stage in [.mutate, .commit, .verificationOpen] {
                let directory = try ArchiveTestDirectory(), archive = try CompressedTarFixture.make(directory.url, format: format)
                let session = try ArchiveSession(url: archive), entries = await session.entries()
                let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
                let progress = Progress(), reached = ArchiveTestCounter()
                let observation = progress.observe(\.completedUnitCount, options: [.new]) { @Sendable value, _ in
                    if stage == .commit, value.totalUnitCount > 1000, value.completedUnitCount > 1 {
                        reached.increment(); value.cancel(); withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
                defer { observation.invalidate() }
                let task = Task {
                    try await ArchiveStageDiagnostics.observer.withValue({ event in
                        if case .began(_, let current) = event, current == stage, stage != .commit {
                            reached.increment(); progress.cancel(); withUnsafeCurrentTask { $0?.cancel() }
                        }
                    }) { _ = try await session.createFolder(in: "", baseName: "new", progress: progress) }
                }
                do { try await task.value; XCTFail("Cancellation ignored at \(stage)") }
                catch { XCTAssertTrue(error is CancellationError, "\(error)") }
                XCTAssertGreaterThan(reached.value, 0)
                try await assertUnchanged(session, archive: archive, bytes: original, identity: identity, entries: entries, generation: 0)
                await session.close()
            }
        }
    }

    func testCancellationAfterPublicationStillAdopts() async throws {
        for format in CompressedTarFixture.formats {
            let directory = try ArchiveTestDirectory(), archive = try CompressedTarFixture.make(directory.url, format: format)
            let session = try ArchiveSession(url: archive), trace = CompressedTarTrace()
            let task = Task {
                try await trace.observing {
                    try await ArchiveImportTransaction.didPublishForTesting.withValue({ _ in withUnsafeCurrentTask { $0?.cancel() } }) {
                        let result = try await session.createFolder(in: "", baseName: "new", progress: Progress())
                        XCTAssertNil(result.reloadFailure)
                    }
                }
            }
            try await task.value
            trace.assertAdopted(); XCTAssertEqual(session.generation, 1)
            await session.close()
        }
    }
}
