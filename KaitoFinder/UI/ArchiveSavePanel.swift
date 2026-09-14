import AppKit
import GyoshukuKit
import UniformTypeIdentifiers

/// popup の選択・型・名前の変更を、パネルを表示せずに検証できる。
final class ArchiveSavePanelController {
    static let defaultsKey = "ArchiveCreationFormat"
    static let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .sevenZip, .lha]
    private let defaults: UserDefaults
    private(set) var format: GyoshukuKit.ArchiveFormat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // writer の enum は raw value を持たないため、保存値には正準の拡張子を使う。
        let saved = defaults.string(forKey: Self.defaultsKey)
        format = Self.formats.first { ArchiveCreationPlan.filenameExtension(for: $0) == saved } ?? .zip
    }

    var selectedIndex: Int { Self.formats.firstIndex(of: format)! }
    var allowedContentTypes: [UTType] { [Self.contentType(for: format)] }

    static func title(for format: GyoshukuKit.ArchiveFormat) -> String {
        switch format {
        case .zip: String(localized: "ZIP")
        case .tar: String(localized: "tar")
        case .tarGzip: String(localized: "tar.gz")
        case .sevenZip: String(localized: "7z")
        case .lha: String(localized: "LHA")
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
        defaults.set(ArchiveCreationPlan.filenameExtension(for: format), forKey: Self.defaultsKey)
        return stem + "." + ArchiveCreationPlan.filenameExtension(for: format)
    }
}

final class ArchiveSavePanel: NSObject {
    let panel = NSSavePanel()
    let controller: ArchiveSavePanelController
    let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(sources: [URL], existingURL: URL? = nil, defaults: UserDefaults = .standard) {
        controller = ArchiveSavePanelController(defaults: defaults)
        super.init()
        panel.directoryURL = sources.first?.deletingLastPathComponent()
        panel.nameFieldStringValue = existingURL.map { ArchiveCreationPlan.conversionName(for: $0, format: controller.format) }
            ?? ArchiveCreationPlan.defaultName(for: sources, format: controller.format)
        panel.allowedContentTypes = controller.allowedContentTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        formatPopup.addItems(withTitles: ArchiveSavePanelController.formats.map(ArchiveSavePanelController.title))
        formatPopup.selectItem(at: controller.selectedIndex)
        formatPopup.target = self
        formatPopup.action = #selector(changeFormat(_:))
        formatPopup.setAccessibilityLabel(String(localized: "形式"))
        let row = NSStackView(views: [NSTextField(labelWithString: String(localized: "形式")), formatPopup])
        row.spacing = 12
        let note = NSTextField(labelWithString: String(localized: "暗号化はできません"))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let accessory = NSStackView(views: [row, note])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        panel.accessoryView = accessory
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
