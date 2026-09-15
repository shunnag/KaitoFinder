import AppKit
import UniformTypeIdentifiers
import XCTest

/// 画面収録権限を使わず、テスト内で構築したビューを描画する。
@MainActor enum UISnapshot {
    static var directory: URL { runDirectory }

    private static let runDirectory: URL = {
        let url: URL
        if let path = ProcessInfo.processInfo.environment["KAITOFINDER_SNAPSHOT_DIR"], !path.isEmpty {
            url = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("KaitoFinderSnapshots", isDirectory: true)
                .appendingPathComponent(timestamp, isDirectory: true)
        }
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { XCTFail("スナップショット保存先を作成できません: \(error)") }
        print("KaitoFinder UI snapshots: \(url.path)")
        return url
    }()

    private enum SnapshotError: Error {
        case emptyBounds(String)
        case bitmapUnavailable(String)
        case pngUnavailable(String)
        case missingContentView(String)
    }

    @discardableResult static func render(_ view: NSView, name: String) throws -> URL {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else {
            throw SnapshotError.emptyBounds(name)
        }
        guard var bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError.bitmapUnavailable(name)
        }
        let width = Int(ceil(bounds.width * 2)), height = Int(ceil(bounds.height * 2))
        // 接続中の画面の倍率に依存せず、常にポイント数の2倍の画素で保存する。
        if bitmap.pixelsWide != width || bitmap.pixelsHigh != height {
            guard let scaled = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw SnapshotError.bitmapUnavailable(name)
            }
            bitmap = scaled
        }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        // 透明なコンテンツビューにもウインドウの地色を敷き、画像単体で文字を読めるようにする。
        guard let cachedImage = bitmap.cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SnapshotError.bitmapUnavailable(name)
        }
        let pixels = CGRect(x: 0, y: 0, width: width, height: height)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            context.fill(pixels)
            if let background = view.window?.backgroundColor {
                context.setFillColor(background.cgColor)
                context.fill(pixels)
            }
        }
        context.draw(cachedImage, in: pixels)
        guard let composed = context.makeImage() else { throw SnapshotError.bitmapUnavailable(name) }
        let result = NSBitmapImageRep(cgImage: composed)
        result.size = bounds.size
        guard let png = result.representation(using: .png, properties: [:]) else {
            throw SnapshotError.pngUnavailable(name)
        }
        let filename = name.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? String($0) : "_" }.joined()
        let url = directory.appendingPathComponent(filename + ".png")
        try png.write(to: url, options: .atomic)
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(contentsOfFile: url, uniformTypeIdentifier: UTType.png.identifier)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        return url
    }

    @discardableResult static func render(_ window: NSWindow, name: String) throws -> URL {
        window.layoutIfNeeded()
        guard let content = window.contentView else { throw SnapshotError.missingContentView(name) }
        return try render(content, name: name)
    }

    @discardableResult static func render(_ alert: NSAlert, name: String) throws -> URL {
        alert.layout()
        return try render(alert.window, name: name)
    }

    /// 内容の必要サイズと親の表示領域を調べ、位置と文言付きで違反を返す。
    static func overflowViolations(in root: NSView) -> [String] {
        root.layoutSubtreeIfNeeded()
        var violations: [String] = []
        let tolerance: CGFloat = 0.5

        func checkSize(_ required: NSSize, of view: NSView, path: String) {
            if required.width > view.bounds.width + tolerance {
                violations.append("\(path): 内容の幅\(required.width) > 表示幅\(view.bounds.width)")
            }
            if required.height > view.bounds.height + tolerance {
                violations.append("\(path): 内容の高さ\(required.height) > 表示高\(view.bounds.height)")
            }
        }

        func visit(_ view: NSView, path: String) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            let description: String
            if let field = view as? NSTextField {
                // パスワード値は診断文にも含めない。
                description = field is NSSecureTextField ? "<パスワード>" : field.stringValue
            } else if let button = view as? NSButton { description = button.title }
            else { description = view.identifier?.rawValue ?? "" }
            let location = path + " " + String(reflecting: type(of: view)) + " 「\(description)」"
            if view !== root, let parent = view.superview, !(parent is NSScrollView), !(parent is NSClipView) {
                let area = parent.bounds.insetBy(dx: -tolerance, dy: -tolerance)
                if !area.contains(view.frame) {
                    violations.append("\(location): 枠\(view.frame)が親の領域\(parent.bounds)を越えています")
                }
            }
            if let field = view as? NSTextField {
                if field.cell?.wraps == true, !field.usesSingleLineMode {
                    let size = field.sizeThatFits(NSSize(width: field.bounds.width, height: .greatestFiniteMagnitude))
                    checkSize(NSSize(width: NSView.noIntrinsicMetric, height: size.height), of: field, path: location)
                } else { checkSize(field.intrinsicContentSize, of: field, path: location) }
            } else if let popup = view as? NSPopUpButton {
                checkSize(popup.intrinsicContentSize, of: popup, path: location)
            } else if let button = view as? NSButton {
                checkSize(button.intrinsicContentSize, of: button, path: location)
            }
            for (index, child) in view.subviews.enumerated() { visit(child, path: location + "/\(index)") }
        }

        visit(root, path: "root")
        return violations
    }
}
