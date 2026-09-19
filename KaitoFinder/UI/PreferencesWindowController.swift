import AppKit

/// 画面を出さずに、各コントロールの選択と即時保存を検証できる。
final class PreferencesViewModel {
    static let zipMethods: [ArchivePreferences.ZipMethod] = [.deflate, .stored]
    static let extractionDestinations: [ArchivePreferences.ExtractionDestination] = [.sameFolder, .ask]
    static let folderPolicies: [ArchivePreferences.FolderPolicy] = [.always, .whenMultipleTopLevelItems, .never]
    static let openingBehaviors = ArchivePreferences.OpeningBehavior.allCases
    private let store: ArchivePreferencesStore

    init(store: ArchivePreferencesStore = .shared) { self.store = store }

    var preferences: ArchivePreferences { store.preferences }
    var defaultFormatIndex: Int { ArchivePreferences.formats.firstIndex(of: preferences.defaultFormat)! }
    var openingBehaviorIndex: Int { Self.openingBehaviors.firstIndex(of: preferences.openingBehavior)! }
    var zipMethodIndex: Int { Self.zipMethods.firstIndex(of: preferences.zipMethod)! }
    var extractionDestinationIndex: Int { Self.extractionDestinations.firstIndex(of: preferences.extractionDestination)! }
    var afterExpansionIndex: Int { preferences.trashesArchiveAfterExtraction ? 1 : 0 }
    var folderPolicyIndex: Int { Self.folderPolicies.firstIndex(of: preferences.folderPolicy)! }
    var zipLevelLabel: String { String(preferences.zipLevel) }
    var tarGzipLevelLabel: String { String(preferences.tarGzipLevel) }
    var tarBzip2LevelLabel: String { String(preferences.tarBzip2Level) }

    func selectDefaultFormat(at index: Int) {
        guard ArchivePreferences.formats.indices.contains(index) else { return }
        store.preferences.defaultFormat = ArchivePreferences.formats[index]
    }

    func selectOpeningBehavior(at index: Int) {
        guard Self.openingBehaviors.indices.contains(index) else { return }
        store.preferences.openingBehavior = Self.openingBehaviors[index]
    }

    func selectZipMethod(at index: Int) {
        guard Self.zipMethods.indices.contains(index) else { return }
        store.preferences.zipMethod = Self.zipMethods[index]
    }

    func changeZipLevel(to level: Int) { store.preferences.zipLevel = ArchivePreferences.clampedLevel(level) }
    func changeZipSkipsCompressedTypes(to enabled: Bool) { store.preferences.zipSkipsCompressedTypes = enabled }
    func changeTarGzipLevel(to level: Int) { store.preferences.tarGzipLevel = ArchivePreferences.clampedLevel(level) }
    func changeTarBzip2Level(to level: Int) { store.preferences.tarBzip2Level = ArchivePreferences.clampedLevel(level) }
    func changeTarPreservesOwnerIDs(to enabled: Bool) { store.preferences.tarPreservesOwnerIDs = enabled }
    func changeShowsHiddenFiles(to enabled: Bool) { store.preferences.showsHiddenFiles = enabled }
    func changeShowsWelcomeWindowAtLaunch(to enabled: Bool) { store.preferences.showsWelcomeWindowAtLaunch = enabled }
    func changeRenamesOnClick(to enabled: Bool) { store.preferences.renamesOnClick = enabled }
    func changeExcludesDSStore(to enabled: Bool) { store.preferences.excludesDSStore = enabled }
    func changeExcludesHiddenFiles(to enabled: Bool) { store.preferences.excludesHiddenFiles = enabled }

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

/// 設定の切り替えでは上辺と幅を保ち、内容に必要な高さだけを変える。
final class PreferencesTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let size = tabViewItem?.viewController?.preferredContentSize, size.width > 0 else { return }
        preferredContentSize = size
        guard let window = view.window else { return }
        let sizeWithTitlebar = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - sizeWithTitlebar.height,
                           width: sizeWithTitlebar.width, height: sizeWithTitlebar.height)
        if let visible = window.screen?.visibleFrame, frame.height <= visible.height {
            // 画面下端に置いた一般タブを広げても、圧縮の設定が画面外へ落ちないようにする。
            frame.origin.y = max(visible.minY, frame.minY)
        }
        window.setFrame(frame, display: true,
                        animate: window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

final class PreferencesWindowController: NSWindowController {
    nonisolated static let frameAutosaveName = "Preferences"

    let viewModel: PreferencesViewModel
    private let bundle: Bundle
    private let softwareUpdater: any SoftwareUpdating
    let tabController = PreferencesTabViewController()
    let defaultFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let openingBehaviorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let zipMethodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let zipLevelSlider = NSSlider(value: 6, minValue: 1, maxValue: 9, target: nil, action: nil)
    let zipLevelLabel = NSTextField(labelWithString: "")
    let zipSkipsCompressedTypesCheckbox: NSButton
    let tarGzipLevelSlider = NSSlider(value: 6, minValue: 1, maxValue: 9, target: nil, action: nil)
    let tarGzipLevelLabel = NSTextField(labelWithString: "")
    let tarBzip2LevelSlider = NSSlider(value: 9, minValue: 1, maxValue: 9, target: nil, action: nil)
    let tarBzip2LevelLabel = NSTextField(labelWithString: "")
    let tarPreservesOwnerIDsCheckbox: NSButton
    let extractionDestinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let folderPolicyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let afterExpansionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let revealsExtractedItemsInFinderCheckbox: NSButton
    let showsHiddenFilesCheckbox: NSButton
    let showsWelcomeWindowAtLaunchCheckbox: NSButton
    let renamesOnClickCheckbox: NSButton
    let excludesDSStoreCheckbox: NSButton
    let excludesHiddenFilesCheckbox: NSButton
    let automaticallyChecksForUpdatesCheckbox: NSButton
    let automaticallyDownloadsUpdatesCheckbox: NSButton
    let checkForUpdatesButton: NSButton
    let lastUpdateCheckLabel = NSTextField(labelWithString: "")
    let updateAvailabilityLabel: NSTextField

    init(store: ArchivePreferencesStore = .shared, bundle: Bundle = .main,
         softwareUpdater: any SoftwareUpdating = SoftwareUpdateController.shared) {
        self.bundle = bundle
        self.softwareUpdater = softwareUpdater
        automaticallyChecksForUpdatesCheckbox = NSButton(
            checkboxWithTitle: String(localized: "アップデートを自動的に確認", bundle: bundle), target: nil, action: nil)
        automaticallyDownloadsUpdatesCheckbox = NSButton(
            checkboxWithTitle: String(localized: "アップデートを自動的にダウンロードしてインストール", bundle: bundle), target: nil, action: nil)
        checkForUpdatesButton = NSButton(title: String(localized: "アップデートを確認…", bundle: bundle), target: nil, action: nil)
        updateAvailabilityLabel = NSTextField(wrappingLabelWithString:
            String(localized: "ダウンロードしたアップデートは、KaitoFinderの終了時にインストールされます。", bundle: bundle))
        showsWelcomeWindowAtLaunchCheckbox = NSButton(
            checkboxWithTitle: String(localized: "起動時にようこそウインドウを表示", bundle: bundle), target: nil, action: nil)
        showsHiddenFilesCheckbox = NSButton(
            checkboxWithTitle: String(localized: "隠しファイルを表示", bundle: bundle), target: nil, action: nil)
        renamesOnClickCheckbox = NSButton(
            checkboxWithTitle: String(localized: "選択した名前をクリックして名称変更（Finderと同じ）", bundle: bundle), target: nil, action: nil)
        excludesDSStoreCheckbox = NSButton(
            checkboxWithTitle: String(localized: ".DS_Store を含めない", bundle: bundle), target: nil, action: nil)
        excludesHiddenFilesCheckbox = NSButton(
            checkboxWithTitle: String(localized: "隠しファイル(名前が . で始まる)を含めない", bundle: bundle), target: nil, action: nil)
        zipSkipsCompressedTypesCheckbox = NSButton(
            checkboxWithTitle: String(localized: "圧縮済みのファイル(zip・jpg・mp4など)は無圧縮で格納", bundle: bundle), target: nil, action: nil)
        tarPreservesOwnerIDsCheckbox = NSButton(
            checkboxWithTitle: String(localized: "所有者ID(uid / gid)を保存", bundle: bundle), target: nil, action: nil)
        revealsExtractedItemsInFinderCheckbox = NSButton(
            checkboxWithTitle: String(localized: "展開した項目をFinderに表示", bundle: bundle), target: nil, action: nil)
        viewModel = PreferencesViewModel(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = String(localized: "設定", bundle: bundle)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.autorecalculatesKeyViewLoop = true
        window.toolbarStyle = .preference
        window.center()
        window.setFrameAutosaveName(Self.frameAutosaveName)
        tabController.tabStyle = .toolbar
        tabController.canPropagateSelectedChildViewControllerTitle = false
        configureControls()
        addTab(title: String(localized: "一般", bundle: bundle), symbol: "gearshape", sections: [
            group(rows: [
                row(String(localized: "新規アーカイブの既定フォーマット:", bundle: bundle), control: defaultFormatPopup),
                row(String(localized: "アーカイブを開くとき:", bundle: bundle), control: openingBehaviorPopup)
            ]),
            group(rows: [
                checkboxRow(showsHiddenFilesCheckbox),
                checkboxRow(showsWelcomeWindowAtLaunchCheckbox),
                checkboxRow(renamesOnClickCheckbox)
            ], spanningRows: [0, 1, 2])
        ])
        let footnote = NSTextField(wrappingLabelWithString: String(localized: "tar.xz、7z、LHA の圧縮レベルは固定です", bundle: bundle))
        footnote.textColor = .secondaryLabelColor
        footnote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        footnote.preferredMaxLayoutWidth = 520
        addTab(title: String(localized: "圧縮", bundle: bundle), symbol: "archivebox", sections: [
            group(rows: [checkboxRow(excludesDSStoreCheckbox), checkboxRow(excludesHiddenFilesCheckbox)], spanningRows: [0, 1]),
            group(title: String(localized: "ZIP", bundle: bundle), rows: [
                row(String(localized: "圧縮方式:", bundle: bundle), control: zipMethodPopup),
                row(String(localized: "圧縮レベル:", bundle: bundle), control: levelControl(zipLevelSlider, label: zipLevelLabel)),
                checkboxRow(zipSkipsCompressedTypesCheckbox)
            ], spanningRows: [2]),
            group(title: String(localized: "tar", bundle: bundle), rows: [
                row(String(localized: "gzipレベル:", bundle: bundle), control: levelControl(tarGzipLevelSlider, label: tarGzipLevelLabel)),
                row(String(localized: "bzip2レベル:", bundle: bundle), control: levelControl(tarBzip2LevelSlider, label: tarBzip2LevelLabel)),
                checkboxRow(tarPreservesOwnerIDsCheckbox)
            ], spanningRows: [2]),
            footnote
        ])
        addTab(title: String(localized: "展開", bundle: bundle), symbol: "tray.and.arrow.down", sections: [
            group(rows: [
                row(String(localized: "展開したファイルの保存場所:", bundle: bundle), control: extractionDestinationPopup),
                row(String(localized: "フォルダを作成:", bundle: bundle), control: folderPolicyPopup)
            ]),
            group(rows: [
                row(String(localized: "展開後:", bundle: bundle), control: afterExpansionPopup),
                checkboxRow(revealsExtractedItemsInFinderCheckbox)
            ], spanningRows: [1])
        ])
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let versionLabel = NSTextField(labelWithString: "KaitoFinder \(version) (\(build))")
        versionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        updateAvailabilityLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        updateAvailabilityLabel.textColor = .secondaryLabelColor
        updateAvailabilityLabel.preferredMaxLayoutWidth = 520
        // 状態や日時の変化でウインドウを揺らさない。文言は既存の設定幅で折り返す。
        lastUpdateCheckLabel.textColor = .secondaryLabelColor
        lastUpdateCheckLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lastUpdateCheckLabel.lineBreakMode = .byTruncatingTail
        lastUpdateCheckLabel.widthAnchor.constraint(equalToConstant: 520).isActive = true
        let updateActions = NSStackView(views: [checkForUpdatesButton, lastUpdateCheckLabel])
        updateActions.orientation = .vertical
        updateActions.alignment = .leading
        updateActions.spacing = 10
        updateActions.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        addTab(title: String(localized: "アップデート", bundle: bundle), symbol: "arrow.triangle.2.circlepath", sections: [
            versionLabel,
            group(rows: [checkboxRow(automaticallyChecksForUpdatesCheckbox),
                         checkboxRow(automaticallyDownloadsUpdatesCheckbox)], spanningRows: [0, 1]),
            updateAvailabilityLabel,
            updateActions
        ])
        // 長い翻訳も省略しない共通の幅を選び、高さはタブの内容に合わせる。
        let width = tabController.tabViewItems.reduce(CGFloat(600)) { width, item in
            max(width, item.viewController?.preferredContentSize.width ?? 0)
        }
        for item in tabController.tabViewItems {
            guard let pane = item.viewController else { continue }
            pane.preferredContentSize.width = width
            pane.view.setFrameSize(pane.preferredContentSize)
        }
        let contentSize = tabController.tabViewItems[0].viewController!.preferredContentSize
        tabController.preferredContentSize = contentSize
        window.contentViewController = tabController
        window.setContentSize(contentSize)
        window.toolbar?.displayMode = .iconAndLabel
        window.toolbar?.allowsUserCustomization = false
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)),
                                               name: ArchivePreferencesStore.didChange, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(softwareUpdatesDidChange(_:)),
                                               name: SoftwareUpdateController.didChange, object: softwareUpdater)
        refreshControls()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        refreshControls()
        super.showWindow(sender)
    }

    private func configureControls() {
        defaultFormatPopup.addItems(withTitles: ArchivePreferences.formats.map { ArchiveSavePanelController.title(for: $0, bundle: bundle) })
        openingBehaviorPopup.addItems(withTitles: [String(localized: "macOSの設定に従う", bundle: bundle),
                                                  String(localized: "新しいタブ", bundle: bundle),
                                                  String(localized: "新しいウインドウ", bundle: bundle)])
        zipMethodPopup.addItems(withTitles: [String(localized: "Deflate", bundle: bundle), String(localized: "無圧縮", bundle: bundle)])
        extractionDestinationPopup.addItems(withTitles: [String(localized: "アーカイブと同じディレクトリ内", bundle: bundle), String(localized: "場所を選択…", bundle: bundle)])
        afterExpansionPopup.addItems(withTitles: [String(localized: "アーカイブをそのままにする", bundle: bundle),
                                                 String(localized: "アーカイブをゴミ箱に入れる", bundle: bundle)])
        folderPolicyPopup.addItems(withTitles: [String(localized: "常に", bundle: bundle), String(localized: "複数の項目があるとき", bundle: bundle),
                                              String(localized: "作らない", bundle: bundle)])
        let actions: [(NSControl, Selector)] = [
            (showsWelcomeWindowAtLaunchCheckbox, #selector(changeShowsWelcomeWindowAtLaunch(_:))),
            (showsHiddenFilesCheckbox, #selector(changeShowsHiddenFiles(_:))),
            (renamesOnClickCheckbox, #selector(changeRenamesOnClick(_:))),
            (excludesDSStoreCheckbox, #selector(changeExcludesDSStore(_:))),
            (excludesHiddenFilesCheckbox, #selector(changeExcludesHiddenFiles(_:))),
            (defaultFormatPopup, #selector(changeDefaultFormat(_:))),
            (openingBehaviorPopup, #selector(changeOpeningBehavior(_:))),
            (zipMethodPopup, #selector(changeZipMethod(_:))),
            (zipLevelSlider, #selector(changeZipLevel(_:))),
            (zipSkipsCompressedTypesCheckbox, #selector(changeZipSkipsCompressedTypes(_:))),
            (tarGzipLevelSlider, #selector(changeTarGzipLevel(_:))),
            (tarBzip2LevelSlider, #selector(changeTarBzip2Level(_:))),
            (tarPreservesOwnerIDsCheckbox, #selector(changeTarPreservesOwnerIDs(_:))),
            (extractionDestinationPopup, #selector(changeExtractionDestination(_:))),
            (folderPolicyPopup, #selector(changeFolderPolicy(_:))),
            (afterExpansionPopup, #selector(changeAfterExpansion(_:))),
            (revealsExtractedItemsInFinderCheckbox, #selector(changeRevealsExtractedItemsInFinder(_:))),
            (automaticallyChecksForUpdatesCheckbox, #selector(changeAutomaticallyChecksForUpdates(_:))),
            (automaticallyDownloadsUpdatesCheckbox, #selector(changeAutomaticallyDownloadsUpdates(_:))),
            (checkForUpdatesButton, #selector(checkForUpdates(_:)))
        ]
        for (control, action) in actions { control.target = self; control.action = action }
        zipLevelSlider.setAccessibilityLabel(String(localized: "圧縮レベル", bundle: bundle))
        tarGzipLevelSlider.setAccessibilityLabel(String(localized: "gzipレベル", bundle: bundle))
        tarBzip2LevelSlider.setAccessibilityLabel(String(localized: "bzip2レベル", bundle: bundle))
    }

    private func levelControl(_ slider: NSSlider, label: NSTextField) -> NSView {
        slider.numberOfTickMarks = 9
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        label.widthAnchor.constraint(equalToConstant: 24).isActive = true
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
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
        label.alignment = .left
        if label.intrinsicContentSize.width > 260 {
            // 長い翻訳だけを二行まで折り返し、行のコントロールはグリッドで中央に揃える。
            label.usesSingleLineMode = false
            label.cell?.wraps = true
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            label.preferredMaxLayoutWidth = 260
        }
        control.setAccessibilityLabel(title)
        return [label, control]
    }

    private func checkboxRow(_ button: NSButton) -> [NSView] {
        let width: CGFloat = 520
        button.cell?.wraps = true
        button.cell?.lineBreakMode = .byWordWrapping
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        // チェックの領域を差し引いた幅で、日英どちらの長い文言も折り返す。
        let size = button.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)) ?? .zero
        button.heightAnchor.constraint(equalToConstant: ceil(size.height)).isActive = true
        return [button, NSGridCell.emptyContentView]
    }

    private func group(title: String? = nil, rows: [[NSView]], spanningRows: [Int] = []) -> NSView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 14
        grid.columnSpacing = 20
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).leadingPadding = 2
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 1).trailingPadding = 2
        for row in spanningRows {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: row, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .leading
        }
        let required = grid.fittingSize
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = 0.5
        box.cornerRadius = 8
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        let content = box.contentView!
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            // NSBox の contentView は枠線の内側にある。
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(required.width) + 32 + box.borderWidth * 2),
            box.heightAnchor.constraint(equalToConstant: ceil(required.height) + 28 + box.borderWidth * 2),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        guard let title else { return box }
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let header = NSStackView(views: [heading])
        header.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        let section = NSStackView(views: [header, box])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        box.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func addTab(title: String, symbol: String, sections: [NSView]) {
        let controller = NSViewController()
        controller.title = title
        controller.view = NSView()
        let stack = NSStackView(views: sections)
        stack.identifier = NSUserInterfaceItemIdentifier("preferences.sections." + symbol)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.spacing = 20
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4).isActive = true
        }
        let required = stack.fittingSize
        controller.preferredContentSize = NSSize(width: max(600, ceil(required.width) + 48),
                                                height: ceil(required.height) + 48)
        controller.view.setFrameSize(controller.preferredContentSize)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: controller.view.bottomAnchor, constant: -24)
        ])
        let item = NSTabViewItem(viewController: controller)
        item.identifier = "preferences." + symbol
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabController.addTabViewItem(item)
    }

    @objc private func preferencesDidChange(_ notification: Notification) { refreshControls() }
    @objc private func softwareUpdatesDidChange(_ notification: Notification) { refreshUpdateControls() }

    @objc private func changeAutomaticallyChecksForUpdates(_ sender: NSButton) {
        softwareUpdater.automaticallyChecksForUpdates = sender.state == .on
        refreshUpdateControls()
    }

    @objc private func changeAutomaticallyDownloadsUpdates(_ sender: NSButton) {
        softwareUpdater.automaticallyDownloadsUpdates = sender.state == .on
        refreshUpdateControls()
    }

    @objc private func checkForUpdates(_ sender: NSButton) { softwareUpdater.checkForUpdates() }

    private func refreshUpdateControls() {
        automaticallyChecksForUpdatesCheckbox.state = softwareUpdater.automaticallyChecksForUpdates ? .on : .off
        automaticallyChecksForUpdatesCheckbox.isEnabled = softwareUpdater.isAvailable
        automaticallyDownloadsUpdatesCheckbox.state = softwareUpdater.automaticallyDownloadsUpdates ? .on : .off
        automaticallyDownloadsUpdatesCheckbox.isEnabled = softwareUpdater.isAvailable
            && softwareUpdater.automaticallyChecksForUpdates && softwareUpdater.allowsAutomaticUpdates
        checkForUpdatesButton.isEnabled = softwareUpdater.canCheckForUpdates
        let lastCheck = softwareUpdater.lastUpdateCheckDate.map {
            DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short)
        } ?? String(localized: "未確認", bundle: bundle)
        lastUpdateCheckLabel.stringValue = String(format: String(localized: "最終確認: %@", bundle: bundle), lastCheck)
        lastUpdateCheckLabel.toolTip = lastUpdateCheckLabel.stringValue
        updateAvailabilityLabel.stringValue = softwareUpdater.isAvailable
            ? String(localized: "ダウンロードしたアップデートは、KaitoFinderの終了時にインストールされます。", bundle: bundle)
            : String(localized: "このビルドでは自動更新を利用できません。", bundle: bundle)
    }

    private func refreshControls() {
        refreshUpdateControls()
        let preferences = viewModel.preferences
        showsWelcomeWindowAtLaunchCheckbox.state = preferences.showsWelcomeWindowAtLaunch ? .on : .off
        showsHiddenFilesCheckbox.state = preferences.showsHiddenFiles ? .on : .off
        renamesOnClickCheckbox.state = preferences.renamesOnClick ? .on : .off
        excludesDSStoreCheckbox.state = preferences.excludesDSStore ? .on : .off
        excludesHiddenFilesCheckbox.state = preferences.excludesHiddenFiles ? .on : .off
        defaultFormatPopup.selectItem(at: viewModel.defaultFormatIndex)
        openingBehaviorPopup.selectItem(at: viewModel.openingBehaviorIndex)
        zipMethodPopup.selectItem(at: viewModel.zipMethodIndex)
        zipLevelSlider.integerValue = preferences.zipLevel
        zipLevelLabel.stringValue = viewModel.zipLevelLabel
        zipLevelSlider.isEnabled = preferences.zipMethod == .deflate
        zipLevelLabel.textColor = zipLevelSlider.isEnabled ? .secondaryLabelColor : .disabledControlTextColor
        zipSkipsCompressedTypesCheckbox.state = preferences.zipSkipsCompressedTypes ? .on : .off
        tarGzipLevelSlider.integerValue = preferences.tarGzipLevel
        tarGzipLevelLabel.stringValue = viewModel.tarGzipLevelLabel
        tarBzip2LevelSlider.integerValue = preferences.tarBzip2Level
        tarBzip2LevelLabel.stringValue = viewModel.tarBzip2LevelLabel
        tarPreservesOwnerIDsCheckbox.state = preferences.tarPreservesOwnerIDs ? .on : .off
        extractionDestinationPopup.selectItem(at: viewModel.extractionDestinationIndex)
        folderPolicyPopup.selectItem(at: viewModel.folderPolicyIndex)
        afterExpansionPopup.selectItem(at: viewModel.afterExpansionIndex)
        revealsExtractedItemsInFinderCheckbox.state = preferences.revealsExtractedItemsInFinder ? .on : .off
    }

    @objc private func changeDefaultFormat(_ sender: NSPopUpButton) { viewModel.selectDefaultFormat(at: sender.indexOfSelectedItem) }
    @objc private func changeOpeningBehavior(_ sender: NSPopUpButton) { viewModel.selectOpeningBehavior(at: sender.indexOfSelectedItem) }
    @objc private func changeShowsHiddenFiles(_ sender: NSButton) { viewModel.changeShowsHiddenFiles(to: sender.state == .on) }
    @objc private func changeRenamesOnClick(_ sender: NSButton) { viewModel.changeRenamesOnClick(to: sender.state == .on) }
    @objc private func changeShowsWelcomeWindowAtLaunch(_ sender: NSButton) {
        viewModel.changeShowsWelcomeWindowAtLaunch(to: sender.state == .on)
    }
    @objc private func changeExcludesDSStore(_ sender: NSButton) { viewModel.changeExcludesDSStore(to: sender.state == .on) }
    @objc private func changeExcludesHiddenFiles(_ sender: NSButton) { viewModel.changeExcludesHiddenFiles(to: sender.state == .on) }
    @objc private func changeZipMethod(_ sender: NSPopUpButton) { viewModel.selectZipMethod(at: sender.indexOfSelectedItem) }
    @objc private func changeZipLevel(_ sender: NSSlider) { viewModel.changeZipLevel(to: sender.integerValue) }
    @objc private func changeZipSkipsCompressedTypes(_ sender: NSButton) { viewModel.changeZipSkipsCompressedTypes(to: sender.state == .on) }
    @objc private func changeTarGzipLevel(_ sender: NSSlider) { viewModel.changeTarGzipLevel(to: sender.integerValue) }
    @objc private func changeTarBzip2Level(_ sender: NSSlider) { viewModel.changeTarBzip2Level(to: sender.integerValue) }
    @objc private func changeTarPreservesOwnerIDs(_ sender: NSButton) { viewModel.changeTarPreservesOwnerIDs(to: sender.state == .on) }
    @objc private func changeExtractionDestination(_ sender: NSPopUpButton) { viewModel.selectExtractionDestination(at: sender.indexOfSelectedItem) }
    @objc private func changeFolderPolicy(_ sender: NSPopUpButton) { viewModel.selectFolderPolicy(at: sender.indexOfSelectedItem) }
    @objc private func changeAfterExpansion(_ sender: NSPopUpButton) { viewModel.selectAfterExpansion(at: sender.indexOfSelectedItem) }
    @objc private func changeRevealsExtractedItemsInFinder(_ sender: NSButton) { viewModel.changeRevealsExtractedItemsInFinder(to: sender.state == .on) }
}
