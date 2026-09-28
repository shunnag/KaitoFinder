import AppKit
import GyoshukuKit
import KaitoKit
import Synchronization

extension ArchiveDocument {
    nonisolated enum Contents: Sendable {
        case empty, locked(URL), open(ArchiveSession), closed
    }
    // セッションが文書を保持せずに、通知で更新した設定だけを worker から読めるようにする。
    nonisolated final class PreferencesSnapshot: Sendable {
        let value: Mutex<ArchivePreferences>
        init(_ preferences: ArchivePreferences) { value = Mutex(preferences) }
    }
    nonisolated fileprivate final class OpeningPreferences: Sendable {
        let snapshot: Mutex<PreferencesSnapshot>
        init(_ preferences: ArchivePreferences) { snapshot = Mutex(PreferencesSnapshot(preferences)) }
        func writerOptions(_ format: GyoshukuKit.ArchiveFormat) -> WriterOptions {
            snapshot.withLock { $0 }.value.withLock { $0.writerOptions(for: format) }
        }
        func importOptions() -> ArchiveImportPlan.Options {
            snapshot.withLock { $0 }.value.withLock { $0.importOptions }
        }
    }

    nonisolated final class PreopenedArchive: Sendable {
        private let contents: Mutex<Contents?>
        private let url: URL
        private let identity: ArchiveSetIdentity
        private let layout: ArchiveVolumeLayout?
        private let saveBehavior: ArchivePreferences.SaveBehavior
        private let metadataStore: ArchiveVolumeMetadataStore
        private let recoveryIndex: RecoverableWorkIndex
        private let preferences: OpeningPreferences

        fileprivate init(contents: Contents, url: URL, identity: ArchiveSetIdentity, layout: ArchiveVolumeLayout?,
                         saveBehavior: ArchivePreferences.SaveBehavior, metadataStore: ArchiveVolumeMetadataStore,
                         recoveryIndex: RecoverableWorkIndex, preferences: OpeningPreferences) {
            self.contents = Mutex(contents)
            self.url = url
            self.identity = identity
            self.layout = layout
            self.saveBehavior = saveBehavior
            self.metadataStore = metadataStore
            self.recoveryIndex = recoveryIndex
            self.preferences = preferences
        }

        func adopt(into document: ArchiveDocument, from url: URL) -> Contents? {
            guard ArchiveSplitVolume.gateURL(for: url).standardizedFileURL == self.url.standardizedFileURL,
                  document.saveBehavior == saveBehavior,
                  document.volumeMetadataStore === metadataStore, document.volumeRecoveryIndex === recoveryIndex,
                  (try? ArchiveSetIdentity.capture(url: self.url, layout: layout)) == identity else { return nil }
            return contents.withLock { value in
                guard let result = value else { return nil }
                preferences.snapshot.withLock { $0 = document.preferencesSnapshot }
                value = nil
                return result
            }
        }

        func close() async {
            let unused = contents.withLock { value in
                let result = value
                value = nil
                return result
            }
            if case .open(let session) = unused { await session.close() }
        }

        #if DEBUG
        var sessionForTesting: ArchiveSession? {
            contents.withLock { if case .open(let session) = $0 { session } else { nil } }
        }
        #endif

        deinit {
            if case .open(let session) = contents.withLock({ $0 }) { Task { await session.close() } }
        }
    }

    nonisolated static func openingError(_ error: any Error) -> NSError {
        NSError(domain: KaitoFinderErrorDomain.document, code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "アーカイブを開けませんでした"),
            NSLocalizedFailureReasonErrorKey: ArchiveAlertText.informativeText(ArchiveErrorText.describe(error)),
            NSUnderlyingErrorKey: error as NSError
        ])
    }

    @concurrent static func preopen(_ url: URL, preferences: ArchivePreferences,
                                    metadataStore: ArchiveVolumeMetadataStore,
                                    recoveryIndex: RecoverableWorkIndex) async throws -> PreopenedArchive {
        let options = OpeningPreferences(preferences)
        do {
            let contents: Contents
            let identity: ArchiveSetIdentity
            let layout: ArchiveVolumeLayout?
            do {
                let session = try await openArchive(url, password: nil, writerOptions: { options.writerOptions($0) },
                    importOptions: { options.importOptions() }, allowsSplitSave: preferences.saveBehavior == .onSave,
                    allowsImmediateSplitSave: preferences.saveBehavior == .immediate, volumeMetadataStore: metadataStore)
                contents = .open(session)
                identity = await session.sourceIdentity
                layout = session.volumeLayout
            } catch KaitoError.passwordRequired {
                contents = .locked(url)
                layout = try lockedVolumeLayout(url)
                identity = try ArchiveSetIdentity.capture(url: url, layout: layout)
            }
            let opened = PreopenedArchive(contents: contents, url: url, identity: identity, layout: layout,
                saveBehavior: preferences.saveBehavior, metadataStore: metadataStore, recoveryIndex: recoveryIndex,
                preferences: options)
            if Task.isCancelled { await opened.close(); throw CancellationError() }
            return opened
        } catch is CancellationError { throw CancellationError() }
        catch { throw openingError(error) }
    }

    nonisolated private static func lockedVolumeLayout(_ url: URL) throws -> ArchiveVolumeLayout? {
        guard let parsed = ArchiveVolumeSet.parse(fileName: url.lastPathComponent),
              case .numbered = parsed.scheme else { return nil }
        let members = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil).compactMap { member -> (Int, URL)? in
                guard let part = ArchiveVolumeSet.parse(fileName: member.lastPathComponent),
                      part.scheme == parsed.scheme else { return nil }
                return (part.index, member)
            }.sorted { $0.0 < $1.0 }
        guard !members.isEmpty else { return nil }
        return try ArchiveVolumeLayout(scheme: parsed.scheme, volumes: members.map { _, member in
            .init(url: member, length: try ArchiveSetIdentity.capture(url: member).volumes[0].size)
        }, openedVolumeIndex: 0)
    }

    @concurrent static func openArchive(
        _ url: URL, password: String?,
        writerOptions: @escaping @Sendable (GyoshukuKit.ArchiveFormat) -> WriterOptions,
        importOptions: @escaping @Sendable () -> ArchiveImportPlan.Options,
        checksCancellation: Bool = true, allowsSplitSave: Bool, allowsImmediateSplitSave: Bool, volumeMetadataStore: ArchiveVolumeMetadataStore
    ) async throws -> ArchiveSession {
        if checksCancellation { try Task.checkCancellation() }
        else {
            // 公開後の再オープンは遅れて届いた取消しに左右されない。KaitoKit は圧縮 tar の一時展開で
            // Task の取消しを検査するため、取消し状態を継承しない detached Task で開く。
            return try await Task.detached(priority: Task.currentPriority) {
                try ArchiveSession(url: url, password: password, allowsSplitSave: allowsSplitSave, allowsImmediateSplitSave: allowsImmediateSplitSave, volumeMetadataStore: volumeMetadataStore,
                                   writerOptions: writerOptions, importOptions: importOptions)
            }.value
        }
        return try ArchiveSession(url: url, password: password, allowsSplitSave: allowsSplitSave, allowsImmediateSplitSave: allowsImmediateSplitSave, volumeMetadataStore: volumeMetadataStore,
                                   writerOptions: writerOptions, importOptions: importOptions)
    }
}
