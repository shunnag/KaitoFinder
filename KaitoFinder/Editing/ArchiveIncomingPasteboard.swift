import AppKit

nonisolated enum ArchiveIncomingRepresentation {
    case promises, fileURLs, none
    static func choose(hasPromises: Bool, hasFileURLs: Bool) -> Self {
        hasPromises ? .promises : hasFileURLs ? .fileURLs : .none
    }
}

/// データの取り出しと型の照会を分離し、サービスなしでも呼出し順を検証する。
nonisolated protocol ArchivePasteboardSource {
    associatedtype Promise
    var hasPromises: Bool { get }
    var hasFileURLs: Bool { get }
    func readPromises() -> [Promise]
    func readFileURLs() -> [URL]
}

nonisolated struct AppKitArchivePasteboard: ArchivePasteboardSource {
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
