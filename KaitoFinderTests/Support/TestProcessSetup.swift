import Foundation
@testable import KaitoFinder

nonisolated final class TestProcessSetup: NSObject {
    override init() {
        super.init()
        PendingWorkRegistry.shared = PendingWorkRegistry(fileURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("KaitoFinderTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            .appendingPathComponent("pending-work.json"))
        // テストで表示されないウインドウでも、シート表示・文書のcloseは
        // _NSWindowTransformAnimationを開始する。_runBlockingが完了せず、
        // GCDワーカーを占有したまま残る（全件実行でtask_threadsが9→96、うち80が待機）。
        // プールが枯渇するとNSDocumentControllerのCoordinationキューが動けず、
        // 内包書庫を開くテストが順序依存でタイムアウトする。開始前の無効化で23以下に収まる。
        // principal classとして全テストより先に登録する。揮発性の登録ドメインのみを使い、
        // アプリの保存済み設定には書き込まない。
        UserDefaults.standard.register(defaults: ["NSAutomaticWindowAnimationsEnabled": false])
    }
}
