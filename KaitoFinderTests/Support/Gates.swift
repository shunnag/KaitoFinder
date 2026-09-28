import Foundation
import Synchronization
import XCTest

/// 固定 sleep に頼らず、最初の実書き込みを止めて競合する操作を再現する。
nonisolated final class ScenarioGate: Sendable {
    private let entered = Mutex(false)
    private let semaphore = DispatchSemaphore(value: 0)
    var isEntered: Bool { entered.withLock { $0 } }
    func pauseOnce() {
        let first = entered.withLock { value in
            if value { return false }
            value = true
            return true
        }
        if first { XCTAssertEqual(semaphore.wait(timeout: .now() + 20), .success, "競合テストの解除待ちが時間切れ") }
    }
    func release() { semaphore.signal() }
}
