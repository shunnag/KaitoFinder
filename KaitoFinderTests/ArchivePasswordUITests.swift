import AppKit
import GyoshukuKit
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePasswordUITests: XCTestCase {
    @MainActor func testSavePanelDelegateValidatesEmptyMismatchAndMatchingPasswords() throws {
        let suite = try ArchivePreferencesTestDefaults()
        let save = ArchiveSavePanel(sources: [], defaults: suite.defaults)
        let destination = URL(fileURLWithPath: "/tmp/password.zip")
        XCTAssertTrue(save.panel.delegate === save)
        XCTAssertEqual(save.encryptionCheckbox.state, .off)
        XCTAssertEqual(save.passwordFields.methodPopup.indexOfSelectedItem, 0)
        XCTAssertEqual(save.passwordFields.headersCheckbox.state, .off)
        XCTAssertNoThrow(try save.panel(save.panel, validate: destination))
        save.encryptionCheckbox.state = .on
        save.changeEncryption(save.encryptionCheckbox)
        XCTAssertThrowsError(try save.panel(save.panel, validate: destination)) {
            XCTAssertEqual(($0 as NSError).localizedDescription, String(localized: "パスワードを入力してください。"))
        }
        save.passwordFields.passwordField.stringValue = "first"
        save.passwordFields.verifyField.stringValue = "second"
        XCTAssertThrowsError(try save.panel(save.panel, validate: destination)) {
            XCTAssertEqual(($0 as NSError).localizedDescription, String(localized: "パスワードが一致しません。"))
        }
        save.passwordFields.verifyField.stringValue = "first"
        XCTAssertNoThrow(try save.panel(save.panel, validate: destination))
        XCTAssertNotNil(save.encryptionSettings.password)
    }

    @MainActor func testFormatSwitchPreservesFieldsAndOnlyShowsRequiredItems() throws {
        let suite = try ArchivePreferencesTestDefaults()
        let save = ArchiveSavePanel(sources: [], defaults: suite.defaults)
        let accessory = try XCTUnwrap(save.panel.accessoryView)
        let initialSize = accessory.frame.size
        XCTAssertTrue(save.passwordFields.view.isHidden)
        XCTAssertFalse(save.passwordFields.passwordField.isEnabled)
        save.encryptionCheckbox.state = .on
        save.passwordFields.fill(.init(password: "kept", zipEncryption: .zipCrypto, encryptsSevenZipHeaders: true))
        save.changeEncryption(save.encryptionCheckbox)
        let expandedHeight = accessory.frame.height
        XCTAssertGreaterThan(expandedHeight, initialSize.height)
        for (index, format) in ArchiveSavePanelController.formats.enumerated() {
            save.formatPopup.selectItem(at: index)
            save.changeFormat(save.formatPopup)
            let supported = format == .zip || format == .sevenZip
            XCTAssertEqual(save.encryptionCheckbox.isEnabled, supported)
            XCTAssertEqual(save.encryptionNote.isHidden, supported)
            XCTAssertEqual(save.passwordFields.view.isHidden, !supported)
            XCTAssertEqual(save.passwordFields.passwordField.isEnabled, supported)
            XCTAssertEqual(save.passwordFields.verifyField.isEnabled, supported)
            XCTAssertEqual(save.passwordFields.methodPopup.isEnabled, supported)
            XCTAssertEqual(save.passwordFields.headersCheckbox.isEnabled, supported)
            XCTAssertTrue(save.passwordFields.passwordField.stringValue == "kept")
            XCTAssertTrue(save.passwordFields.verifyField.stringValue == "kept")
            XCTAssertEqual(save.passwordFields.headersCheckbox.isHidden, format != .sevenZip)
            XCTAssertEqual(save.passwordFields.methodPopup.isHiddenOrHasHiddenAncestor, format != .zip)
            XCTAssertEqual(save.encryptionSettings.password != nil, supported)
            XCTAssertEqual(accessory.frame.width, initialSize.width, accuracy: 0.5)
            if supported { XCTAssertGreaterThanOrEqual(accessory.frame.height, expandedHeight) }
            else { XCTAssertLessThan(accessory.frame.height, expandedHeight) }
            if !supported {
                save.passwordFields.verifyField.stringValue = "mismatch"
                XCTAssertNoThrow(try save.panel(save.panel, validate: URL(fileURLWithPath: "/tmp/output." + ArchiveCreationPlan.filenameExtension(for: format))))
                save.passwordFields.verifyField.stringValue = "kept"
            }
        }
        save.formatPopup.selectItem(at: 0)
        save.changeFormat(save.formatPopup)
        save.encryptionCheckbox.state = .off
        XCTAssertTrue(save.encryptionCheckbox.sendAction(save.encryptionCheckbox.action, to: save.encryptionCheckbox.target))
        XCTAssertEqual(accessory.frame.size, initialSize)
        XCTAssertTrue(save.passwordFields.view.isHidden)
        XCTAssertFalse(save.passwordFields.passwordField.isEnabled)
        XCTAssertNil(save.encryptionSettings.password)
        XCTAssertTrue(save.passwordFields.passwordField.stringValue == "kept")
    }

    @MainActor func testPlanCarriesPasswordMethodAndHeadersWithoutOverwritingPreferences() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.zipSkipsCompressedTypes = false
        let creator = ArchiveCreationController(store: store)
        for format in ArchiveSavePanelController.formats {
            let plan = creator.creationPlan(sources: [], destination: URL(fileURLWithPath: "/tmp/output"), format: format,
                level: .maximum, encryption: .init(password: "chosen", zipEncryption: .zipCrypto, encryptsSevenZipHeaders: true))
            XCTAssertEqual(plan.options.password != nil, format == .zip || format == .sevenZip)
            XCTAssertEqual(plan.options.zipEncryption, .zipCrypto)
            XCTAssertEqual(plan.options.encryptsSevenZipHeaders, format == .sevenZip)
            if format == .zip {
                XCTAssertFalse(plan.options.useCompressionHeuristic)
                XCTAssertEqual(plan.options.deflateLevel, 9)
            }
        }
        XCTAssertNil(store.preferences.writerOptions(for: .zip).password)
    }

    @MainActor func testPresentedSavePanelAnimatesEncryptionAndCancelsWithoutSaving() async throws {
        let restoreAnimations = enableNativeWindowAnimations()
        defer { restoreAnimations() }
        let suite = try ArchivePreferencesTestDefaults()
        let save = ArchiveSavePanel(sources: [], store: ArchivePreferencesStore(defaults: suite.defaults), reducesMotion: { false })
        let accessory = try XCTUnwrap(save.panel.accessoryView)
        let collapsedHeight = accessory.fittingSize.height
        var response: NSApplication.ModalResponse?
        save.begin { response = $0 }
        defer { save.cancel() }
        try await scenarioWait { save.panel.isVisible && abs(accessory.frame.height - collapsedHeight) < 0.5 }
        let accessoryWindow = try XCTUnwrap(accessory.window)
        let collapsedPanelFrame = save.panel.frame
        XCTAssertTrue(save.passwordFields.view.isHidden)
        XCTAssertFalse(save.passwordFields.passwordField.isEnabled)
        try UISnapshot.render(accessory, name: "save-encryption-off")
        save.encryptionCheckbox.performClick(nil)
        let expandedHeight = try XCTUnwrap(accessory.subviews.first).fittingSize.height
        var openingHeights: [CGFloat] = []
        try await scenarioWait {
            if let height = accessory.layer?.presentation()?.bounds.height { openingHeights.append(height) }
            return save.passwordFields.passwordField.currentEditor() != nil && abs(accessory.frame.height - expandedHeight) < 0.5
        }
        XCTAssertGreaterThan(expandedHeight, collapsedHeight)
        XCTAssertTrue(openingHeights.contains { $0 > collapsedHeight + 1 && $0 < expandedHeight - 1 })
        XCTAssertGreaterThan(save.panel.frame.height, collapsedPanelFrame.height)
        XCTAssertEqual(save.panel.frame.width, collapsedPanelFrame.width, accuracy: 0.5)
        XCTAssertEqual(save.panel.frame.maxY, collapsedPanelFrame.maxY, accuracy: 0.5)
        XCTAssertFalse(save.passwordFields.view.isHidden)
        let fieldEditor = try XCTUnwrap(save.passwordFields.passwordField.currentEditor())
        XCTAssertTrue(accessoryWindow.firstResponder === fieldEditor)
        save.passwordFields.passwordField.stringValue = "typing"
        save.passwordFields.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertFalse(save.passwordFields.notice.stringValue.isEmpty)
        fieldEditor.insertTab(nil)
        XCTAssertNotNil(save.passwordFields.verifyField.currentEditor())
        save.passwordFields.verifyField.stringValue = "typing"
        save.passwordFields.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(save.passwordFields.notice.stringValue.isEmpty)
        XCTAssertEqual(accessory.frame.height, expandedHeight, accuracy: 0.5)
        XCTAssertTrue(UISnapshot.overflowViolations(in: accessory).isEmpty)
        try UISnapshot.render(accessory, name: "save-encryption-on")
        save.passwordFields.verifyField.stringValue = "different"
        save.passwordFields.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertFalse(save.passwordFields.notice.stringValue.isEmpty)
        save.encryptionCheckbox.performClick(nil)
        var closingHeights: [CGFloat] = []
        try await scenarioWait {
            if let height = accessory.layer?.presentation()?.bounds.height { closingHeights.append(height) }
            return save.passwordFields.view.isHidden && abs(accessory.frame.height - collapsedHeight) < 0.5 && abs(save.panel.frame.height - collapsedPanelFrame.height) < 0.5
        }
        XCTAssertTrue(closingHeights.contains { $0 > collapsedHeight + 1 && $0 < expandedHeight - 1 })
        XCTAssertTrue(zip(openingHeights, openingHeights.dropFirst()).allSatisfy { $0 <= $1 + 0.5 }, "展開中の高さ: \(openingHeights)")
        XCTAssertTrue(zip(closingHeights, closingHeights.dropFirst()).allSatisfy { $0 >= $1 - 0.5 }, "縮小中の高さ: \(closingHeights)")
        XCTAssertTrue(UISnapshot.overflowViolations(in: accessory).isEmpty)
        XCTAssertFalse(save.passwordFields.passwordField.isEnabled)
        XCTAssertTrue(save.passwordFields.notice.stringValue.isEmpty)
        XCTAssertNil(save.encryptionSettings.password)
        XCTAssertNoThrow(try save.panel(save.panel, validate: URL(fileURLWithPath: "/tmp/password.zip")))
        XCTAssertFalse(accessoryWindow.firstResponder === fieldEditor)
        // 伸びている途中に逆転し、さらに開き直しても最後の状態だけを適用する。
        save.encryptionCheckbox.state = .on
        XCTAssertTrue(save.encryptionCheckbox.sendAction(save.encryptionCheckbox.action, to: save.encryptionCheckbox.target))
        try await scenarioWait {
            let height = accessory.layer?.presentation()?.bounds.height ?? accessory.frame.height
            return height > collapsedHeight + 2 && height < expandedHeight - 2
        }
        save.encryptionCheckbox.state = .off
        XCTAssertTrue(save.encryptionCheckbox.sendAction(save.encryptionCheckbox.action, to: save.encryptionCheckbox.target))
        save.encryptionCheckbox.state = .on
        XCTAssertTrue(save.encryptionCheckbox.sendAction(save.encryptionCheckbox.action, to: save.encryptionCheckbox.target))
        try await scenarioWait { save.passwordFields.passwordField.currentEditor() != nil && abs(accessory.frame.height - expandedHeight) < 0.5 }
        XCTAssertTrue(save.passwordFields.passwordField.stringValue == "typing")
        XCTAssertTrue(save.passwordFields.verifyField.stringValue == "different")
        XCTAssertFalse(save.passwordFields.notice.stringValue.isEmpty)
        let resumedEditor = try XCTUnwrap(save.passwordFields.passwordField.currentEditor())
        save.formatPopup.selectItem(at: try XCTUnwrap(ArchiveSavePanelController.formats.firstIndex(of: .tar)))
        XCTAssertTrue(save.formatPopup.sendAction(save.formatPopup.action, to: save.formatPopup.target))
        try await scenarioWait { save.passwordFields.view.isHidden && abs(accessory.frame.height - accessory.fittingSize.height) < 0.5 }
        XCTAssertFalse(accessoryWindow.firstResponder === resumedEditor)
        XCTAssertNil(save.encryptionSettings.password)
        save.cancel()
        try await scenarioWait { response != nil }
        XCTAssertEqual(response, .cancel)
    }

    @MainActor func testSavePanelResizesWithoutSlidingContents() async throws {
        let restoreAnimations = enableNativeWindowAnimations()
        defer { restoreAnimations() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KaitoFinder-SavePanel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for browserExpanded in [false, true] {
            let restoreBrowser = setNativeSavePanelBrowserExpanded(browserExpanded)
            defer { restoreBrowser() }
            for asSheet in [false, true] {
                let suite = try ArchivePreferencesTestDefaults()
                let save = ArchiveSavePanel(sources: [], store: ArchivePreferencesStore(defaults: suite.defaults), reducesMotion: { false })
                save.panel.directoryURL = directory
                let accessory = try XCTUnwrap(save.panel.accessoryView)
                let controls: [NSView] = [save.formatPopup, save.levelPopup, save.encryptionCheckbox]
                let collapsedHeight = accessory.fittingSize.height
                let parent = asSheet ? NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 550),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false) : nil
                parent?.isReleasedWhenClosed = false
                parent?.center()
                parent?.makeKeyAndOrderFront(nil)
                var response: NSApplication.ModalResponse?
                if let parent { save.begin(on: parent) { response = $0 } }
                else { save.begin { response = $0 } }
                defer { save.cancel(); parent?.close() }
                try await scenarioWait {
                    save.panel.isVisible && abs(accessory.frame.height - collapsedHeight) < 0.5
                }
                // シート自体が現れる動きが終わってから、伸縮の基準位置を記録する。
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(save.panel.isExpanded, browserExpanded)
                if browserExpanded {
                    // 前回のユーザーサイズに左右されず、伸縮できる余地のある条件にする。
                    let frame = save.panel.frame
                    let height = min(600, (save.panel.screen?.visibleFrame.height ?? 900) - 200)
                    let y = asSheet ? frame.midY - height / 2 : frame.maxY - height
                    save.panel.setFrame(NSRect(x: frame.minX, y: y, width: frame.width, height: height), display: true)
                    try await Task.sleep(for: .milliseconds(200))
                }
                let initialPanelFrame = save.panel.frame
                let nonAccessoryHeight = initialPanelFrame.height - accessory.frame.height
                func framesInVisibleViewport(panelFrame: NSRect) -> [NSRect] {
                    // アクセサリは別の XPC ホスト内にある。ローカルのレイヤーだけでは
                    // 見えないずれを、表示中の保存パネルの寸法と合成して検査する。
                    let viewportHeight = panelFrame.height - nonAccessoryHeight
                    return controls.map { control in
                        var frame = control.convert(control.bounds, to: accessory)
                        frame.origin.y += viewportHeight - accessory.bounds.height
                        return frame
                    }
                }
                let initial = framesInVisibleViewport(panelFrame: initialPanelFrame)
                let captureFolder = try await beginSavePanelCapture(save, parent: parent, browserExpanded: browserExpanded)
                let collapsedPanelHeight = save.panel.frame.height
                var expandedPanelHeight = collapsedPanelHeight
                for state in [NSControl.StateValue.on, .off] {
                    save.encryptionCheckbox.performClick(nil)
                    XCTAssertEqual(save.encryptionCheckbox.state, state)
                    if state == .on {
                        expandedPanelHeight += try XCTUnwrap(accessory.subviews.first).fittingSize.height - collapsedHeight
                    }
                    let targetPanelHeight = state == .on ? expandedPanelHeight : collapsedPanelHeight
                    var samples: [[NSRect]] = []
                    var panelFrames: [NSRect] = []
                    var accessoryOrigins: [NSPoint] = []
                    var clipping: [CGFloat] = []
                    var hostClipping: [CGFloat] = []
                    let started = ContinuousClock.now
                    try await scenarioWait {
                        let panelFrame = save.panel.frame
                        samples.append(framesInVisibleViewport(panelFrame: panelFrame))
                        panelFrames.append(panelFrame)
                        accessoryOrigins.append(accessory.frame.origin)
                        // 位置の合成だけでなく、ホスト側の描画可能範囲も検査する。
                        // 要求がホストより先行すると、座標が正しくても文字が欠ける。
                        hostClipping.append(contentsOf: controls.map { $0.bounds.height - $0.visibleRect.intersection($0.bounds).height })
                        // visibleRect はローカル XPC ホストの古い寸法を含む。
                        // 実パネルの表示領域と、アプリ側で追加したクリップを合成する。
                        let viewport = NSRect(x: 0, y: accessory.bounds.height - (panelFrame.height - nonAccessoryHeight),
                                              width: accessory.bounds.width, height: panelFrame.height - nonAccessoryHeight)
                        clipping.append(contentsOf: controls.map { control in
                            var visible = control.bounds.intersection(control.convert(viewport, from: accessory))
                            var ancestor: NSView? = control
                            while let view = ancestor {
                                if view.clipsToBounds {
                                    visible = visible.intersection(control.convert(view.bounds, from: view))
                                }
                                if view === accessory { break }
                                ancestor = view.superview
                            }
                            return control.bounds.height - visible.height
                        })
                        let finished = state == .on ? save.passwordFields.view.alphaValue == 1 : save.passwordFields.view.isHidden
                        return finished && abs(panelFrame.height - targetPanelHeight) < 0.5 && started.duration(to: .now) > .milliseconds(650)
                    }
                    let drift = samples.flatMap { sample in
                        zip(sample, initial).map { max(abs($0.minX - $1.minX), abs($0.minY - $1.minY)) }
                    }.max()
                    let sizeChange = samples.flatMap { sample in
                        zip(sample, initial).map { max(abs($0.width - $1.width), abs($0.height - $1.height)) }
                    }.max()
                    XCTAssertLessThanOrEqual(try XCTUnwrap(drift), 0.01, "形式・圧縮レベル・暗号化の行が伸縮中にスライドした")
                    XCTAssertLessThanOrEqual(try XCTUnwrap(sizeChange), 0.5, "伸縮中にコントロールが伸び縮みした")
                    XCTAssertLessThanOrEqual(clipping.max() ?? 0, 0.01, "伸縮中にコントロールが切れた")
                    XCTAssertLessThanOrEqual(hostClipping.max() ?? 0, 0.01, "ホストの描画可能範囲から行が欠けた")
                    let panelHeights = panelFrames.map(\.height)
                    XCTAssertTrue(panelHeights.contains { $0 > collapsedPanelHeight + 1 && $0 < expandedPanelHeight - 1 },
                                  "保存パネル自体が中間の大きさを経由していない")
                    XCTAssertTrue(zip(panelHeights, panelHeights.dropFirst()).allSatisfy {
                        state == .on ? $0 <= $1 + 0.5 : $0 >= $1 - 0.5
                    }, "保存パネルが伸縮中に逆方向へ跳ねた: \(panelHeights)")
                    XCTAssertTrue(panelFrames.allSatisfy {
                        abs($0.minX - initialPanelFrame.minX) <= 0.5 && abs($0.width - initialPanelFrame.width) <= 0.5
                    }, "保存パネルが横に揺れた")
                    // AppKit の通常パネルは上端、浮動シートは中央を基準に伸縮する。
                    let topDrift = panelFrames.map { abs($0.maxY - initialPanelFrame.maxY) }.max() ?? 0
                    let centerDrift = panelFrames.map { abs($0.midY - initialPanelFrame.midY) }.max() ?? 0
                    let anchorDrift = min(topDrift, centerDrift)
                    XCTAssertLessThanOrEqual(anchorDrift, 0.01, "保存パネルの基準位置が揺れた")
                    let originDrift = accessoryOrigins.map { max(abs($0.x), abs($0.y)) }.max() ?? 0
                    XCTAssertLessThanOrEqual(originDrift, 0.5, "保存パネルへ渡すフォームの原点が伸縮中に往復した")
                    print("Save panel stability: browser=\(browserExpanded), sheet=\(asSheet), encryption=\(state.rawValue), content=\(drift ?? 0) pt, origin=\(originDrift) pt, anchor=\(anchorDrift) pt")
                }
                if let captureFolder {
                    try await scenarioWait { FileManager.default.fileExists(atPath: captureFolder.appendingPathComponent("frames.json").path) }
                }
                save.cancel()
                try await scenarioWait { response != nil }
                XCTAssertEqual(response, .cancel)
            }
        }
    }

    @MainActor func testSavePanelSheetReversesAnimationAndCancelsDuringExpansion() async throws {
        let restoreAnimations = enableNativeWindowAnimations()
        defer { restoreAnimations() }
        let suite = try ArchivePreferencesTestDefaults()
        let save = ArchiveSavePanel(sources: [], store: ArchivePreferencesStore(defaults: suite.defaults), reducesMotion: { false })
        let accessory = try XCTUnwrap(save.panel.accessoryView)
        let collapsedHeight = accessory.fittingSize.height
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 550),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil)
        let destination = Task { try await save.destination(on: parent) }
        defer { destination.cancel(); save.cancel(); parent.close() }
        try await scenarioWait { save.panel.isVisible && abs(accessory.frame.height - collapsedHeight) < 0.5 }
        XCTAssertTrue(parent.attachedSheet === save.panel)
        save.encryptionCheckbox.performClick(nil)
        let expandedHeight = try XCTUnwrap(accessory.subviews.first).fittingSize.height
        var heights: [CGFloat] = []
        try await scenarioWait {
            heights.append(accessory.layer?.presentation()?.bounds.height ?? accessory.frame.height)
            return save.passwordFields.passwordField.currentEditor() != nil && abs(accessory.frame.height - expandedHeight) < 0.5
        }
        XCTAssertTrue(heights.contains { $0 > collapsedHeight + 1 && $0 < expandedHeight - 1 })
        // 畳む途中で開き直し、すぐにオフにする。古い完了通知で再表示・再フォーカスしない。
        save.encryptionCheckbox.state = .off
        XCTAssertTrue(save.encryptionCheckbox.sendAction(save.encryptionCheckbox.action, to: save.encryptionCheckbox.target))
        try await scenarioWait {
            let height = accessory.layer?.presentation()?.bounds.height ?? accessory.frame.height
            return height > collapsedHeight + 2 && height < expandedHeight - 2
        }
        for state in [NSControl.StateValue.on, .off] {
            save.encryptionCheckbox.state = state
            XCTAssertTrue(save.encryptionCheckbox.sendAction(save.encryptionCheckbox.action, to: save.encryptionCheckbox.target))
        }
        try await scenarioWait { save.passwordFields.view.isHidden && abs(accessory.frame.height - collapsedHeight) < 0.5 }
        XCTAssertNil(save.passwordFields.passwordField.currentEditor())
        XCTAssertNil(save.encryptionSettings.password)
        save.encryptionCheckbox.state = .on
        XCTAssertTrue(save.encryptionCheckbox.sendAction(save.encryptionCheckbox.action, to: save.encryptionCheckbox.target))
        try await scenarioWait {
            let height = accessory.layer?.presentation()?.bounds.height ?? accessory.frame.height
            return height > collapsedHeight + 2 && height < expandedHeight - 2
        }
        destination.cancel()
        do {
            _ = try await destination.value
            XCTFail("展開途中のキャンセルが保存待ちを終了しなかった")
        } catch is CancellationError { }
        try await scenarioWait { parent.attachedSheet == nil && !save.panel.isVisible }
        XCTAssertNil(save.passwordFields.passwordField.currentEditor())
    }

    @MainActor func testSavePanelReducedMotionChangesSizeWithoutAnimation() async throws {
        // 書庫のドラッグ後と同じく、アプリが前面にある状態でもホストの初期フォーカスに負けない。
        NSApp.activate(ignoringOtherApps: true)
        let restoreAnimations = enableNativeWindowAnimations()
        defer { restoreAnimations() }
        let suite = try ArchivePreferencesTestDefaults()
        var reducesMotion = true
        let save = ArchiveSavePanel(sources: [], store: ArchivePreferencesStore(defaults: suite.defaults), reducesMotion: { reducesMotion })
        let accessory = try XCTUnwrap(save.panel.accessoryView)
        let collapsedHeight = accessory.fittingSize.height
        var response: NSApplication.ModalResponse?
        save.begin { response = $0 }
        defer { save.cancel() }
        try await scenarioWait { save.panel.isVisible && abs(accessory.frame.height - collapsedHeight) < 0.5 }
        save.encryptionCheckbox.performClick(nil)
        let expandedHeight = try XCTUnwrap(accessory.subviews.first).fittingSize.height
        var heights: [CGFloat] = []
        try await scenarioWait {
            heights.append(accessory.layer?.presentation()?.bounds.height ?? accessory.frame.height)
            return save.passwordFields.passwordField.currentEditor() != nil && abs(accessory.frame.height - expandedHeight) < 0.5
        }
        XCTAssertGreaterThan(expandedHeight, collapsedHeight)
        XCTAssertFalse(heights.contains { $0 > collapsedHeight + 1 && $0 < expandedHeight - 1 })
        save.encryptionCheckbox.performClick(nil)
        XCTAssertTrue(save.passwordFields.view.isHidden)
        try await scenarioWait { abs(accessory.frame.height - collapsedHeight) < 0.5 }
        // 動きの抑制を途中から有効にした場合も、進行中のアニメーションを止める。
        reducesMotion = false
        save.encryptionCheckbox.state = .on
        XCTAssertTrue(save.encryptionCheckbox.sendAction(save.encryptionCheckbox.action, to: save.encryptionCheckbox.target))
        try await scenarioWait {
            let height = accessory.layer?.presentation()?.bounds.height ?? accessory.frame.height
            return height > collapsedHeight + 2 && height < expandedHeight - 2
        }
        reducesMotion = true
        save.encryptionCheckbox.state = .off
        XCTAssertTrue(save.encryptionCheckbox.sendAction(save.encryptionCheckbox.action, to: save.encryptionCheckbox.target))
        XCTAssertTrue(save.passwordFields.view.isHidden)
        try await scenarioWait { abs(accessory.frame.height - collapsedHeight) < 0.5 }
        try await scenarioWait {
            abs((accessory.layer?.presentation()?.bounds.height ?? accessory.frame.height) - collapsedHeight) < 0.5
                && (accessory.layer?.animationKeys()?.isEmpty ?? true)
        }
        XCTAssertNil(save.passwordFields.passwordField.currentEditor())
        save.cancel()
        try await scenarioWait { response != nil }
        XCTAssertEqual(response, .cancel)
    }

    @MainActor private func setNativeSavePanelBrowserExpanded(_ expanded: Bool) -> () -> Void {
        // 別プロセスの標準パネルが読むため、保存値を一時的に指定して必ず復元する。
        let defaults = UserDefaults.standard
        let key = "NSNavPanelExpandedStateForSaveMode"
        let previous = defaults.object(forKey: key)
        defaults.set(expanded, forKey: key)
        defaults.synchronize()
        return {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
            defaults.synchronize()
        }
    }

    @MainActor private func beginSavePanelCapture(_ save: ArchiveSavePanel, parent: NSWindow?, browserExpanded: Bool) async throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["KAITOFINDER_SAVE_PANEL_CAPTURE_DIRECTORY"] else { return nil }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let name = "\(browserExpanded ? "expanded" : "compact")-\(parent == nil ? "panel" : "sheet")"
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let request = ["window": String(parent?.windowNumber ?? save.panel.windowNumber), "folder": folder.path]
        try JSONSerialization.data(withJSONObject: request).write(to: root.appendingPathComponent("request.json"), options: .atomic)
        try await scenarioWait { FileManager.default.fileExists(atPath: folder.appendingPathComponent("ready").path) }
        try await Task.sleep(for: .milliseconds(250))
        return folder
    }

    @MainActor func testExpandedSavePanelRebasesAfterNativeResizeAndFitsTheScreen() async throws {
        let restoreAnimations = enableNativeWindowAnimations()
        let restoreBrowser = setNativeSavePanelBrowserExpanded(true)
        defer { restoreAnimations(); restoreBrowser() }
        let suite = try ArchivePreferencesTestDefaults()
        let save = ArchiveSavePanel(sources: [], defaults: suite.defaults)
        let accessory = try XCTUnwrap(save.panel.accessoryView)
        var response: NSApplication.ModalResponse?
        save.begin { response = $0 }
        defer { save.cancel() }
        try await scenarioWait { save.panel.isVisible }
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(save.panel.isExpanded)
        save.encryptionCheckbox.performClick(nil)
        try await scenarioWait { save.passwordFields.passwordField.currentEditor() != nil }
        save.encryptionCheckbox.performClick(nil)
        try await scenarioWait { save.passwordFields.view.isHidden }
        let screen = try XCTUnwrap(save.panel.screen).visibleFrame
        // 標準のリサイズ開始通知から、実ウインドウの寸法変更を経て再度切り替える。
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: save.panel)
        let resized = NSRect(x: save.panel.frame.minX, y: screen.minY + 20,
                             width: save.panel.frame.width, height: screen.height - 20)
        save.panel.setFrame(resized, display: true)
        try await Task.sleep(for: .milliseconds(300))
        save.encryptionCheckbox.performClick(nil)
        try await scenarioWait {
            save.passwordFields.view.alphaValue == 1 && abs(accessory.frame.height - accessory.fittingSize.height) < 0.5
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(save.panel.frame.height, screen.height + 0.5)
        XCTAssertGreaterThanOrEqual(save.panel.frame.minY, screen.minY - 0.5)
        XCTAssertLessThanOrEqual(save.panel.frame.maxY, screen.maxY + 0.5)
        for view in [save.formatPopup, save.levelPopup, save.encryptionCheckbox, save.passwordFields.passwordField] as [NSView] {
            let visible = view.visibleRect.intersection(view.bounds)
            XCTAssertEqual(visible.height, view.bounds.height, accuracy: 0.5, "リサイズ後に入力欄が切れた")
            XCTAssertEqual(visible.width, view.bounds.width, accuracy: 0.5, "リサイズ後に入力欄が切れた")
        }
        let expandedHeight = save.panel.frame.height
        save.encryptionCheckbox.performClick(nil)
        try await scenarioWait { save.passwordFields.view.isHidden && save.panel.frame.height < expandedHeight - 1 }
        save.cancel()
        try await scenarioWait { response != nil }
        XCTAssertEqual(response, .cancel)
    }

    @MainActor func testExpandedSaveSheetKeepsItsButtonsOnScreenNearTheBottom() async throws {
        let restoreAnimations = enableNativeWindowAnimations()
        let restoreBrowser = setNativeSavePanelBrowserExpanded(true)
        defer { restoreAnimations(); restoreBrowser() }
        let suite = try ArchivePreferencesTestDefaults()
        let save = ArchiveSavePanel(sources: [], defaults: suite.defaults)
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 550),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.makeKeyAndOrderFront(nil)
        var response: NSApplication.ModalResponse?
        save.begin(on: parent) { response = $0 }
        defer { save.cancel(); parent.close() }
        try await scenarioWait { save.panel.isVisible }
        try await Task.sleep(for: .seconds(1))
        let screen = try XCTUnwrap(save.panel.screen).visibleFrame
        let frame = save.panel.frame
        let height = min(600, screen.height - 200)
        let bottom = screen.minY + 8
        save.panel.setFrame(NSRect(x: frame.minX, y: bottom,
                                   width: frame.width, height: height), display: true)
        try await Task.sleep(for: .milliseconds(300))
        // 前のパネルが大きいと、AppKit は表示時に親を上へ移動する。
        // シートの原点指定は無視されるので、親ごと下端の検査位置へ戻す。
        parent.setFrameOrigin(NSPoint(x: parent.frame.minX,
            y: parent.frame.minY + bottom - save.panel.frame.minY))
        try await scenarioWait { abs(save.panel.frame.minY - bottom) < 0.5 }
        for state in [NSControl.StateValue.on, .off, .on, .off] {
            save.encryptionCheckbox.performClick(nil)
            try await scenarioWait {
                state == .on ? save.passwordFields.view.alphaValue == 1 : save.passwordFields.view.isHidden
            }
            try await Task.sleep(for: .milliseconds(300))
            // ローカルのビューだけでなく、WindowServer が表示するシート全体を調べる。
            let windows = try XCTUnwrap(CGWindowListCopyWindowInfo(.optionIncludingWindow,
                CGWindowID(save.panel.windowNumber)) as? [[String: Any]])
            let bounds = try XCTUnwrap(windows.first?[kCGWindowBounds as String] as? [String: CGFloat])
            let displayed = try XCTUnwrap(CGRect(dictionaryRepresentation: bounds as CFDictionary))
            let primaryTop = try XCTUnwrap(NSScreen.screens.first).frame.maxY
            let visible = NSRect(x: displayed.minX, y: primaryTop - displayed.maxY,
                                 width: displayed.width, height: displayed.height)
            print("Save sheet screen fit: model=\(save.panel.frame), displayed=\(visible), screen=\(screen)")
            XCTAssertGreaterThanOrEqual(visible.minY, screen.minY - 0.5, "保存ボタンが画面下端からはみ出した")
            XCTAssertLessThanOrEqual(visible.maxY, screen.maxY + 0.5)
            if state == .on {
                for field in [save.passwordFields.passwordField, save.passwordFields.verifyField] {
                    XCTAssertEqual(field.visibleRect.intersection(field.bounds).height, field.bounds.height, accuracy: 0.5)
                }
            }
        }
        save.cancel()
        try await scenarioWait { response != nil }
        XCTAssertEqual(response, .cancel)
    }

    // 大量の非表示ウインドウを作る通常テストとは分け、実パネルでは標準アニメーションも有効にする。
    // 保存済みのユーザー設定には書き込まず、登録ドメインだけを一時的に差し替える。
    @MainActor private func enableNativeWindowAnimations() -> () -> Void {
        let defaults = UserDefaults.standard
        let registration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defaults.register(defaults: ["NSAutomaticWindowAnimationsEnabled": true])
        return { defaults.setVolatileDomain(registration, forName: UserDefaults.registrationDomain) }
    }

    @MainActor func testSetAndChangeSheetsValidateInlineAndNeverPrefillTheOldPassword() throws {
        for action in [ArchivePasswordAction.set, .change] {
            let editor = ArchivePasswordEditor(action: action, format: .zip, archiveName: "example.zip",
                                               settings: .init(password: "old", zipEncryption: .zipCrypto))
            let fields = try XCTUnwrap(editor.fields)
            XCTAssertTrue(fields.passwordField.stringValue.isEmpty)
            XCTAssertEqual(fields.methodPopup.indexOfSelectedItem, 1)
            XCTAssertFalse(try XCTUnwrap(editor.alert.buttons.first).isEnabled)
            XCTAssertEqual(fields.notice.stringValue, String(localized: "パスワードを入力してください。"))
            fields.passwordField.stringValue = "new"
            fields.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            XCTAssertEqual(fields.notice.stringValue, String(localized: "パスワードが一致しません。"))
            XCTAssertFalse(editor.alert.buttons[0].isEnabled)
            fields.verifyField.stringValue = "new"
            fields.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            XCTAssertTrue(fields.notice.stringValue.isEmpty)
            XCTAssertTrue(editor.alert.buttons[0].isEnabled)
        }
    }

    @MainActor func testVisibleSavePanelPasswordRowsAndAllThreeSheetsFitInEveryLanguage() throws {
        for language in LocalizationAcceptance.languages {
            let bundle = try LocalizationAcceptance.bundle(language)
            let suite = try ArchivePreferencesTestDefaults()
            let controller = ArchiveSavePanelController(defaults: suite.defaults)
            // NSSavePanel の XPC サービスがない環境でも、本番のアクセサリ自体を描画する。
            let fields = ArchivePasswordFields(format: .zip,
                minimumLabelWidth: ArchiveSavePanel.minimumLabelWidth(bundle: bundle), bundle: bundle)
            fields.fill(.init(password: "snapshot", zipEncryption: .zipCrypto))
            let formats = NSPopUpButton(frame: .zero, pullsDown: false)
            formats.addItems(withTitles: ArchiveSavePanelController.formats.map { ArchiveSavePanelController.title(for: $0, bundle: bundle) })
            let levels = NSPopUpButton(frame: .zero, pullsDown: false)
            levels.addItems(withTitles: ArchiveSavePanelController.Level.allCases.map { $0.title(bundle: bundle) })
            let checkbox = NSButton(checkboxWithTitle: String(localized: "暗号化", bundle: bundle), target: nil, action: nil)
            checkbox.state = .on
            let fixedNote = ArchiveSavePanel.makeNote(String(localized: "tar.xz、7z、LHA の圧縮レベルは固定です", bundle: bundle), width: fields.width)
            let encryptionNote = ArchiveSavePanel.makeNote(String(localized: "tar と LHA は暗号化できません", bundle: bundle), width: fields.width)
            let accessory = ArchiveSavePanel.makeAccessoryView(formatPopup: formats, levelPopup: levels, fixedLevelNote: fixedNote,
                encryptionCheckbox: checkbox, passwordFields: fields, encryptionNote: encryptionNote, bundle: bundle)
            let width = accessory.frame.width
            for (index, format) in ArchiveSavePanelController.formats.enumerated() {
                formats.selectItem(at: index)
                controller.selectFormat(at: index)
                levels.removeAllItems()
                levels.addItems(withTitles: controller.levels.map { $0.title(bundle: bundle) })
                levels.selectItem(at: controller.selectedLevelIndex)
                levels.isEnabled = controller.isLevelEnabled
                fields.selectFormat(format)
                checkbox.isEnabled = ArchiveEncryptionSettings.supports(format)
                fields.view.isHidden = !checkbox.isEnabled
                fixedNote.isHidden = format != .sevenZip && format != .lha
                encryptionNote.isHidden = checkbox.isEnabled
                ArchivePasswordLayout.size(accessory)
                XCTAssertEqual(accessory.frame.width, width, accuracy: 0.5, language)
                XCTAssertTrue(fields.passwordField.stringValue == "snapshot")
                XCTAssertTrue(fields.verifyField.stringValue == "snapshot")
                for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    accessory.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                    let name = "\(language)-encryption-save-\(ArchiveCreationPlan.filenameExtension(for: format))-\(style)"
                    try UISnapshot.render(accessory, name: name)
                    XCTAssertTrue(UISnapshot.overflowViolations(in: accessory).isEmpty,
                                  name + "\n" + UISnapshot.overflowViolations(in: accessory).joined(separator: "\n"))
                }
            }
            for action in ArchivePasswordAction.allCases {
                for format in [GyoshukuKit.ArchiveFormat.zip, .sevenZip] {
                    let editor = ArchivePasswordEditor(action: action, format: format,
                        archiveName: String(repeating: "旅行の写真", count: 14) + ".zip",
                        settings: .init(zipEncryption: .zipCrypto), bundle: bundle)
                    for state in ["empty", "mismatch", "valid"] {
                        if state != "empty" { editor.fields?.passwordField.stringValue = "snapshot" }
                        if state == "valid" { editor.fields?.verifyField.stringValue = "snapshot" }
                        editor.refreshValidation()
                        let name = "\(language)-password-\(action)-\(format)-\(state)"
                        try UISnapshot.render(editor.alert, name: name)
                        let content = try XCTUnwrap(editor.alert.window.contentView)
                        let failures = UISnapshot.overflowViolations(in: content)
                        XCTAssertTrue(failures.isEmpty, name + "\n" + failures.joined(separator: "\n"))
                        XCTAssertLessThanOrEqual(editor.alert.window.frame.width, 800, name)
                        if action == .remove { break }
                    }
                }
            }
        }
    }
}
