import AppKit
import XCTest

/// メニューを実際に表示し、動的項目の生成と自動 validation を通す。
/// Timer から開くことで、tracking 中も main queue の非同期処理を進められる。
@MainActor private final class MenuInteraction: NSObject {
    let menu: NSMenu
    let ready: () -> Bool
    let timeout: TimeInterval
    var completion: CheckedContinuation<Bool, Never>?
    private var deadline = Date.distantPast
    private var matched = false

    init(menu: NSMenu, timeout: TimeInterval, ready: @escaping () -> Bool) {
        self.menu = menu
        self.timeout = timeout
        self.ready = ready
    }

    func run() async -> Bool {
        await withCheckedContinuation { completion in
            self.completion = completion
            let start = Timer(timeInterval: 0, target: self, selector: #selector(show), userInfo: nil, repeats: false)
            RunLoop.main.add(start, forMode: .common)
        }
    }

    @objc private func show() {
        deadline = Date().addingTimeInterval(timeout)
        let poll = Timer(timeInterval: 0.02, target: self, selector: #selector(check), userInfo: nil, repeats: true)
        RunLoop.main.add(poll, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 100, y: 100), in: nil)
        poll.invalidate()
        completion?.resume(returning: matched)
        completion = nil
    }

    @objc private func check() {
        matched = ready()
        if matched || Date() >= deadline { menu.cancelTracking() }
    }
}

extension XCTestCase {
    @MainActor func showMenu(_ menu: NSMenu, timeout: TimeInterval = 3,
                            until ready: @escaping () -> Bool = { true },
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        var matched = false
        repeat {
            // 履歴などの動的項目は開く時点で再構築される。サービスの更新より先に
            // 開いたメニューを保持し続けず、同じ期限内で開き直して検査する。
            matched = await MenuInteraction(menu: menu, timeout: min(0.2, max(0, deadline.timeIntervalSinceNow)), ready: ready).run()
            if !matched { try? await Task.sleep(for: .milliseconds(20)) }
        } while !matched && Date() < deadline
        let state = menu.items.map { "\($0.title): \($0.action.map(NSStringFromSelector) ?? "nil"), enabled=\($0.isEnabled)" }
        XCTAssertTrue(matched, "表示中のメニューが期待した状態にならない: \(menu.title)\n" + state.joined(separator: "\n"), file: file, line: line)
    }

    @MainActor func menuItem(_ action: Selector, in menu: NSMenu, file: StaticString = #filePath,
                             line: UInt = #line) throws -> NSMenuItem {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == action { return item }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        return try XCTUnwrap(find(menu), "メニューに \(action) がない", file: file, line: line)
    }

    @MainActor func performMenuItem(_ item: NSMenuItem, file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        let menu = try XCTUnwrap(item.menu, file: file, line: line)
        menu.update()
        _ = try XCTUnwrap(item.isEnabled ? item : nil, "無効なメニュー項目: \(item.title)", file: file, line: line)
        let action = try XCTUnwrap(item.action, file: file, line: line)
        _ = try XCTUnwrap(NSApp.target(forAction: action, to: item.target, from: item),
                          "action の送り先がない: \(item.title)", file: file, line: line)
        menu.performActionForItem(at: menu.index(of: item))
    }

    @MainActor func preserveApplicationMenus() {
        let main = NSApp.mainMenu, services = NSApp.servicesMenu, windows = NSApp.windowsMenu, help = NSApp.helpMenu
        addTeardownBlock { @MainActor in
            NSApp.mainMenu = main
            NSApp.servicesMenu = services
            NSApp.windowsMenu = windows
            NSApp.helpMenu = help
        }
    }
}
