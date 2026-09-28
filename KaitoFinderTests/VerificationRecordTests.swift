import Foundation
import XCTest

/// 日付つきの検証記録（Documentation/verification/）が、そこで約束した規則の記述を保っていることを確かめる。
/// 記録の置き場所や名前を変えたときは、この file の path だけを直す（処理を検査するテストは記録を読まない）。
nonisolated final class VerificationRecordTests: XCTestCase {
    /// 分割セットの公開（VolumeSetPublication・VolumePublishRecovery）の検証記録。
    private static let volumeSetPublisherReport = TestPaths.repositoryRoot
        .appendingPathComponent("Documentation/verification/2026-09-23-volume-set-publisher.md")

    func testVerificationReportDescribesRound2RecoveryRules() throws {
        let report = try String(contentsOf: Self.volumeSetPublisherReport, encoding: .utf8)
        for term in ["Round 2", ".discard", "journal last", "getmntinfo", "NFC", "length + SHA-256", "any volume", "NSCocoaErrorDomain Code=512"] {
            XCTAssertTrue(report.contains(term), "Missing correction evidence: \(term)")
        }
        XCTAssertFalse(report.contains("Never retire/place/restore live names or require the new set still to exist."))
    }

    func testVerificationReportCoversRound3RecoveryRules() throws {
        let report = try String(contentsOf: Self.volumeSetPublisherReport, encoding: .utf8)
        for term in ["Round 3", "stored path first", "staging-locks", "keptOldVolumes", "EBUSY", "coalesc", "non-local", "hint"] {
            XCTAssertTrue(report.contains(term), "Missing round-3 rule: \(term)")
        }
        XCTAssertFalse(report.contains("A done staging with a freshly proven live new set cannot block"))
    }

    func testVerificationReportCoversRound4RecoveryRules() throws {
        let report = try String(contentsOf: Self.volumeSetPublisherReport, encoding: .utf8)
        for term in ["Round 4", "FSKit", "incomplete enumeration", "set lock → staging lock", "running job", "stored-path probes", "unlink"] {
            XCTAssertTrue(report.contains(term), "Missing round-4 rule: \(term)")
        }
    }
}
