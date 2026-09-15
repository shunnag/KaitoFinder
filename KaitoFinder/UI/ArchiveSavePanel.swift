import AppKit
import GyoshukuKit
import UniformTypeIdentifiers

/// popup の選択・型・名前の変更を、パネルを表示せずに検証できる。
final class ArchiveSavePanelController {
    nonisolated enum Level: Int, CaseIterable, Sendable {
        case none = 0, fast = 1, normal = 6, high = 8, maximum = 9

        static func closest(to value: Int) -> Level {
            [.fast, .normal, .high, .maximum].min {
                let left = abs($0.rawValue - value), right = abs($1.rawValue - value)
                return left == right ? $0.rawValue > $1.rawValue : left < right
            }!
        }

        func title(bundle: Bundle = .main) -> String {
            switch self {
            case .none: String(localized: "圧縮しない", bundle: bundle)
            case .fast: String(localized: "速い", bundle: bundle)
            case .normal: String(localized: "標準", bundle: bundle)
            case .high: String(localized: "高い", bundle: bundle)
            case .maximum: String(localized: "最高", bundle: bundle)
            }
        }

        func applying(to options: WriterOptions, format: GyoshukuKit.ArchiveFormat) -> WriterOptions {
            var options = options
            if format == .zip {
                options.compressionMethod = self == .none ? .stored : .deflate
            }
            if (format == .zip || format == .tarGzip), self != .none { options.deflateLevel = rawValue }
            return options
        }
    }

    static let defaultsKey = ArchivePreferencesStore.Key.defaultFormat
    static let formats = ArchivePreferences.formats
    private let store: ArchivePreferencesStore
    private(set) var format: GyoshukuKit.ArchiveFormat
    private(set) var level: Level = .normal

    init(store: ArchivePreferencesStore = .shared) {
        self.store = store
        format = store.preferences.defaultFormat
        resetLevel()
    }

    convenience init(defaults: UserDefaults) { self.init(store: ArchivePreferencesStore(defaults: defaults)) }

    var selectedIndex: Int { Self.formats.firstIndex(of: format)! }
    var allowedContentTypes: [UTType] { [Self.contentType(for: format)] }
    var isLevelEnabled: Bool { format == .zip || format == .tarGzip }
    var levels: [Level] {
        switch format {
        case .zip: Level.allCases
        case .tarGzip: [.fast, .normal, .high, .maximum]
        case .tar, .sevenZip, .lha: [.normal]
        }
    }
    var selectedLevelIndex: Int { levels.firstIndex(of: level)! }

    func selectLevel(at index: Int) {
        guard isLevelEnabled, levels.indices.contains(index) else { return }
        level = levels[index]
    }

    private func resetLevel() {
        let preferences = store.preferences
        switch format {
        case .zip: level = preferences.zipMethod == .stored ? .none : .closest(to: preferences.zipLevel)
        case .tarGzip: level = .closest(to: preferences.tarGzipLevel)
        case .tar, .sevenZip, .lha: level = .normal
        }
    }

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
        resetLevel()
        store.preferences.defaultFormat = format
        return stem + "." + ArchiveCreationPlan.filenameExtension(for: format)
    }
}

final class ArchiveSavePanel: NSObject {
    private static let accessoryWidth: CGFloat = 360
    private static let accessoryHorizontalInset: CGFloat = 2
    let panel = NSSavePanel()
    let controller: ArchiveSavePanelController
    let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fixedLevelNote: NSTextField
    private let bundle: Bundle

    convenience init(sources: [URL], existingURL: URL? = nil, defaults: UserDefaults, bundle: Bundle = .main) {
        self.init(sources: sources, existingURL: existingURL, store: ArchivePreferencesStore(defaults: defaults), bundle: bundle)
    }

    init(sources: [URL], existingURL: URL? = nil, store: ArchivePreferencesStore = .shared, bundle: Bundle = .main) {
        self.bundle = bundle
        fixedLevelNote = Self.makeNote(String(localized: "7z と LHA の圧縮レベルは固定です", bundle: bundle))
        controller = ArchiveSavePanelController(store: store)
        super.init()
        panel.directoryURL = (existingURL ?? sources.first)?.deletingLastPathComponent()
        panel.nameFieldStringValue = existingURL.map { ArchiveCreationPlan.conversionName(for: $0, format: controller.format) }
            ?? ArchiveCreationPlan.defaultName(for: sources, format: controller.format)
        panel.allowedContentTypes = controller.allowedContentTypes
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        formatPopup.addItems(withTitles: ArchiveSavePanelController.formats.map { ArchiveSavePanelController.title(for: $0, bundle: bundle) })
        formatPopup.selectItem(at: controller.selectedIndex)
        formatPopup.target = self
        formatPopup.action = #selector(changeFormat(_:))
        levelPopup.target = self
        levelPopup.action = #selector(changeLevel(_:))
        refreshLevel()
        panel.accessoryView = Self.makeAccessoryView(formatPopup: formatPopup, levelPopup: levelPopup,
                                                     fixedLevelNote: fixedLevelNote, bundle: bundle)
    }

    // 保存パネルの外部サービスに接続せず、同じアクセサリを構築できる。
    static func makeAccessoryView(formatPopup: NSPopUpButton, levelPopup: NSPopUpButton,
                                  fixedLevelNote: NSTextField, bundle: Bundle = .main) -> NSView {
        formatPopup.setAccessibilityLabel(String(localized: "フォーマット", bundle: bundle))
        levelPopup.setAccessibilityLabel(String(localized: "圧縮レベル", bundle: bundle))
        let rows = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "フォーマット", bundle: bundle)), formatPopup],
            [NSTextField(labelWithString: String(localized: "圧縮レベル", bundle: bundle)), levelPopup]
        ])
        rows.columnSpacing = 12
        rows.rowSpacing = 8
        rows.column(at: 0).leadingPadding = 2
        rows.column(at: 1).trailingPadding = 2
        rows.column(at: 1).xPlacement = .fill
        rows.yPlacement = .center
        let note = makeNote(String(localized: "暗号化はできません", bundle: bundle))
        let accessory = NSStackView(views: [rows, note, fixedLevelNote])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 0, left: accessoryHorizontalInset, bottom: 0, right: accessoryHorizontalInset)
        accessory.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
        accessory.setFrameSize(accessory.fittingSize)
        return accessory
    }

    private static func makeNote(_ text: String) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.alignment = .left
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        // NSTextField の左右の整列用余白も、固定幅のアクセサリ内に収める。
        let width = accessoryWidth - 2 * accessoryHorizontalInset
        note.preferredMaxLayoutWidth = width
        note.widthAnchor.constraint(equalToConstant: width).isActive = true
        return note
    }

    private func refreshLevel() {
        levelPopup.removeAllItems()
        levelPopup.addItems(withTitles: controller.levels.map { $0.title(bundle: bundle) })
        levelPopup.selectItem(at: controller.selectedLevelIndex)
        levelPopup.isEnabled = controller.isLevelEnabled
        fixedLevelNote.isHidden = controller.format != .sevenZip && controller.format != .lha
        if let accessory = panel.accessoryView { accessory.setFrameSize(accessory.fittingSize) }
    }

    @objc func changeLevel(_ sender: NSPopUpButton) { controller.selectLevel(at: sender.indexOfSelectedItem) }

    @objc func changeFormat(_ sender: NSPopUpButton) {
        let filename = controller.selectFormat(at: sender.indexOfSelectedItem, filename: panel.nameFieldStringValue)
        panel.allowedContentTypes = controller.allowedContentTypes
        panel.nameFieldStringValue = filename
        refreshLevel()
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
