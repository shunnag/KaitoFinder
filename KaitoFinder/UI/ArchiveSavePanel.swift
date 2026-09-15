import AppKit
import GyoshukuKit
import UniformTypeIdentifiers

/// popup の選択・型・名前の変更を、パネルを表示せずに検証できる。
final class ArchiveSavePanelController {
    static let defaultsKey = ArchivePreferencesStore.Key.defaultFormat
    static let formats = ArchivePreferences.formats
    private let store: ArchivePreferencesStore
    private(set) var format: GyoshukuKit.ArchiveFormat

    init(store: ArchivePreferencesStore = .shared) {
        self.store = store
        format = store.preferences.defaultFormat
    }

    convenience init(defaults: UserDefaults) { self.init(store: ArchivePreferencesStore(defaults: defaults)) }

    var selectedIndex: Int { Self.formats.firstIndex(of: format)! }
    var allowedContentTypes: [UTType] { [Self.contentType(for: format)] }

    static func title(for format: GyoshukuKit.ArchiveFormat, bundle: Bundle = .main) -> String {
        switch format {
        case .zip: String(localized: "ZIP", bundle: bundle)
        case .tar: String(localized: "tar", bundle: bundle)
        case .tarGzip: String(localized: "tar.gz", bundle: bundle)
        case .sevenZip: String(localized: "7z", bundle: bundle)
        case .lha: String(localized: "LHA", bundle: bundle)
        }
    }

    static func contentType(for format: GyoshukuKit.ArchiveFormat) -> UTType {
        let identifier: String
        switch format {
        case .zip: return .zip
        case .tar: identifier = "public.tar-archive"
        case .tarGzip:
            // 実測: system の org.gnu.gnu-zip-tar-archive の拡張子タグは ["tgz"] のみ。
            // UTType(filenameExtension: "tar.gz") は nil で、アプリの imported 宣言でもタグは変わらない。
            // この UTI を NSSavePanel に指定すると Docs.tar.gz.tgz になるため、末尾 gz に合う .gzip を使う。
            return .gzip
        case .sevenZip: identifier = "org.7-zip.7-zip-archive"
        case .lha: identifier = "public.lha-archive"
        }
        // 宣言が未登録なら拡張子から解決する。
        let suffix = ArchiveCreationPlan.filenameExtension(for: format)
        return UTType(identifier) ?? UTType(filenameExtension: suffix) ?? .data
    }

    func selectFormat(at index: Int, filename: String) -> String {
        guard Self.formats.indices.contains(index) else { return filename }
        let suffix = "." + ArchiveCreationPlan.filenameExtension(for: format)
        let stem = filename.lowercased().hasSuffix(suffix) ? String(filename.dropLast(suffix.count)) : filename
        format = Self.formats[index]
        store.preferences.defaultFormat = format
        return stem + "." + ArchiveCreationPlan.filenameExtension(for: format)
    }
}

final class ArchiveSavePanel: NSObject {
    let panel = NSSavePanel()
    let controller: ArchiveSavePanelController
    let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    convenience init(sources: [URL], existingURL: URL? = nil, defaults: UserDefaults, bundle: Bundle = .main) {
        self.init(sources: sources, existingURL: existingURL, store: ArchivePreferencesStore(defaults: defaults), bundle: bundle)
    }

    init(sources: [URL], existingURL: URL? = nil, store: ArchivePreferencesStore = .shared, bundle: Bundle = .main) {
        controller = ArchiveSavePanelController(store: store)
        super.init()
        panel.directoryURL = sources.first?.deletingLastPathComponent()
        panel.nameFieldStringValue = existingURL.map { ArchiveCreationPlan.conversionName(for: $0, format: controller.format) }
            ?? ArchiveCreationPlan.defaultName(for: sources, format: controller.format)
        panel.allowedContentTypes = controller.allowedContentTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        formatPopup.addItems(withTitles: ArchiveSavePanelController.formats.map { ArchiveSavePanelController.title(for: $0, bundle: bundle) })
        formatPopup.selectItem(at: controller.selectedIndex)
        formatPopup.target = self
        formatPopup.action = #selector(changeFormat(_:))
        panel.accessoryView = Self.makeAccessoryView(formatPopup: formatPopup, bundle: bundle)
    }

    // 保存パネルの外部サービスに接続せず、同じアクセサリを構築できる。
    static func makeAccessoryView(formatPopup: NSPopUpButton, bundle: Bundle = .main) -> NSView {
        formatPopup.setAccessibilityLabel(String(localized: "フォーマット", bundle: bundle))
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "フォーマット", bundle: bundle)), formatPopup])
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        let note = NSTextField(labelWithString: String(localized: "暗号化はできません", bundle: bundle))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let accessory = NSStackView(views: [row, note])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        accessory.setFrameSize(accessory.fittingSize)
        return accessory
    }

    @objc func changeFormat(_ sender: NSPopUpButton) {
        let filename = controller.selectFormat(at: sender.indexOfSelectedItem, filename: panel.nameFieldStringValue)
        panel.allowedContentTypes = controller.allowedContentTypes
        panel.nameFieldStringValue = filename
    }

    func destination(on parent: NSWindow?) async throws -> URL? {
        try Task.checkCancellation()
        let response: NSApplication.ModalResponse = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .cancel); return }
                if let parent {
                    panel.beginSheetModal(for: parent) { continuation.resume(returning: $0) }
                } else {
                    panel.begin { continuation.resume(returning: $0) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.panel.cancel(nil) }
        }
        try Task.checkCancellation()
        return response == .OK ? panel.url : nil
    }
}
