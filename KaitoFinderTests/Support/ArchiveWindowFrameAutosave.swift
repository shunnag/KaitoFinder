import Foundation
import XCTest
@testable import KaitoFinder

@MainActor struct ArchiveWindowFrameAutosave {
    private static let key = "NSWindow Frame \(ArchiveWindowController.frameAutosaveName)"
    private let frame = UserDefaults.standard.string(forKey: key)

    func restore() {
        if let frame { UserDefaults.standard.set(frame, forKey: Self.key) }
        else { UserDefaults.standard.removeObject(forKey: Self.key) }
    }
}

extension XCTestCase {
    @MainActor func preserveArchiveWindowFrame() {
        let autosave = ArchiveWindowFrameAutosave()
        // 後で登録する文書のcloseを先に済ませ、最後にユーザーの保存値を戻す。
        addTeardownBlock { @MainActor in autosave.restore() }
    }
}
