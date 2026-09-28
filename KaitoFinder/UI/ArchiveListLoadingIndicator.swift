import AppKit

/// 一覧の読み込み中に回すスピナー。開始から revealDelay 待っても終わらないときだけ表示する。
/// 非同期の検索中も同じインジケータを使い、読み上げラベルだけを切り替える。
final class ArchiveListLoadingIndicator {
    let view = NSProgressIndicator()
    private let bundle: Bundle
    /// 進行中の読み込みの token。nil なら読み込み中ではない。
    private(set) var token: UUID?
    private var revealTask: Task<Void, Never>?
    private(set) var isVisible = false
    private(set) var isFilterPending = false
    /// 表示状態が変わったときに呼ぶ。ステータスバーの文言を合わせるのに使う。
    var didChange: () -> Void = {}

    init(bundle: Bundle) {
        self.bundle = bundle
        view.style = .spinning
        view.controlSize = .small
        view.isIndeterminate = true
        view.isDisplayedWhenStopped = false
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityLabel(String(localized: "項目を読み込んでいます…", bundle: bundle))
    }

    /// 前の読み込みを取り消して新しい token を発行する。revealDelay 後もその token が現役なら表示する。
    @discardableResult func begin() -> UUID {
        cancel()
        let token = UUID()
        self.token = token
        let revealAt = ContinuousClock.now + ArchiveProgressTiming.revealDelay
        revealTask = Task { [weak self] in
            do { try await Task.sleep(until: revealAt, clock: .continuous) }
            catch { return }
            guard let self, self.isCurrent(token) else { return }
            self.isVisible = true
            self.update()
        }
        return token
    }

    func isCurrent(_ token: UUID) -> Bool { self.token == token }

    func finish(_ token: UUID) {
        guard isCurrent(token) else { return }
        cancel()
    }

    func cancel() {
        token = nil
        revealTask?.cancel()
        revealTask = nil
        isVisible = false
        update()
    }

    /// 非同期の検索が続いているあいだ「検索しています…」として回す。
    func update(filterPending: Bool) {
        isFilterPending = filterPending
        update()
    }

    private func update() {
        let visible = isVisible || isFilterPending
        view.isHidden = !visible
        view.setAccessibilityLabel(isVisible
            ? String(localized: "項目を読み込んでいます…", bundle: bundle)
            : String(localized: "検索しています…", bundle: bundle))
        if visible { view.startAnimation(nil) }
        else { view.stopAnimation(nil) }
        didChange()
    }
}
