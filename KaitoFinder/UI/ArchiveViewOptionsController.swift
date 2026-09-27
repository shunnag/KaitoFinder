import AppKit

final class ArchiveViewOptionsController: NSWindowController {
    nonisolated static let frameAutosaveName = "ArchiveViewOptions"
    private let store: ArchivePreferencesStore
    private let mainWindow: () -> NSWindow?
    private(set) weak var target: ArchiveWindowController?
    let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let orderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let iconSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let textSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var columnCheckboxes: [ArchiveColumn: NSButton] = [:]
    let foldersOnTopCheckbox: NSButton
    let hiddenFilesCheckbox: NSButton

    init(store: ArchivePreferencesStore = .shared, bundle: Bundle = .main,
         mainWindow: @escaping () -> NSWindow? = { NSApp.mainWindow }) {
        self.store = store
        self.mainWindow = mainWindow
        foldersOnTopCheckbox = NSButton(checkboxWithTitle: String(localized: "フォルダを常に先頭に表示", bundle: bundle), target: nil, action: nil)
        hiddenFilesCheckbox = NSButton(checkboxWithTitle: String(localized: "隠しファイルを表示", bundle: bundle), target: nil, action: nil)
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = String(localized: "表示オプション", bundle: bundle)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        sortPopup.addItems(withTitles: ArchiveColumn.allCases.map { $0.title(bundle: bundle) })
        orderPopup.addItems(withTitles: [String(localized: "昇順", bundle: bundle), String(localized: "降順", bundle: bundle)])
        iconSizePopup.addItems(withTitles: [String(localized: "小", bundle: bundle), String(localized: "大", bundle: bundle)])
        textSizePopup.addItems(withTitles: ArchivePreferences.listTextSizeRange.map(String.init))
        for (control, action) in [(sortPopup, #selector(changeSort(_:))), (orderPopup, #selector(changeSort(_:))),
                                  (iconSizePopup, #selector(changeIconSize(_:))), (textSizePopup, #selector(changeTextSize(_:)))] {
            control.target = self
            control.action = action
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(control.intrinsicContentSize.width)).isActive = true
        }
        for (button, action) in [(foldersOnTopCheckbox, #selector(changeFoldersOnTop(_:))),
                                 (hiddenFilesCheckbox, #selector(changeHiddenFiles(_:)))] {
            button.target = self
            button.action = action
            button.cell?.wraps = true
            button.cell?.lineBreakMode = .byWordWrapping
            button.widthAnchor.constraint(equalToConstant: 440).isActive = true
            let size = button.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 440, height: 1000)) ?? .zero
            button.heightAnchor.constraint(equalToConstant: ceil(size.height)).isActive = true
        }
        let columns = NSStackView()
        columns.orientation = .vertical
        columns.alignment = .leading
        columns.spacing = 4
        for (index, column) in ArchiveColumn.allCases.enumerated() {
            let button = NSButton(checkboxWithTitle: column.title(bundle: bundle), target: self, action: #selector(changeColumn(_:)))
            button.tag = index
            columnCheckboxes[column] = button
            columns.addArrangedSubview(button)
        }
        let rows = [
            ArchiveFormRow.make(String(localized: "並べ順:", bundle: bundle), control: sortPopup),
            ArchiveFormRow.make(String(localized: "順序:", bundle: bundle), control: orderPopup),
            ArchiveFormRow.make(String(localized: "列:", bundle: bundle), control: columns),
            [foldersOnTopCheckbox, NSGridCell.emptyContentView],
            [hiddenFilesCheckbox, NSGridCell.emptyContentView],
            ArchiveFormRow.make(String(localized: "アイコンのサイズ:", bundle: bundle), control: iconSizePopup),
            ArchiveFormRow.make(String(localized: "文字のサイズ:", bundle: bundle), control: textSizePopup)
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).leadingPadding = 2
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).trailingPadding = 2
        grid.cell(atColumnIndex: 0, rowIndex: 2).yPlacement = .top
        for index in [3, 4] {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: index, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: index).xPlacement = .leading
        }
        let required = grid.fittingSize
        let content = NSView(frame: NSRect(x: 0, y: 0, width: ceil(required.width) + 40, height: ceil(required.height) + 40))
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        panel.contentView = content
        panel.setContentSize(content.frame.size)
        panel.initialFirstResponder = sortPopup
        panel.center()
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged(_:)),
                                               name: ArchivePreferencesStore.didChange, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(viewOptionsChanged(_:)),
                                               name: ArchiveWindowController.viewOptionsDidChange, object: nil)
        refreshTarget()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        refreshTarget()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }

    func refreshTarget(excluding window: NSWindow? = nil) {
        let main = mainWindow()
        target = main === window ? nil : main?.windowController as? ArchiveWindowController
        refreshControls()
    }

    func refreshControls() {
        let available = target?.canChangeViewOptions == true
        let descriptor = target?.outlineView.sortDescriptors.first
        let column = descriptor?.key.flatMap(ArchiveColumn.init(rawValue:)) ?? .name
        sortPopup.selectItem(at: ArchiveColumn.allCases.firstIndex(of: column) ?? 0)
        orderPopup.selectItem(at: descriptor?.ascending == false ? 1 : 0)
        sortPopup.isEnabled = available
        orderPopup.isEnabled = available
        for column in ArchiveColumn.allCases {
            let button = columnCheckboxes[column]!
            button.state = column == .name || target?.outlineView.tableColumn(withIdentifier: .init(column.rawValue))?.isHidden == false ? .on : .off
            button.isEnabled = available && column != .name
        }
        let preferences = store.preferences
        foldersOnTopCheckbox.state = preferences.keepsFoldersOnTop ? .on : .off
        hiddenFilesCheckbox.state = preferences.showsHiddenFiles ? .on : .off
        iconSizePopup.selectItem(at: preferences.listIconSize == .small ? 0 : 1)
        textSizePopup.selectItem(withTitle: String(preferences.listTextSize))
    }

    @objc private func windowChanged(_ notification: Notification) {
        refreshTarget(excluding: notification.name == NSWindow.didBecomeMainNotification ? nil : notification.object as? NSWindow)
    }
    @objc private func preferencesChanged(_ notification: Notification) { refreshControls() }
    @objc private func viewOptionsChanged(_ notification: Notification) {
        if notification.object as? ArchiveWindowController === target { refreshControls() }
    }

    @objc private func changeSort(_ sender: NSPopUpButton) {
        defer { refreshControls() }
        guard let target, target.canChangeViewOptions, ArchiveColumn.allCases.indices.contains(sortPopup.indexOfSelectedItem) else { return }
        let column = ArchiveColumn.allCases[sortPopup.indexOfSelectedItem]
        target.outlineView.tableColumn(withIdentifier: .init(column.rawValue))?.isHidden = false
        target.outlineView.sortDescriptors = [NSSortDescriptor(key: column.rawValue, ascending: orderPopup.indexOfSelectedItem == 0)]
    }

    @objc private func changeColumn(_ sender: NSButton) {
        defer { refreshControls() }
        guard let target, target.canChangeViewOptions, ArchiveColumn.allCases.indices.contains(sender.tag) else { return }
        let column = ArchiveColumn.allCases[sender.tag]
        let item = NSMenuItem()
        item.representedObject = column.rawValue
        target.toggleColumn(item)
    }
    @objc private func changeFoldersOnTop(_ sender: NSButton) { store.preferences.keepsFoldersOnTop = sender.state == .on }
    @objc private func changeHiddenFiles(_ sender: NSButton) { store.preferences.showsHiddenFiles = sender.state == .on }
    @objc private func changeIconSize(_ sender: NSPopUpButton) {
        store.preferences.listIconSize = sender.indexOfSelectedItem == 1 ? .large : .small
    }
    @objc private func changeTextSize(_ sender: NSPopUpButton) {
        store.preferences.listTextSize = Int(sender.titleOfSelectedItem ?? "") ?? 13
    }
}
