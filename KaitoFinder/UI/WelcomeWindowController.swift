import AppKit

private final class WelcomeWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

final class WelcomeWindowController: NSWindowController {
    static let contentSize = NSSize(width: 720, height: 440)
    let openDropZone: WelcomeDropZoneView
    let createDropZone: WelcomeDropZoneView
    let showsWelcomeWindowAtLaunchCheckbox: NSButton
    private let store: ArchivePreferencesStore

    init(store: ArchivePreferencesStore = .shared, bundle: Bundle = .main,
         openAction: @escaping () -> Void = { NSDocumentController.shared.openDocument(nil) },
         createAction: @escaping () -> Void,
         openDropAction: @escaping ([URL]) -> Void = { WelcomeWindowController.openArchives($0) },
         createDropAction: @escaping ([URL], NSWindow?) -> Void) {
        self.store = store
        let window = WelcomeWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        openDropZone = WelcomeDropZoneView(kind: .open, bundle: bundle, clickAction: openAction, dropAction: openDropAction)
        createDropZone = WelcomeDropZoneView(kind: .create, bundle: bundle, clickAction: createAction,
                                            dropAction: { [weak window] in createDropAction($0, window) })
        showsWelcomeWindowAtLaunchCheckbox = NSButton(
            checkboxWithTitle: String(localized: "KaitoFinderの起動時にこのウインドウを表示", bundle: bundle),
            target: nil, action: nil)
        super.init(window: window)
        window.title = String(localized: "ようこそKaitoFinderへ", bundle: bundle)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        buildContent(bundle: bundle)
        showsWelcomeWindowAtLaunchCheckbox.target = self
        showsWelcomeWindowAtLaunchCheckbox.action = #selector(changeShowsWelcomeWindowAtLaunch(_:))
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesDidChange(_:)),
                                               name: ArchivePreferencesStore.didChange, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(archiveWindowBecameMain(_:)),
                                               name: NSWindow.didBecomeMainNotification, object: nil)
        refreshCheckbox()
        window.initialFirstResponder = openDropZone
        openDropZone.nextKeyView = createDropZone
        createDropZone.nextKeyView = showsWelcomeWindowAtLaunchCheckbox
        showsWelcomeWindowAtLaunchCheckbox.nextKeyView = openDropZone
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        refreshCheckbox()
        super.showWindow(sender)
    }

    private func buildContent(bundle: Bundle) {
        guard let content = window?.contentView else { return }
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: String(localized: "ようこそKaitoFinderへ", bundle: bundle))
        title.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title1).pointSize, weight: .bold)
        title.alignment = .center
        let number = Bundle(for: WelcomeWindowController.self)
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let version = NSTextField(labelWithString: String(localized: "バージョン \(number)", bundle: bundle))
        version.textColor = .secondaryLabelColor
        version.alignment = .center
        for view in [icon, title, version, openDropZone, createDropZone, showsWelcomeWindowAtLaunchCheckbox] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 8),
            title.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 32),
            title.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -32),
            version.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            version.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            openDropZone.topAnchor.constraint(equalTo: content.topAnchor, constant: 188),
            openDropZone.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            openDropZone.widthAnchor.constraint(equalTo: createDropZone.widthAnchor),
            openDropZone.heightAnchor.constraint(equalToConstant: 190),
            createDropZone.leadingAnchor.constraint(equalTo: openDropZone.trailingAnchor, constant: 24),
            createDropZone.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            createDropZone.topAnchor.constraint(equalTo: openDropZone.topAnchor),
            createDropZone.heightAnchor.constraint(equalTo: openDropZone.heightAnchor),
            showsWelcomeWindowAtLaunchCheckbox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            showsWelcomeWindowAtLaunchCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -32),
            showsWelcomeWindowAtLaunchCheckbox.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    private static func openArchives(_ urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
    }

    private func refreshCheckbox() {
        showsWelcomeWindowAtLaunchCheckbox.state = store.preferences.showsWelcomeWindowAtLaunch ? .on : .off
    }

    @objc private func preferencesDidChange(_ notification: Notification) { refreshCheckbox() }

    @objc private func changeShowsWelcomeWindowAtLaunch(_ sender: NSButton) {
        store.preferences.showsWelcomeWindowAtLaunch = sender.state == .on
    }

    @objc private func archiveWindowBecameMain(_ notification: Notification) {
        guard let archiveWindow = notification.object as? NSWindow,
              archiveWindow.windowController is ArchiveWindowController else { return }
        close()
    }
}
