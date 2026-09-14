import AppKit
import KaitoKit

/// 三つの入口で保存先の選択・進捗・完成した文書の open を共有する。
final class ArchiveCreationController {
    private(set) var savePanel: ArchiveSavePanel?
    private(set) var progressSheet: ExtractionProgressSheet?

    func createAndOpen(sources: [URL], existing: ArchiveCreationPlan.Existing? = nil,
                       on parent: NSWindow? = nil, progress: Progress = Progress()) async throws {
        let save = ArchiveSavePanel(sources: sources, existingURL: existing?.url)
        savePanel = save
        defer { savePanel = nil }
        guard let destination = try await save.destination(on: parent) else { return }
        savePanel = nil
        try ArchiveImportPlan.checkCancellation(progress)
        let plan = ArchiveCreationPlan(sources: sources, destination: destination,
                                       format: save.controller.format, existing: existing)
        let sheet = ExtractionProgressSheet(progress: progress, title: String(localized: "書庫を作成しています"))
        progressSheet = sheet
        defer { sheet.finish(); progressSheet = nil }
        if let parent { sheet.begin(on: parent) }
        else { sheet.beginStandalone() }
        let result = try await Self.create(plan: plan, progress: progress)
        sheet.finish()
        // rename 後の取消しで成功を隠さない。文書の open 失敗は作成失敗と分けて提示する。
        NSDocumentController.shared.openDocument(withContentsOf: result, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }

    @concurrent private static func create(plan: ArchiveCreationPlan, progress: Progress) async throws -> URL {
        try ArchiveCreationTransaction.run(plan: plan, progress: progress)
    }

    static func presentFailure(_ error: any Error) {
        // ExtractionFailure / WriterError の具体的な理由も AppKit のエラーパネルへ渡す。
        NSApp.presentError(NSError(domain: "com.shunnag.KaitoFinder.creation", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "書庫を作成できませんでした"),
            NSLocalizedFailureReasonErrorKey: String(describing: error)
        ]))
    }
}

nonisolated struct ArchiveConversionNotice {
    let messageText: String
    let informativeText: String

    init(formatName: String, entries: [ArchiveEntry], bundle: Bundle = .main) {
        messageText = String(localized: "この \(formatName) 書庫は変更できません", bundle: bundle)
        var detail = String(localized: "中身と追加する項目で新しい書庫を作れます。元の書庫は変わりません。", bundle: bundle)
        if entries.contains(where: \.isEncrypted) {
            detail += "\n\n" + String(localized: "元の書庫は暗号化されていますが、新しい書庫は暗号化されません。", bundle: bundle)
        }
        informativeText = detail
    }

    static func formatName(for session: ArchiveSession) -> String {
        switch session.capabilities.refusal {
        case .format(let name): return name
        case .gatekeeper(.sfxPrefix, _): return String(localized: "SFX ZIP")
        default:
            switch session.format {
            case .tar: return "tar"
            case .sevenZip: return "7z"
            default: return session.format.rawValue.uppercased()
            }
        }
    }
}
