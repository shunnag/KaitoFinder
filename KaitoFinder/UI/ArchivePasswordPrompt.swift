import AppKit

nonisolated struct ArchivePasswordResponse: Sendable {
    let password: String
    let remember: Bool
}

final class ArchivePasswordPrompt {
    let alert = NSAlert()
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    let challenge: ArchivePasswordChallenge
    let rememberCheckbox: NSButton
    var waiters: [UUID: CheckedContinuation<ArchivePasswordResponse, any Error>] = [:]

    init(challenge: ArchivePasswordChallenge, archiveName: String? = nil, bundle: Bundle = .main) {
        self.challenge = challenge
        rememberCheckbox = NSButton(checkboxWithTitle: String(localized: "このパスワードを記憶", bundle: bundle),
                                    target: nil, action: nil)
        // 記憶は毎回明示的に選ぶ。前の入力や別のアーカイブの選択を引き継がない。
        rememberCheckbox.state = .off
        alert.messageText = String(localized: "アーカイブのロックを解除", bundle: bundle)
        if let archiveName {
            switch challenge {
            case .required:
                alert.informativeText = String(localized: "“\(archiveName)”のパスワードを入力してください。", bundle: bundle)
            case .incorrect:
                alert.informativeText = String(localized: "“\(archiveName)”のパスワードが違います。もう一度入力してください。", bundle: bundle)
            }
        } else { alert.informativeText = challenge.message(bundle: bundle) }
        alert.addButton(withTitle: String(localized: "ロックを解除", bundle: bundle))
        alert.addButton(withTitle: String(localized: "キャンセル", bundle: bundle))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        field.placeholderString = String(localized: "パスワード", bundle: bundle)
        let accessory = ArchivePasswordLayout.stack([field, rememberCheckbox])
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        field.widthAnchor.constraint(equalTo: accessory.widthAnchor).isActive = true
        // NSAlertはアクセサリの初期フレームで領域を確保する。
        ArchivePasswordLayout.size(accessory)
        alert.accessoryView = accessory
    }
}

/// 文書と単独の進捗パネルで入力待ちを共有し、取消しごとに継続を一度だけ回収する。
@MainActor final class ArchivePasswordPresenter {
    private(set) var prompt: ArchivePasswordPrompt?
    private var didAccept: (() -> Void)?

    func response(to challenge: ArchivePasswordChallenge, on window: NSWindow, archiveName: String? = nil,
                  bundle: Bundle = .main,
                  nextResponder: NSResponder? = nil, willPresent: () -> Void = {},
                  didAccept: @escaping () -> Void = {}) async throws -> ArchivePasswordResponse {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let prompt {
                    prompt.waiters[id] = continuation
                    return
                }
                let prompt = ArchivePasswordPrompt(challenge: challenge, archiveName: archiveName, bundle: bundle)
                self.prompt = prompt
                self.didAccept = didAccept
                prompt.waiters[id] = continuation
                willPresent()
                if let nextResponder { prompt.alert.window.nextResponder = nextResponder }
                prompt.alert.beginSheetModal(for: window) { [weak self, weak prompt] response in
                    guard let self, let prompt else { return }
                    self.finish(prompt, password: response == .alertFirstButtonReturn ? prompt.field.stringValue : nil)
                }
                prompt.alert.window.makeFirstResponder(prompt.field)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(id) }
        }
    }

    func cancel() {
        if let prompt { finish(prompt, password: nil) }
    }

    private func cancelRequest(_ id: UUID) {
        guard let prompt else { return }
        prompt.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if prompt.waiters.isEmpty { finish(prompt, password: nil) }
    }

    private func finish(_ prompt: ArchivePasswordPrompt, password: String?) {
        guard self.prompt === prompt else { return }
        self.prompt = nil
        let accepted = didAccept
        didAccept = nil
        prompt.field.stringValue = ""
        if let parent = prompt.alert.window.sheetParent { parent.endSheet(prompt.alert.window) }
        prompt.alert.window.orderOut(nil)
        let waiters = Array(prompt.waiters.values)
        prompt.waiters.removeAll()
        if let password {
            let response = ArchivePasswordResponse(password: password, remember: prompt.rememberCheckbox.state == .on)
            accepted?()
            for waiter in waiters { waiter.resume(returning: response) }
        } else {
            for waiter in waiters { waiter.resume(throwing: CancellationError()) }
        }
    }
}
