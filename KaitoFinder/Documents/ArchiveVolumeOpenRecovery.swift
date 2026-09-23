import AppKit
import Foundation
import KaitoKit

/// Read-only discovery is shared by the controller (before gate normalization/type lookup) and read(from:).
nonisolated struct ArchiveVolumeOpenRecovery: Sendable {
    let gate: URL
    let stagings: [URL]
    let index: RecoverableWorkIndex
    let metadataStore: ArchiveVolumeMetadataStore

    static func discover(_ url: URL, index: RecoverableWorkIndex = .shared,
                         metadataStore: ArchiveVolumeMetadataStore = .shared) throws -> Self? {
        guard let parsed = ArchiveVolumeSet.parse(fileName: url.lastPathComponent),
              case .numbered(let stem, _) = parsed.scheme else { return nil }
        let parent = try VolumePublishDirectory(VolumePublishFS.canonicalParent(of: url))
        var gate: URL?, stages: [URL] = []
        for name in try parent.names() where VolumePublishRemoval.stagingName(name) == name {
            guard let record = try? VolumePublishJournal.inspect(parent.directory(name)), record.stem == stem else { continue }
            try record.validate(stagingName: name)
            guard record.phase != .done else { continue } // A committed backup is cleanup only.
            gate = parent.url.appendingPathComponent(record.newGate)
            stages.append(parent.url.appendingPathComponent(name, isDirectory: true))
        }
        guard let gate else { return nil }
        return Self(gate: gate, stagings: stages.sorted { $0.path < $1.path }, index: index, metadataStore: metadataStore)
    }

    func recover() async -> [VolumePublishRecovery.Result] {
        await VolumePublishRecoveryQueue.shared.recover(stagings: stagings, index: index, metadataStore: metadataStore)
    }
}

nonisolated struct ArchiveVolumeOpenError: LocalizedError, RecoverableError {
    let recovery: ArchiveVolumeOpenRecovery
    var errorDescription: String? { String(localized: "分割アーカイブの保存が中断されています") }
    var recoverySuggestion: String? { String(localized: "中断した保存を完了して開く") }
    var recoveryOptions: [String] { [String(localized: "中断した保存を完了して開く"), String(localized: "キャンセル")] }
    // Cocoa uses the asynchronous recovery entry. Never block its modal/main thread on file coordination.
    func attemptRecovery(optionIndex: Int) -> Bool { false }
    private final class Reply: @unchecked Sendable {
        let callback: (Bool) -> Void
        init(_ callback: @escaping (Bool) -> Void) { self.callback = callback }
    }
    func attemptRecovery(optionIndex: Int, resultHandler handler: @escaping (Bool) -> Void) {
        guard optionIndex == 0 else { handler(false); return }
        let reply = Reply(handler), recovery = recovery
        Task { @MainActor in
            let results = await recovery.recover()
            for result in results {
                switch result {
                case .recovered: continue
                case .owned:
                    let alert = NSAlert()
                    alert.messageText = String(localized: "別の保存または回復処理中です。しばらくしてからもう一度保存してください。")
                    alert.runModal(); reply.callback(false); return
                case .held(let staging, _, _):
                    let alert = NSAlert()
                    alert.messageText = String(localized: "分割アーカイブの回復を完了できませんでした")
                    alert.addButton(withTitle: String(localized: "キャンセル"))
                    alert.addButton(withTitle: String(localized: "Finderで表示"))
                    if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([staging]) }
                    reply.callback(false); return
                }
            }
            NSDocumentController.shared.openDocument(withContentsOf: recovery.gate, display: true) { document, _, error in
                if let error { NSApplication.shared.presentError(error) }
                reply.callback(document != nil && error == nil)
            }
        }
    }
}
