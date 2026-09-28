import AppKit

// NSPathControlItem は representedObject を持たず、SDK はサブクラス化も認めていない。
// URL を書庫内パスに偽装せず、表示中の node 自体を項目に結び付ける。
@MainActor extension NSPathControlItem {
    private static var representedObjectKey: UInt8 = 0

    var representedObject: Any? {
        get { objc_getAssociatedObject(self, &Self.representedObjectKey) }
        set { objc_setAssociatedObject(self, &Self.representedObjectKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
