import AppKit
import GyoshukuKit
import KaitoKit

/// 三つの入口で保存先の選択・進捗・完成した文書の open を共有する。
final class ArchiveCreationController {
    private let store: ArchivePreferencesStore
    private(set) var savePanel: ArchiveSavePanel?
    private(set) var progressSheet: ExtractionProgressSheet?
    private(set) var createdEncryption = ArchiveEncryptionSettings()
    // パネルの確定だけを置き換え、実際の作成・進捗・文書切り替えを検証する。
    var destinationHandler: ((ArchiveSavePanel, NSWindow?) async throws -> URL?)?

    init(store: ArchivePreferencesStore = .shared) { self.store = store }

    // 保存パネルの確定時に設定を読む。表示中に変更されても古い値を使わない。
    func creationPlan(sources: [URL], destination: URL, format: GyoshukuKit.ArchiveFormat,
                      existing: ArchiveCreationPlan.Existing? = nil,
                      level: ArchiveSavePanelController.Level? = nil,
                      encryption: ArchiveEncryptionSettings = .init()) -> ArchiveCreationPlan {
        let preferences = store.preferences
        let defaults = preferences.writerOptions(for: format)
        let options = encryption.applying(to: level?.applying(to: defaults, format: format) ?? defaults, format: format)
        return ArchiveCreationPlan(sources: sources, destination: destination, format: format,
                                   options: options, existing: existing, importOptions: preferences.importOptions)
    }

    func createAndOpen(sources: [URL], existing: ArchiveCreationPlan.Existing? = nil,
                       on parent: NSWindow? = nil, progress: Progress = Progress()) async throws {
        guard let result = try await create(sources: sources, existing: existing, on: parent, progress: progress) else { return }
        // rename 後の取消しで成功を隠さない。文書の open 失敗は作成失敗と分けて提示する。
        NSDocumentController.shared.openDocument(withContentsOf: result, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    func create(sources: [URL], existing: ArchiveCreationPlan.Existing? = nil,
                on parent: NSWindow? = nil, progress: Progress = Progress()) async throws -> URL? {
        createdEncryption = .init()
        let encryption = existing?.encryption ?? ArchiveEncryptionSettings(
            password: existing?.entries.contains(where: \.isEncrypted) == true ? existing?.password : nil,
            zipEncryption: ArchiveEncryptionSettings.zipMethod(in: existing?.entries ?? []))
        let save = ArchiveSavePanel(sources: sources, existingURL: existing?.url, store: store, encryption: encryption)
        savePanel = save
        defer { savePanel = nil; save.passwordFields.clear() }
        let destination: URL?
        if let destinationHandler { destination = try await destinationHandler(save, parent) }
        else { destination = try await save.destination(on: parent) }
        guard let destination else { return nil }
        try save.panel(save.panel, validate: destination)
        savePanel = nil
        try ArchiveImportPlan.checkCancellation(progress)
        let plan = creationPlan(sources: sources, destination: destination,
                                format: save.controller.format, existing: existing, level: save.controller.level,
                                encryption: save.encryptionSettings)
        let sheet = ExtractionProgressSheet(progress: progress, title: ArchiveProgressOperation.creatingArchive.title(),
                                            detail: destination.lastPathComponent)
        progressSheet = sheet
        defer { sheet.finish(); progressSheet = nil }
        if let parent { sheet.begin(on: parent) }
        else { sheet.beginStandalone() }
        let result = try await Self.create(plan: plan, progress: progress)
        createdEncryption = save.encryptionSettings
        save.passwordFields.clear()
        return result
    }

    static func existingArchive(from session: ArchiveSession, progress: Progress) async throws -> ArchiveCreationPlan.Existing {
        let password = try await session.preparedPassword()
        let snapshot = await session.snapshot()
        try ArchiveImportPlan.checkCancellation(progress)
        return .init(url: session.sourceURL, password: password, entries: snapshot.entries,
                     encryption: await session.encryptionSettings())
    }

    @concurrent private static func create(plan: ArchiveCreationPlan, progress: Progress) async throws -> URL {
        try ArchiveCreationTransaction.run(plan: plan, progress: progress)
    }

    static func presentFailure(_ error: any Error) {
        // ExtractionFailure / WriterError の具体的な理由も AppKit のエラーパネルへ渡す。
        NSApp.presentError(NSError(domain: "com.shunnag.KaitoFinder.creation", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "アーカイブを作成できませんでした"),
            NSLocalizedFailureReasonErrorKey: ArchiveAlertText.informativeText(ArchiveErrorText.describe(error))
        ]))
    }
}

nonisolated struct ArchiveConversionNotice {
    let messageText: String
    let informativeText: String

    init(formatName: String, entries: [ArchiveEntry], bundle: Bundle = .main) {
        messageText = String(localized: "この\(formatName)アーカイブは変更できません", bundle: bundle)
        var detail = String(localized: "中身と追加する項目で新しいアーカイブを作れます。元のアーカイブは変わりません。", bundle: bundle)
        if entries.contains(where: \.isEncrypted) {
            detail += "\n\n" + String(localized: "新しいアーカイブの暗号化設定は、保存時に変更できます。", bundle: bundle)
        }
        informativeText = detail
    }

    @MainActor static func makeAlert(formatName: String, entries: [ArchiveEntry], bundle: Bundle = .main) -> NSAlert {
        let notice = ArchiveConversionNotice(formatName: formatName, entries: entries, bundle: bundle)
        let alert = NSAlert()
        alert.messageText = notice.messageText
        alert.informativeText = notice.informativeText
        alert.addButton(withTitle: String(localized: "新規アーカイブを作成…", bundle: bundle))
        alert.addButton(withTitle: String(localized: "キャンセル", bundle: bundle))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        return alert
    }

    static func formatName(for session: ArchiveSession) -> String {
        switch session.capabilities.refusal {
        case .format(let name): return name
        case .gatekeeper(.sfxPrefix, _): return String(localized: "SFX ZIP")
        default:
            switch session.format {
            case .tar: return String(localized: "tar")
            case .sevenZip: return String(localized: "7z")
            default: return session.format.displayName
            }
        }
    }
}
