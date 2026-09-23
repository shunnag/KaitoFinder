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
            if try VolumePublishLock.stagingIsOwned(name, directory: index.stagingLocksURL) { continue }
            // Invalid same-stem journals still get the recovery/Finder offer. Never trust their paths.
            if (try? record.validate(stagingName: name)) != nil {
                if try record.phase == .done || restoredOldSet(record, in: parent) { continue }
                gate = parent.url.appendingPathComponent(record.newGate)
            } else {
                gate = parent.url.appendingPathComponent(parsed.scheme.fileName(forVolumeAt: 0, count: 1))
            }
            stages.append(parent.url.appendingPathComponent(name, isDirectory: true))
        }
        guard let gate else { return nil }
        return Self(gate: gate, stagings: stages.sorted { $0.path < $1.path }, index: index, metadataStore: metadataStore)
    }

    private static func restoredOldSet(_ record: VolumePublishJournalRecord, in parent: VolumePublishDirectory) throws -> Bool {
        guard record.phase == .abandoned, !record.oldVolumes.isEmpty,
              try record.oldVolumes.allSatisfy({ try $0.matches(in: parent, useHash: record.hashesOldVolumes) }) else { return false }
        let next = record.scheme.fileName(forVolumeAt: record.oldVolumes.count, count: record.oldVolumes.count + 1)
        return try parent.info(next) == nil
    }

    func recover() async -> [VolumePublishRecovery.Result] {
        await VolumePublishRecoveryQueue.shared.recover(stagings: stagings, index: index, metadataStore: metadataStore)
    }
}

nonisolated struct ArchiveVolumeOpenError: LocalizedError, RecoverableError, CustomNSError {
    static let errorDomain = "com.shunnag.KaitoFinder.split-recovery"
    var errorCode: Int { 1 }
    var errorUserInfo: [String: Any] {
        [NSLocalizedDescriptionKey: errorDescription ?? "",
         NSLocalizedRecoverySuggestionErrorKey: recoverySuggestion ?? "",
         NSLocalizedRecoveryOptionsErrorKey: recoveryOptions,
         NSRecoveryAttempterErrorKey: ArchiveVolumeRecoveryAttempter(self)]
    }
    var presentedError: NSError { NSError(domain: Self.errorDomain, code: errorCode, userInfo: errorUserInfo) }

    let recovery: ArchiveVolumeOpenRecovery
    var openRecovered: @MainActor @Sendable (URL) async -> Bool = { url in
        await withCheckedContinuation { continuation in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
                if let error { NSApplication.shared.presentError(error) }
                continuation.resume(returning: document != nil && error == nil)
            }
        }
    }
    var showAlert: @MainActor @Sendable (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    var errorDescription: String? { String(localized: "分割アーカイブの保存が中断されています") }
    var recoverySuggestion: String? { String(localized: "中断した保存を完了して開く") }
    var recoveryOptions: [String] { [String(localized: "中断した保存を完了して開く"), String(localized: "キャンセル")] }
    // App-modal errors use this synchronous entry; sheet errors use the result-handler entry below.
    // Return false immediately and reopen on completion, without claiming recovery has already succeeded.
    func attemptRecovery(optionIndex: Int) -> Bool {
        attemptRecovery(optionIndex: optionIndex, resultHandler: { _ in })
        return false
    }
    private final class Reply: @unchecked Sendable {
        let callback: (Bool) -> Void
        init(_ callback: @escaping (Bool) -> Void) { self.callback = callback }
    }
    func attemptRecovery(optionIndex: Int, resultHandler handler: @escaping (Bool) -> Void) {
        guard optionIndex == 0 else { handler(false); return }
        let reply = Reply(handler), recovery = recovery
        Task { @MainActor in
            let results = await recovery.recover()
            var cleanupPending = false
            for result in results {
                switch result {
                case .recovered(_, _, let disposal):
                    if case .kept = disposal { cleanupPending = true }
                    continue
                case .owned:
                    let alert = NSAlert()
                    alert.messageText = String(localized: "別の保存または回復処理中です。しばらくしてからもう一度開いてください。")
                    _ = showAlert(alert); reply.callback(false); return
                case .held(let staging, _, _):
                    let alert = NSAlert()
                    alert.messageText = String(localized: "分割アーカイブの回復を完了できませんでした")
                    alert.addButton(withTitle: String(localized: "キャンセル"))
                    alert.addButton(withTitle: String(localized: "Finderで表示"))
                    if showAlert(alert) == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([staging]) }
                    reply.callback(false); return
                }
            }
            let opened = await openRecovered(recovery.gate)
            if opened, cleanupPending {
                let alert = NSAlert()
                alert.messageText = String(localized: "変更は保存されましたが、作業フォルダの後片付けが残っています。")
                _ = showAlert(alert)
            }
            reply.callback(opened)
        }
    }
}

/// AppKit receives this object in the actual NSError, including after userInfo copying.
/// NSObject's informal recovery protocol has both application-modal and sheet entry points.
nonisolated final class ArchiveVolumeRecoveryAttempter: NSObject, @unchecked Sendable {
    let offer: ArchiveVolumeOpenError
    init(_ offer: ArchiveVolumeOpenError) { self.offer = offer; super.init() }

    override func attemptRecovery(fromError error: any Error, optionIndex: Int) -> Bool {
        offer.attemptRecovery(optionIndex: Int(optionIndex))
    }

    override func attemptRecovery(fromError error: any Error, optionIndex: Int, delegate: Any?,
                 didRecoverSelector selector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        offer.attemptRecovery(optionIndex: Int(optionIndex)) { recovered in
            guard let delegate = delegate as? NSObject, let selector, delegate.responds(to: selector),
                  let implementation = delegate.method(for: selector) else { return }
            typealias Callback = @convention(c) (AnyObject, Selector, Bool, UnsafeMutableRawPointer?) -> Void
            unsafeBitCast(implementation, to: Callback.self)(delegate, selector, recovered, contextInfo)
        }
    }
}
