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

    func changeTrashesArchiveAfterExtraction(to enabled: Bool) { store.preferences.trashesArchiveAfterExtraction = enabled }
}

final class PreferencesWindowController: NSWindowController {
    let viewModel: PreferencesViewModel
    let tabController = NSTabViewController()
    let defaultFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let zipMethodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let zipLevelSlider = NSSlider(value: 6, minValue: 1, maxValue: 9, target: nil, action: nil)
    let zipLevelLabel = NSTextField(labelWithString: "")
    let zipSkipsCompressedTypesCheckbox = NSButton(
        checkboxWithTitle: String(localized: "圧縮済みのファイル(zip・jpg・mp4 など)は無圧縮で格納"), target: nil, action: nil)
    let tarGzipLevelSlider = NSSlider(value: 6, minValue: 1, maxValue: 9, target: nil, action: nil)
    let tarGzipLevelLabel = NSTextField(labelWithString: "")
    let tarPreservesOwnerIDsCheckbox = NSButton(
        checkboxWithTitle: String(localized: "所有者 ID(uid / gid)を保存"), target: nil, action: nil)
    let extractionDestinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let folderPolicyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let trashesArchiveAfterExtractionCheckbox = NSButton(
        checkboxWithTitle: String(localized: "展開後に書庫をゴミ箱に入れる"), target: nil, action: nil)

    init(store: ArchivePreferencesStore = .shared) {
        viewModel = PreferencesViewModel(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = String(localized: "設定")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("Preferences")
        tabController.tabStyle = .toolbar
        configureControls()
        addTab(title: String(localized: "一般"), symbol: "gearshape", views: [
            row(String(localized: "新規書庫の既定形式"), control: defaultFormatPopup)
        ])
        addTab(title: String(localized: "圧縮"), symbol: "archivebox", views: [
            group(title: String(localized: "ZIP"), views: [
                row(String(localized: "圧縮方式"), control: zipMethodPopup),
                row(String(localized: "圧縮レベル"), control: levelControl(zipLevelSlider, label: zipLevelLabel)),
                zipSkipsCompressedTypesCheckbox
            ]),
            group(title: String(localized: "tar.gz"), views: [
                row(String(localized: "gzip レベル"), control: levelControl(tarGzipLevelSlider, label: tarGzipLevelLabel))
            ]),
            group(title: String(localized: "tar"), views: [tarPreservesOwnerIDsCheckbox]),
            NSTextField(wrappingLabelWithString: String(localized: "7z は LZMA2、LHA は -lh5- 固定です"))
        ])
        addTab(title: String(localized: "展開"), symbol: "tray.and.arrow.down", views: [
            row(String(localized: "展開先"), control: extractionDestinationPopup),
            row(String(localized: "フォルダを作成"), control: folderPolicyPopup),
            trashesArchiveAfterExtractionCheckbox
        ])
        window.contentViewController = tabController
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
        defaultFormatPopup.addItems(withTitles: ArchivePreferences.formats.map(ArchiveSavePanelController.title))
        zipMethodPopup.addItems(withTitles: [String(localized: "Deflate"), String(localized: "無圧縮")])
        extractionDestinationPopup.addItems(withTitles: [String(localized: "書庫と同じフォルダ"), String(localized: "毎回選ぶ")])
        folderPolicyPopup.addItems(withTitles: [String(localized: "常に"), String(localized: "複数の項目があるとき"),
                                              String(localized: "作らない")])
        let actions: [(NSControl, Selector)] = [
            (defaultFormatPopup, #selector(changeDefaultFormat(_:))),
            (zipMethodPopup, #selector(changeZipMethod(_:))),
            (zipLevelSlider, #selector(changeZipLevel(_:))),
            (zipSkipsCompressedTypesCheckbox, #selector(changeZipSkipsCompressedTypes(_:))),
            (tarGzipLevelSlider, #selector(changeTarGzipLevel(_:))),
            (tarPreservesOwnerIDsCheckbox, #selector(changeTarPreservesOwnerIDs(_:))),
            (extractionDestinationPopup, #selector(changeExtractionDestination(_:))),
            (folderPolicyPopup, #selector(changeFolderPolicy(_:))),
            (trashesArchiveAfterExtractionCheckbox, #selector(changeTrashesArchiveAfterExtraction(_:)))
        ]
        for (control, action) in actions { control.target = self; control.action = action }
        zipLevelSlider.setAccessibilityLabel(String(localized: "圧縮レベル"))
        tarGzipLevelSlider.setAccessibilityLabel(String(localized: "gzip レベル"))
    }

    private func levelControl(_ slider: NSSlider, label: NSTextField) -> NSView {
        slider.numberOfTickMarks = 9
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 250).isActive = true
        label.widthAnchor.constraint(equalToConstant: 24).isActive = true
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.alignment = .right
        let stack = NSStackView(views: [slider, label])
        stack.spacing = 12
        stack.alignment = .centerY
        return stack
    }

    private func row(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 180).isActive = true
        control.setAccessibilityLabel(title)
        let stack = NSStackView(views: [label, control])
        stack.spacing = 12
        stack.alignment = .centerY
        return stack
    }

    private func group(title: String, views: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let stack = NSStackView(views: [label] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func addTab(title: String, symbol: String, views: [NSView]) {
        let controller = NSViewController()
        controller.title = title
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 420))
        controller.preferredContentSize = controller.view.frame.size
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: controller.view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: controller.view.bottomAnchor, constant: -24)
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
        trashesArchiveAfterExtractionCheckbox.state = preferences.trashesArchiveAfterExtraction ? .on : .off
    }

    @objc private func changeDefaultFormat(_ sender: NSPopUpButton) { viewModel.selectDefaultFormat(at: sender.indexOfSelectedItem) }
    @objc private func changeZipMethod(_ sender: NSPopUpButton) { viewModel.selectZipMethod(at: sender.indexOfSelectedItem) }
    @objc private func changeZipLevel(_ sender: NSSlider) { viewModel.changeZipLevel(to: sender.integerValue) }
    @objc private func changeZipSkipsCompressedTypes(_ sender: NSButton) { viewModel.changeZipSkipsCompressedTypes(to: sender.state == .on) }
    @objc private func changeTarGzipLevel(_ sender: NSSlider) { viewModel.changeTarGzipLevel(to: sender.integerValue) }
    @objc private func changeTarPreservesOwnerIDs(_ sender: NSButton) { viewModel.changeTarPreservesOwnerIDs(to: sender.state == .on) }
    @objc private func changeExtractionDestination(_ sender: NSPopUpButton) { viewModel.selectExtractionDestination(at: sender.indexOfSelectedItem) }
    @objc private func changeFolderPolicy(_ sender: NSPopUpButton) { viewModel.selectFolderPolicy(at: sender.indexOfSelectedItem) }
    @objc private func changeTrashesArchiveAfterExtraction(_ sender: NSButton) { viewModel.changeTrashesArchiveAfterExtraction(to: sender.state == .on) }
}
