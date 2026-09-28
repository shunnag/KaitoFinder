import Foundation
import XCTest

extension XCTestCase {
    /// `condition` が真になるまで、main actor を 5 ms ずつ譲りながら最大 `timeout` 待つ。
    /// 時間切れは呼び出し行の失敗として記録したうえで投げ、後続の assertion を連鎖させない。
    /// `condition` を最後の引数にしているので、`waitUntil(timeout: .seconds(5)) { … }` と書ける。
    @MainActor func waitUntil(timeout: Duration = .seconds(10), _ message: @autoclosure () -> String = "状態遷移が時間切れ",
                              file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), message(), file: file, line: line)
        guard condition() else { throw WaitTimeout.expired }
    }

    /// シーン系のテストが使う `waitUntil` の別名（既定の 10 秒で待つ）。
    @MainActor func scenarioWait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("シーンの状態遷移が時間切れ", file: file, line: line, predicate)
    }
}

private nonisolated enum WaitTimeout: Error { case expired }
