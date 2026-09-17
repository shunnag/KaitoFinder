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
    private struct Received {
        let url: URL
        let index: Int
        let originalPath: String?
    }
    private struct State {
        var remaining = 0
        var files: [Received] = []
        var failures: [String] = []
        var resolvedURLs: [URL]?
        var originalPaths: [URL: String] = [:]
    }
    private let state = Mutex(State())
    private let directory: URL
    private let queue = OperationQueue()

    @MainActor init(receivers: [NSFilePromiseReceiver], originalPaths: [String]? = nil) throws {
        if let originalPaths, originalPaths.count != receivers.count { throw ArchiveEditError.staleSelection }
        directory = try ExtractionTemporaryDirectory().create()
        queue.name = "com.shunnag.KaitoFinder.receive"
        queue.qualityOfService = .userInitiated
        // acceptDrop の同期呼出し中に要求を開始する。Task に移すと AppKit が拒否する。
        let directory = self.directory
        for (index, receiver) in receivers.enumerated() {
            let originalPath = originalPaths?[index]
            // AppKit は指定した背景 queue で callback を呼ぶ。@Sendable を明示しないと
            // init の MainActor を継承し、書庫間ドロップで実行時の隔離検査が trap する。
            // AppKit の契約上、一つの drag 内の全 receiver は同じ保存先を指定する。
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { @Sendable [self] url, error in
                state.withLock {
                    if let error { $0.failures.append(ArchiveErrorText.describe(error)) }
                    else if ExtractionPath.isInside(url, root: directory) {
                        $0.files.append(Received(url: url, index: index, originalPath: originalPath))
                    }
                    else { $0.failures.append(String(localized: "promiseの出力が一時領域の外を指しています。")) }
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

    func originalPath(for url: URL) -> String? { state.withLock { $0.originalPaths[url] } }

    @concurrent func receive(progress: Progress) async throws -> [URL] {
        while state.withLock({ $0.remaining > 0 }) {
            try ArchiveImportPlan.checkCancellation(progress)
            try await Task.sleep(for: .milliseconds(50))
        }
        try ArchiveImportPlan.checkCancellation(progress)
        return try state.withLock {
            guard $0.failures.isEmpty else { throw ExtractionFailure.refused($0.failures.joined(separator: "\n")) }
            if let urls = $0.resolvedURLs { return urls }
            var urls: [URL] = []
            let files = $0.files.sorted { $0.index == $1.index ? $0.url.path < $1.url.path : $0.index < $1.index }
            for file in files {
                try ArchiveImportPlan.checkCancellation(progress)
                guard let path = file.originalPath, let name = ArchivePath.components(path).last else { urls.append(file.url); continue }
                // AppKit は same.txt / same 2.txt と改名する。アプリ内では元の名前を
                // 個別領域に復元し、追加側の比較・置き換えの選択を通す。
                let leaf = try ArchiveImportPlan.path(name)
                guard ArchivePath.components(leaf).count == 1 else { throw ArchiveEditError.invalidName(name) }
                let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let url = folder.appendingPathComponent(leaf)
                try FileManager.default.moveItem(at: file.url, to: url)
                urls.append(url)
                $0.originalPaths[url] = path
            }
            $0.resolvedURLs = urls
            return urls
        }
    }
}
