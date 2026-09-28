import AppKit
import GyoshukuKit
import KaitoKit
import XCTest
@testable import KaitoFinder

/// OS が与える drag 情報だけを差し替え、pasteboard → acceptDrop → 文書更新は実物を使う。
@MainActor final class FileURLDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    var draggingSource: Any?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(urls: [URL], window: NSWindow?, location: NSPoint) {
        draggingPasteboard = .withUniqueName()
        draggingDestinationWindow = window
        draggingLocation = location
        super.init()
        if !urls.isEmpty { XCTAssertTrue(draggingPasteboard.writeObjects(urls.map { $0 as NSURL })) }
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
