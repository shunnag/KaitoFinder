import AppKit

final class ArchiveDocumentWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if ExtractionProgressSheet.consumePendingInput(event, on: self) { return }
        super.sendEvent(event)
    }
}
