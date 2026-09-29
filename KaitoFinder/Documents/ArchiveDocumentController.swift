import AppKit
import KaitoKit

/// Finder の関連付けを増やさず、アプリ内では分割巻を文書として開く。
class ArchiveDocumentController: NSDocumentController {
    var volumeRecoveryIndex = RecoverableWorkIndex.shared
    var volumeMetadataStore = ArchiveVolumeMetadataStore.shared
    var volumeRecoveryError: (ArchiveVolumeOpenRecovery) -> NSError = { ArchiveVolumeOpenError(recovery: $0).presentedError }
    nonisolated static let splitVolumeType = "com.shunnag.KaitoFinder.split-volume"
    var openingRevealDelay = ArchiveProgressTiming.revealDelay
    #if DEBUG
    var preopenWillStart: (@Sendable () async throws -> Void)?
    var preopenDidFinish: ((ArchiveDocument.PreopenedArchive) throws -> Void)?
    var preopenWillMakeDocument: ((URL, String) throws -> Void)?
    var recordsRecentDocuments = true

    override func noteNewRecentDocumentURL(_ url: URL) {
        if recordsRecentDocuments { super.noteNewRecentDocumentURL(url) }
    }
    #endif

    private struct OpenRequest {
        let display: Bool
        let completion: (NSDocument?, Bool, (any Error)?) -> Void
    }
    private final class Opening {
        var requests: [OpenRequest]
        let progress = Progress(totalUnitCount: 0)
        let sheet: ExtractionProgressSheet
        var task: Task<Void, Never>?
        var contents: ArchiveDocument.PreopenedArchive?
        var failure: NSError?

        init(url: URL, request: OpenRequest, delay: Duration) {
            requests = [request]
            sheet = ExtractionProgressSheet(progress: progress,
                title: ArchiveProgressOperation.openingArchive(url.lastPathComponent).title(), revealDelay: delay)
        }
    }
    private var openings: [URL: Opening] = [:]
    private var nextOpeningPanelPoint: NSPoint?

    func openingSheet(for url: URL) -> ExtractionProgressSheet? {
        openings[ArchiveSplitVolume.gateURL(for: url).standardizedFileURL]?.sheet
    }

    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        let opening = openings[ArchiveSplitVolume.gateURL(for: url).standardizedFileURL]
        let result: Result<ArchiveDocument.PreopenedArchive, NSError>? =
            opening?.failure.map { .failure($0) } ?? opening?.contents.map { .success($0) }
        return try ArchiveDocument.preopenedArchive.withValue(result) {
            #if DEBUG
            try preopenWillMakeDocument?(url, typeName)
            #endif
            return try super.makeDocument(withContentsOf: url, ofType: typeName)
        }
    }

    override func typeForContents(of url: URL) throws -> String {
        let type = try super.typeForContents(of: url)
        if documentClass(forType: type) == nil, ArchiveSplitVolume.isOpenableName(url.lastPathComponent) {
            return Self.splitVolumeType
        }
        return type
    }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        // 既存文書の検索は回復の探索より先に行う。この文書の publisher が gate を隠している間も同じ。
        let gate = ArchiveSplitVolume.gateURL(for: url)
        let canonicalParent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let parsed = ArchiveVolumeSet.parse(fileName: url.lastPathComponent)
        if let existing = document(for: gate) ?? documents.first(where: { document in
            guard let source = document.fileURL,
                  source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == canonicalParent,
                  let parsed, case .numbered(let stem, _) = parsed.scheme,
                  let sourcePart = ArchiveVolumeSet.parse(fileName: source.lastPathComponent),
                  case .numbered(let sourceStem, _) = sourcePart.scheme else { return false }
            return stem == sourceStem && parsed.scheme == sourcePart.scheme
        }) {
            if displayDocument {
                if existing.windowControllers.isEmpty { existing.makeWindowControllers() }
                existing.showWindows()
            }
            if let url = existing.fileURL { noteNewRecentDocumentURL(url) }
            completionHandler(existing, true, nil)
            return
        }
        do {
            if let recovery = try ArchiveVolumeOpenRecovery.discover(url, index: volumeRecoveryIndex, metadataStore: volumeMetadataStore) {
                completionHandler(nil, false, volumeRecoveryError(recovery))
                return
            }
        } catch { completionHandler(nil, false, error); return }
        let key = gate.standardizedFileURL
        let request = OpenRequest(display: displayDocument, completion: completionHandler)
        if let opening = openings[key] {
            opening.requests.append(request)
            return
        }
        let opening = Opening(url: gate, request: request, delay: openingRevealDelay)
        openings[key] = opening
        let preferences = ArchivePreferencesStore.shared.preferences
        let metadataStore = volumeMetadataStore, recoveryIndex = volumeRecoveryIndex
        let task = Task {
            do {
                #if DEBUG
                try await preopenWillStart?()
                #endif
                let contents = try await ArchiveDocument.preopen(gate, preferences: preferences,
                    metadataStore: metadataStore, recoveryIndex: recoveryIndex)
                opening.contents = contents
                #if DEBUG
                try preopenDidFinish?(contents)
                #endif
                // cancel() が cancellationHandler を別キューで呼ぶ場合も、引き渡し前に止める。
                if opening.progress.isCancelled { throw CancellationError() }
                try Task.checkCancellation()
            } catch {
                opening.sheet.finish()
                await opening.contents?.close()
                if opening.progress.isCancelled || Task.isCancelled || error is CancellationError {
                    finishOpening(key, opening: opening, document: nil, wasOpen: false,
                        error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                    return
                }
                opening.failure = error as NSError
            }
            opening.sheet.finish()
            opening.progress.cancellationHandler = nil
            let display = opening.requests.contains(where: \.display)
            let (document, wasOpen, error) = await openPreopenedDocument(gate, display: display)
            await opening.contents?.close()
            if let document, !display, opening.requests.contains(where: \.display) {
                if document.windowControllers.isEmpty { document.makeWindowControllers() }
                document.showWindows()
            }
            finishOpening(key, opening: opening, document: document, wasOpen: wasOpen, error: error)
        }
        opening.task = task
        opening.progress.cancellationHandler = { task.cancel() }
        opening.sheet.beginStandalone()
        if let window = opening.sheet.window {
            let point = nextOpeningPanelPoint ?? NSPoint(x: window.frame.minX, y: window.frame.maxY)
            nextOpeningPanelPoint = window.cascadeTopLeft(from: point)
        }
    }

    private func openPreopenedDocument(_ url: URL, display: Bool) async -> (NSDocument?, Bool, (any Error)?) {
        await withCheckedContinuation { continuation in
            super.openDocument(withContentsOf: url, display: display) { document, wasOpen, error in
                continuation.resume(returning: (document, wasOpen, error))
            }
        }
    }

    private func finishOpening(_ key: URL, opening: Opening, document: NSDocument?, wasOpen: Bool, error: (any Error)?) {
        openings[key] = nil
        if openings.isEmpty { nextOpeningPanelPoint = nil }
        opening.task = nil
        opening.contents = nil
        opening.progress.cancellationHandler = nil
        let requests = opening.requests
        opening.requests.removeAll()
        for (index, request) in requests.enumerated() {
            request.completion(document, document != nil && (wasOpen || index > 0), error)
        }
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        ArchiveOpenPanelDelegate.install(on: openPanel)
        super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
    }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        ArchiveOpenPanelDelegate.install(on: openPanel)
        return super.runModalOpenPanel(openPanel, forTypes: nil)
    }
}
