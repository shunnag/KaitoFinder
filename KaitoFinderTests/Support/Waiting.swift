import Foundation
import XCTest

extension XCTestCase {
    @MainActor func scenarioWait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), "シーンの状態遷移が時間切れ", file: file, line: line)
        guard predicate() else { throw ScenarioTimeout.expired }
    }
}

private nonisolated enum ScenarioTimeout: Error { case expired }
