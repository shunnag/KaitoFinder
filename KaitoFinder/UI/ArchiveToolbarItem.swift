import AppKit

/// アーカイブウインドウのツールバー項目の目録。ArchiveColumn と同じ読み方をする。
/// rawValue はツールバーの autosave（ArchiveToolbar）に保存されるため変更しない。
enum ArchiveToolbarItem: String, CaseIterable {
    case navigation, extract, addFiles, newFolder, delete, quickLook, search, previewSidebar

    var identifier: NSToolbarItem.Identifier { .init(rawValue) }

    /// 既定の並び。区切りの space / flexibleSpace を含む。
    static let defaultOrder: [NSToolbarItem.Identifier] = [
        navigation.identifier, extract.identifier, .space,
        addFiles.identifier, newFolder.identifier, delete.identifier, .space,
        quickLook.identifier, .flexibleSpace, search.identifier, previewSidebar.identifier
    ]

    func label(bundle: Bundle) -> String {
        switch self {
        case .navigation: String(localized: "戻る/進む", bundle: bundle)
        case .extract: String(localized: "展開", bundle: bundle)
        case .addFiles: String(localized: "追加…", bundle: bundle)
        case .newFolder: String(localized: "新規フォルダ", bundle: bundle)
        case .delete: String(localized: "削除", bundle: bundle)
        case .quickLook: String(localized: "クイックルック", bundle: bundle)
        case .search: String(localized: "検索", bundle: bundle)
        case .previewSidebar: String(localized: "プレビューを表示", bundle: bundle)
        }
    }

    /// SF Symbols の名前。navigation と search は専用の view を持つため nil。
    var symbol: String? {
        switch self {
        case .extract: "tray.and.arrow.down"
        case .addFiles: "plus"
        case .newFolder: "folder.badge.plus"
        case .delete: "trash"
        case .quickLook: "eye"
        case .previewSidebar: "sidebar.right"
        case .navigation, .search: nil
        }
    }

    var action: Selector? {
        switch self {
        case .extract: #selector(ArchiveWindowController.extractFromToolbar(_:))
        case .addFiles: #selector(ArchiveWindowController.addFiles(_:))
        case .newFolder: #selector(ArchiveWindowController.newFolder(_:))
        case .delete: #selector(ArchiveWindowController.deleteEntries(_:))
        case .quickLook: #selector(ArchiveWindowController.togglePreviewPanel(_:))
        case .previewSidebar: #selector(ArchiveWindowController.togglePreviewSidebar(_:))
        case .navigation, .search: nil
        }
    }
}
