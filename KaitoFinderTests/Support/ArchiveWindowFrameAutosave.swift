import Foundation
import XCTest

@MainActor struct ArchiveWindowFrameAutosave {
    private let frame = UserDefaults.standard.string(forKey: "NSWindow Frame ArchiveWindow")

    func restore() {
        if let frame { UserDefaults.standard.set(frame, forKey: "NSWindow Frame ArchiveWindow") }
        else { UserDefaults.standard.removeObject(forKey: "NSWindow Frame ArchiveWindow") }
    }
}

extension XCTestCase {
    @MainActor func preserveArchiveWindowFrame() {
        let autosave = ArchiveWindowFrameAutosave()
        // 後で登録する文書のcloseを先に済ませ、最後にユーザーの保存値を戻す。
        addTeardownBlock { @MainActor in autosave.restore() }
    }
}
