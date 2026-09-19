import Foundation
import XCTest
@testable import KaitoFinder

nonisolated final class TestProcessSetup: NSObject, XCTestObservation {
    static let autosaveKeys = [
        "NSTableView Sort Ordering v2 \(ArchiveWindowController.columnsAutosaveName)",
        "NSTableView Columns v3 \(ArchiveWindowController.columnsAutosaveName)",
        "NSTableView Supports v2 \(ArchiveWindowController.columnsAutosaveName)",
        "NSToolbar Configuration \(ArchiveWindowController.toolbarAutosaveName)",
        "NSWindow Frame \(ArchiveWindowController.frameAutosaveName)",
        "NSWindow Frame \(PreferencesWindowController.frameAutosaveName)"
    ]

    private let savedAutosaveValues: [String: Any]

    override init() {
        savedAutosaveValues = Dictionary(uniqueKeysWithValues: Self.autosaveKeys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
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

        // テストホストは実アプリのdefaultsを使う。ユーザーの値を開始時に退避し、
        // 各テストの前にAppKitの保存値を消して、並び順や列・ウインドウの状態を隔離する。
        // ObservationCenterがobserverを保持し、全テストの終了後に元の値を戻す。
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    static func resetAutosaveDefaults() {
        for key in autosaveKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        Self.resetAutosaveDefaults()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        for key in Self.autosaveKeys {
            if let value = savedAutosaveValues[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        XCTestObservationCenter.shared.removeTestObserver(self)
    }
}
