import Foundation

/// AppKit の終了レビューは文書を documents から除いた後に applicationShouldTerminate を呼ぶ。
@MainActor final class DocumentCleanupRegistry {
    static let shared = DocumentCleanupRegistry()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    var hasPendingCleanup: Bool { !tasks.isEmpty }

    func track(_ task: Task<Void, Never>) {
        let id = UUID()
        tasks[id] = task
        Task { await task.value; tasks.removeValue(forKey: id) }
    }

    func waitUntilEmpty() async {
        while let task = tasks.values.first { await task.value; await Task.yield() }
    }
}
