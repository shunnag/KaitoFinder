import AppKit
import GyoshukuKit

/// NSAlert は初期フレームからアクセサリの領域を決める。解除・設定・保存で同じ規則を使う。
enum ArchivePasswordLayout {
    static func stack(_ views: [NSView], width: CGFloat? = nil, detachesHiddenViews: Bool = false) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.detachesHiddenViews = detachesHiddenViews
        if let width { stack.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return stack
    }

    static func size(_ view: NSView) {
        view.setFrameSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
    }
}

/// 保存パネルと設定・変更シートで入力・検証・はみ出し対策を共有する。
final class ArchivePasswordFields: NSObject, NSTextFieldDelegate {
    let passwordField = NSSecureTextField()
    let verifyField = NSSecureTextField()
    let methodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let headersCheckbox: NSButton
    let notice = NSTextField(wrappingLabelWithString: "")
    let view: NSStackView
    let width: CGFloat
    let labelWidth: CGFloat
    private let methodRow: NSGridView
    private let headersRow: NSGridView
    private let fieldLabels: [NSTextField]
    private let bundle: Bundle
    private(set) var format: GyoshukuKit.ArchiveFormat
    var didChange: (() -> Void)?

    init(format: GyoshukuKit.ArchiveFormat, changing: Bool = false, minimumLabelWidth: CGFloat = 0, bundle: Bundle = .main) {
        self.format = format
        self.bundle = bundle
        headersCheckbox = NSButton(checkboxWithTitle: String(localized: "ファイル名も暗号化", bundle: bundle), target: nil, action: nil)
        let passwordLabel = NSTextField(labelWithString: changing
            ? String(localized: "新しいパスワード:", bundle: bundle) : String(localized: "パスワード:", bundle: bundle))
        let verifyLabel = NSTextField(labelWithString: String(localized: "確認:", bundle: bundle))
        let methodLabel = NSTextField(labelWithString: String(localized: "方式:", bundle: bundle))
        fieldLabels = [passwordLabel, verifyLabel, methodLabel]
        methodPopup.addItems(withTitles: [String(localized: "AES-256(推奨)", bundle: bundle),
                                         String(localized: "ZipCrypto(互換性優先、安全性は低い)", bundle: bundle)])
        labelWidth = max(minimumLabelWidth, passwordLabel.intrinsicContentSize.width,
                         verifyLabel.intrinsicContentSize.width, methodLabel.intrinsicContentSize.width)
        width = max(360, labelWidth + 12 + max(220, methodPopup.intrinsicContentSize.width,
                                             headersCheckbox.intrinsicContentSize.width) + 8)
        let grid = NSGridView(views: [[passwordLabel, passwordField], [verifyLabel, verifyField]])
        methodRow = NSGridView(views: [[methodLabel, methodPopup]])
        headersRow = NSGridView(views: [[NSGridCell.emptyContentView, headersCheckbox]])
        for rows in [grid, methodRow, headersRow] {
            rows.columnSpacing = 12
            rows.rowSpacing = 8
            rows.column(at: 0).width = labelWidth
            rows.column(at: 0).xPlacement = .trailing
            rows.column(at: 0).leadingPadding = 2
            rows.column(at: 1).trailingPadding = 2
            rows.column(at: 1).xPlacement = .fill
            rows.yPlacement = .center
        }
        headersRow.column(at: 1).xPlacement = .leading
        let formatControl = NSView()
        formatControl.addSubview(methodRow)
        formatControl.addSubview(headersRow)
        for control in [methodRow, headersRow] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.leadingAnchor.constraint(equalTo: formatControl.leadingAnchor).isActive = true
            control.centerYAnchor.constraint(equalTo: formatControl.centerYAnchor).isActive = true
            control.trailingAnchor.constraint(equalTo: formatControl.trailingAnchor).isActive = true
        }
        formatControl.heightAnchor.constraint(equalToConstant: max(30, methodRow.fittingSize.height,
                                                                   headersRow.fittingSize.height)).isActive = true
        // NSTextField の alignment rect は実フレームより左右 2 pt 内側にある。
        // ラベルだけの行にも余白を設け、可視フレームを親の中へ収める。
        let noticeContainer = NSView()
        noticeContainer.addSubview(notice)
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.leadingAnchor.constraint(equalTo: noticeContainer.leadingAnchor, constant: 2).isActive = true
        notice.trailingAnchor.constraint(equalTo: noticeContainer.trailingAnchor, constant: -2).isActive = true
        notice.centerYAnchor.constraint(equalTo: noticeContainer.centerYAnchor).isActive = true
        noticeContainer.heightAnchor.constraint(equalTo: notice.heightAnchor).isActive = true
        view = ArchivePasswordLayout.stack([grid, formatControl, noticeContainer], width: width)
        super.init()
        for control in [grid as NSView, formatControl, noticeContainer] {
            control.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        for (field, label) in [(passwordField, passwordLabel), (verifyField, verifyLabel)] {
            label.alignment = .right
            field.delegate = self
            field.setAccessibilityLabel(label.stringValue)
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        }
        methodPopup.setAccessibilityLabel(methodLabel.stringValue)
        methodLabel.alignment = .right
        passwordField.nextKeyView = verifyField
        verifyField.nextKeyView = methodPopup
        notice.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        notice.textColor = .secondaryLabelColor
        notice.preferredMaxLayoutWidth = width - 4
        // エラーの有無でシートや保存パネルの高さを変えない。
        let messages = [String(localized: "パスワードを入力してください。", bundle: bundle),
                        String(localized: "パスワードが一致しません。", bundle: bundle)]
        let height = messages.map { text -> CGFloat in
            notice.stringValue = text
            return notice.sizeThatFits(NSSize(width: width - 4, height: 1000)).height
        }.max() ?? 20
        notice.heightAnchor.constraint(equalToConstant: max(20, height)).isActive = true
        notice.stringValue = ""
        selectFormat(format)
        ArchivePasswordLayout.size(view)
    }

    func selectFormat(_ format: GyoshukuKit.ArchiveFormat) {
        self.format = format
        methodRow.isHidden = format != .zip
        headersRow.isHidden = format != .sevenZip
        headersCheckbox.isHidden = format != .sevenZip
        verifyField.nextKeyView = format == .sevenZip ? headersCheckbox : methodPopup
    }

    func fill(_ settings: ArchiveEncryptionSettings) {
        passwordField.stringValue = settings.password ?? ""
        verifyField.stringValue = settings.password ?? ""
        methodPopup.selectItem(at: settings.zipEncryption == .zipCrypto ? 1 : 0)
        headersCheckbox.state = settings.encryptsSevenZipHeaders ? .on : .off
    }

    func setEnabled(_ enabled: Bool) {
        for control in [passwordField as NSControl, verifyField, methodPopup, headersCheckbox] {
            control.isEnabled = enabled
        }
        for label in fieldLabels { label.textColor = enabled ? .labelColor : .disabledControlTextColor }
    }

    var settings: ArchiveEncryptionSettings {
        ArchiveEncryptionSettings(password: passwordField.stringValue,
                                  zipEncryption: methodPopup.indexOfSelectedItem == 1 ? .zipCrypto : .aes256,
                                  encryptsSevenZipHeaders: format == .sevenZip && headersCheckbox.state == .on)
    }

    var validationMessage: String? {
        if passwordField.stringValue.isEmpty { return String(localized: "パスワードを入力してください。", bundle: bundle) }
        if passwordField.stringValue != verifyField.stringValue { return String(localized: "パスワードが一致しません。", bundle: bundle) }
        return nil
    }

    func validate() throws {
        if let message = validationMessage {
            throw NSError(domain: "com.shunnag.KaitoFinder.password", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func controlTextDidChange(_ notification: Notification) { didChange?() }

    func clear() {
        passwordField.stringValue = ""
        verifyField.stringValue = ""
    }
}

final class ArchivePasswordEditor {
    let alert = NSAlert()
    let fields: ArchivePasswordFields?
    let action: ArchivePasswordAction

    init(action: ArchivePasswordAction, format: GyoshukuKit.ArchiveFormat, archiveName: String,
         settings: ArchiveEncryptionSettings = .init(), bundle: Bundle = .main) {
        self.action = action
        if action == .remove {
            fields = nil
            alert.messageText = String(localized: "“\(archiveName)”のパスワードを削除しますか？", bundle: bundle)
            alert.informativeText = String(localized: "アーカイブは暗号化されていない状態で書き直されます。", bundle: bundle)
        } else {
            let fields = ArchivePasswordFields(format: format, changing: action == .change, bundle: bundle)
            self.fields = fields
            // 変更シートには新しい鍵だけを入力する。暗号化方式の選択は引き継ぐ。
            var choices = settings
            choices.password = nil
            fields.fill(choices)
            alert.messageText = action.buttonTitle(bundle: bundle)
            alert.accessoryView = fields.view
        }
        alert.addButton(withTitle: action.buttonTitle(bundle: bundle))
        alert.addButton(withTitle: String(localized: "キャンセル", bundle: bundle))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.window.autorecalculatesKeyViewLoop = true
        alert.window.initialFirstResponder = fields?.passwordField
        fields?.didChange = { [weak self] in self?.refreshValidation() }
        refreshValidation()
    }

    func refreshValidation() {
        fields?.notice.stringValue = fields?.validationMessage ?? ""
        alert.buttons.first?.isEnabled = fields?.validationMessage == nil
    }
}
