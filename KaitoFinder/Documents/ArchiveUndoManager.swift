import Foundation

/// 非同期の置換中に二つ目の undo が同期の履歴だけを進めないようにする。
final class ArchiveUndoManager: UndoManager {
    var isSuspended = false
    override var canUndo: Bool { !isSuspended && super.canUndo }
    override var canRedo: Bool { !isSuspended && super.canRedo }
    override func undo() { if canUndo { super.undo() } }
    override func redo() { if canRedo { super.redo() } }

    override func setActionName(_ actionName: String) {
        // 文書が保存する操作名はカタログのキー。redo の再登録にも同じ翻訳を使う。
        super.setActionName(String(localized: String.LocalizationValue(actionName)))
    }

    override func undoMenuTitle(forUndoActionName actionName: String) -> String {
        if actionName == String(localized: "パスワードの設定") { return String(localized: "パスワードの設定を取り消す") }
        if actionName == String(localized: "パスワードの変更") { return String(localized: "パスワードの変更を取り消す") }
        if actionName == String(localized: "パスワードの削除") { return String(localized: "パスワードの削除を取り消す") }
        return actionName.isEmpty ? String(localized: "取り消す") : String(localized: "取り消す — \(actionName)")
    }

    override func redoMenuTitle(forUndoActionName actionName: String) -> String {
        actionName.isEmpty ? String(localized: "やり直す") : String(localized: "やり直す — \(actionName)")
    }
}
