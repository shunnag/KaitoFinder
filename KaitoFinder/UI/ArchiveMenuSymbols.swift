import AppKit

/// メニューバーとコンテキストメニューで、同じ操作を同じ SF Symbol で示す。
enum ArchiveMenuSymbols {
    private static let symbols: [Selector: String] = [
        #selector(AppDelegate.newArchive(_:)): "doc.badge.plus",
        #selector(AppDelegate.extractArchivesFromMenu(_:)): "tray.and.arrow.down",
        #selector(NSDocumentController.openDocument(_:)): "folder",
        #selector(ArchiveWindowController.openEntry(_:)): "doc",
        #selector(ArchiveWindowController.openWithEntry(_:)): "arrow.up.forward.app",
        #selector(ArchiveWindowController.togglePreviewPanel(_:)): "eye",
        #selector(ArchiveWindowController.saveArchiveAs(_:)): "square.and.arrow.down",
        #selector(ArchiveWindowController.newFolder(_:)): "folder.badge.plus",
        #selector(ArchiveWindowController.deleteEntries(_:)): "trash",
        #selector(ArchiveWindowController.renameEntry(_:)): "pencil",
        #selector(ArchiveWindowController.extractSelected(_:)): "tray.and.arrow.down",
        #selector(ArchiveWindowController.extractAll(_:)): "tray.and.arrow.down",
        #selector(ArchiveWindowController.revealArchiveInFinder(_:)): "folder",
        #selector(ArchiveWindowController.setArchivePassword(_:)): "lock",
        #selector(ArchiveWindowController.changeArchivePassword(_:)): "key",
        #selector(ArchiveWindowController.removeArchivePassword(_:)): "lock.open"
    ]

    static func apply(to menu: NSMenu) {
        for item in menu.items {
            guard let action = item.action, let symbol = symbols[action] else { continue }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }
}
