import AppKit
import Darwin
import Synchronization

/// byte は同一ボリュームの clone に置き、ロックにはその所在だけを持たせる。
nonisolated final class ArchiveUndoStack: Sendable {
    struct Slot: Sendable {
        let id: UUID
        let directory: URL
        let url: URL
        let byteCount: UInt64
        let isRedo: Bool
    }

    enum Failure: Error {
        case closed, missingSlot, cloningUnsupported, sourceChanged
    }

    typealias Clone = @Sendable (URL, URL) -> Int32
    let maximumCount: Int
    let maximumBytes: UInt64
    private let clone: Clone
    private struct State {
        var slots: [Slot] = []
        var cloningSupported = true
        var closed = false
    }
    private let storage = Mutex(State())

    init(maximumCount: Int = 10, maximumBytes: UInt64 = 2 * 1024 * 1024 * 1024,
         clone: @escaping Clone = ArchiveUndoStack.cloneFile) {
        self.maximumCount = min(10, max(0, maximumCount))
        self.maximumBytes = maximumBytes
        self.clone = clone
    }

    var slots: [Slot] { storage.withLock { $0.slots } }
    var retainedBytes: UInt64 { storage.withLock { Self.bytes(in: $0.slots) } }
    var canUndoNextMutation: Bool {
        storage.withLock { !$0.closed && $0.cloningSupported && maximumCount > 0 }
    }

    static func cloneFile(from source: URL, to destination: URL) -> Int32 {
        // copyItem は非 APFS で全量コピーに落ちるため、ここでは使えない。
        clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 ? 0 : errno
    }

    // 原本の公開直前に呼び、公開の成否が決まるまでは履歴へ登録しない。
    func capture(_ archive: URL, id: UUID = UUID(), isRedo: Bool = false) throws -> Slot? {
        guard storage.withLock({ !$0.closed }) else { throw Failure.closed }
        let info = try Self.attributes(archive)
        let manager = FileManager.default
        let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: archive, create: true)
        let url = directory.appendingPathComponent("archive.zip")
        var kept = false
        defer { if !kept { Self.remove(directory) } }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let code = clone(archive, url)
        if code == ENOTSUP || code == EXDEV {
            storage.withLock { $0.cloningSupported = false }
            return nil
        }
        guard code == 0 else { throw ExtractionFailure.system(code) }
        // 作業用の mode が原本へ戻らないよう、swap 側で置換直前の mode を復元する。
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        storage.withLock { $0.cloningSupported = true }
        kept = true
        return Slot(id: id, directory: directory, url: url, byteCount: UInt64(info.st_size), isRedo: isRedo)
    }

    func discard(_ slot: Slot?) {
        if let slot { Self.remove(slot.directory) }
    }

    func recordMutation(_ slot: Slot?) {
        let discarded = storage.withLock { state in
            // 取り消せない編集を跨いで古い snapshot を戻すと、その編集まで消えてしまう。
            guard let slot, !state.closed else {
                let discarded = state.slots + (slot.map { [$0] } ?? [])
                state.slots = []
                return discarded
            }
            var discarded = state.slots.filter(\.isRedo)
            state.slots.removeAll(where: \.isRedo)
            state.slots.append(slot)
            discarded += evict(&state)
            return discarded
        }
        for slot in discarded { discard(slot) }
    }

    @concurrent func finishMutation(_ slot: Slot?, published: Bool) async {
        if published { recordMutation(slot) }
        else { discard(slot) }
    }

    /// 置換後の属性エラーは別に返し、呼び出し側が必ず reader と世代を更新できるようにする。
    func swap(_ id: UUID, archive: URL) throws -> (any Error)? {
        guard let slot = storage.withLock({ $0.slots.first { $0.id == id } }) else {
            throw Failure.missingSlot
        }
        let before = try Self.attributes(archive)
        let quarantine = try ExtractionQuarantine.read(from: archive)
        guard let inverse = try capture(archive, id: id, isRedo: !slot.isRedo) else {
            throw Failure.cloningUnsupported
        }
        do {
            try Task.checkCancellation()
            guard Self.unchanged(before, try Self.attributes(archive)) else { throw Failure.sourceChanged }
            _ = try FileManager.default.replaceItemAt(archive, withItemAt: slot.url)
        } catch {
            discard(inverse)
            throw error
        }
        let restorationFailure: (any Error)?
        do {
            // ArchiveUpdater.commit() と同じ順序。replaceItemAt は quarantine を落とす。
            try FileManager.default.setAttributes([.posixPermissions: before.st_mode & 0o7777],
                                                   ofItemAtPath: archive.path)
            if let quarantine { try ExtractionQuarantine.apply(quarantine, to: archive) }
            restorationFailure = nil
        } catch { restorationFailure = error }
        let discarded = storage.withLock { state in
            state.slots.removeAll { $0.id == id }
            state.slots.append(inverse)
            return evict(&state)
        }
        discard(slot)
        for slot in discarded { discard(slot) }
        return restorationFailure
    }

    private func evict(_ state: inout State) -> [Slot] {
        var discarded: [Slot] = []
        while state.slots.count > maximumCount || Self.bytes(in: state.slots) > maximumBytes {
            discarded.append(state.slots.removeFirst())
        }
        return discarded
    }

    private static func bytes(in slots: [Slot]) -> UInt64 {
        slots.reduce(0) { $0 + $1.byteCount }
    }

    @concurrent func dispose() async {
        let discarded = storage.withLock { state in
            state.closed = true
            let slots = state.slots
            state.slots = []
            return slots
        }
        for slot in discarded { discard(slot) }
    }

    private static func remove(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { NSLog("取り消し用の一時ファイルを削除できません: %@", String(describing: error)) }
    }

    private static func attributes(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw Failure.sourceChanged }
        return info
    }

    private static func unchanged(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size
            && first.st_mode == second.st_mode
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}

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
        actionName.isEmpty ? String(localized: "取り消す") : String(localized: "取り消す — \(actionName)")
    }

    override func redoMenuTitle(forUndoActionName actionName: String) -> String {
        actionName.isEmpty ? String(localized: "やり直す") : String(localized: "やり直す — \(actionName)")
    }
}
