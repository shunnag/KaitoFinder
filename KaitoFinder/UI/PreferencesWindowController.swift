import AppKit
import GyoshukuKit

private func joinedSentences(_ first: String, _ second: String) -> String {
    let separator = first.hasSuffix("。") || first.hasSuffix("！") || first.hasSuffix("？") ? "" : " "
    return first + separator + second
}

/// 画面を出さずに、各コントロールの選択と即時保存を検証できる。
final class PreferencesViewModel {
    enum CompressionTab: String, CaseIterable {
        case zip, sevenZip, tar, lha

        var title: String {
            switch self {
            case .zip: "ZIP"
            case .sevenZip: "7z"
            case .tar: "tar"
            case .lha: "LHA"
            }
        }
    }

    static let zipMethods: [ArchivePreferences.ZipMethod] = [.deflate, .stored, .bzip2, .lzma, .xz, .zstd, .ppmd]
    static let extractionDestinations: [ArchivePreferences.ExtractionDestination] = [.sameFolder, .ask]
    static let folderPolicies: [ArchivePreferences.FolderPolicy] = [.always, .whenMultipleTopLevelItems, .never]
    static let saveBehaviors = ArchivePreferences.SaveBehavior.allCases
    static let additionPositions = ArchivePreferences.AdditionPosition.allCases
    static let tarCarriedOwnerPolicies = ArchivePreferences.CarriedOwnerIDPolicy.allCases
    static let openingBehaviors = ArchivePreferences.OpeningBehavior.allCases
    static let folderOpenings = ArchivePreferences.FolderOpening.allCases
    static let powerPolicies = ArchivePreferences.PowerPolicy.allCases
    private let store: ArchivePreferencesStore
    let hardware: ArchiveHardware
    private let bundle: Bundle

    init(store: ArchivePreferencesStore = .shared, hardware: ArchiveHardware = .current, bundle: Bundle = .main) {
        self.store = store
        self.hardware = hardware
        self.bundle = bundle
    }

    var preferences: ArchivePreferences { store.preferences }
    var compressionThreadChoices: [Int] {
        Array(0...min(ArchivePreferences.compressionThreadRange.upperBound,
                      max(1, hardware.processors, preferences.compressionThreads)))
    }
    var compressionThreadIndex: Int { compressionThreadChoices.firstIndex(of: preferences.compressionThreads)! }
    var compressionThreadTitles: [String] {
        compressionThreadChoices.map {
            $0 == 0 ? String(format: String(localized: "自動（%lld）", bundle: bundle),
                             hardware.automaticCompressionThreads(powerPolicy: preferences.powerPolicy.writerPolicy)) : String($0)
        }
    }
    var memoryNote: (text: String, warns: Bool) {
        let threads = preferences.compressionThreads == 0
            ? hardware.automaticCompressionThreads(powerPolicy: preferences.powerPolicy.writerPolicy) : preferences.compressionThreads
        let warns = ArchiveHardware.estimatedLZMA2Memory(threads: threads) > hardware.memory / 4
        return (memoryNote(threads: threads, warns: warns), warns)
    }
    var maximumMemoryNote: String {
        memoryNote(threads: compressionThreadChoices.last!, warns: true)
    }

    private func memoryNote(threads: Int, warns: Bool) -> String {
        let memory = ByteCountFormatter.string(fromByteCount: Int64(ArchiveHardware.estimatedLZMA2Memory(threads: threads)),
                                               countStyle: .memory)
        let estimate = String(format: String(localized: "7z・tar.xz の圧縮では、最大で約 %@ のメモリを使います。", bundle: bundle), memory)
        return warns ? joinedSentences(estimate, String(localized: "物理メモリに対して大きいため、ほかの処理が遅くなることがあります。", bundle: bundle)) : estimate
    }

    func selectCompressionThreads(at index: Int) {
        let choices = compressionThreadChoices
        guard choices.indices.contains(index) else { return }
        store.preferences.compressionThreads = choices[index]
    }

    var powerPolicyIndex: Int { Self.powerPolicies.firstIndex(of: preferences.powerPolicy)! }
    var powerPolicyTitles: [String] { Self.powerPolicies.map { $0.title(bundle: bundle) } }

    func selectPowerPolicy(at index: Int) {
        guard Self.powerPolicies.indices.contains(index) else { return }
        store.preferences.powerPolicy = Self.powerPolicies[index]
    }

    func changePrefersSpeed(to enabled: Bool) { store.preferences.prefersSpeed = enabled }

    var defaultFormatIndex: Int { ArchivePreferences.formats.firstIndex(of: preferences.defaultFormat)! }
    var saveBehaviorIndex: Int { Self.saveBehaviors.firstIndex(of: preferences.saveBehavior)! }
    var openingBehaviorIndex: Int { Self.openingBehaviors.firstIndex(of: preferences.openingBehavior)! }
    var folderOpeningIndex: Int { Self.folderOpenings.firstIndex(of: preferences.folderOpening)! }
    var additionPositionIndex: Int { Self.additionPositions.firstIndex(of: preferences.additionPosition)! }
    var tarCarriedOwnerIDsIndex: Int { Self.tarCarriedOwnerPolicies.firstIndex(of: preferences.tarCarriedOwnerIDs)! }
    var zipMethodIndex: Int { Self.zipMethods.firstIndex(of: preferences.zipMethod)! }
    var extractionDestinationIndex: Int { Self.extractionDestinations.firstIndex(of: preferences.extractionDestination)! }
    var afterExpansionIndex: Int { preferences.trashesArchiveAfterExtraction ? 1 : 0 }
    var folderPolicyIndex: Int { Self.folderPolicies.firstIndex(of: preferences.folderPolicy)! }
    var zipUsesLZMA: Bool { preferences.zipMethod == .lzma || preferences.zipMethod == .xz }
    var zipLevel: Int {
        switch preferences.zipMethod {
        case .lzma, .xz: preferences.zipLZMALevel
        case .zstd: preferences.zipZstdLevel
        case .ppmd: preferences.zipPPMdLevel
        default: preferences.zipLevel
        }
    }
    var zipLevelLabel: String { String(zipLevel) }
    static let additionalFormats: [GyoshukuKit.ArchiveFormat] = [.tarXZ, .tarZstd, .tarLzip, .tarLZMA, .sevenZip, .lha]

    func compressionController(for format: GyoshukuKit.ArchiveFormat) -> ArchiveSavePanelController {
        let controller = ArchiveSavePanelController(store: store)
        controller.selectFormat(at: ArchivePreferences.formats.firstIndex(of: format)!, persistsDefault: false)
        return controller
    }

    var initialCompressionTabIndex: Int {
        switch preferences.defaultFormat {
        case .zip: 0
        case .sevenZip: 1
        case .lha: 3
        default: 2
        }
    }
    // 一つの形式だけをコピーし、通知も一度の保存にまとめる。
    func resetCompressionDefaults(for tab: CompressionTab) {
        var value = preferences
        applyCompressionDefaults(to: &value, for: tab)
        store.preferences = value
    }

    func compressionDefaultsAreCurrent(for tab: CompressionTab) -> Bool {
        var value = preferences
        applyCompressionDefaults(to: &value, for: tab)
        return value == preferences
    }

    private func applyCompressionDefaults(to value: inout ArchivePreferences, for tab: CompressionTab) {
        let defaults = ArchivePreferences()
        switch tab {
        case .zip:
            value.zipMethod = defaults.zipMethod
            value.zipLevel = defaults.zipLevel
            value.zipLZMALevel = defaults.zipLZMALevel
            value.zipZstdLevel = defaults.zipZstdLevel
            value.zipPPMdLevel = defaults.zipPPMdLevel
            value.zipSkipsCompressedTypes = defaults.zipSkipsCompressedTypes
        case .sevenZip:
            value.sevenZipMethod = defaults.sevenZipMethod
            value.sevenZipLevel = defaults.sevenZipLevel
            value.sevenZipPPMdLevel = defaults.sevenZipPPMdLevel
            value.sevenZipSolid = defaults.sevenZipSolid
            value.sevenZipFilter = defaults.sevenZipFilter
        case .tar:
            value.tarGzipLevel = defaults.tarGzipLevel
            value.tarBzip2Level = defaults.tarBzip2Level
            value.tarXZLevel = defaults.tarXZLevel
            value.tarZstdLevel = defaults.tarZstdLevel
            value.tarLzipLevel = defaults.tarLzipLevel
            value.tarLZMALevel = defaults.tarLZMALevel
            value.tarPreservesOwnerIDs = defaults.tarPreservesOwnerIDs
            value.tarCarriedOwnerIDs = defaults.tarCarriedOwnerIDs
        case .lha:
            value.lhaMethod = defaults.lhaMethod
            value.lhaLevel = defaults.lhaLevel
        }
    }

    var sevenZipMethodIndex: Int { compressionController(for: .sevenZip).selectedMethodIndex }
    var sevenZipLevelIndex: Int { compressionController(for: .sevenZip).selectedLevelIndex }
    var lhaMethodIndex: Int { compressionController(for: .lha).selectedMethodIndex }
    var lhaLevelIndex: Int { compressionController(for: .lha).selectedLevelIndex }
    var tarXZLevelIndex: Int { compressionController(for: .tarXZ).selectedLevelIndex }
    var tarZstdLevelIndex: Int { compressionController(for: .tarZstd).selectedLevelIndex }
    var tarLzipLevelIndex: Int { compressionController(for: .tarLzip).selectedLevelIndex }
    var tarLZMALevelIndex: Int { compressionController(for: .tarLZMA).selectedLevelIndex }

    func selectSevenZipMethod(at index: Int) { selectCompressionMethod(at: index, for: .sevenZip) }
    func selectSevenZipLevel(at index: Int) { selectCompressionLevel(at: index, for: .sevenZip) }
    func selectLHAMethod(at index: Int) { selectCompressionMethod(at: index, for: .lha) }
    func selectLHALevel(at index: Int) { selectCompressionLevel(at: index, for: .lha) }
    func selectTarXZLevel(at index: Int) { selectCompressionLevel(at: index, for: .tarXZ) }
    func selectTarZstdLevel(at index: Int) { selectCompressionLevel(at: index, for: .tarZstd) }
    func selectTarLzipLevel(at index: Int) { selectCompressionLevel(at: index, for: .tarLzip) }
    func selectTarLZMALevel(at index: Int) { selectCompressionLevel(at: index, for: .tarLZMA) }
    func changeSevenZipSolid(to enabled: Bool) { store.preferences.sevenZipSolid = enabled }
    func selectSevenZipFilter(at index: Int) {
        let filters = ArchivePreferences.SevenZipFilter.allCases
        guard filters.indices.contains(index) else { return }
        store.preferences.sevenZipFilter = filters[index]
    }

    private func selectCompressionMethod(at index: Int, for format: GyoshukuKit.ArchiveFormat) {
        let controller = compressionController(for: format)
        guard controller.methods.indices.contains(index) else { return }
        controller.selectMethod(at: index)
        changeCompressionDefault(controller)
    }

    private func selectCompressionLevel(at index: Int, for format: GyoshukuKit.ArchiveFormat) {
        let controller = compressionController(for: format)
        guard controller.levels.indices.contains(index) else { return }
        controller.selectLevel(at: index)
        changeCompressionDefault(controller)
    }

    func changeCompressionDefault(_ controller: ArchiveSavePanelController) {
        var value = store.preferences
        switch controller.format {
        case .tarZstd: value.tarZstdLevel = controller.level.rawValue
        case .tarXZ: value.tarXZLevel = controller.level.rawValue
        case .tarLzip: value.tarLzipLevel = controller.level.rawValue
        case .tarLZMA: value.tarLZMALevel = controller.level.rawValue
        case .sevenZip:
            value.sevenZipMethod = switch controller.method {
            case .lzma: .lzma
            case .deflate: .deflate
            case .bzip2: .bzip2
            case .ppmd: .ppmd
            default: .lzma2
            }
            if controller.method == .ppmd && controller.level != .none {
                value.sevenZipPPMdLevel = controller.level.rawValue
                if value.sevenZipLevel == -1 { value.sevenZipLevel = 6 }
            } else { value.sevenZipLevel = controller.level.rawValue }
            value.sevenZipSolid = controller.sevenZipSolid
            value.sevenZipFilter = controller.sevenZipFilter
        case .lha:
            value.lhaMethod = controller.method == .lh6 ? .lh6 : controller.method == .lh7 ? .lh7 : .lh5
            value.lhaLevel = controller.level.rawValue
        default: return
        }
        store.preferences = value
    }
    var tarGzipLevelLabel: String { String(preferences.tarGzipLevel) }
    var tarBzip2LevelLabel: String { String(preferences.tarBzip2Level) }

    func selectDefaultFormat(at index: Int) {
        guard ArchivePreferences.formats.indices.contains(index) else { return }
        store.preferences.defaultFormat = ArchivePreferences.formats[index]
    }

    func selectSaveBehavior(at index: Int) {
        guard Self.saveBehaviors.indices.contains(index) else { return }
        store.preferences.saveBehavior = Self.saveBehaviors[index]
    }

    func selectOpeningBehavior(at index: Int) {
        guard Self.openingBehaviors.indices.contains(index) else { return }
        store.preferences.openingBehavior = Self.openingBehaviors[index]
    }

    func selectFolderOpening(at index: Int) {
        guard Self.folderOpenings.indices.contains(index) else { return }
        store.preferences.folderOpening = Self.folderOpenings[index]
    }

    func selectZipMethod(at index: Int) {
        guard Self.zipMethods.indices.contains(index) else { return }
        store.preferences.zipMethod = Self.zipMethods[index]
    }

    func changeAdditionPosition(to value: ArchivePreferences.AdditionPosition) { store.preferences.additionPosition = value }
    func changeTarCarriedOwnerIDs(to value: ArchivePreferences.CarriedOwnerIDPolicy) { store.preferences.tarCarriedOwnerIDs = value }

    func changeZipLevel(to level: Int) {
        if preferences.zipMethod == .zstd { store.preferences.zipZstdLevel = ArchivePreferences.validLevel(level, range: 1...19, fallback: 3) }
        else if preferences.zipMethod == .ppmd { store.preferences.zipPPMdLevel = ArchivePreferences.validLevel(level, range: 1...9, fallback: 6) }
        else if zipUsesLZMA { store.preferences.zipLZMALevel = min(9, max(0, level)) }
        else { store.preferences.zipLevel = ArchivePreferences.clampedLevel(level) }
    }
    func changeZipSkipsCompressedTypes(to enabled: Bool) { store.preferences.zipSkipsCompressedTypes = enabled }
    func changeTarGzipLevel(to level: Int) { store.preferences.tarGzipLevel = ArchivePreferences.clampedLevel(level) }
    func changeTarBzip2Level(to level: Int) { store.preferences.tarBzip2Level = ArchivePreferences.clampedLevel(level) }
    func changeTarPreservesOwnerIDs(to enabled: Bool) { store.preferences.tarPreservesOwnerIDs = enabled }
    func changeKeepsFoldersOnTop(to enabled: Bool) { store.preferences.keepsFoldersOnTop = enabled }
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

private final class PreferencesScrollDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// legacyのスクロールバー分を外側の右余白で吸収し、本文の幅を変えない。
private final class PreferencesScrollView: NSScrollView {
    var documentTrailingConstraint: NSLayoutConstraint?

    override func tile() {
        super.tile()
        let width = hasVerticalScroller && scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        documentTrailingConstraint?.constant = -24 + width
    }
}

/// 設定の切り替えでは上辺と幅を保ち、内容に必要な高さだけを変える。
final class PreferencesTabViewController: NSTabViewController {
    private static let resizeDuration: CFTimeInterval = 0.22
    var animationsEnabled = true
    var drivesResizeWithTimer = true
    var targetContentSizes: [NSSize] = []
    var prepareSelectedPane: (() -> Void)?
    private(set) var targetWindowFrame: NSRect?
    private var resizeGeneration = 0
    private var resizeTimer: Timer?
    private var resizeStartFrame: NSRect?
    private var resizeStartTime: CFTimeInterval = 0
    private var pendingShrinkCommit: (generation: Int, apply: () -> Void)?
    private var fadingPanes: [NSView] = []

    var isResizing: Bool { resizeTimer != nil }

    var targetContentSize: NSSize? {
        targetContentSizes.indices.contains(selectedTabViewItemIndex)
            ? targetContentSizes[selectedTabViewItemIndex] : nil
    }

    var animatesSelection: Bool {
        animationsEnabled && view.window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        finishPendingResize()
        if let window = view.window {
            // AppKitの501の制約が、切り替え前のウインドウ寸法と一致するようにする。
            let content = window.contentRect(forFrameRect: window.frame).size
            if Self.isValidSize(content) {
                tabViewItem?.viewController?.preferredContentSize = content
                preferredContentSize = content
            }
        }
        super.tabView(tabView, willSelect: tabViewItem)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        prepareSelectedPane?()
        resizeToSelectedPane(fading: tabViewItem?.viewController?.view)
    }

    override func viewWillDisappear() {
        // closeだけでなくorderOutやビューの取り外しでも、タイマーを残さない。
        completePendingResize()
        super.viewWillDisappear()
    }

    // 非表示になる前なら、本文・ウインドウ・フェードを最後の選択へ確定できる。
    func completePendingResize(in window: NSWindow? = nil) {
        if resizeStartFrame != nil {
            _ = applyResizeProgress(1, generation: resizeGeneration, in: window)
        }
        finishPendingResize()
    }

    // 次の選択より先に、前の縮小で保留した本文寸法を確定する。
    func finishPendingResize() {
        resizeTimer?.invalidate()
        resizeTimer = nil
        resizeStartFrame = nil
        resizeStartTime = 0
        let pending = pendingShrinkCommit
        pendingShrinkCommit = nil
        if let pending, pending.generation == resizeGeneration {
            pending.apply()
        }
        finishPendingFades()
    }

    func applyCompressionLayout(shrinking: Bool, _ apply: @escaping () -> Void) {
        if shrinking && animatesSelection && selectedTabViewItemIndex == 1 {
            pendingShrinkCommit = (resizeGeneration + 1, apply)
        } else {
            apply()
        }
    }

    // 切り替えの開始時に、外部・内部のペインのフェードをすべて完了させる。
    func finishPendingFades() {
        for pane in fadingPanes {
            pane.layer?.removeAllAnimations()
            pane.alphaValue = 1
        }
        fadingPanes.removeAll()
    }

    // 目標は別に保管し、preferredContentSizeには各フレームの現在寸法だけを渡す。
    func resizeToSelectedPane(fading incoming: NSView? = nil) {
        resizeTimer?.invalidate()
        resizeTimer = nil
        finishPendingFades()
        guard let size = targetContentSize, Self.isValidSize(size), let window = view.window,
              Self.isValidFrame(window.frame),
              Self.isValidSize(window.contentRect(forFrameRect: window.frame).size) else {
            finishPendingResize()
            return
        }
        let sizeWithTitlebar = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - sizeWithTitlebar.height,
                           width: window.frame.width, height: sizeWithTitlebar.height)
        if let visible = window.screen?.visibleFrame, frame.height <= visible.height {
            // 画面下端で広げたときは、従来どおり画面内へ戻す。
            frame.origin.y = min(visible.maxY - frame.height, max(visible.minY, frame.minY))
        }
        guard Self.isValidFrame(frame) else { finishPendingResize(); return }
        resizeGeneration += 1
        let generation = resizeGeneration
        targetWindowFrame = frame
        resizeStartFrame = window.frame
        guard animatesSelection else {
            applyResizeProgress(1)
            return
        }
        if let incoming {
            incoming.wantsLayer = true
            incoming.alphaValue = 0
            fadingPanes.append(incoming)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.resizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                incoming.animator().alphaValue = 1
            }
        }
        guard drivesResizeWithTimer else { return }
        resizeStartTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let continues = MainActor.assumeIsolated {
                guard self.resizeGeneration == generation else {
                    // 古い世代のタイマーだけを止め、新しい選択の状態は触らない。
                    return false
                }
                let elapsed = max(0, CACurrentMediaTime() - self.resizeStartTime)
                let completed = elapsed >= Self.resizeDuration
                let fraction = min(1, elapsed / Self.resizeDuration)
                let progress: CGFloat = completed ? 1 : CGFloat(fraction * fraction * (3 - 2 * fraction))
                let applied = self.applyResizeProgress(progress, generation: generation)
                // windowが外れた場合も、期限を過ぎた場合も必ず終了する。
                if !applied || completed {
                    if self.resizeGeneration == generation { self.finishPendingResize() }
                    return false
                }
                return true
            }
            if !continues { timer.invalidate() }
        }
        resizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @discardableResult func applyResizeProgress(_ progress: CGFloat) -> Bool {
        let applied = applyResizeProgress(progress, generation: resizeGeneration)
        if !applied { finishPendingResize() }
        return applied
    }

    private func applyResizeProgress(_ progress: CGFloat, generation: Int, in window: NSWindow? = nil) -> Bool {
        guard generation == resizeGeneration, let start = resizeStartFrame,
              let target = targetWindowFrame, let window = window ?? view.window,
              tabViewItems.indices.contains(selectedTabViewItemIndex), progress.isFinite,
              Self.isValidFrame(start), Self.isValidFrame(target) else { return false }
        let p = min(1, max(0, progress))
        let height = (start.height + (target.height - start.height) * p).rounded()
        // 上辺のクランプが必要な場合だけ、補正量を各フレームに分配する。
        let top = start.maxY + (target.maxY - start.maxY) * p
        let frame = p == 1 ? target : NSRect(x: start.minX, y: top - height, width: target.width, height: height)
        let content = window.contentRect(forFrameRect: frame).size
        guard Self.isValidFrame(frame), Self.isValidSize(content) else { return false }
        tabViewItems[selectedTabViewItemIndex].viewController?.preferredContentSize = content
        preferredContentSize = content
        if p == 1 {
            finishPendingResize()
        }
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return true
    }

    private static func isValidSize(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func isValidFrame(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite && isValidSize(frame.size)
    }
}

final class PreferencesWindowController: NSWindowController, NSTabViewDelegate {
    nonisolated static let frameAutosaveName = "Preferences"

    let viewModel: PreferencesViewModel
    private let bundle: Bundle
    private let softwareUpdater: any SoftwareUpdating
    let tabController = PreferencesTabViewController()
    let defaultFormatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let saveBehaviorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let openingBehaviorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let folderOpeningPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let additionPositionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tarCarriedOwnerIDsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let compressionThreadsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let powerPolicyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let prefersSpeedCheckbox: NSButton
    let prefersSpeedNote: NSTextField
    let compressionMemoryNote = NSTextField(wrappingLabelWithString: "")
    // 最初のitem追加時もcontentRectが負にならない寸法を渡す。
    let compressionTabView = NSTabView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
    private(set) var compressionResetButtons: [PreferencesViewModel.CompressionTab: NSButton] = [:]
    private var compressionPaneHeights: [CGFloat] = []
    private var compressionTabHeight: NSLayoutConstraint?
    private var compressionBorderHeight: CGFloat = 0
    private var compressionStack: NSStackView?
    private var compressionScroll: NSScrollView?
    private var compressionDocumentHeight: NSLayoutConstraint?
    let sevenZipMethodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sevenZipLevelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let lhaMethodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let lhaLevelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tarXZLevelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tarZstdLevelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tarLzipLevelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let tarLZMALevelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let zipMethodDescription = NSTextField(wrappingLabelWithString: "")
    let sevenZipMethodDescription = NSTextField(wrappingLabelWithString: "")
    let lhaMethodDescription = NSTextField(wrappingLabelWithString: "")
    let sevenZipSolidCheckbox: NSButton
    let sevenZipFilterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sevenZipSolidNote = NSTextField(wrappingLabelWithString: "")
    private let zipCompatibilityNote = NSTextField(wrappingLabelWithString: "")
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
    let keepsFoldersOnTopCheckbox: NSButton
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
         softwareUpdater: any SoftwareUpdating = SoftwareUpdateController.shared, hardware: ArchiveHardware = .current) {
        self.bundle = bundle
        prefersSpeedCheckbox = NSButton(
            checkboxWithTitle: String(localized: "速さを優先する（圧縮率がわずかに下がります）", bundle: bundle), target: nil, action: nil)
        prefersSpeedNote = NSTextField(wrappingLabelWithString:
            String(localized: "コア数の多いMacで、対応する圧縮方式の処理を速めます。", bundle: bundle))
        sevenZipSolidCheckbox = NSButton(checkboxWithTitle: String(localized: "ソリッド圧縮", bundle: bundle), target: nil, action: nil)
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
        keepsFoldersOnTopCheckbox = NSButton(
            checkboxWithTitle: String(localized: "フォルダを常に先頭に表示", bundle: bundle), target: nil, action: nil)
        showsHiddenFilesCheckbox = NSButton(
            checkboxWithTitle: String(localized: "隠しファイルを表示", bundle: bundle), target: nil, action: nil)
        renamesOnClickCheckbox = NSButton(
            checkboxWithTitle: String(localized: "選択した名前をクリックして名称変更（Finderと同じ）", bundle: bundle), target: nil, action: nil)
        excludesDSStoreCheckbox = NSButton(
            checkboxWithTitle: String(localized: ".DS_Store を含めない", bundle: bundle), target: nil, action: nil)
        excludesHiddenFilesCheckbox = NSButton(
            checkboxWithTitle: String(localized: "隠しファイル（名前が . で始まる）を含めない", bundle: bundle), target: nil, action: nil)
        zipSkipsCompressedTypesCheckbox = NSButton(
            checkboxWithTitle: String(localized: "圧縮済みのファイル（zip・jpg・mp4など）は無圧縮で格納", bundle: bundle), target: nil, action: nil)
        tarPreservesOwnerIDsCheckbox = NSButton(
            checkboxWithTitle: String(localized: "追加するファイルの所有者ID（uid / gid）を保存", bundle: bundle), target: nil, action: nil)
        revealsExtractedItemsInFinderCheckbox = NSButton(
            checkboxWithTitle: String(localized: "展開した項目をFinderに表示", bundle: bundle), target: nil, action: nil)
        viewModel = PreferencesViewModel(store: store, hardware: hardware, bundle: bundle)
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
        tabController.transitionOptions = []
        tabController.canPropagateSelectedChildViewControllerTitle = false
        configureControls()
        compressionMemoryNote.stringValue = viewModel.maximumMemoryNote
        compressionMemoryNote.preferredMaxLayoutWidth = 360
        compressionMemoryNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        compressionMemoryNote.textColor = .secondaryLabelColor
        // 警告を含む最長の注記の高さを先に確保し、選択でタブの高さが変わらないようにする。
        let memoryNoteSize = compressionMemoryNote.sizeThatFits(NSSize(width: 360, height: CGFloat.greatestFiniteMagnitude))
        compressionMemoryNote.heightAnchor.constraint(greaterThanOrEqualToConstant: ceil(memoryNoteSize.height)).isActive = true
        let saveNote = NSTextField(wrappingLabelWithString: String(localized: "次に開くアーカイブから有効になります。", bundle: bundle))
        saveNote.preferredMaxLayoutWidth = 360
        saveNote.textColor = .secondaryLabelColor
        saveNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let additionNote = NSTextField(wrappingLabelWithString: String(localized: "ZIPでは常に末尾に追加します。", bundle: bundle))
        additionNote.preferredMaxLayoutWidth = 360
        additionNote.textColor = .secondaryLabelColor
        additionNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        addTab(title: String(localized: "一般", bundle: bundle), symbol: "gearshape", sections: [
            group(rows: [
                row(String(localized: "新規アーカイブのデフォルトフォーマット:", bundle: bundle), control: defaultFormatPopup),
                row(String(localized: "アーカイブを開くとき:", bundle: bundle), control: openingBehaviorPopup),
                row(String(localized: "変更の書き込み:", bundle: bundle), control: saveBehaviorPopup),
                row("", control: saveNote),
                row(String(localized: "追加した項目の位置:", bundle: bundle), control: additionPositionPopup),
                row("", control: additionNote)
            ]),
            group(rows: [
                checkboxRow(showsHiddenFilesCheckbox),
                checkboxRow(keepsFoldersOnTopCheckbox),
                checkboxRow(showsWelcomeWindowAtLaunchCheckbox),
                checkboxRow(renamesOnClickCheckbox),
                row(String(localized: "フォルダを開くとき:", bundle: bundle), control: folderOpeningPopup)
            ], spanningRows: [0, 1, 2, 3])
        ])
        sevenZipSolidNote.stringValue = String(localized: "ソリッドブロック内の項目を削除すると、そのブロックを再圧縮します", bundle: bundle)
        sevenZipSolidNote.preferredMaxLayoutWidth = 520
        sevenZipSolidNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sevenZipSolidNote.textColor = .secondaryLabelColor
        zipCompatibilityNote.stringValue = String(localized: "このZIPはmacOSのアーカイブユーティリティやunzipでは開けません", bundle: bundle)
        zipCompatibilityNote.textColor = .secondaryLabelColor
        zipCompatibilityNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        zipCompatibilityNote.preferredMaxLayoutWidth = 520
        prefersSpeedNote.preferredMaxLayoutWidth = 520
        prefersSpeedNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        prefersSpeedNote.textColor = .secondaryLabelColor
        reserveDescription(zipMethodDescription, texts: PreferencesViewModel.zipMethods.map { CompressionOptionHelp.zip($0, bundle: bundle) })
        reserveDescription(sevenZipMethodDescription, texts: viewModel.compressionController(for: .sevenZip).methods.map {
            CompressionOptionHelp.sevenZip($0, bundle: bundle)
        })
        reserveDescription(lhaMethodDescription, texts: viewModel.compressionController(for: .lha).methods.map {
            CompressionOptionHelp.lha($0, bundle: bundle)
        })
        let tarNote = secondaryNote(String(localized: "単体のファイル（.gz・.bz2・.xz・.zst・.lz・.lzma）にも同じレベルを使います。tar・tar.lz4・tar.br・tar.Zには設定がありません。", bundle: bundle))
        // 内部タブの形式名は、すべての言語で同じ表記を使う。
        let compressionTabs = configureCompressionTabs(panes: [
            ("zip", "ZIP", [group(rows: [
                row(String(localized: "圧縮方式:", bundle: bundle), control: zipMethodPopup),
                [zipMethodDescription, NSGridCell.emptyContentView],
                row(String(localized: "圧縮レベル:", bundle: bundle), control: levelControl(zipLevelSlider, label: zipLevelLabel)),
                checkboxRow(zipSkipsCompressedTypesCheckbox)
            ], spanningRows: [1, 3]), zipCompatibilityNote]),
            ("sevenZip", "7z", [group(rows: [
                row(String(localized: "圧縮方式:", bundle: bundle), control: sevenZipMethodPopup),
                [sevenZipMethodDescription, NSGridCell.emptyContentView],
                row(String(localized: "圧縮レベル:", bundle: bundle), control: sevenZipLevelPopup),
                checkboxRow(sevenZipSolidCheckbox),
                row(String(localized: "フィルタ:", bundle: bundle), control: sevenZipFilterPopup),
                [sevenZipSolidNote, NSGridCell.emptyContentView]
            ], spanningRows: [1, 3, 5])]),
            ("tar", "tar", [group(rows: [
                tarLevelRow(String(localized: "gzipレベル:", bundle: bundle), control: levelControl(tarGzipLevelSlider, label: tarGzipLevelLabel), format: .tarGzip),
                tarLevelRow(String(localized: "bzip2レベル:", bundle: bundle), control: levelControl(tarBzip2LevelSlider, label: tarBzip2LevelLabel), format: .tarBzip2),
                tarLevelRow(String(localized: "xzレベル:", bundle: bundle), control: tarXZLevelPopup, format: .tarXZ),
                tarLevelRow(String(localized: "zstdレベル:", bundle: bundle), control: tarZstdLevelPopup, format: .tarZstd),
                tarLevelRow(String(localized: "lzipレベル:", bundle: bundle), control: tarLzipLevelPopup, format: .tarLzip),
                tarLevelRow(String(localized: "lzmaレベル:", bundle: bundle), control: tarLZMALevelPopup, format: .tarLZMA),
                checkboxRow(tarPreservesOwnerIDsCheckbox),
                row(String(localized: "変更しない項目の所有者ID:", bundle: bundle), control: tarCarriedOwnerIDsPopup)
            ], spanningRows: [6]), tarNote]),
            ("lha", "LHA", [group(rows: [
                row(String(localized: "圧縮方式:", bundle: bundle), control: lhaMethodPopup),
                [lhaMethodDescription, NSGridCell.emptyContentView],
                row(String(localized: "圧縮レベル:", bundle: bundle), control: lhaLevelPopup)
            ], spanningRows: [1])])
        ])
        addTab(title: String(localized: "圧縮", bundle: bundle), symbol: "archivebox", sections: [
            group(rows: [checkboxRow(excludesDSStoreCheckbox), checkboxRow(excludesHiddenFilesCheckbox)], spanningRows: [0, 1]),
            compressionTabs
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
        let powerNote = secondaryNote(String(localized: "圧縮と展開の両方で、自動の並列数に使います。", bundle: bundle), width: 360)
        addTab(title: String(localized: "パフォーマンス", bundle: bundle), symbol: "speedometer", sections: [
            group(rows: [
                row(String(localized: "圧縮の並列数:", bundle: bundle), control: compressionThreadsPopup),
                row("", control: compressionMemoryNote),
                row(String(localized: "電力の使用方針:", bundle: bundle), control: powerPolicyPopup),
                row("", control: powerNote),
                checkboxRow(prefersSpeedCheckbox),
                [prefersSpeedNote, NSGridCell.emptyContentView]
            ], spanningRows: [4, 5])
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
        additionPositionPopup.setAccessibilityLabel(String(localized: "追加した項目の位置", bundle: bundle))
        tarCarriedOwnerIDsPopup.setAccessibilityLabel(String(localized: "変更しない項目の所有者ID", bundle: bundle))
        // 長い翻訳も省略しない共通の幅を選び、高さはタブの内容に合わせる。
        let width = tabController.targetContentSizes.reduce(CGFloat(600)) { max($0, $1.width) }
        for (index, item) in tabController.tabViewItems.enumerated() {
            guard let pane = item.viewController else { continue }
            var size = tabController.targetContentSizes[index]
            size.width = width
            // スクロールバーの表示方式が変わっても、ペインからウインドウの幅を広げない。
            pane.view.widthAnchor.constraint(equalToConstant: width).isActive = true
            pane.view.setFrameSize(size)
            // 共通幅と制約を反映した後の必要高も使い、初期計測より高い内容を切り取らない。
            pane.view.layoutSubtreeIfNeeded()
            size.height = max(size.height, ceil(pane.view.fittingSize.height))
            tabController.targetContentSizes[index] = size
            pane.preferredContentSize = size
            pane.view.setFrameSize(size)
        }
        let contentSize = tabController.targetContentSizes[0]
        tabController.preferredContentSize = contentSize
        tabController.view.setFrameSize(contentSize)
        window.contentViewController = tabController
        window.setContentSize(contentSize)
        window.toolbar?.displayMode = .iconAndLabel
        window.toolbar?.allowsUserCustomization = false
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)),
                                               name: ArchivePreferencesStore.didChange, object: store)
        // 自動値の表示も、現在の電力・温度状態で更新する。
        NotificationCenter.default.addObserver(self, selector: #selector(hardwareDidChange(_:)),
                                               name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(hardwareDidChange(_:)),
                                               name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(softwareUpdatesDidChange(_:)),
                                               name: SoftwareUpdateController.didChange, object: softwareUpdater)
        tabController.prepareSelectedPane = { [weak self] in
            guard let self, self.tabController.selectedTabViewItemIndex == 1 else { return }
            self.updateCompressionPaneSize()
        }
        refreshControls()
    }

    required init?(coder: NSCoder) { nil }

    override func close() {
        tabController.completePendingResize(in: window)
        super.close()
    }

    override func showWindow(_ sender: Any?) {
        refreshControls()
        tabController.finishPendingResize()
        if tabController.selectedTabViewItemIndex == 1 { updateCompressionPaneSize() }
        tabController.resizeToSelectedPane()
        super.showWindow(sender)
    }

    private func configureControls() {
        folderOpeningPopup.addItems(withTitles: [String(localized: "フォルダに移動", bundle: bundle),
                                                 String(localized: "その場で展開", bundle: bundle)])
        compressionThreadsPopup.addItems(withTitles: viewModel.compressionThreadTitles)
        powerPolicyPopup.addItems(withTitles: viewModel.powerPolicyTitles)
        defaultFormatPopup.addItems(withTitles: ArchivePreferences.formats.map { ArchiveSavePanelController.title(for: $0, bundle: bundle) })
        saveBehaviorPopup.addItems(withTitles: [String(localized: "すぐに書き込む", bundle: bundle),
                                               String(localized: "保存時にまとめて書き込む", bundle: bundle)])
        openingBehaviorPopup.addItems(withTitles: [String(localized: "macOSの設定に従う", bundle: bundle),
                                                  String(localized: "新しいタブ", bundle: bundle),
                                                  String(localized: "新しいウインドウ", bundle: bundle)])
        additionPositionPopup.addItems(withTitles: [String(localized: "末尾", bundle: bundle),
            String(localized: "先頭（編集のたびに全体を書き直す）", bundle: bundle)])
        tarCarriedOwnerIDsPopup.addItems(withTitles: [String(localized: "そのまま保つ", bundle: bundle),
            String(localized: "0に戻す（編集のたびに全体を書き直す）", bundle: bundle)])
        zipMethodPopup.addItems(withTitles: [String(localized: "Deflate", bundle: bundle), String(localized: "無圧縮", bundle: bundle), "BZip2", "LZMA", "XZ", String(localized: "Zstandard", bundle: bundle), String(localized: "PPMd", bundle: bundle)])
        let defaults = ArchivePreferences()
        if let index = PreferencesViewModel.zipMethods.firstIndex(of: defaults.zipMethod) {
            markStandardItem(in: zipMethodPopup, at: index)
        }
        sevenZipFilterPopup.addItems(withTitles: ArchivePreferences.SevenZipFilter.allCases.map { $0.title(bundle: bundle) })
        if let index = ArchivePreferences.SevenZipFilter.allCases.firstIndex(of: defaults.sevenZipFilter) {
            markStandardItem(in: sevenZipFilterPopup, at: index)
        }
        sevenZipFilterPopup.setAccessibilityLabel(String(localized: "フィルタ", bundle: bundle))
        // 最長のレベル名も初期計測に含め、方式の変更で幅を変えない。
        for (popup, format) in compressionLevelPopups {
            let controller = viewModel.compressionController(for: format)
            popup.addItems(withTitles: controller.levels.map {
                $0.title(bundle: bundle, startsAtZero: controller.startsAtZero, zstd: controller.usesZstd)
            })
            popup.toolTip = CompressionOptionHelp.level(bundle: bundle)
        }
        sevenZipMethodPopup.addItems(withTitles: viewModel.compressionController(for: .sevenZip).methods.map { $0.title(bundle: bundle) })
        lhaMethodPopup.addItems(withTitles: viewModel.compressionController(for: .lha).methods.map { $0.title(bundle: bundle) })
        if let index = viewModel.compressionController(for: .sevenZip).methods.firstIndex(where: { $0.rawValue.lowercased() == defaults.sevenZipMethod.rawValue }) {
            markStandardItem(in: sevenZipMethodPopup, at: index)
        }
        if let index = viewModel.compressionController(for: .lha).methods.firstIndex(where: { $0.rawValue == defaults.lhaMethod.rawValue }) {
            markStandardItem(in: lhaMethodPopup, at: index)
        }
        zipLevelSlider.toolTip = CompressionOptionHelp.level(bundle: bundle)
        zipSkipsCompressedTypesCheckbox.toolTip = CompressionOptionHelp.skipsCompressedTypes(bundle: bundle)
        sevenZipSolidCheckbox.toolTip = CompressionOptionHelp.solid(bundle: bundle)
        compressionThreadsPopup.toolTip = CompressionOptionHelp.threads(bundle: bundle)
        powerPolicyPopup.toolTip = CompressionOptionHelp.power(bundle: bundle)
        prefersSpeedCheckbox.toolTip = CompressionOptionHelp.speed(bundle: bundle)
        extractionDestinationPopup.addItems(withTitles: [String(localized: "アーカイブと同じディレクトリ内", bundle: bundle), String(localized: "場所を選択…", bundle: bundle)])
        afterExpansionPopup.addItems(withTitles: [String(localized: "アーカイブをそのままにする", bundle: bundle),
                                                 String(localized: "アーカイブをゴミ箱に入れる", bundle: bundle)])
        folderPolicyPopup.addItems(withTitles: [String(localized: "常に", bundle: bundle), String(localized: "複数の項目があるとき", bundle: bundle),
                                              String(localized: "作らない", bundle: bundle)])
        let actions: [(NSControl, Selector)] = [
            (showsWelcomeWindowAtLaunchCheckbox, #selector(changeShowsWelcomeWindowAtLaunch(_:))),
            (showsHiddenFilesCheckbox, #selector(changeShowsHiddenFiles(_:))),
            (keepsFoldersOnTopCheckbox, #selector(changeKeepsFoldersOnTop(_:))),
            (renamesOnClickCheckbox, #selector(changeRenamesOnClick(_:))),
            (excludesDSStoreCheckbox, #selector(changeExcludesDSStore(_:))),
            (excludesHiddenFilesCheckbox, #selector(changeExcludesHiddenFiles(_:))),
            (defaultFormatPopup, #selector(changeDefaultFormat(_:))),
            (saveBehaviorPopup, #selector(changeSaveBehavior(_:))),
            (openingBehaviorPopup, #selector(changeOpeningBehavior(_:))),
            (folderOpeningPopup, #selector(changeFolderOpening(_:))),
            (additionPositionPopup, #selector(changeAdditionPosition(_:))),
            (tarCarriedOwnerIDsPopup, #selector(changeTarCarriedOwnerIDs(_:))),
            (compressionThreadsPopup, #selector(changeCompressionThreads(_:))),
            (powerPolicyPopup, #selector(changePowerPolicy(_:))),
            (prefersSpeedCheckbox, #selector(changePrefersSpeed(_:))),
            (sevenZipMethodPopup, #selector(changeSevenZipMethod(_:))),
            (sevenZipLevelPopup, #selector(changeSevenZipLevel(_:))),
            (lhaMethodPopup, #selector(changeLHAMethod(_:))),
            (lhaLevelPopup, #selector(changeLHALevel(_:))),
            (tarXZLevelPopup, #selector(changeTarXZLevel(_:))),
            (tarZstdLevelPopup, #selector(changeTarZstdLevel(_:))),
            (tarLzipLevelPopup, #selector(changeTarLzipLevel(_:))),
            (tarLZMALevelPopup, #selector(changeTarLZMALevel(_:))),
            (sevenZipSolidCheckbox, #selector(changeSevenZipSolid(_:))),
            (sevenZipFilterPopup, #selector(changeSevenZipFilter(_:))),
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

    private func secondaryNote(_ text: String, width: CGFloat = 520) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = width
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func reserveDescription(_ label: NSTextField, texts: [String]) {
        label.preferredMaxLayoutWidth = 520
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.identifier = NSUserInterfaceItemIdentifier("preferences.compression.methodDescription")
        let height = texts.reduce(CGFloat(0)) { height, text in
            label.stringValue = text
            return max(height, label.sizeThatFits(NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)).height)
        }
        label.stringValue = texts.first ?? ""
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 520).isActive = true
        label.heightAnchor.constraint(equalToConstant: ceil(height)).isActive = true
    }

    private func tarLevelRow(_ title: String, control: NSView, format: GyoshukuKit.ArchiveFormat) -> [NSView] {
        let help = CompressionOptionHelp.tar(format, bundle: bundle)
        let views = row(title, control: control)
        views[0].toolTip = help
        let levelHelp = joinedSentences(help, CompressionOptionHelp.level(bundle: bundle))
        control.toolTip = levelHelp
        for child in control.subviews { child.toolTip = levelHelp }
        return views
    }

    private func markStandardItem(in popup: NSPopUpButton, at index: Int) {
        guard let item = popup.item(at: index) else { return }
        item.title = String(format: String(localized: "%@（デフォルト）", bundle: bundle), item.title)
    }

    private func configureCompressionTabs(panes: [(String, String, [NSView])]) -> NSView {
        compressionTabView.tabViewType = .topTabsBezelBorder
        compressionTabView.identifier = NSUserInterfaceItemIdentifier("preferences.compression.formats")
        var maximum = NSSize.zero
        // 非選択タブは階層から外れるため、追加する前に各ペインの必要寸法を測る。
        for (identifier, title, sections) in panes {
            let tab = PreferencesViewModel.CompressionTab(rawValue: identifier)!
            let button = NSButton(title: String(localized: "デフォルトに戻す", bundle: bundle),
                                  target: self, action: #selector(resetCompressionDefaults(_:)))
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier("preferences.compression.reset." + identifier)
            button.toolTip = String(format: String(localized: "%@の設定をデフォルトに戻します。", bundle: bundle), title)
            button.setAccessibilityLabel(String(format: String(localized: "%@の設定をデフォルトに戻す", bundle: bundle), title))
            compressionResetButtons[tab] = button
            let actions = NSStackView(views: [NSView(), button])
            actions.spacing = 0
            actions.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
            let pane = PreferencesScrollDocumentView()
            let stack = NSStackView(views: sections + [actions])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.detachesHiddenViews = false
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
            stack.spacing = 14
            for section in sections + [actions] { section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4).isActive = true }
            let required = stack.fittingSize
            let size = NSSize(width: ceil(required.width) + 32, height: ceil(required.height) + 32)
            maximum.width = max(maximum.width, size.width)
            maximum.height = max(maximum.height, size.height)
            compressionPaneHeights.append(size.height)
            pane.setFrameSize(size)
            stack.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 16)
            ])
            let item = NSTabViewItem(identifier: "preferences.compression." + identifier)
            item.label = title
            item.view = pane
            compressionTabView.setFrameSize(NSSize(width: maximum.width + 32, height: maximum.height + 64))
            compressionTabView.addTabViewItem(item)
        }
        let border = NSSize(width: compressionTabView.frame.width - compressionTabView.contentRect.width,
                            height: compressionTabView.frame.height - compressionTabView.contentRect.height)
        compressionBorderHeight = border.height
        // NSTabViewの整列矩形の外に描かれる標準ベゼルもコンテナ内に収める。
        let insets = compressionTabView.alignmentRectInsets
        let container = PreferencesScrollDocumentView()
        compressionTabView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(compressionTabView)
        let height = container.heightAnchor.constraint(equalToConstant: compressionPaneHeights[viewModel.initialCompressionTabIndex] + border.height)
        compressionTabHeight = height
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: maximum.width + border.width),
            height,
            compressionTabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            compressionTabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            compressionTabView.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            compressionTabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom)
        ])
        compressionTabView.selectTabViewItem(at: viewModel.initialCompressionTabIndex)
        compressionTabView.delegate = self
        return container
    }

    func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        // 非表示の内部タブ変更では、表示中の別ペインの伸縮を止めない。
        if tabController.selectedTabViewItemIndex == 1 { tabController.finishPendingResize() }
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let item = tabViewItem, let index = tabView.tabViewItems.firstIndex(of: item),
              compressionPaneHeights.indices.contains(index) else { return }
        updateCompressionPaneSize()
        guard tabController.selectedTabViewItemIndex == 1 else { return }
        tabController.resizeToSelectedPane(fading: item.view?.subviews.first)
    }

    private func updateCompressionPaneSize() {
        guard let stack = compressionStack, let scroll = compressionScroll,
              let tabHeight = compressionTabHeight, let documentHeight = compressionDocumentHeight,
              let item = compressionTabView.selectedTabViewItem,
              let index = compressionTabView.tabViewItems.firstIndex(of: item),
              tabController.targetContentSizes.indices.contains(1) else { return }
        stack.layoutSubtreeIfNeeded()
        let innerHeight = compressionPaneHeights[index] + compressionBorderHeight
        let height = ceil(stack.fittingSize.height) + 48 + innerHeight - tabHeight.constant
        let window = self.window
        let visibleHeight = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 838
        let titlebar = window?.frameRect(forContentRect: .zero).height ?? 38
        let available = max(1, visibleHeight - titlebar - 40)
        let scrolls = height > 698 || height > available
        tabController.targetContentSizes[1].height = scrolls ? min(height, 698, available) : height
        // スクロール位置は最初のフレームより先に戻し、不要な二度目のtileを避ける。
        if scroll.contentView.bounds.origin != .zero {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        tabController.applyCompressionLayout(shrinking: innerHeight < tabHeight.constant || height < documentHeight.constant) {
            tabHeight.constant = innerHeight
            documentHeight.constant = height
            scroll.hasVerticalScroller = scrolls
            scroll.tile()
        }
    }

    @objc private func resetCompressionDefaults(_ sender: NSButton) {
        guard let tab = compressionResetButtons.first(where: { $0.value === sender })?.key else { return }
        viewModel.resetCompressionDefaults(for: tab)
    }

    private func levelControl(_ slider: NSSlider, label: NSTextField) -> NSView {
        slider.toolTip = CompressionOptionHelp.level(bundle: bundle)
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
        ArchiveFormRow.make(title, control: control)
    }

    private func checkboxRow(_ button: NSButton) -> [NSView] {
        ArchiveFormRow.checkbox(button, width: 520)
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
            if rows[row][0] is NSTextField {
                grid.cell(atColumnIndex: 0, rowIndex: row).xPlacement = .fill
            }
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
        controller.view = PreferencesScrollDocumentView()
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
        let isCompression = symbol == "archivebox"
        let maximumHeight = required.height + (compressionPaneHeights.max() ?? 0)
            - (compressionPaneHeights.indices.contains(viewModel.initialCompressionTabIndex) ? compressionPaneHeights[viewModel.initialCompressionTabIndex] : 0)
        // 長い内容では従来どおりlegacyの幅を確保し、共通幅の計測を保つ。
        let scrollerWidth = isCompression && maximumHeight > 650
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let size = NSSize(width: max(600, ceil(required.width) + 48 + scrollerWidth), height: ceil(required.height) + 48)
        tabController.targetContentSizes.append(size)
        controller.view.setFrameSize(size)
        stack.translatesAutoresizingMaskIntoConstraints = false
        if isCompression {
            compressionStack = stack
            let scroll = PreferencesScrollView(frame: NSRect(origin: .zero, size: size))
            compressionScroll = scroll
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            let document = PreferencesScrollDocumentView(frame: NSRect(origin: .zero, size: size))
            document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(stack)
            scroll.documentView = document
            controller.view.addSubview(scroll)
            // document の最小幅を scroll の必須幅へ伝播させず、表示領域の幅に追従させる。
            let documentWidth = document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            documentWidth.priority = .defaultHigh
            let documentHeight = document.heightAnchor.constraint(equalToConstant: ceil(required.height) + 48)
            compressionDocumentHeight = documentHeight
            let trailing = stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24)
            scroll.documentTrailingConstraint = trailing
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: controller.view.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
                documentWidth,
                documentHeight,
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
                stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
                trailing
            ])
        } else {
            controller.view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24),
                stack.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24)
            ])
        }
        if isCompression { updateCompressionPaneSize() }
        controller.preferredContentSize = tabController.targetContentSizes.last!
        let item = NSTabViewItem(viewController: controller)
        item.identifier = "preferences." + symbol
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabController.addTabViewItem(item)
    }

    @objc private func preferencesDidChange(_ notification: Notification) { refreshControls() }
    @objc nonisolated private func hardwareDidChange(_ notification: Notification) {
        // 電力通知は background queue から届くため、表示更新を main actor へ送る。
        Task { @MainActor [weak self] in self?.refreshControls() }
    }
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
        for (tab, button) in compressionResetButtons {
            button.isEnabled = !viewModel.compressionDefaultsAreCurrent(for: tab)
        }
        let preferences = viewModel.preferences
        showsWelcomeWindowAtLaunchCheckbox.state = preferences.showsWelcomeWindowAtLaunch ? .on : .off
        keepsFoldersOnTopCheckbox.state = preferences.keepsFoldersOnTop ? .on : .off
        showsHiddenFilesCheckbox.state = preferences.showsHiddenFiles ? .on : .off
        renamesOnClickCheckbox.state = preferences.renamesOnClick ? .on : .off
        excludesDSStoreCheckbox.state = preferences.excludesDSStore ? .on : .off
        excludesHiddenFilesCheckbox.state = preferences.excludesHiddenFiles ? .on : .off
        defaultFormatPopup.selectItem(at: viewModel.defaultFormatIndex)
        saveBehaviorPopup.selectItem(at: viewModel.saveBehaviorIndex)
        openingBehaviorPopup.selectItem(at: viewModel.openingBehaviorIndex)
        folderOpeningPopup.selectItem(at: viewModel.folderOpeningIndex)
        additionPositionPopup.selectItem(at: viewModel.additionPositionIndex)
        tarCarriedOwnerIDsPopup.selectItem(at: viewModel.tarCarriedOwnerIDsIndex)
        let threadTitles = viewModel.compressionThreadTitles
        if compressionThreadsPopup.itemTitles != threadTitles {
            compressionThreadsPopup.removeAllItems()
            compressionThreadsPopup.addItems(withTitles: threadTitles)
        }
        compressionThreadsPopup.selectItem(at: viewModel.compressionThreadIndex)
        powerPolicyPopup.selectItem(at: viewModel.powerPolicyIndex)
        prefersSpeedCheckbox.state = preferences.prefersSpeed ? .on : .off
        let memoryNote = viewModel.memoryNote
        compressionMemoryNote.stringValue = memoryNote.text
        compressionMemoryNote.textColor = memoryNote.warns ? .systemOrange : .secondaryLabelColor
        zipMethodPopup.selectItem(at: viewModel.zipMethodIndex)
        zipLevelSlider.minValue = viewModel.zipUsesLZMA ? 0 : 1
        zipLevelSlider.maxValue = preferences.zipMethod == .zstd ? 19 : 9
        zipLevelSlider.numberOfTickMarks = Int(zipLevelSlider.maxValue - zipLevelSlider.minValue) + 1
        zipLevelSlider.integerValue = viewModel.zipLevel
        zipLevelLabel.stringValue = viewModel.zipLevelLabel
        zipLevelSlider.isEnabled = preferences.zipMethod != .stored
        zipLevelLabel.textColor = zipLevelSlider.isEnabled ? .secondaryLabelColor : .disabledControlTextColor
        zipCompatibilityNote.isHidden = ![.bzip2, .lzma, .xz, .zstd, .ppmd].contains(preferences.zipMethod)
        refreshCompressionFormats()
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

    private var compressionLevelPopups: [(NSPopUpButton, GyoshukuKit.ArchiveFormat)] {
        [(sevenZipLevelPopup, .sevenZip), (lhaLevelPopup, .lha), (tarXZLevelPopup, .tarXZ),
         (tarZstdLevelPopup, .tarZstd), (tarLzipLevelPopup, .tarLzip), (tarLZMALevelPopup, .tarLZMA)]
    }

    private func refreshCompressionFormats() {
        for (popup, format) in compressionLevelPopups {
            let controller = viewModel.compressionController(for: format)
            let titles = controller.levels.map {
                $0.title(bundle: bundle, startsAtZero: controller.startsAtZero, zstd: controller.usesZstd)
            }
            if popup.itemTitles != titles {
                popup.removeAllItems()
                popup.addItems(withTitles: titles)
            }
            popup.selectItem(at: controller.selectedLevelIndex)
            popup.isEnabled = controller.isLevelEnabled
        }
        let sevenZip = viewModel.compressionController(for: .sevenZip)
        sevenZipMethodPopup.selectItem(at: sevenZip.selectedMethodIndex)
        sevenZipSolidCheckbox.state = sevenZip.sevenZipSolid ? .on : .off
        sevenZipSolidCheckbox.isEnabled = sevenZip.showsSevenZipOptions
        sevenZipFilterPopup.isEnabled = sevenZip.showsSevenZipOptions
        sevenZipFilterPopup.selectItem(at: ArchivePreferences.SevenZipFilter.allCases.firstIndex(of: sevenZip.sevenZipFilter)!)
        sevenZipSolidNote.isHidden = !sevenZip.sevenZipSolid
        let lha = viewModel.compressionController(for: .lha)
        lhaMethodPopup.selectItem(at: lha.selectedMethodIndex)
        updateMethodHelp(zipMethodPopup, texts: PreferencesViewModel.zipMethods.map { CompressionOptionHelp.zip($0, bundle: bundle) },
                         description: zipMethodDescription)
        updateMethodHelp(sevenZipMethodPopup, texts: sevenZip.methods.map { CompressionOptionHelp.sevenZip($0, bundle: bundle) },
                         description: sevenZipMethodDescription)
        updateMethodHelp(lhaMethodPopup, texts: lha.methods.map { CompressionOptionHelp.lha($0, bundle: bundle) },
                         description: lhaMethodDescription)
        updateMethodHelp(sevenZipFilterPopup, texts: ArchivePreferences.SevenZipFilter.allCases.map {
            CompressionOptionHelp.filter($0, bundle: bundle)
        })
    }

    private func updateMethodHelp(_ popup: NSPopUpButton, texts: [String], description: NSTextField? = nil) {
        for (item, text) in zip(popup.itemArray, texts) { item.toolTip = text }
        popup.toolTip = popup.selectedItem?.toolTip
        description?.stringValue = popup.toolTip ?? ""
    }

    @objc private func changeSevenZipSolid(_ sender: NSButton) { viewModel.changeSevenZipSolid(to: sender.state == .on) }
    @objc private func changeSevenZipFilter(_ sender: NSPopUpButton) { viewModel.selectSevenZipFilter(at: sender.indexOfSelectedItem) }
    @objc private func changeSevenZipMethod(_ sender: NSPopUpButton) { viewModel.selectSevenZipMethod(at: sender.indexOfSelectedItem) }
    @objc private func changeSevenZipLevel(_ sender: NSPopUpButton) { viewModel.selectSevenZipLevel(at: sender.indexOfSelectedItem) }
    @objc private func changeLHAMethod(_ sender: NSPopUpButton) { viewModel.selectLHAMethod(at: sender.indexOfSelectedItem) }
    @objc private func changeLHALevel(_ sender: NSPopUpButton) { viewModel.selectLHALevel(at: sender.indexOfSelectedItem) }
    @objc private func changeTarXZLevel(_ sender: NSPopUpButton) { viewModel.selectTarXZLevel(at: sender.indexOfSelectedItem) }
    @objc private func changeTarZstdLevel(_ sender: NSPopUpButton) { viewModel.selectTarZstdLevel(at: sender.indexOfSelectedItem) }
    @objc private func changeTarLzipLevel(_ sender: NSPopUpButton) { viewModel.selectTarLzipLevel(at: sender.indexOfSelectedItem) }
    @objc private func changeTarLZMALevel(_ sender: NSPopUpButton) { viewModel.selectTarLZMALevel(at: sender.indexOfSelectedItem) }

    @objc private func changeDefaultFormat(_ sender: NSPopUpButton) { viewModel.selectDefaultFormat(at: sender.indexOfSelectedItem) }
    @objc private func changeSaveBehavior(_ sender: NSPopUpButton) { viewModel.selectSaveBehavior(at: sender.indexOfSelectedItem) }
    @objc private func changeOpeningBehavior(_ sender: NSPopUpButton) { viewModel.selectOpeningBehavior(at: sender.indexOfSelectedItem) }
    @objc private func changeFolderOpening(_ sender: NSPopUpButton) { viewModel.selectFolderOpening(at: sender.indexOfSelectedItem) }
    @objc private func changeKeepsFoldersOnTop(_ sender: NSButton) { viewModel.changeKeepsFoldersOnTop(to: sender.state == .on) }
    @objc private func changeShowsHiddenFiles(_ sender: NSButton) { viewModel.changeShowsHiddenFiles(to: sender.state == .on) }
    @objc private func changeRenamesOnClick(_ sender: NSButton) { viewModel.changeRenamesOnClick(to: sender.state == .on) }
    @objc private func changeShowsWelcomeWindowAtLaunch(_ sender: NSButton) {
        viewModel.changeShowsWelcomeWindowAtLaunch(to: sender.state == .on)
    }
    @objc private func changeExcludesDSStore(_ sender: NSButton) { viewModel.changeExcludesDSStore(to: sender.state == .on) }
    @objc private func changeExcludesHiddenFiles(_ sender: NSButton) { viewModel.changeExcludesHiddenFiles(to: sender.state == .on) }
    @objc private func changeAdditionPosition(_ sender: NSPopUpButton) {
        guard PreferencesViewModel.additionPositions.indices.contains(sender.indexOfSelectedItem) else { return }
        viewModel.changeAdditionPosition(to: PreferencesViewModel.additionPositions[sender.indexOfSelectedItem])
    }
    @objc private func changeTarCarriedOwnerIDs(_ sender: NSPopUpButton) {
        guard PreferencesViewModel.tarCarriedOwnerPolicies.indices.contains(sender.indexOfSelectedItem) else { return }
        viewModel.changeTarCarriedOwnerIDs(to: PreferencesViewModel.tarCarriedOwnerPolicies[sender.indexOfSelectedItem])
    }
    @objc private func changeZipMethod(_ sender: NSPopUpButton) { viewModel.selectZipMethod(at: sender.indexOfSelectedItem) }
    @objc private func changeCompressionThreads(_ sender: NSPopUpButton) {
        viewModel.selectCompressionThreads(at: sender.indexOfSelectedItem)
    }
    @objc private func changePowerPolicy(_ sender: NSPopUpButton) {
        viewModel.selectPowerPolicy(at: sender.indexOfSelectedItem)
    }
    @objc private func changePrefersSpeed(_ sender: NSButton) { viewModel.changePrefersSpeed(to: sender.state == .on) }
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
