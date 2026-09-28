import AppKit
import XCTest

/// OS が与える drag 情報だけを差し替え、pasteboard → validateDrop・acceptDrop → 文書更新は実物を使う。
/// `pasteboardReads` は `draggingPasteboard` が読まれた回数。
@MainActor final class TestDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    private(set) var pasteboardReads = 0
    var draggingPasteboard: NSPasteboard { pasteboardReads += 1; return pasteboard }
    var draggingDestinationWindow: NSWindow?
    var draggingSource: Any?
    var draggingSourceOperationMask: NSDragOperation
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    /// 一意の pasteboard を作り、`urls` があれば書き込む（書けなければ失敗にする）。
    init(urls: [URL] = [], window: NSWindow? = nil, location: NSPoint = .zero, operationMask: NSDragOperation = .copy) {
        pasteboard = .withUniqueName()
        draggingDestinationWindow = window
        draggingLocation = location
        draggingSourceOperationMask = operationMask
        super.init()
        if !urls.isEmpty { XCTAssertTrue(pasteboard.writeObjects(urls.map { $0 as NSURL })) }
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
