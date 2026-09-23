import AppKit

nonisolated enum ArchiveSplitScheduleChoice: Sendable, Equatable {
    case original, mostCommon, single, size(UInt64)

    func schedule(for layout: ArchiveVolumeLayout) throws -> VolumePlan.Schedule {
        switch self {
        case .original: return .explicit(layout.volumes.map(\.length))
        case .mostCommon:
            let counts = Dictionary(grouping: layout.volumes.map(\.length), by: { $0 }).mapValues(\.count)
            // Ties choose the larger size, avoiding an arbitrary directory/enumeration order.
            let size = counts.keys.max { counts[$0]! == counts[$1]! ? $0 < $1 : counts[$0]! < counts[$1]! }!
            return .uniform(size: size)
        case .single: return .single
        case .size(let size):
            guard size >= 64 * 1024, size <= UInt64(Int64.max) else { throw VolumePublishError.invalidPlan }
            return .uniform(size: size)
        }
    }
}

@MainActor final class ArchiveSplitSaveSheet: NSObject {
    let alert = NSAlert()
    let choices = NSPopUpButton(frame: .zero, pullsDown: false)
    let number = NSTextField(string: "10")
    let units = NSPopUpButton(frame: .zero, pullsDown: false)

    init(tooManyVolumes: Bool = false, bundle: Bundle = .main) {
        super.init()
        alert.messageText = String(localized: "巻サイズを選択", bundle: bundle)
        alert.informativeText = tooManyVolumes
            ? String(localized: "分割数が上限（128）を超えるため保存できません。巻サイズを大きくしてください。", bundle: bundle)
            : String(localized: "巻サイズが揃っていません。保存時に選びます。", bundle: bundle)
        choices.addItems(withTitles: [String(localized: "元の巻サイズを再現する", bundle: bundle),
            String(localized: "最も多い巻サイズにそろえる", bundle: bundle), String(localized: "1つのファイルにする", bundle: bundle),
            String(localized: "サイズを指定…", bundle: bundle)])
        units.addItems(withTitles: ["KB", "MB", "GB"])
        units.selectItem(at: 1)
        number.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let row = NSStackView(views: [number, units]); row.spacing = 8
        let view = ArchivePasswordLayout.stack([choices, row,
            NSTextField(labelWithString: String(localized: "64 KB以上のサイズを指定してください。", bundle: bundle))])
        ArchivePasswordLayout.size(view)
        alert.accessoryView = view
        alert.addButton(withTitle: String(localized: "保存", bundle: bundle))
        alert.addButton(withTitle: String(localized: "キャンセル", bundle: bundle))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        choices.target = self; choices.action = #selector(changeChoice(_:))
        if tooManyVolumes { choices.selectItem(at: 3) }
        changeChoice(nil)
    }

    @objc private func changeChoice(_ sender: Any?) {
        number.isEnabled = choices.indexOfSelectedItem == 3
        units.isEnabled = number.isEnabled
    }
    func choice() throws -> ArchiveSplitScheduleChoice {
        switch choices.indexOfSelectedItem {
        case 0: return .original
        case 1: return .mostCommon
        case 2: return .single
        default:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            guard let value = formatter.number(from: number.stringValue)?.doubleValue, value.isFinite, value > 0 else {
                throw VolumePublishError.invalidPlan
            }
            let bytes = value * pow(1024, Double(units.indexOfSelectedItem + 1))
            guard bytes >= 65536, bytes < Double(Int64.max) else { throw VolumePublishError.invalidPlan }
            return .size(UInt64(bytes))
        }
    }
    func choose(on window: NSWindow?) async throws -> ArchiveSplitScheduleChoice {
        while true {
            guard try await Self.present(alert, on: window) == .alertFirstButtonReturn else { throw CancellationError() }
            do { return try choice() }
            catch { alert.informativeText = String(localized: "64 KB以上のサイズを指定してください。") }
        }
    }
    static func hazardAlert(bundle: Bundle = .main) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "分割アーカイブへの書き込みを許可", bundle: bundle)
        alert.informativeText = String(localized: "この場所では、保存が中断されると回復が必要になる場合があります。保存中にほかのアプリが読み込むと、新旧の巻が混在する場合があります。", bundle: bundle)
        alert.addButton(withTitle: String(localized: "キャンセル", bundle: bundle))
        alert.addButton(withTitle: String(localized: "書き込む", bundle: bundle))
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        return alert
    }
    static func consent(on window: NSWindow?) async throws -> Bool {
        try await present(hazardAlert(), on: window) == .alertSecondButtonReturn
    }
    private static func present(_ alert: NSAlert, on window: NSWindow?) async throws -> NSApplication.ModalResponse {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let response: NSApplication.ModalResponse
            if let window {
                response = await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                }
            } else { response = alert.runModal() }
            try Task.checkCancellation()
            return response
        } onCancel: {
            Task { @MainActor in
                if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
                else { NSApplication.shared.abortModal() }
                alert.window.orderOut(nil)
            }
        }
    }
}
