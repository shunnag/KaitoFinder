import AppKit
import Foundation
import KaitoKit

/// 読み取りだけの発見処理。controller（gate への正規化と種類の判定の前）と read(from:) が共有する。
nonisolated struct ArchiveVolumeOpenRecovery: Sendable {
    let gate: URL
    let stagings: [URL]
    let index: RecoverableWorkIndex
    let metadataStore: ArchiveVolumeMetadataStore

    static func discover(_ url: URL, index: RecoverableWorkIndex = .shared,
                         metadataStore: ArchiveVolumeMetadataStore = .shared) throws -> Self? {
        do { return try inspect(url, index: index, metadataStore: metadataStore) }
        catch {
            let underlying: NSError
            let reason: String
            if case VolumePublishError.system(let code) = error {
                underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                reason = ArchiveErrorText.describe(ExtractionFailure.system(code))
            } else {
                underlying = error as NSError
                reason = ""
            }
            throw NSError(domain: KaitoFinderErrorDomain.splitDiscovery, code: underlying.code, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "分割アーカイブの状態を確認できませんでした"),
                NSLocalizedFailureReasonErrorKey: reason,
                NSUnderlyingErrorKey: underlying
            ])
        }
    }

    private static func inspect(_ url: URL, index: RecoverableWorkIndex,
                                metadataStore: ArchiveVolumeMetadataStore) throws -> Self? {
        guard let parsed = ArchiveVolumeSet.parse(fileName: url.lastPathComponent),
              case .numbered(let stem, _) = parsed.scheme else { return nil }
        let parent = try VolumePublishDirectory(VolumePublishFS.canonicalParent(of: url))
        var gate: URL?, stages: [URL] = []
        for name in try parent.names() where VolumePublishRemoval.stagingName(name) == name {
            guard let record = try? VolumePublishJournal.inspect(parent.directory(name)), record.stem == stem else { continue }
            if try VolumePublishLock.stagingIsOwned(name, directory: index.stagingLocksURL) { continue }
            // 不正な同じ stem の journal にも、回復と Finder での表示を提案する。その中のパスは信用しない。
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

/// 前回の保存が中断した分割セットを開くときに出すエラー。回復を選ぶと中断した保存を完了し、セットを開き直す。
/// `ArchiveSplitSaveFailure`（SplitVolumes/ArchiveSplitSaveFailure.swift）と対になる開く時の型。どちらも
/// LocalizedError + RecoverableError で、「Finderで表示」で staging を示す。あちらは失敗した保存を報告する。
nonisolated struct ArchiveVolumeOpenError: LocalizedError, RecoverableError, CustomNSError {
    static let errorDomain = KaitoFinderErrorDomain.splitRecovery
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
    // App-modal のエラーはこの同期の入口を、sheet のエラーは下の result handler の入口を使う。
    // 回復が済んだとは主張せずにすぐ false を返し、完了したら開き直す。
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

/// AppKit は実際の NSError の中でこのオブジェクトを受け取る。userInfo が複製された後も同じ。
/// NSObject の非形式の回復 protocol には、application-modal と sheet の両方の入口がある。
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
