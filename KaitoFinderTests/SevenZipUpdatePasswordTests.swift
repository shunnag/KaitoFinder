import Foundation
@_spi(Testing) import GyoshukuKit
@_spi(SevenZipEditLayout) import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class SevenZipUpdatePasswordTests: XCTestCase {
    func testFrozenPasswordLifecycleAndDeferredRenameUseUpdater() async throws {
        for fixture in ["g_plain", "g_aes", "g_aesh", "z_default", "z_aes", "z_aesh", "z_aesonlyh"] {
            for headers in [false, true] {
                let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.frozen(fixture, at: directory.url)
                let original = try ArchiveOracle.contents(SevenZipUpdateFixture.reader(archive), including: .nonDirectories)
                let encrypted = fixture.contains("aes")
                let session = try ArchiveSession(url: archive, password: encrypted ? "secret" : nil)
                XCTAssertEqual(session.capabilities.sevenZipAssessment?.canReencrypt, true)
                for (pass, action) in [encrypted ? ArchivePasswordAction.change : .set, .change, .remove].enumerated() {
                    let trace = SevenZipUpdateTrace(), progress = Progress(), password = action == .remove ? nil : "key-\(pass)"
                    try await trace.observing {
                        let result = try await session.updatePassword(action, settings: .init(password: password, encryptsSevenZipHeaders: headers), progress: progress)
                        XCTAssertNil(result.reloadFailure)
                    }
                    trace.assertRoute([.updaterOpen])
                    XCTAssertEqual(trace.strategies.withLock { $0 }, [.reencrypted])
                    XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 1)
                    XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                    let reader = try SevenZipUpdateFixture.reader(archive, password: password)
                    try ArchiveOutputProjection(projected: reader.entries, mode: .update(.sevenZip), sevenZipEncryption: password != nil).validate(reader)
                    XCTAssertEqual(try XCTUnwrap(reader.sevenZipEditingSnapshot()).header.isEncrypted, password != nil && headers)
                    XCTAssertEqual(try ArchiveOracle.contents(reader, including: .nonDirectories), original)
                }
                let snapshot = try await session.deferredSnapshot(), target = try XCTUnwrap(snapshot.entries.first { $0.kind == .file })
                var pending = ArchivePendingChanges()
                pending.outputEncryption = .init(password: "saved", encryptsSevenZipHeaders: headers)
                pending.renames[.init(index: target.index, expectedName: target.name, baseGeneration: snapshot.generation)] = "renamed.txt"
                let publication = ArchiveSavePublication(); defer { publication.finish() }
                let trace = SevenZipUpdateTrace(), progress = Progress()
                try await trace.observing {
                    let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: progress, publication: publication)
                    XCTAssertNil(result.reloadFailure)
                }
                trace.assertRoute([.updaterOpen])
                XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                let reader = try SevenZipUpdateFixture.reader(archive, password: "saved")
                XCTAssertEqual(reader.entries[target.index].name, "renamed.txt")
                try ArchiveOutputProjection(projected: reader.entries, mode: .update(.sevenZip), sevenZipEncryption: true).validate(reader)
                XCTAssertEqual(try XCTUnwrap(reader.sevenZipEditingSnapshot()).header.isEncrypted, headers)
                await session.close()
            }
        }
    }

    func testUnsupportedAssessmentUsesRewriterAndCompletesProgress() async throws {
        for fixture in ["bcj2"] + SevenZipUpdateFixture.fallbacks {
            let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.frozen(fixture, at: directory.url)
            let expected = try ArchiveOracle.contents(SevenZipUpdateFixture.reader(archive), including: .nonDirectories)
            let session = try ArchiveSession(url: archive)
            XCTAssertEqual(session.capabilities.sevenZipAssessment?.canReencrypt, false)
            let trace = SevenZipUpdateTrace(), progress = Progress()
            try await trace.observing {
                let result = try await session.updatePassword(.set, settings: .init(password: "new", encryptsSevenZipHeaders: true), progress: progress)
                XCTAssertNil(result.reloadFailure)
            }
            trace.assertRoute([.rewriterOpen])
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
            let reader = try SevenZipUpdateFixture.reader(archive, password: "new")
            XCTAssertEqual(try ArchiveOracle.contents(reader, including: .nonDirectories), expected)
            try ArchiveOutputProjection(projected: reader.entries, mode: .rewrite(.sevenZip), sevenZipEncryption: true).validate(reader)
            await session.close()
        }
    }

    func testOpenFallbackPasswordMutationAcceptsRewriter() throws {
        for fixture in SevenZipUpdateFixture.fallbacks {
            let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.frozen(fixture, at: directory.url)
            let entries = try SevenZipUpdateFixture.reader(archive).entries, progress = Progress(totalUnitCount: 1)
            let fallback = ArchiveTestCounter(), mutated = ArchiveTestCounter()
            try ArchiveImportTransaction.didFallBackToRewriteForTesting.withValue({ _ in fallback.increment() }) {
                try ArchiveImportTransaction.publish(archive: archive, mode: .update(.sevenZip), options: .init(password: "new"), progress: progress,
                    willPublish: nil, expectedOutput: .init(projected: entries, mode: .update(.sevenZip), sevenZipEncryption: true)) { editor in
                        mutated.increment()
                        try (editor as? any ArchiveReencrypting)?.reencryptExistingEntries(currentPassword: nil)
                    }
            }
            XCTAssertEqual(fallback.value, 1); XCTAssertEqual(mutated.value, 1)
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
            let reader = try SevenZipUpdateFixture.reader(archive, password: "new")
            XCTAssertTrue(reader.entries.allSatisfy(\.isEncrypted))
        }
    }

    func testMixedPasswordsStopDuringVerificationBeforeUpdaterOpen() async throws {
        let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.frozen("mix", at: directory.url)
        let original = try Data(contentsOf: archive), identity = try ArchiveFileIdentity.capture(url: archive)
        let reader = try SevenZipUpdateFixture.reader(archive)
        XCTAssertThrowsError(try reader.read(XCTUnwrap(reader.entries.first { $0.name == "b.bin" }))) {
            guard case KaitoError.wrongPassword = $0 else { return XCTFail("Expected wrongPassword: \($0)") }
        }
        let session = try ArchiveSession(url: archive, password: "secret"), trace = SevenZipUpdateTrace()
        do {
            try await trace.observing { _ = try await session.updatePassword(.change, settings: .init(password: "new"), progress: Progress()) }
            XCTFail("Different folder passwords must fail")
        } catch ExtractionFailure.refused(let message) {
            // P1c は一部だけ成功した wrongPassword を、既存の混在パスワードの診断に写す。
            XCTAssertEqual(message, String(localized: "選択した項目には異なるパスワードが設定されています。同じパスワードの項目ごとに展開してください。"))
        }
        trace.assertRoute([])
        XCTAssertTrue(trace.stages.withLock { $0.contains(.passwordVerification) })
        XCTAssertFalse(trace.stages.withLock { $0.contains(.commit) || $0.contains(.publish) })
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(try ArchiveFileIdentity.capture(url: archive), identity)
        XCTAssertEqual(session.generation, 0)
        try ArchiveReencryptionTestSupport.assertNoWork(directory.url)
        await session.close()
    }

    func testReencryptionFailureUsesExistingDiagnosticAndPreservesSource() async throws {
        let directory = try ArchiveTestDirectory(), archive = try SevenZipUpdateFixture.make(directory.url)
        let original = try Data(contentsOf: archive), session = try ArchiveSession(url: archive)
        let failure = UpdaterError.reencryptionFailed(index: 0, name: "keep", reason: "injected")
        do {
            try await ArchiveImportTransaction.willCommitUpdaterForTesting.withValue({ throw failure }) {
                _ = try await session.updatePassword(.set, settings: .init(password: "new"), progress: Progress())
            }
            XCTFail("Injected failure must not publish")
        } catch {
            guard case UpdaterError.reencryptionFailed = error else { return XCTFail("Unexpected: \(error)") }
            XCTAssertEqual(ArchiveErrorText.describe(error), ArchiveErrorText.describe(failure))
            XCTAssertNil(ArchivePasswordChallenge(error))
        }
        XCTAssertEqual(try Data(contentsOf: archive), original)
        XCTAssertEqual(session.generation, 0); XCTAssertTrue(session.capabilities.canEdit)
        try ArchiveReencryptionTestSupport.assertNoWork(directory.url)
        await session.close()
    }
}
