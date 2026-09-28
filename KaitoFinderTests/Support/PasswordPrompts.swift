import Foundation
import Synchronization
import XCTest
@testable import KaitoFinder

/// `ArchiveSession.setPasswordPrompt` に渡す、テストでよく使う応答。
nonisolated enum PasswordPrompts {
    /// 呼ばれたらテストを失敗にして取り消す。パスワードを要求しない・既知のパスワードを再利用するはずの経路に使う。
    static func refusing(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> ArchiveSession.PasswordPrompt {
        { _ in
            XCTFail(message, file: file, line: line)
            throw CancellationError()
        }
    }

    /// 毎回 `password` を返す。
    static func fixed(_ password: String) -> ArchiveSession.PasswordPrompt {
        { _ in password }
    }

    /// 呼ばれた回数を数える。`password` が nil なら毎回取り消す。
    static func counting(returning password: String? = nil) -> CountingPasswordPrompt {
        CountingPasswordPrompt(password: password)
    }
}

/// `PasswordPrompts.counting(returning:)` が返す。`prompt` を setPasswordPrompt に渡し、`count` で回数を読む。
nonisolated final class CountingPasswordPrompt: Sendable {
    private let calls = Mutex(0)
    private let password: String?

    init(password: String?) { self.password = password }

    var count: Int { calls.withLock { $0 } }

    var prompt: ArchiveSession.PasswordPrompt {
        { [self] _ in
            calls.withLock { $0 += 1 }
            guard let password else { throw CancellationError() }
            return password
        }
    }
}
