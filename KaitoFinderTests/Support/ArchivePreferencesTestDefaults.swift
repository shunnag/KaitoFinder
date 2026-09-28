import Foundation
import GyoshukuKit
import Synchronization
import XCTest
@testable import KaitoFinder

/// 各テスト専用の永続ドメインを使い、実際の利用者の設定を変更しない。
nonisolated final class ArchivePreferencesTestDefaults {
    let name = "KaitoFinder-PreferencesTests-" + UUID().uuidString
    let defaults: UserDefaults
    init() throws { defaults = try XCTUnwrap(UserDefaults(suiteName: name)) }
    deinit { defaults.removePersistentDomain(forName: name) }
}
