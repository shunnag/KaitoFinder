import AppKit

/// A fixed-height field, using the same grid column and natural row sizing as the other options.
@MainActor final class ArchiveSaveSplitControls: NSObject {
    let choices = NSPopUpButton(frame: .zero, pullsDown: false)
    let number = NSTextField(string: "10")
    let units = NSPopUpButton(frame: .zero, pullsDown: false)
    let view: NSStackView
    let originalSize: UInt64?
    let originalSchedule: VolumePlan.Schedule?
    var didChange: (() -> Void)?
    var isSplitting: Bool { choices.indexOfSelectedItem > 0 }
    private let bundle: Bundle

    init(layout: ArchiveVolumeLayout?, bundle: Bundle = .main) {
        originalSize = layout?.uniformSize
        originalSchedule = layout?.immediateSchedule
        self.bundle = bundle
        let sizeRow = NSStackView(views: [number, units])
        sizeRow.spacing = 8
        view = ArchivePasswordLayout.stack([choices, sizeRow])
        super.init()
        choices.addItem(withTitle: String(localized: "しない", bundle: bundle))
        if let originalSchedule {
            let size: String
            switch originalSchedule {
            case .uniform(let bytes): size = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
            case .single: size = String(localized: "1つのファイルにする", bundle: bundle)
            case .explicit: size = String(localized: "元の巻サイズを再現する", bundle: bundle)
            }
            choices.addItem(withTitle: String(localized: "元と同じ（\(size)）", bundle: bundle))
        }
        choices.addItem(withTitle: String(localized: "サイズを指定…", bundle: bundle))
        choices.selectItem(at: originalSchedule == nil ? 0 : 1)
        choices.setAccessibilityIdentifier("ArchiveSaveSplit")
        choices.setAccessibilityLabel(String(localized: "分割:", bundle: bundle))
        number.setAccessibilityIdentifier("ArchiveSaveSplitSize")
        units.setAccessibilityIdentifier("ArchiveSaveSplitUnits")
        number.widthAnchor.constraint(equalToConstant: 120).isActive = true
        units.addItems(withTitles: ["KB", "MB", "GB"])
        units.selectItem(at: 1)
        choices.target = self; choices.action = #selector(changeChoice(_:))
        changeChoice(nil)
    }

    @objc func changeChoice(_ sender: Any?) {
        number.isEnabled = choices.indexOfSelectedItem == choices.numberOfItems - 1
        units.isEnabled = number.isEnabled
        didChange?()
    }

    /// nil means one ordinary archive, with no .001 suffix or volume metadata.
    func schedule() throws -> VolumePlan.Schedule? {
        if choices.indexOfSelectedItem == 0 { return nil }
        if choices.indexOfSelectedItem == 1, let originalSchedule { return originalSchedule }
        do { return .uniform(size: try ArchiveSplitSaveSheet.volumeSize(number: number.stringValue, unit: units.indexOfSelectedItem)) }
        catch { throw NSError(domain: "com.shunnag.KaitoFinder.creation", code: 1, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "64 KB以上のサイズを指定してください。", bundle: bundle)
        ]) }
    }
}
