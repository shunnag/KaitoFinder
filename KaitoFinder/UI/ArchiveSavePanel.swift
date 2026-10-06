import AppKit
import KaitoKit
import GyoshukuKit
import QuartzCore
import UniformTypeIdentifiers

/// 内容を自然な高さで上端に置き、表示範囲の切り取りは保存パネルに任せる。
/// フォームの下端をパネルに拘束すると、アニメーション中に行が潰れたり引き伸ばされたりする。
private final class ArchiveSaveAccessoryView: NSView {
    private let form: NSStackView
    // 内容の自然な高さとは別に、保存パネルへ現在の表示領域の高さを伝える。
    var viewportHeight: CGFloat?
    var viewportHeightInPanel: (() -> CGFloat)?

    init(form: NSStackView) {
        self.form = form
        super.init(frame: .zero)
        autoresizingMask = [.width]
        // 表示領域のクリップは保存パネルのホストに任せる。
        // 要求中の小さい高さで先に切り取ると、縮小時に先頭行が一瞬欠ける。
        clipsToBounds = false
        addSubview(form)
        // XPC は fittingSize とは別に制約も検査する。高さゼロの代替固定制約を
        // AppKit に挿入されないよう最小値だけを定め、実際の高さは伸縮に任せる。
        heightAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: fittingSize.width).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    var contentSize: NSSize {
        let size = form.fittingSize
        return NSSize(width: size.width + 32, height: size.height)
    }

    override var fittingSize: NSSize {
        var size = contentSize
        if let viewportHeight { size.height = viewportHeight }
        return size
    }

    override func layout() {
        super.layout()
        let size = form.fittingSize
        // XPC ホストの bounds は、実際の保存パネルより遅れて更新される。
        // 画面に出ているパネルの高さを基準に、フォームを上端へ合わせる。
        let top = viewportHeightInPanel.map { bounds.height - $0() } ?? 0
        form.frame = NSRect(x: (bounds.width - size.width) / 2, y: top, width: size.width, height: size.height)
        form.layoutSubtreeIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        // ホストからのリサイズでも、次の描画まで配置の補正を持ち越さない。
        layoutSubtreeIfNeeded()
    }
}

/// ディスプレイの描画周期で高さを更新し、独立したタイマーとのずれを避ける。
private final class ArchiveSaveResizeAnimation: NSObject {
    // CADisplayLink が target を保持しても、終了したパネルを保持し続けない。
    private final class Target: NSObject {
        weak var animation: ArchiveSaveResizeAnimation?
        @objc func tick(_ link: CADisplayLink) { animation?.tick(link) }
    }
    private let update: @MainActor (CGFloat) -> Void
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var generation = 0

    init(update: @escaping @MainActor (CGFloat) -> Void) {
        self.update = update
        super.init()
    }

    isolated deinit { link?.invalidate() }

    func start(on view: NSView) {
        let target = Target()
        target.animation = self
        let link = view.displayLink(target: target, selector: #selector(Target.tick(_:)))
        self.link = link
        startTime = CACurrentMediaTime()
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        generation += 1
        link?.invalidate()
        link = nil
    }

    private func tick(_ link: CADisplayLink) {
        // 目標時刻を過ぎても、XPC 側への反映が終わるまでは更新を続ける。
        let progress = min(1, max(0, (link.targetTimestamp - startTime) / 0.24))
        let value = CGFloat((1 - cos(progress * .pi)) / 2)
        let generation = generation
        // ウインドウの変更は描画コールバックを抜けてからまとめて反映する。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.update(value)
        }
    }
}

final class ArchiveSavePanel: NSObject, NSOpenSavePanelDelegate {
    private var configuredFilename = ""
    private var suggestedStem = ""
    private static let accessoryHorizontalInset: CGFloat = 2
    /// 分割保存の先頭巻に付く拡張子。分割中は名前欄に常にこの拡張子付きで表示する。
    private static let firstVolumeExtension = "001"
    private static var firstVolumeSuffix: String { "." + firstVolumeExtension }
    private static func hasFirstVolumeSuffix(_ name: String) -> Bool { name.hasSuffix(firstVolumeSuffix) }
    private static func strippingFirstVolumeSuffix(_ name: String) -> String {
        hasFirstVolumeSuffix(name) ? String(name.dropLast(firstVolumeSuffix.count)) : name
    }
    private static func appendingFirstVolumeSuffix(_ name: String) -> String { name + firstVolumeSuffix }
    let panel = NSSavePanel()
    let controller: ArchiveSavePanelController
    let splitControls: ArchiveSaveSplitControls?
    var estimatedSplitLength: UInt64 = 1
    let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let methodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let compatibilityNote: NSTextField
    let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let encryptionCheckbox: NSButton
    let passwordFields: ArchivePasswordFields
    let encryptionNote: NSTextField
    private let fixedLevelNote: NSTextField
    private let bundle: Bundle
    private let reducesMotion: () -> Bool
    private var layoutGeneration = 0
    private var resizeAnimation: ArchiveSaveResizeAnimation?
    private struct FilenameChange {
        let name: String
        let directory: URL?
        let tags: [String]?
        let frame: NSRect
        let accessoryHeight: CGFloat
    }
    private var pendingFilenameChange: FilenameChange?
    private weak var parentWindow: NSWindow?
    private var completionHandler: ((NSApplication.ModalResponse) -> Void)?
    private var parentCloseObserver: NSObjectProtocol?
    private var initialAnimationBehavior: NSWindow.AnimationBehavior = .default
    private var extensionHiddenObservation: NSKeyValueObservation?
    var isReconfiguring: Bool { pendingFilenameChange != nil }

    #if DEBUG
    // 標準パネルの表示だけを差し替え、完了コールバックと非同期の受け渡しはテストでも実物を通す。
    var presentationHandlerForTesting: ((@escaping (NSApplication.ModalResponse) -> Void) -> Void)?

    func stageFilenameChangeForTesting() {
        pendingFilenameChange = FilenameChange(name: "review.tar.gz", directory: panel.directoryURL,
            tags: panel.tagNames, frame: panel.frame, accessoryHeight: 0)
    }
    #endif


    isolated deinit {
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
    }

    convenience init(sources: [URL], existingURL: URL? = nil, defaults: UserDefaults, bundle: Bundle = .main) {
        self.init(sources: sources, existingURL: existingURL, store: ArchivePreferencesStore(defaults: defaults), bundle: bundle)
    }

    init(sources: [URL], existingURL: URL? = nil, store: ArchivePreferencesStore = .shared,
         encryption: ArchiveEncryptionSettings = .init(), sourceLayout: ArchiveVolumeLayout? = nil, bundle: Bundle = .main,
         reducesMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        splitControls = existingURL != nil && sources.isEmpty ? ArchiveSaveSplitControls(layout: sourceLayout, bundle: bundle) : nil
        self.bundle = bundle
        self.reducesMotion = reducesMotion
        passwordFields = ArchivePasswordFields(format: store.preferences.defaultFormat,
            minimumLabelWidth: Self.minimumLabelWidth(bundle: bundle), bundle: bundle)
        encryptionCheckbox = NSButton(checkboxWithTitle: String(localized: "暗号化", bundle: bundle), target: nil, action: nil)
        encryptionNote = Self.makeNote(String(localized: "tar と LHA は暗号化できません", bundle: bundle), width: passwordFields.width)
        fixedLevelNote = Self.makeNote(String(localized: "この形式は圧縮レベルを選べません", bundle: bundle), width: passwordFields.width)
        compatibilityNote = Self.makeNote(String(localized: "このZIPはmacOSのアーカイブユーティリティやunzipでは開けません", bundle: bundle), width: passwordFields.width)
        controller = ArchiveSavePanelController(store: store, sources: sources, allowsSingleStream: existingURL == nil)
        super.init()
        estimatedSplitLength = max(1, sourceLayout?.volumes.reduce(UInt64(0)) { $0 + $1.length }
            ?? UInt64(max(0, (try? existingURL?.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)))
        panel.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidResize(_:)), name: NSWindow.didResizeNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelWillStartLiveResize(_:)), name: NSWindow.willStartLiveResizeNotification, object: panel)
        panel.autorecalculatesKeyViewLoop = true
        passwordFields.fill(encryption)
        encryptionCheckbox.state = encryption.password == nil ? .off : .on
        encryptionCheckbox.target = self
        encryptionCheckbox.action = #selector(changeEncryption(_:))
        passwordFields.didChange = { [weak self] in self?.refreshPasswordNotice() }
        panel.directoryURL = (existingURL ?? sources.first)?.deletingLastPathComponent()
        let suggestedURL = sourceLayout.map { layout in
            if case .numbered = layout.scheme { return layout.gateURL.deletingPathExtension() }
            return layout.gateURL
        } ?? existingURL
        let suggestedName = suggestedURL.map { ArchiveCreationPlan.conversionName(for: $0, format: controller.format) }
            ?? ArchiveCreationPlan.defaultName(for: sources, format: controller.format)
        panel.allowedContentTypes = ArchiveSavePanelController.panelContentTypes
        panel.currentContentType = controller.allowedContentTypes.first
        panel.canCreateDirectories = true
        panel.isExtensionHidden = true
        // 初期表示では AppKit が最後の拡張子だけを隠す。
        // 本体を残し、保存時の完全な拡張子は currentContentType に任せる。
        let stem = ArchiveSavePanelController.filenameStem(suggestedName, format: controller.format)
        let suffix = controller.filenameExtension.split(separator: ".").last!
        suggestedStem = stem
        configuredFilename = stem + "." + suffix
        panel.nameFieldStringValue = configuredFilename
        formatPopup.addItems(withTitles: ArchiveSavePanelController.formats.map { ArchiveSavePanelController.title(for: $0, bundle: bundle) })
        if controller.offersSingleStream {
            formatPopup.menu?.addItem(.separator())
            let section = NSMenuItem(title: String(localized: "1 ファイルの圧縮", bundle: bundle), action: nil, keyEquivalent: "")
            section.isEnabled = false
            formatPopup.menu?.addItem(section)
            formatPopup.addItems(withTitles: ArchiveCreationPlan.singleStreamFormats.map { "." + ArchiveCreationPlan.filenameExtension(for: $0) })
        }
        formatPopup.selectItem(at: controller.selectedIndex)
        formatPopup.target = self
        formatPopup.action = #selector(changeFormat(_:))
        methodPopup.target = self
        methodPopup.action = #selector(changeMethod(_:))
        levelPopup.target = self
        levelPopup.action = #selector(changeLevel(_:))
        refreshLevel()
        // XPC 側が初期サイズを記憶する前に、不要な欄を隠しておく。
        refreshEncryption()
        panel.accessoryView = Self.makeAccessoryView(formatPopup: formatPopup, levelPopup: levelPopup,
                                                     fixedLevelNote: fixedLevelNote, encryptionCheckbox: encryptionCheckbox,
                                                     passwordFields: passwordFields, encryptionNote: encryptionNote, splitControls: splitControls, bundle: bundle,
                                                     methodPopup: methodPopup, compatibilityNote: compatibilityNote)
        refreshLevel()
        splitControls?.didChange = { [weak self] in self?.changeSplitChoice() }
        refreshSplitContentType()
        if splitControls?.isSplitting == true {
            configuredFilename = Self.appendingFirstVolumeSuffix(configuredFilename)
            panel.nameFieldStringValue = configuredFilename
        }
        extensionHiddenObservation = panel.observe(\.isExtensionHidden, options: [.new]) { [weak self] panel, _ in
            MainActor.assumeIsolated {
                guard let self, !self.isReconfiguring, self.splitControls?.isSplitting != true, panel.isVisible, panel.isExtensionHidden,
                      panel.currentContentType != self.controller.allowedContentTypes.first else { return }
                // 拡張子を消して名前を入力し直したら、完全な拡張子の自動補完へ戻す。
                // 名前の通知時点では hidden が旧値なので、その更新を直接観察する。
                panel.currentContentType = self.controller.allowedContentTypes.first
            }
        }
    }

    static func minimumLabelWidth(bundle: Bundle) -> CGFloat {
        [String(localized: "フォーマット", bundle: bundle), String(localized: "圧縮レベル", bundle: bundle), String(localized: "圧縮方式:", bundle: bundle), String(localized: "分割:", bundle: bundle)]
            .map { NSTextField(labelWithString: $0).intrinsicContentSize.width }.max() ?? 0
    }

    // 保存パネルの外部サービスに接続せず、同じアクセサリを構築できる。
    static func makeAccessoryView(formatPopup: NSPopUpButton, levelPopup: NSPopUpButton,
                                  fixedLevelNote: NSTextField, encryptionCheckbox: NSButton,
                                  passwordFields: ArchivePasswordFields, encryptionNote: NSTextField,
                                  splitControls: ArchiveSaveSplitControls? = nil, bundle: Bundle = .main,
                                  methodPopup: NSPopUpButton? = nil, compatibilityNote: NSTextField? = nil) -> NSView {
        formatPopup.setAccessibilityLabel(String(localized: "フォーマット", bundle: bundle))
        formatPopup.setAccessibilityIdentifier("ArchiveSaveFormat")
        levelPopup.setAccessibilityLabel(String(localized: "圧縮レベル", bundle: bundle))
        let rows = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "フォーマット", bundle: bundle)), formatPopup],
            [NSTextField(labelWithString: String(localized: "圧縮レベル", bundle: bundle)), levelPopup]
        ])
        if let methodPopup {
            methodPopup.setAccessibilityLabel(String(localized: "圧縮方式:", bundle: bundle))
            methodPopup.setAccessibilityIdentifier("ArchiveSaveMethod")
            rows.insertRow(at: 1, with: [NSTextField(labelWithString: String(localized: "圧縮方式:", bundle: bundle)), methodPopup])
            rows.row(at: 1).isHidden = methodPopup.isHidden
        }
        if let splitControls {
            rows.addRow(with: [NSTextField(labelWithString: String(localized: "分割:", bundle: bundle)), splitControls.view])
        }
        rows.columnSpacing = 12
        rows.rowSpacing = 10
        rows.column(at: 0).width = passwordFields.labelWidth
        rows.column(at: 0).xPlacement = .trailing
        rows.column(at: 0).leadingPadding = 2
        rows.column(at: 1).trailingPadding = 2
        rows.column(at: 1).xPlacement = .fill
        rows.yPlacement = .center
        for row in 0..<rows.numberOfRows {
            (rows.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField)?.alignment = .right
        }
        let width = passwordFields.width
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: width).isActive = true
        let encryptionRow = NSGridView(views: [[NSGridCell.emptyContentView, encryptionCheckbox]])
        encryptionRow.columnSpacing = 12
        encryptionRow.column(at: 0).width = passwordFields.labelWidth
        encryptionRow.column(at: 0).leadingPadding = 2
        encryptionRow.column(at: 1).xPlacement = .leading
        encryptionRow.column(at: 1).trailingPadding = 2
        encryptionRow.widthAnchor.constraint(equalToConstant: width).isActive = true
        let form = ArchiveAccessoryLayout.stack([rows, fixedLevelNote] + (compatibilityNote.map { [$0] } ?? [])
                                                + [separator, encryptionRow, passwordFields.view, encryptionNote],
                                                width: width + 2 * accessoryHorizontalInset, detachesHiddenViews: true)
        form.spacing = 12
        form.edgeInsets = NSEdgeInsets(top: 12, left: accessoryHorizontalInset, bottom: 8, right: accessoryHorizontalInset)
        rows.widthAnchor.constraint(equalToConstant: width).isActive = true
        // パネルの横幅は AppKit に任せ、フォームだけを中央に揃える。
        // accessoryView 自体の幅を固定すると、macOS 26 以降の保存パネルが伸縮できない。
        let accessory = ArchiveSaveAccessoryView(form: form)
        ArchiveAccessoryLayout.size(accessory)
        return accessory
    }

    static func makeNote(_ text: String, width: CGFloat) -> NSTextField {
        let note = NSTextField(wrappingLabelWithString: text)
        note.alignment = .left
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = width
        note.widthAnchor.constraint(equalToConstant: width).isActive = true
        return note
    }

    var encryptionSettings: ArchiveEncryptionSettings {
        encryptionCheckbox.isEnabled && encryptionCheckbox.state == .on ? passwordFields.settings : .init()
    }

    /// NSSavePanel には実際の先頭巻の名前を表示する。トランザクションにはその本体（.001 を除いた名前）を渡す。
    func baseDestination(_ url: URL) -> URL {
        splitControls?.isSplitting == true && url.pathExtension == Self.firstVolumeExtension ? url.deletingPathExtension() : url
    }

    private func refreshSplitContentType() {
        panel.allowedContentTypes = splitControls?.isSplitting == true ? [] : ArchiveSavePanelController.panelContentTypes
        panel.currentContentType = splitControls?.isSplitting == true ? nil : controller.allowedContentTypes.first
    }

    private func changeSplitChoice() {
        let entered = panel.nameFieldStringValue
        let base = Self.strippingFirstVolumeSuffix(entered)
        let name = splitControls?.isSplitting == true ? Self.appendingFirstVolumeSuffix(base) : base
        refreshSplitContentType()
        guard name != entered else { return }
        if panel.isVisible, completionHandler != nil {
            pendingFilenameChange = FilenameChange(name: name, directory: panel.directoryURL, tags: panel.tagNames,
                frame: panel.frame, accessoryHeight: (panel.accessoryView as? ArchiveSaveAccessoryView)?.contentSize.height ?? 0)
            resizeAnimation?.stop(); resizeAnimation = nil; layoutGeneration += 1
            panel.animationBehavior = .none
            panel.cancel(nil)
        } else {
            configuredFilename = name
            panel.nameFieldStringValue = name
        }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        let schedule = try splitControls?.schedule()
        let url = baseDestination(url)
        guard controller.acceptedExtensions.contains(where: { url.lastPathComponent.lowercased().hasSuffix("." + $0.lowercased()) }) else {
            let list = controller.acceptedExtensions.map { "." + $0 }.joined(separator: ", ")
            throw ArchiveUserError.creation(String(localized: "この形式のファイル名は次の拡張子で終わる必要があります: \(list)", bundle: bundle))
        }
        if let schedule {
            let scheme = KaitoKit.ArchiveVolumeSet.Scheme.numbered(stem: url.lastPathComponent, width: 3)
            let plan = try VolumePlan(totalLength: estimatedSplitLength, schedule: schedule, scheme: scheme)
            let parent = try VolumePublishDirectory(VolumePublishFS.canonicalParent(of: url))
            do { try VolumeSetPublication.checkOccupancy(plan: plan, oldCount: 0, parent: parent) }
            catch VolumePublishError.nameOccupied {
                throw ArchiveUserError.creation(String(localized: "同じ名前の分割ファイルが既にあります。", bundle: bundle), code: 2)
            }
        }
        if encryptionCheckbox.isEnabled && encryptionCheckbox.state == .on {
            passwordFields.notice.stringValue = passwordFields.validationMessage ?? ""
            try passwordFields.validate()
        }
    }

    @objc func changeEncryption(_ sender: NSButton) {
        refreshEncryption(focusPassword: true)
    }

    @objc private func panelDidResize(_ notification: Notification) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            panel.accessoryView?.needsLayout = true
            panel.accessoryView?.layoutSubtreeIfNeeded()
        }
    }

    @objc private func panelWillStartLiveResize(_ notification: Notification) {
        prepareForNativeResize()
    }

    func panel(_ sender: Any, willExpand expanding: Bool) {
        prepareForNativeResize()
    }

    private func prepareForNativeResize() {
        // 一覧の開閉やユーザーのリサイズでは、アクセサリ以外の高さも変わる。
        // 進行中の切り替えを確定し、次の切り替えで基準の高さを測り直す。
        if resizeAnimation != nil { refreshEncryption(animateResize: false) }
        (panel.accessoryView as? ArchiveSaveAccessoryView)?.viewportHeightInPanel = nil
        panel.accessoryView?.needsLayout = true
        panel.accessoryView?.layoutSubtreeIfNeeded()
    }

    private func refreshPasswordNotice() {
        guard encryptionCheckbox.isEnabled, encryptionCheckbox.state == .on else {
            passwordFields.notice.stringValue = ""
            return
        }
        let hasInput = !passwordFields.passwordField.stringValue.isEmpty || !passwordFields.verifyField.stringValue.isEmpty
        passwordFields.notice.stringValue = hasInput ? passwordFields.validationMessage ?? "" : ""
    }

    private func refreshEncryption(focusPassword: Bool = false, animateResize: Bool = true) {
        // 現在の高さから再開し、古い更新で表示とフォーカスを変更しない。
        layoutGeneration += 1
        let generation = layoutGeneration
        resizeAnimation?.stop()
        resizeAnimation = nil
        if let accessory = panel.accessoryView as? ArchiveSaveAccessoryView {
            accessory.viewportHeight = accessory.frame.height
        }
        let wasVisible = !passwordFields.view.isHidden
        encryptionCheckbox.isEnabled = controller.singleStreamFormat == nil && ArchiveEncryptionSettings.supports(controller.format)
        passwordFields.selectFormat(controller.format)
        let enablesFields = encryptionCheckbox.isEnabled && encryptionCheckbox.state == .on
        if !enablesFields, let window = passwordFields.view.window, let responder = window.firstResponder {
            let editsPassword = [passwordFields.passwordField, passwordFields.verifyField].contains { $0.currentEditor() === responder }
            if editsPassword || (responder as? NSView)?.isDescendant(of: passwordFields.view) == true {
                let next = encryptionCheckbox.isEnabled ? encryptionCheckbox as NSView : formatPopup
                if !window.makeFirstResponder(next) { window.makeFirstResponder(nil) }
            }
        }
        passwordFields.setEnabled(enablesFields)
        passwordFields.view.isHidden = !enablesFields
        encryptionNote.isHidden = encryptionCheckbox.isEnabled
        refreshPasswordNotice()
        guard let accessory = panel.accessoryView as? ArchiveSaveAccessoryView else {
            passwordFields.view.alphaValue = enablesFields ? 1 : 0
            return
        }
        if panel.isVisible, accessory.viewportHeightInPanel == nil {
            let chromeHeight = panel.frame.height - accessory.frame.height
            accessory.viewportHeightInPanel = { [weak panel] in (panel?.frame.height ?? chromeHeight) - chromeHeight }
        }
        var size = accessory.contentSize
        if accessory.window != nil { size.width = max(size.width, accessory.frame.width) }
        let initialHeight = accessory.frame.height
        let initialPanelFrame = panel.frame
        let screenFrame = panel.screen?.visibleFrame
        let expandedHeight = initialPanelFrame.height + size.height - initialHeight
        let fitsScreen = screenFrame.map {
            expandedHeight <= $0.height && initialPanelFrame.maxY - expandedHeight >= $0.minY
        } ?? true
        // 画面の下端付近では XPC シートが setFrame の原点を維持しないことがある。
        // 現在の上端から収まらない場合も、一覧の領域調整を標準パネルに任せる。
        if !fitsScreen { accessory.viewportHeightInPanel = nil }
        let animate = animateResize && panel.isVisible && !reducesMotion() && fitsScreen && abs(initialHeight - size.height) > 0.5
        let panelChromeHeight = initialPanelFrame.height - (accessory.viewportHeightInPanel?() ?? initialHeight)
        let sizesExpandedPanel = panel.isVisible && panel.isExpanded && fitsScreen
        // 中央から伸縮するシートでは、奇数ポイントの増減で原点が丸め直される。
        // 増分を偶数にして、中央が 1 ピクセルずつ往復するのを防ぐ。
        let heightStep: CGFloat = panel.sheetParent == nil ? 1 : 2
        let initialAlpha = passwordFields.view.alphaValue
        let focusOrigin = passwordFields.view.window?.firstResponder
        // 畳む途中は元の高さの内容をクリップし、フェードが終わってから取り除く。
        if animate && wasVisible { passwordFields.view.isHidden = false }
        accessory.needsLayout = true
        accessory.layoutSubtreeIfNeeded()
        let update: @MainActor (CGFloat) -> Void = { [weak self, weak accessory] progress in
            guard let self, let accessory, self.layoutGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                // 途中の寸法を整数ポイントに揃え、保存パネル側の丸め直しを抑える。
                var height = progress >= 1 ? size.height
                    : initialHeight + ((size.height - initialHeight) * progress / heightStep).rounded() * heightStep
                if animate {
                    // XPC 側の表示領域より何フレームも先へ要求を進めない。
                    // 先行分を上余白より小さく保ち、ホストの古いクリップが行へ届くのを防ぐ。
                    let hostHeight = accessory.superview?.bounds.height ?? accessory.bounds.height
                    let visibleHeight = accessory.viewportHeightInPanel?() ?? hostHeight
                    let growing = size.height > initialHeight
                    let acknowledgedHeight = growing ? min(hostHeight, visibleHeight) : max(hostHeight, visibleHeight)
                    let step = ((acknowledgedHeight - initialHeight) / heightStep).rounded(.towardZero) * heightStep + initialHeight
                    height = growing ? min(height, step + 8) : max(height, step - 8)
                    height = min(max(height, min(initialHeight, size.height)), max(initialHeight, size.height))
                }
                accessory.viewportHeight = height
                if sizesExpandedPanel {
                    // 一覧を開いた保存パネルは、アクセサリを畳むと一覧を広げる。
                    // 一覧の高さを保ち、パネル自体を必要な高さへ戻す。
                    let panelHeight = panelChromeHeight + height
                    let anchoredY = self.panel.sheetParent == nil ? initialPanelFrame.maxY - panelHeight : initialPanelFrame.midY - panelHeight / 2
                    let y = screenFrame.map { min(max(anchoredY, $0.minY), $0.maxY - panelHeight) } ?? anchoredY
                    self.panel.setFrame(NSRect(x: initialPanelFrame.minX, y: y, width: initialPanelFrame.width, height: panelHeight), display: false)
                }
                // 一覧付きパネルは先に表示領域を更新する。アクセサリを先に広げると、
                // シートのホストが古い範囲で描画し、先頭行が一瞬欠ける。
                accessory.setFrameSize(NSSize(width: size.width, height: height))
                let visibleProgress = animate ? min(1, max(0, (height - initialHeight) / (size.height - initialHeight))) : progress
                self.passwordFields.view.alphaValue = initialAlpha + ((enablesFields ? 1 : 0) - initialAlpha) * visibleProgress
                accessory.layoutSubtreeIfNeeded()
            }
            if progress >= 1 && abs(accessory.frame.height - size.height) < 0.5 {
                self.resizeAnimation?.stop()
                self.resizeAnimation = nil
                self.passwordFields.view.isHidden = !enablesFields
                accessory.viewportHeight = nil
                accessory.needsLayout = true
                accessory.layoutSubtreeIfNeeded()
                self.panel.recalculateKeyViewLoop()
                if focusPassword && enablesFields && self.panel.isVisible {
                    let focus = { @MainActor [weak self] in
                        guard let self, self.layoutGeneration == generation, self.panel.isVisible,
                              self.passwordFields.verifyField.currentEditor() == nil,
                              let window = self.passwordFields.passwordField.window,
                              window.firstResponder === focusOrigin || window.firstResponder === self.encryptionCheckbox
                                || window.firstResponder === window else { return }
                        window.makeFirstResponder(self.passwordFields.passwordField)
                    }
                    focus()
                    // 動きを減らす場合は、XPC ホストの更新より先にここへ到達する。
                    // 次の main queue でも引き渡し、ホストが一度戻したフォーカスを復元する。
                    // 別の入力欄を選んだ場合やキャンセル・再切り替え後は上の guard で触らない。
                    DispatchQueue.main.async(execute: focus)
                }
            }
        }
        if animate {
            let animation = ArchiveSaveResizeAnimation(update: update)
            resizeAnimation = animation
            animation.start(on: panel.contentView ?? accessory)
        } else {
            update(1)
        }
        panel.recalculateKeyViewLoop()
    }

    private func refreshLevel() {
        levelPopup.removeAllItems()
        methodPopup.removeAllItems()
        methodPopup.addItems(withTitles: controller.methods.map(\.rawValue))
        methodPopup.selectItem(at: controller.selectedMethodIndex)
        methodPopup.isHidden = controller.methods.isEmpty
        (methodPopup.superview as? NSGridView)?.row(at: 1).isHidden = methodPopup.isHidden
        compatibilityNote.isHidden = !controller.showsZipCompatibilityNote
        levelPopup.addItems(withTitles: controller.levels.map { $0.title(bundle: bundle, startsAtZero: controller.startsAtZero) })
        levelPopup.selectItem(at: controller.selectedLevelIndex)
        levelPopup.isEnabled = controller.isLevelEnabled
        fixedLevelNote.isHidden = controller.isLevelEnabled
    }

    @objc func changeLevel(_ sender: NSPopUpButton) {
        controller.selectLevel(at: sender.indexOfSelectedItem)
        refreshLevel()
        refreshEncryption()
    }

    @objc func changeMethod(_ sender: NSPopUpButton) {
        controller.selectMethod(at: sender.indexOfSelectedItem)
        refreshLevel()
        refreshEncryption()
    }

    func panel(_ sender: Any, userEnteredFilename filename: String, confirmed okFlag: Bool) -> String? {
        if splitControls?.isSplitting == true {
            return Self.hasFirstVolumeSuffix(filename) ? filename : Self.appendingFirstVolumeSuffix(filename)
        }
        // foo.zip を ZIP に入れる場合、foo.zip.zip の末尾を隠した名前は foo.zip。
        // 未編集の候補だけを補正し、元の書庫名が再び拡張子として消えるのを防ぐ。
        if okFlag, panel.isExtensionHidden, panel.nameFieldStringValue == configuredFilename,
           filename == suggestedStem {
            return suggestedStem + "." + controller.filenameExtension
        }
        // LaunchServices は拡張子を小文字にするため、隠された拡張子だけ正規の表記に戻す。
        let suffix = "." + controller.filenameExtension
        if okFlag, panel.isExtensionHidden, !filename.hasSuffix(suffix),
           let range = filename.range(of: suffix, options: [.caseInsensitive, .backwards, .anchored]),
           let directory = panel.directoryURL {
            let corrected = filename.replacingCharacters(in: range, with: suffix)
            let canonicalURL = directory.appendingPathComponent(corrected)
            let originalURL = directory.appendingPathComponent(filename)
            // 大小文字を区別する保存先では、未確認の別ファイルを上書きしない。
            do {
                if let canonicalID = try canonicalURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
                   let originalID = try? originalURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
                   canonicalID.isEqual(originalID) {
                    return corrected
                }
            } catch {
                if (error as? CocoaError)?.code == .fileReadNoSuchFile { return corrected }
            }
        }
        return filename
    }

    @objc func changeFormat(_ sender: NSPopUpButton) {
        guard !isReconfiguring, sender.selectedItem?.isEnabled == true else { return }
        let previousExtension = controller.filenameExtension
        let changesFormat = sender.indexOfSelectedItem != controller.selectedIndex
        // 名前を明示した後は、末尾一つだけを置換する標準パネルに任せると .tar が残る。
        // 表示後の nameFieldStringValue は変更できないため、同じパネルを再構成する。
        // 確定URLの後処理は行わず、画面と標準の上書き確認も正しい名前に揃える。
        let enteredName = changesFormat && panel.isVisible && (!panel.isExtensionHidden || splitControls?.isSplitting == true) && completionHandler != nil
            ? panel.nameFieldStringValue : nil
        controller.selectFormat(at: sender.indexOfSelectedItem)
        guard changesFormat else {
            refreshLevel()
            refreshEncryption()
            return
        }
        if let enteredName {
            let isSplitting = splitControls?.isSplitting == true
            let renamed = controller.filenameByChangingFormat(
                isSplitting ? Self.strippingFirstVolumeSuffix(enteredName) : enteredName, previousExtension: previousExtension)
            pendingFilenameChange = FilenameChange(
                name: isSplitting ? Self.appendingFirstVolumeSuffix(renamed) : renamed,
                directory: panel.directoryURL, tags: panel.tagNames, frame: panel.frame,
                accessoryHeight: (panel.accessoryView as? ArchiveSaveAccessoryView)?.contentSize.height ?? 0)
            resizeAnimation?.stop()
            resizeAnimation = nil
            layoutGeneration += 1
            formatPopup.isEnabled = false
            panel.animationBehavior = .none
            panel.cancel(nil)
            return
        }
        if splitControls?.isSplitting == true {
            let base = Self.strippingFirstVolumeSuffix(panel.nameFieldStringValue)
            configuredFilename = Self.appendingFirstVolumeSuffix(
                controller.filenameByChangingFormat(base, previousExtension: previousExtension))
            panel.nameFieldStringValue = configuredFilename
        }
        if !panel.isVisible, splitControls?.isSplitting != true {
            let entered = panel.nameFieldStringValue
            if entered == configuredFilename, panel.isExtensionHidden {
                configuredFilename = suggestedStem + "." + controller.filenameExtension.split(separator: ".").last!
            } else {
                configuredFilename = controller.filenameByChangingFormat(entered, previousExtension: previousExtension)
                suggestedStem = controller.filenameStem(configuredFilename)
            }
            panel.nameFieldStringValue = configuredFilename
        }
        refreshSplitContentType()
        refreshLevel()
        refreshEncryption()
    }

    func begin(on parent: NSWindow? = nil, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        precondition(self.completionHandler == nil)
        self.completionHandler = completionHandler
        parentWindow = parent
        initialAnimationBehavior = panel.animationBehavior
        if let parent {
            parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: parent, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.cancel() }
                }
        }
        presentPanel()
    }

    private func presentPanel() {
        let completed: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, self.completionHandler != nil else { return }
            if response == .cancel, self.pendingFilenameChange != nil {
                // 終了コールバックを抜け、configuration phase に戻ってから設定する。
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.completionHandler != nil, let change = self.pendingFilenameChange else { return }
                    self.applyPendingFilenameChange(change)
                }
            } else {
                self.finishPresentation(response)
            }
        }
        #if DEBUG
        if let presentationHandlerForTesting { presentationHandlerForTesting(completed); return }
        #endif
        if let parentWindow { panel.beginSheetModal(for: parentWindow, completionHandler: completed) }
        else { panel.begin(completionHandler: completed) }
    }

    /// 閉じたパネルへ新しい名前と形式を設定し直し、同じ位置と高さで再表示する。
    private func applyPendingFilenameChange(_ change: FilenameChange) {
        let accessory = panel.accessoryView as? ArchiveSaveAccessoryView
        panel.accessoryView = nil
        panel.directoryURL = change.directory
        panel.tagNames = change.tags
        suggestedStem = controller.filenameStem(change.name)
        if splitControls?.isSplitting == true { refreshSplitContentType() }
        else { panel.currentContentType = controller.explicitFilenameContentType }
        panel.nameFieldStringValue = change.name
        panel.isExtensionHidden = false
        configuredFilename = change.name
        refreshLevel()
        refreshEncryption(animateResize: false)
        accessory?.viewportHeight = nil
        accessory?.viewportHeightInPanel = nil
        if let accessory { ArchiveAccessoryLayout.size(accessory) }
        panel.accessoryView = accessory
        pendingFilenameChange = nil
        formatPopup.isEnabled = true
        presentPanel()
        if let accessory {
            let height = max(panel.minSize.height,
                             change.frame.height + accessory.contentSize.height - change.accessoryHeight)
            let anchoredY = parentWindow == nil ? change.frame.maxY - height : change.frame.midY - height / 2
            let y = panel.screen.map {
                min(max(anchoredY, $0.visibleFrame.minY), $0.visibleFrame.maxY - height)
            } ?? anchoredY
            panel.setFrame(NSRect(x: change.frame.minX, y: y, width: change.frame.width, height: height), display: false)
        }
    }

    private func finishPresentation(_ response: NSApplication.ModalResponse) {
        let completed = completionHandler
        completionHandler = nil
        pendingFilenameChange = nil
        parentWindow = nil
        formatPopup.isEnabled = true
        panel.animationBehavior = initialAnimationBehavior
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        parentCloseObserver = nil
        completed?(response)
    }

    func cancel() {
        if isReconfiguring { finishPresentation(.cancel) }
        panel.cancel(nil)
    }

    func destination(on parent: NSWindow?) async throws -> URL? {
        try Task.checkCancellation()
        defer {
            resizeAnimation?.stop()
            resizeAnimation = nil
            (panel.accessoryView as? ArchiveSaveAccessoryView)?.viewportHeightInPanel = nil
        }
        let response: NSApplication.ModalResponse = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .cancel); return }
                begin(on: parent) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        try Task.checkCancellation()
        return response == .OK ? panel.url : nil
    }
}
