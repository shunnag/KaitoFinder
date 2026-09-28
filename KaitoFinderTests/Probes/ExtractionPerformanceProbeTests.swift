import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class ExtractionPerformanceProbeTests: XCTestCase {
    func testFiftyThousandFileZIPSerialVersusParallel() throws {
        guard TestEnvironment.isEnabled(.performanceProbes) else {
            throw XCTSkip("Set KAITOFINDER_PERFORMANCE_PROBES=1 to run extraction throughput probes")
        }
        let fixture = try ScenarioFixture(script: ScenarioFixture.zipScript(count: 50_000, size: 256))
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        var durations: [Double] = []
        for (name, execution) in [("serial", ExtractionExecution.serial), ("parallel", .parallel(workers: workers))] {
            let destination = fixture.root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let reader = try ArchiveReader.open(url: fixture.archive), progress = Progress()
            let start = Date()
            let result = try ExtractionService.extractResolved(reader.entries, reader: reader, to: destination,
                quarantine: nil, progress: progress, execution: execution)
            let elapsed = Date().timeIntervalSince(start)
            durations.append(elapsed)
            XCTAssertFalse(result.cancelled)
            XCTAssertTrue(result.failures.isEmpty)
            XCTAssertEqual(result.written.count, 50_021)
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
            print(String(format: "50k ZIP %@: %.3f s (%d workers)", name, elapsed, name == "serial" ? 1 : workers))
        }
        print(String(format: "50k ZIP speedup: %.2fx", durations[0] / durations[1]))
    }
}
