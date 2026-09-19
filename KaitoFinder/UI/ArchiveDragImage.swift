import AppKit

/// ドラッグ中にカーソルへ付いてくる項目の画像。行のセルビュー（画面外の行では配置されておらず、
/// 既定のドラッグ画像が崩れる）に依存せず、アイコンと名前だけで組み立てる。
enum ArchiveDragImage {
    static let iconSize: CGFloat = 16
    static let iconInset: CGFloat = 4
    static let labelSpacing: CGFloat = 6
    static let maximumLabelWidth: CGFloat = 320

    struct Layout {
        let iconFrame: NSRect
        let labelFrame: NSRect
        var width: CGFloat { labelFrame.maxX + labelSpacing }
    }

    static func layout(name: String, height: CGFloat, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)) -> Layout {
        let textWidth = min(maximumLabelWidth, ceil((name as NSString).size(withAttributes: [.font: font]).width) + 2)
        let icon = NSRect(x: iconInset, y: ((height - iconSize) / 2).rounded(.down), width: iconSize, height: iconSize)
        let label = NSRect(x: icon.maxX + labelSpacing, y: 0, width: textWidth, height: height)
        return Layout(iconFrame: icon, labelFrame: label)
    }

    static func components(icon: NSImage, name: String, height: CGFloat,
                           font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)) -> [NSDraggingImageComponent] {
        let layout = layout(name: name, height: height, font: font)
        let iconComponent = NSDraggingImageComponent(key: .icon)
        iconComponent.contents = icon
        iconComponent.frame = layout.iconFrame
        let labelComponent = NSDraggingImageComponent(key: .label)
        labelComponent.contents = labelImage(name, size: layout.labelFrame.size, font: font)
        labelComponent.frame = layout.labelFrame
        return [iconComponent, labelComponent]
    }

    /// 名前を一行で描いた画像。長い名前は末尾を省略する。
    static func labelImage(_ name: String, size: NSSize, font: NSFont) -> NSImage {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return NSImage(size: size, flipped: false) { rect in
            let y = ((rect.height - lineHeight) / 2).rounded(.down)
            (name as NSString).draw(in: NSRect(x: 0, y: y, width: rect.width, height: lineHeight), withAttributes: attributes)
            return true
        }
    }
}
