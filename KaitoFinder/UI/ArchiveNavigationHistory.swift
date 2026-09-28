import Foundation

/// フォルダ移動の「戻る/進む」履歴と、フォルダごとの表示状態（LRU）。ウインドウには依存しない。
nonisolated struct ArchiveNavigationHistory {
    /// 移動の種類。push は新しい移動、back / forward は履歴の往復。
    nonisolated enum Direction: Sendable, Equatable { case push, back, forward }
    /// 戻る・進むのそれぞれに残す移動の数。
    static let historyCapacity = 100
    /// 表示状態を覚えておくフォルダの数。古いものから忘れる。
    static let folderStateCapacity = 32

    private(set) var backStack: [String] = []
    private(set) var forwardStack: [String] = []
    private(set) var folderViewStates: [String: ArchiveViewState] = [:]
    private var folderViewStateOrder: [String] = []

    mutating func clear() {
        backStack.removeAll()
        forwardStack.removeAll()
        folderViewStates.removeAll()
        folderViewStateOrder.removeAll()
    }

    /// 離れるフォルダの表示状態を覚える。上限を超えたら最も古いフォルダを忘れる。
    mutating func remember(_ path: String, state: ArchiveViewState) {
        folderViewStates[path] = state
        touch(path)
        if folderViewStateOrder.count > Self.folderStateCapacity {
            folderViewStates.removeValue(forKey: folderViewStateOrder.removeFirst())
        }
    }

    /// 使ったフォルダを LRU の末尾へ動かす。
    mutating func touch(_ path: String) {
        folderViewStateOrder.removeAll { $0 == path }
        folderViewStateOrder.append(path)
    }

    func state(for path: String) -> ArchiveViewState? { folderViewStates[path] }

    /// 離れるフォルダを履歴へ積む。新しい移動では「進む」を捨てる。
    mutating func record(leaving from: String, direction: Direction) {
        switch direction {
        case .push:
            backStack.append(from)
            forwardStack.removeAll()
        case .back: forwardStack.append(from)
        case .forward: backStack.append(from)
        }
        if backStack.count > Self.historyCapacity { backStack.removeFirst(backStack.count - Self.historyCapacity) }
        if forwardStack.count > Self.historyCapacity { forwardStack.removeFirst(forwardStack.count - Self.historyCapacity) }
    }

    /// 次に戻る/進む先。取り除くのは移動が成功した後か、存在しないフォルダを飛ばすとき。
    func peek(_ direction: Direction) -> String? {
        direction == .back ? backStack.last : forwardStack.last
    }

    mutating func pop(_ direction: Direction) {
        if direction == .back { backStack.removeLast() } else { forwardStack.removeLast() }
    }

    /// 改名・移動でパスが変わったとき、履歴と表示状態を新しいパスへ追従させる。
    mutating func remap(_ moved: (String) -> String) {
        backStack = backStack.map(moved)
        forwardStack = forwardStack.map(moved)
        var states: [String: ArchiveViewState] = [:]
        var order: [String] = []
        for key in folderViewStateOrder {
            guard let state = folderViewStates[key] else { continue }
            let next = moved(key)
            states[next] = state.mappingPaths(moved)
            order.removeAll { $0 == next }
            order.append(next)
        }
        folderViewStates = states
        folderViewStateOrder = order
    }
}
