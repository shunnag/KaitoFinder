import AppKit
import UniformTypeIdentifiers

/// 二つの入口から、一度の展開先選択と単独の進捗パネルを共有する。
@MainActor final class ArchiveBatchExtractionController {
    private let store: ArchivePreferencesStore
    private let passwordVault: ArchivePasswordVault
    private let reveal: @Sendable ([URL]) -> Void
    private let passwordPresenter = ArchivePasswordPresenter()
    private(set) var destinationPanel: NSOpenPanel?
    private(set) var progressSheet: ExtractionProgressSheet?
    var passwordPrompt: ArchivePasswordPrompt? { passwordPresenter.prompt }

    init(store: ArchivePreferencesStore = .shared, passwordVault: ArchivePasswordVault = .shared,
         reveal: @escaping @Sendable ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }) {
        self.store = store
        self.passwordVault = passwordVault
        self.reveal = reveal
    }

    static func archiveContentTypes(bundle: Bundle = .main) -> [UTType] {
        let documents = bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]] ?? []
        let identifiers = Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        return identifiers.sorted().map { UTType($0) ?? UTType(importedAs: $0) }
    }

    static func makeArchivePanel(bundle: Bundle = .main) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = archiveContentTypes(bundle: bundle)
        panel.prompt = String(localized: "展開", bundle: bundle)
        panel.message = String(localized: "展開するアーカイブを選んでください。", bundle: bundle)
        return panel
    }

    static func makeDestinationPanel(bundle: Bundle = .main) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "展開", bundle: bundle)
        return panel
    }

    static func progressTitle(count: Int, bundle: Bundle = .main) -> String {
        ArchiveProgressOperation.expandingArchives(count).title(bundle: bundle)
    }

    @discardableResult
    func extract(archives: [URL], progress: Progress = Progress()) async -> ArchiveBatchExtractor.Report? {
        guard !archives.isEmpty, !Task.isCancelled else { return nil }
        let preferences = store.preferences
        let base: URL?
        if preferences.extractionDestination == .ask {
            let panel = Self.makeDestinationPanel()
            panel.directoryURL = archives.first?.deletingLastPathComponent()
            destinationPanel = panel
            let response: NSApplication.ModalResponse = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(returning: .cancel); return }
                    panel.begin { continuation.resume(returning: $0) }
                }
            } onCancel: {
                Task { @MainActor in panel.cancel(nil) }
            }
            destinationPanel = nil
            guard response == .OK, let destination = panel.url, !Task.isCancelled else { return nil }
            base = destination
        } else { base = nil }

        progress.totalUnitCount = Int64(archives.count)
        let sheet = ExtractionProgressSheet(progress: progress, title: Self.progressTitle(count: archives.count))
        progressSheet = sheet
        defer {
            passwordPresenter.cancel()
            sheet.finish()
            progressSheet = nil
        }
        sheet.beginStandalone()
        // 採用候補は展開成功後だけ保存する。誤入力や入力待ち中の「すべて削除」を上書きしない。
        var responses: [URL: (response: ArchivePasswordResponse, generation: UInt64)] = [:]
        let vault = passwordVault
        let extractor = ArchiveBatchExtractor(preferences: preferences, passwordPrompt: { [self] archive, challenge in
            guard let window = sheet.window else { throw CancellationError() }
            let generation = await vault.generation()
            let response = try await passwordPresenter.response(to: challenge, on: window,
                                                                archiveName: archive.lastPathComponent)
            responses[archive] = (response, generation)
            return response.password
        }, rememberedPassword: { archive in
            await vault.password(for: .file(archive))
        }, reveal: reveal, currentArchive: { archive in
            sheet.detail = archive?.lastPathComponent ?? ""
        })
        let report = await extractor.run(archives: archives, base: base, progress: progress)
        for archive in report.extracted {
            if let candidate = responses[archive], candidate.response.remember {
                await vault.save(candidate.response.password, for: .file(archive), generation: candidate.generation)
            }
        }
        sheet.finish()
        if let alert = Self.failureAlert(for: report) { alert.runModal() }
        return report
    }

    static func failureAlert(for report: ArchiveBatchExtractor.Report, bundle: Bundle = .main) -> NSAlert? {
        guard !report.failures.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = String(localized: "\(report.failures.count)個のアーカイブを展開できませんでした", bundle: bundle)
        alert.informativeText = report.failures.map { failure in
            ArchiveAlertText.informativeText(
                String(localized: "\(failure.archive.lastPathComponent): \(failure.reason)", bundle: bundle), bundle: bundle)
        }.joined(separator: "\n")
        return alert
    }
}
