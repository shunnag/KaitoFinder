import Foundation
@testable import KaitoFinder

/// 生成した時点の文書ウインドウの frame の保存値を写し取り、`restore()` でその値へ戻す（値がなければ消す）。
/// 各テストの前の消去と全テスト後の復元は TestProcessSetup が担う。これはテストの中で保存値を戻したい箇所だけが使う。
@MainActor struct ArchiveWindowFrameSnapshot {
    private static let key = "NSWindow Frame \(ArchiveWindowController.frameAutosaveName)"
    private let frame = UserDefaults.standard.string(forKey: key)

    func restore() {
        if let frame { UserDefaults.standard.set(frame, forKey: Self.key) }
        else { UserDefaults.standard.removeObject(forKey: Self.key) }
    }
}
