import Foundation
import GyoshukuKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveWriteProgressTests: XCTestCase {
    private let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha]

    func testEveryBudgetRowAndFinalPublicationUnit() throws {
        let added: UInt64 = 40 << 20, carried: UInt64 = 12 << 20, archive: UInt64 = 8 << 20
        for threads in [1, 8, 36] {
            let options = WriterOptions(compressionThreads: threads)
            for format in formats {
                let wait = options.maximumPendingInputBytes(for: format)
                for changes in [false, true] {
                    for branch in [ArchiveWriteProgress.Branch.writer(format), .updater(format, processesAdditionsAtCommit: [.tarGzip, .tarBzip2, .tarXZ].contains(format)),
                                   .rewriter(format, readsAdditionsDuringCommit: false), .rewriter(format, readsAdditionsDuringCommit: true)] {
                        let progress = Progress()
                        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 2, additions: [added, 0],
                            itemCount: 4, carriedBytes: carried, changesExisting: changes))
                        ledger.begin(branch, archiveBytes: archive, options: options)
                        let additionUnits: Int64, finish: Int64, commit: Int64
                        switch branch {
                        case .writer:
                            additionUnits = Int64(added) + 1; finish = Int64(max(1, min(added, wait))); commit = 0
                        case .updater:
                            additionUnits = Int64(added) + 1
                            finish = [.zip, .lha, .sevenZip].contains(format) ? Int64(max(1, min(added, wait))) : 0
                            commit = Int64(max(1_000, ([.tarGzip, .tarBzip2, .tarXZ, .lha].contains(format) ? added : 0) + (changes ? archive : 0)))
                        case .rewriter(_, let reads):
                            additionUnits = reads ? 2 : Int64(added) + 1; finish = 0
                            commit = Int64(max(1_000, carried + (reads ? added : 0) + min(carried + added, wait)))
                        }
                        XCTAssertEqual(progress.totalUnitCount, 2 + additionUnits + finish + commit + 1, "\(branch)")
                        ledger.didCount(2)
                        ledger.didFinishAddition(0); ledger.didFinishAddition(1)
                        XCTAssertEqual(progress.completedUnitCount, 2 + additionUnits)
                        try ledger.credit(.finishAdditions, completed: 0, total: 0)
                        XCTAssertEqual(progress.completedUnitCount, 2 + additionUnits + finish)
                        try ledger.credit(.commit, completed: 0, total: 0)
                        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount - 1)
                        ledger.didPublish()
                        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                        XCTAssertEqual(progress.userInfo[.fileTotalCountKey] as? Int, 4)
                        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 4)
                    }
                }
            }
        }
    }

    func testStoredAndBzip2FinishBudgetsFollowWriterOptionsAPI() {
        let added: UInt64 = 256 << 20
        for method: CompressionMethod in [.stored, .bzip2] {
            for threads in [1, 18, 36] {
                let options = WriterOptions(compressionMethod: method, compressionThreads: threads,
                                            powerPolicy: .alwaysUseAllCores)
                let progress = Progress()
                let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 0,
                    additions: [added], itemCount: 1, carriedBytes: 0, changesExisting: false))
                ledger.begin(.writer(.zip), archiveBytes: 0, options: options)
                XCTAssertEqual(progress.totalUnitCount, Int64(added + min(added,
                    options.maximumPendingInputBytes(for: .zip)) + 1))
            }
        }
    }

    func testEmptyAdditionsHaveNoDrainAndChangingTotalsNeverRegress() throws {
        for format in formats {
            let progress = Progress()
            let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 0, additions: [], itemCount: 0,
                                                                            carriedBytes: 0, changesExisting: false))
            ledger.begin(.updater(format, processesAdditionsAtCommit: false), archiveBytes: 100, options: .init())
            XCTAssertEqual(progress.totalUnitCount, 1_001)
            for (c, t, expected): (UInt64, UInt64, Int64) in [(0, 100, 0), (40, 100, 400), (20, 100, 400), (90, 90, 1_000), (120, 90, 1_000)] {
                try ledger.credit(.commit, completed: c, total: t)
                XCTAssertEqual(progress.completedUnitCount, expected)
            }
            ledger.didPublish()
            XCTAssertEqual(progress.completedUnitCount, 1_001)
        }
    }

    func testSlotTransitionFillsRemainderAndZeroTotalFillsBudget() throws {
        let progress = Progress()
        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 0, additions: [100, 10], itemCount: 2,
                                                                        carriedBytes: 0, changesExisting: false))
        ledger.begin(.writer(.tar), archiveBytes: 0, options: .init())
        try ledger.credit(.addition(0), completed: 40, total: 100)
        XCTAssertEqual(progress.completedUnitCount, 40)
        try ledger.credit(.addition(1), completed: 2, total: 10)
        XCTAssertEqual(progress.completedUnitCount, 102)
        try ledger.credit(.addition(1), completed: 0, total: 0)
        XCTAssertEqual(progress.completedUnitCount, 110)
        try ledger.credit(.finishAdditions, completed: 0, total: 0)
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount - 1)
    }

    func testCancellationResetAndNonthrowingPublication() throws {
        let progress = Progress()
        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 1, additions: [100], itemCount: 2,
                                                                        carriedBytes: 0, changesExisting: false))
        ledger.begin(.writer(.zip), archiveBytes: 0, options: .init())
        ledger.didCount(); ledger.didFinishAddition(0)
        ledger.reset()
        XCTAssertEqual(progress.completedUnitCount, 0)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 0)
        ledger.begin(.rewriter(.zip, readsAdditionsDuringCommit: true), archiveBytes: 0, options: .init())
        progress.cancel()
        XCTAssertThrowsError(try ledger.credit(.addition(0), completed: 0, total: 0)) { XCTAssertTrue($0 is CancellationError) }
        ledger.didPublish()
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 2)
    }

    func testCarriedItemsAndHookCanReenterLedgerRead() throws {
        let progress = Progress()
        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 0, additions: [], itemCount: 20,
            carriedBytes: 100, changesExisting: false, countsCarriedItems: true))
        ledger.begin(.rewriter(.tar, readsAdditionsDuringCommit: true), archiveBytes: 0, options: .init())
        let calls = Mutex(0)
        try ArchiveWriteProgress.didCreditForTesting.withValue({ _, done, total in
            let read = ledger.snapshot
            XCTAssertEqual(read.completed, done); XCTAssertEqual(read.total, total)
            calls.withLock { $0 += 1 }
        }) {
            try ledger.credit(.commit, completed: 50, total: 100)
        }
        XCTAssertEqual(calls.withLock { $0 }, 1)
        ledger.didCarry(7, 20); ledger.didCarry(7, 20); ledger.didCarry(5, 20)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 7)
        ledger.didCarry(20, 20)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 20)
    }

    func testSmallItemsDoNotIssueDuplicateProgressUpdates() throws {
        let progress = Progress()
        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 0, additions: [4, 0], itemCount: 2,
                                                                        carriedBytes: 0, changesExisting: false))
        ledger.begin(.writer(.tar), archiveBytes: 0, options: .init())
        let changes = Mutex(0)
        let observation = progress.observe(\.completedUnitCount) { _, _ in changes.withLock { $0 += 1 } }
        defer { observation.invalidate() }
        for index in 0..<2 {
            try ledger.credit(.addition(index), completed: 0, total: index == 0 ? 4 : 0)
            try ledger.credit(.addition(index), completed: index == 0 ? 4 : 0, total: index == 0 ? 4 : 0)
            ledger.didFinishAddition(index)
        }
        XCTAssertEqual(changes.withLock { $0 }, 2)
        XCTAssertEqual(progress.userInfo[.fileCompletedCountKey] as? Int, 2)
    }

    func testOverflowingMetadataBudgetsRemainRepresentable() throws {
        let progress = Progress()
        let ledger = ArchiveWriteProgress(progress: progress, plan: .init(counted: 1, additions: [.max, .max], itemCount: 3,
                                                                        carriedBytes: .max, changesExisting: true))
        ledger.begin(.rewriter(.tarXZ, readsAdditionsDuringCommit: false), archiveBytes: .max, options: .init())
        ledger.didCount()
        try ledger.credit(.addition(0), completed: UInt64.max - 1, total: .max)
        ledger.didFinishAddition(0); ledger.didFinishAddition(1)
        try ledger.credit(.commit, completed: 1, total: 1)
        XCTAssertEqual(progress.completedUnitCount, Int64.max - 1)
        ledger.didPublish()
        XCTAssertEqual(progress.completedUnitCount, Int64.max)
    }
}
