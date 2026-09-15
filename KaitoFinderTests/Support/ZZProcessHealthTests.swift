import Darwin
import Foundation
import XCTest

// XCTestの標準の名前順で最後に実行し、先行テストが残したスレッドも検査する。
nonisolated final class ZZProcessHealthTests: XCTestCase {
    func testWindowAnimationsDoNotExhaustWorkerThreads() throws {
        let defaults = UserDefaults.standard
        XCTAssertEqual(
            defaults.volatileDomain(forName: UserDefaults.registrationDomain)["NSAutomaticWindowAnimationsEnabled"] as? Bool,
            false,
            "TestProcessSetupがprincipal classとして揮発性の登録ドメインを設定していません。"
        )
        XCTAssertFalse(defaults.bool(forKey: "NSAutomaticWindowAnimationsEnabled"))

        var threadList: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let status = task_threads(mach_task_self_, &threadList, &count)
        XCTAssertEqual(status, KERN_SUCCESS, "task_threadsによるテストプロセスのスレッド数取得に失敗しました。")
        guard status == KERN_SUCCESS else { return }
        let threads = try XCTUnwrap(threadList)
        defer {
            // task_threadsが返した各ポートの送信権と配列を解放し、監査自体はリークさせない。
            for index in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(count) * MemoryLayout<thread_act_t>.stride)
            )
        }
        XCTAssertLessThanOrEqual(
            count, 48,
            "テストプロセスのスレッド数が\(count)に増加しました。ウインドウのアニメーションがGCDワーカーを占有していないか、Support/TestProcessSetup.swiftのコメントを確認してください。"
        )
    }
}
