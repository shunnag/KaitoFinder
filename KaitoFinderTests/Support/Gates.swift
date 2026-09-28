import Foundation
import Synchronization
import XCTest

/// 固定 sleep に頼らず、最初の実書き込みを止めて競合する操作を再現する。
/// 背景スレッドの書き込み経路（willPublish・didWrite など）から呼ぶ。
/// - `pauseOnce()`: 最初の呼び出しだけ止め、以降は素通りする。解除を最大 20 秒待つ。
/// - `pause()`: 呼び出しごとに止める。main thread から呼ばれたら失敗にする。解除を最大 10 秒待つ。
/// テスト側は `waitUntil { gate.isEntered }` で停止点への到達を待ち、`release()` で解除する。
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
    func pause() {
        XCTAssertFalse(Thread.isMainThread)
        entered.withLock { $0 = true }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 10), .success)
    }
    func release() { semaphore.signal() }
}

/// Swift concurrency の経路（preopen や materialization の worker）を、テストが `release()` するまで止める。
/// - `wait()`: 待機中の task が取り消されると `CancellationError` を投げる。
/// - `waitIgnoringCancellation()`: 取り消しを無視して解除まで待つ。
/// 解除後の呼び出しはすぐ戻る。
actor AsyncGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cancellableWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if released { continuation.resume() }
                else if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { cancellableWaiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func waitIgnoringCancellation() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let waiting = waiters, cancellable = cancellableWaiters.values
        waiters.removeAll()
        cancellableWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
        for waiter in cancellable { waiter.resume() }
    }

    private func cancel(_ id: UUID) {
        cancellableWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
