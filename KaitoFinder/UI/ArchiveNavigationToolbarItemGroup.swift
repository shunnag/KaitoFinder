import AppKit

final class ArchiveNavigationToolbarItemGroup: NSToolbarItemGroup {
    private let segments: NSSegmentedControl
    private var lastSelectedIndex = -1

    init(controller: ArchiveWindowController, bundle: Bundle) {
        let labels = [String(localized: "戻る", bundle: bundle), String(localized: "進む", bundle: bundle)]
        let images = zip(["chevron.left", "chevron.right"], labels).map {
            NSImage(systemSymbolName: $0.0, accessibilityDescription: $0.1)!
        }
        segments = NSSegmentedControl(images: images, trackingMode: .momentary, target: controller,
                                      action: #selector(ArchiveWindowController.navigateFromToolbar(_:)))
        // AppKit の groupWith… はサブクラスを返さないため、指定初期化子を使う。
        super.init(itemIdentifier: .init("navigation"))
        label = String(localized: "戻る/進む", bundle: bundle)
        paletteLabel = label
        toolTip = label
        isBordered = true
        subitems = labels.enumerated().map { index, label in
            let item = NSToolbarItem(itemIdentifier: .init(index == 0 ? "goBack" : "goForward"))
            item.label = label
            item.toolTip = label
            item.image = images[index]
            item.target = controller
            item.action = index == 0 ? #selector(ArchiveWindowController.goBack(_:)) : #selector(ArchiveWindowController.goForward(_:))
            item.autovalidates = false
            segments.setToolTip(label, forSegment: index)
            return item
        }
        segments.setAccessibilityLabel(label)
        view = segments
        target = controller
        action = #selector(ArchiveWindowController.navigateFromToolbar(_:))
    }

    override var selectedIndex: Int {
        get { lastSelectedIndex }
        set { lastSelectedIndex = newValue }
    }

    override func setSelected(_ selected: Bool, at index: Int) {
        if selected { selectedIndex = index }
        else if selectedIndex == index { selectedIndex = -1 }
    }

    override func isSelected(at index: Int) -> Bool {
        selectedIndex == index
    }

    override func validate() {
        let controller = target as? ArchiveWindowController
        let actions = [#selector(ArchiveWindowController.goBack(_:)), #selector(ArchiveWindowController.goForward(_:))]
        let enabled = actions.map { controller?.navigationEnabled($0) == true }
        isEnabled = enabled.contains(true)
        segments.isEnabled = isEnabled
        for (index, pair) in zip(subitems, enabled).enumerated() {
            let (item, isEnabled) = pair
            item.isEnabled = isEnabled
            segments.setEnabled(item.isEnabled, forSegment: index)
        }
    }
}
