import AppKit

/// 画面を出さずに、各コントロールの選択と即時保存を検証できる。
final class PreferencesViewModel {
    static let zipMethods: [ArchivePreferences.ZipMethod] = [.deflate, .stored]
    static let extractionDestinations: [ArchivePreferences.ExtractionDestination] = [.sameFolder, .ask]
    static let folderPolicies: [ArchivePreferences.FolderPolicy] = [.always, .whenMultipleTopLevelItems, .never]
    private let store: ArchivePreferencesStore

    init(store: ArchivePreferencesStore = .shared) { self.store = store }

    var preferences: ArchivePreferences { store.preferences }
    var defaultFormatIndex: Int { ArchivePreferences.formats.firstIndex(of: preferences.defaultFormat)! }
    var zipMethodIndex: Int { Self.zipMethods.firstIndex(of: preferences.zipMethod)! }
    var extractionDestinationIndex: Int { Self.extractionDestinations.firstIndex(of: preferences.extractionDestination)! }
    var afterExpansionIndex: Int { preferences.trashesArchiveAfterExtraction ? 1 : 0 }
    var folderPolicyIndex: Int { Self.folderPolicies.firstIndex(of: preferences.folderPolicy)! }
    var zipLevelLabel: String { String(preferences.zipLevel) }
    var tarGzipLevelLabel: String { String(preferences.tarGzipLevel) }

    func selectDefaultFormat(at index: Int) {
        guard ArchivePreferences.formats.indices.contains(index) else { return }
        store.preferences.defaultFormat = ArchivePreferences.formats[index]
    }

    func selectZipMethod(at index: Int) {
        guard Self.zipMethods.indices.contains(index) else { return }
        store.preferences.zipMethod = Self.zipMethods[index]
    }

    func changeZipLevel(to level: Int) { store.preferences.zipLevel = ArchivePreferences.clampedLevel(level) }
    func changeZipSkipsCompressedTypes(to enabled: Bool) { store.preferences.zipSkipsCompressedTypes = enabled }
    func changeTarGzipLevel(to level: Int) { store.preferences.tarGzipLevel = ArchivePreferences.clampedLevel(level) }
    func changeTarPreservesOwnerIDs(to enabled: Bool) { store.preferences.tarPreservesOwnerIDs = enabled }

    func selectExtractionDestination(at index: Int) {
        guard Self.extractionDestinations.indices.contains(index) else { return }
        store.preferences.extractionDestination = Self.extractionDestinations[index]
    }

    func selectFolderPolicy(at index: Int) {
        guard Self.folderPolicies.indices.contains(index) else { return }
        store.preferences.folderPolicy = Self.folderPolicies[index]
    }

    func selectAfterExpansion(at index: Int) {
        guard (0...1).contains(index) else { return }
        store.preferences.trashesArchiveAfterExtraction = index == 1
    }

    func changeRevealsExtractedItemsInFinder(to enabled: Bool) { store.preferences.revealsExtractedItemsInFinder = enabled }
}

final class PreferencesWindowController: NSWindowController {
    let viewModel: PreferencesViewModel
    private let bundle: Bundle
    let tabController = NSTabViewController()
    let defaultFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let zipMethodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let zipLevelSlider = NSSlider(value: 6, minValue: 1, maxValue: 9, target: nil, action: nil)
    let zipLevelLabel = NSTextField(labelWithString: "")
    let zipSkipsCompressedTypesCheckbox: NSButton
    let tarGzipLevelSlider = NSSlider(value: 6, minValue: 1, maxValue: 9, target: nil, action: nil)
    let tarGzipLevelLabel = NSTextField(labelWithString: "")
    let tarPreservesOwnerIDsCheckbox: NSButton
    let extractionDestinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let folderPolicyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let afterExpansionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let revealsExtractedItemsInFinderCheckbox: NSButton

    init(store: ArchivePreferencesStore = .shared, bundle: Bundle = .main) {
        self.bundle = bundle
        zipSkipsCompressedTypesCheckbox = NSButton(
            checkboxWithTitle: String(localized: "圧縮済みのファイル(zip・jpg・mp4など)は無圧縮で格納", bundle: bundle), target: nil, action: nil)
        tarPreservesOwnerIDsCheckbox = NSButton(
            checkboxWithTitle: String(localized: "所有者ID(uid / gid)を保存", bundle: bundle), target: nil, action: nil)
        revealsExtractedItemsInFinderCheckbox = NSButton(
            checkboxWithTitle: String(localized: "展開した項目をFinderに表示", bundle: bundle), target: nil, action: nil)
        viewModel = PreferencesViewModel(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = String(localized: "設定", bundle: bundle)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("Preferences")
        tabController.tabStyle = .toolbar
        configureControls()
        addTab(title: String(localized: "一般", bundle: bundle), symbol: "gearshape", labelWidth: 250, rows: [
            row(String(localized: "新規アーカイブの既定フォーマット:", bundle: bundle), control: defaultFormatPopup)
        ])
        let footnote = NSTextField(wrappingLabelWithString: String(localized: "7zはLZMA2、LHAは-lh5-で固定です。", bundle: bundle))
        footnote.textColor = .secondaryLabelColor
        footnote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footnote.preferredMaxLayoutWidth = 504
        addTab(title: String(localized: "圧縮", bundle: bundle), symbol: "archivebox", labelWidth: 140, rows: [
            [section(String(localized: "ZIP", bundle: bundle)), NSGridCell.emptyContentView],
            row(String(localized: "圧縮方式:", bundle: bundle), control: zipMethodPopup),
            row(String(localized: "圧縮レベル:", bundle: bundle), control: levelControl(zipLevelSlider, label: zipLevelLabel)),
            [NSGridCell.emptyContentView, wrappingCheckbox(zipSkipsCompressedTypesCheckbox, width: 352)],
            [section(String(localized: "tar.gz", bundle: bundle)), NSGridCell.emptyContentView],
            row(String(localized: "gzipレベル:", bundle: bundle), control: levelControl(tarGzipLevelSlider, label: tarGzipLevelLabel)),
            [section(String(localized: "tar", bundle: bundle)), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, wrappingCheckbox(tarPreservesOwnerIDsCheckbox, width: 352)],
            [footnote, NSGridCell.emptyContentView]
        ], spanningRows: [0, 4, 6, 8])
        addTab(title: String(localized: "展開", bundle: bundle), symbol: "tray.and.arrow.down", labelWidth: 200, rows: [
            row(String(localized: "展開したファイルの保存場所:", bundle: bundle), control: extractionDestinationPopup),
            row(String(localized: "展開後:", bundle: bundle), control: afterExpansionPopup),
            row(String(localized: "フォルダを作成:", bundle: bundle), control: folderPolicyPopup),
            [NSGridCell.emptyContentView, wrappingCheckbox(revealsExtractedItemsInFinderCheckbox, width: 292)]
        ])
        window.contentViewController = tabController
        window.setContentSize(NSSize(width: 560, height: 420))
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)),
                                               name: ArchivePreferencesStore.didChange, object: store)
        refreshControls()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        refreshControls()
        super.showWindow(sender)
    }

    private func configureControls() {
        defaultFormatPopup.addItems(withTitles: ArchivePreferences.formats.map { ArchiveSavePanelController.title(for: $0, bundle: bundle) })
        zipMethodPopup.addItems(withTitles: [String(localized: "Deflate", bundle: bundle), String(localized: "無圧縮", bundle: bundle)])
        extractionDestinationPopup.addItems(withTitles: [String(localized: "アーカイブと同じディレクトリ内", bundle: bundle), String(localized: "場所を選択…", bundle: bundle)])
        afterExpansionPopup.addItems(withTitles: [String(localized: "アーカイブをそのままにする", bundle: bundle),
                                                 String(localized: "アーカイブをゴミ箱に入れる", bundle: bundle)])
        folderPolicyPopup.addItems(withTitles: [String(localized: "常に", bundle: bundle), String(localized: "複数の項目があるとき", bundle: bundle),
                                              String(localized: "作らない", bundle: bundle)])
        let actions: [(NSControl, Selector)] = [
            (defaultFormatPopup, #selector(changeDefaultFormat(_:))),
            (zipMethodPopup, #selector(changeZipMethod(_:))),
            (zipLevelSlider, #selector(changeZipLevel(_:))),
            (zipSkipsCompressedTypesCheckbox, #selector(changeZipSkipsCompressedTypes(_:))),
            (tarGzipLevelSlider, #selector(changeTarGzipLevel(_:))),
            (tarPreservesOwnerIDsCheckbox, #selector(changeTarPreservesOwnerIDs(_:))),
            (extractionDestinationPopup, #selector(changeExtractionDestination(_:))),
            (folderPolicyPopup, #selector(changeFolderPolicy(_:))),
            (afterExpansionPopup, #selector(changeAfterExpansion(_:))),
            (revealsExtractedItemsInFinderCheckbox, #selector(changeRevealsExtractedItemsInFinder(_:)))
        ]
        for (control, action) in actions { control.target = self; control.action = action }
        zipLevelSlider.setAccessibilityLabel(String(localized: "圧縮レベル", bundle: bundle))
        tarGzipLevelSlider.setAccessibilityLabel(String(localized: "gzipレベル", bundle: bundle))
    }

    private func levelControl(_ slider: NSSlider, label: NSTextField) -> NSView {
        slider.numberOfTickMarks = 9
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 312).isActive = true
        label.widthAnchor.constraint(equalToConstant: 24).isActive = true
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.alignment = .right
        let stack = NSStackView(views: [slider, label])
        // ラベルの整列矩形からはみ出す左右2ポイントを確保する。
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.spacing = 12
        stack.alignment = .centerY
        return stack
    }

    private func row(_ title: String, control: NSView) -> [NSView] {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        control.setAccessibilityLabel(title)
        return [label, control]
    }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    private func wrappingCheckbox(_ button: NSButton, width: CGFloat) -> NSButton {
        button.cell?.wraps = true
        button.cell?.lineBreakMode = .byWordWrapping
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        // チェックの領域を差し引いた幅で、日英どちらの長い文言も折り返す。
        let size = button.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)) ?? .zero
        button.heightAnchor.constraint(equalToConstant: ceil(size.height)).isActive = true
        return button
    }

    private func addTab(title: String, symbol: String, labelWidth: CGFloat, rows: [[NSView]], spanningRows: [Int] = []) {
        let controller = NSViewController()
        controller.title = title
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        controller.preferredContentSize = controller.view.frame.size
        let grid = NSGridView(views: rows)
        grid.identifier = NSUserInterfaceItemIdentifier("preferences.grid." + symbol)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.yPlacement = .center
        grid.column(at: 0).width = labelWidth
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).leadingPadding = 2
        grid.column(at: 1).xPlacement = .leading
        grid.column(at: 1).trailingPadding = 2
        for row in spanningRows {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: row, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .leading
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24),
            grid.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: controller.view.bottomAnchor, constant: -24)
        ])
        let item = NSTabViewItem(viewController: controller)
        item.identifier = "preferences." + symbol
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabController.addTabViewItem(item)
    }

    @objc private func preferencesDidChange(_ notification: Notification) { refreshControls() }

    private func refreshControls() {
        let preferences = viewModel.preferences
        defaultFormatPopup.selectItem(at: viewModel.defaultFormatIndex)
        zipMethodPopup.selectItem(at: viewModel.zipMethodIndex)
        zipLevelSlider.integerValue = preferences.zipLevel
        zipLevelLabel.stringValue = viewModel.zipLevelLabel
        zipLevelSlider.isEnabled = preferences.zipMethod == .deflate
        zipSkipsCompressedTypesCheckbox.state = preferences.zipSkipsCompressedTypes ? .on : .off
        tarGzipLevelSlider.integerValue = preferences.tarGzipLevel
        tarGzipLevelLabel.stringValue = viewModel.tarGzipLevelLabel
        tarPreservesOwnerIDsCheckbox.state = preferences.tarPreservesOwnerIDs ? .on : .off
        extractionDestinationPopup.selectItem(at: viewModel.extractionDestinationIndex)
        folderPolicyPopup.selectItem(at: viewModel.folderPolicyIndex)
        afterExpansionPopup.selectItem(at: viewModel.afterExpansionIndex)
        revealsExtractedItemsInFinderCheckbox.state = preferences.revealsExtractedItemsInFinder ? .on : .off
    }

    @objc private func changeDefaultFormat(_ sender: NSPopUpButton) { viewModel.selectDefaultFormat(at: sender.indexOfSelectedItem) }
    @objc private func changeZipMethod(_ sender: NSPopUpButton) { viewModel.selectZipMethod(at: sender.indexOfSelectedItem) }
    @objc private func changeZipLevel(_ sender: NSSlider) { viewModel.changeZipLevel(to: sender.integerValue) }
    @objc private func changeZipSkipsCompressedTypes(_ sender: NSButton) { viewModel.changeZipSkipsCompressedTypes(to: sender.state == .on) }
    @objc private func changeTarGzipLevel(_ sender: NSSlider) { viewModel.changeTarGzipLevel(to: sender.integerValue) }
    @objc private func changeTarPreservesOwnerIDs(_ sender: NSButton) { viewModel.changeTarPreservesOwnerIDs(to: sender.state == .on) }
    @objc private func changeExtractionDestination(_ sender: NSPopUpButton) { viewModel.selectExtractionDestination(at: sender.indexOfSelectedItem) }
    @objc private func changeFolderPolicy(_ sender: NSPopUpButton) { viewModel.selectFolderPolicy(at: sender.indexOfSelectedItem) }
    @objc private func changeAfterExpansion(_ sender: NSPopUpButton) { viewModel.selectAfterExpansion(at: sender.indexOfSelectedItem) }
    @objc private func changeRevealsExtractedItemsInFinder(_ sender: NSButton) { viewModel.changeRevealsExtractedItemsInFinder(to: sender.state == .on) }
}
