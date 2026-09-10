import AppKit
import Synchronization

nonisolated enum ArchiveIncomingRepresentation {
    case promises, fileURLs, none
    static func choose(hasPromises: Bool, hasFileURLs: Bool) -> Self {
        hasPromises ? .promises : hasFileURLs ? .fileURLs : .none
    }
}

/// データの取り出しと型の照会を分離し、サービスなしでも呼出し順を検証する。
protocol ArchivePasteboardSource {
    associatedtype Promise
    var hasPromises: Bool { get }
    var hasFileURLs: Bool { get }
    func readPromises() -> [Promise]
    func readFileURLs() -> [URL]
}

struct AppKitArchivePasteboard: ArchivePasteboardSource {
    let pasteboard: NSPasteboard
    var hasPromises: Bool { pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) }
    var hasFileURLs: Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
    func readPromises() -> [NSFilePromiseReceiver] {
        (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
    }
    func readFileURLs() -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}

/// 検査は型だけを見る。readObjects は実際の drop / paste の実行時だけ。
enum ArchiveIncomingPasteboard {
    enum Contents<Promise> {
        case promises([Promise]), fileURLs([URL]), none
    }
    static func canPaste(_ source: some ArchivePasteboardSource) -> Bool { source.hasFileURLs }
    static func representation(_ source: some ArchivePasteboardSource) -> ArchiveIncomingRepresentation {
        // promise があれば NSURL の照会さえ不要。
        if source.hasPromises { return .promises }
        return ArchiveIncomingRepresentation.choose(hasPromises: false, hasFileURLs: source.hasFileURLs)
    }
    static func readDrop<Source: ArchivePasteboardSource>(_ source: Source) -> Contents<Source.Promise> {
        switch representation(source) {
        case .promises: .promises(source.readPromises())
        case .fileURLs: .fileURLs(source.readFileURLs())
        case .none: .none
        }
    }
    static func readPaste(_ source: some ArchivePasteboardSource) -> [URL] { source.readFileURLs() }
}

/// callback が残る間は一時領域も保持する。取消しで供給元の書き込み先を先に消さない。
nonisolated final class ArchiveIncomingFiles: Sendable {
    private struct State {
        var remaining = 0
        var urls: [URL] = []
        var failures: [String] = []
    }
    private let state = Mutex(State())
    private let directory: URL
    private let queue = OperationQueue()

    @MainActor init(receivers: [NSFilePromiseReceiver]) throws {
        directory = try ExtractionTemporaryDirectory().create()
        queue.name = "com.shunnag.KaitoFinder.receive"
        queue.qualityOfService = .userInitiated
        // acceptDrop の同期呼出し中に要求を開始する。Task に移すと AppKit が拒否する。
        let directory = self.directory
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { [self] url, error in
                state.withLock {
                    if let error { $0.failures.append(String(describing: error)) }
                    else if ExtractionPath.isInside(url, root: directory) { $0.urls.append(url) }
                    else { $0.failures.append("promise の出力が一時領域の外を指しています") }
                    $0.remaining -= 1
                }
            }
            // fileNames は receive の呼出し後に確定する。fileTypes は旧形式では件数を表さない。
            // callback が先着して remaining を減らしていても、加算なので通知を失わない。
            state.withLock { $0.remaining += max(1, receiver.fileNames.count) }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func receive(progress: Progress) async throws -> [URL] {
        while state.withLock({ $0.remaining > 0 }) {
            try ArchiveImportPlan.checkCancellation(progress)
            try await Task.sleep(for: .milliseconds(50))
        }
        try ArchiveImportPlan.checkCancellation(progress)
        return try state.withLock {
            guard $0.failures.isEmpty else { throw ExtractionFailure.refused($0.failures.joined(separator: "\n")) }
            return $0.urls.sorted { $0.path < $1.path }
        }
    }
}
