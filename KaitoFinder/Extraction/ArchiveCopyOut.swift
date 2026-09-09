import AppKit

@MainActor enum ArchiveCopyOut {
    static let progressThreshold: UInt64 = 32 * 1024 * 1024

    static func requiresProgress(_ selection: ExtractionSelection) -> Bool {
        var size: UInt64 = 0
        for entry in selection.entries {
            guard let bytes = entry.uncompressedSize else { return true }
            let sum = size.addingReportingOverflow(bytes)
            if sum.overflow || sum.partialValue >= progressThreshold { return true }
            size = sum.partialValue
        }
        return false
    }

    nonisolated static func check(_ result: ExtractionResult) throws {
        if result.cancelled || Task.isCancelled { throw CancellationError() }
        if !result.failures.isEmpty {
            throw ExtractionFailure.refused(result.failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n"))
        }
    }

    nonisolated struct Prepared: Sendable {
        let urls: [URL]
        let paths: [String]
    }

    /// 公開前に全項目を実体化し、失敗・取消しなら URL の組を返さない。
    @concurrent static func prepare(_ payloads: [ArchiveEntryPayload], from session: ArchiveSession,
                                   progress: Progress,
                                   temporaryDirectory: ExtractionTemporaryDirectory = ExtractionTemporaryDirectory(),
                                   didProcess: (@Sendable (Int) -> Void)? = nil) async throws -> Prepared {
        if progress.isCancelled || Task.isCancelled { throw CancellationError() }
        guard !payloads.isEmpty else { return Prepared(urls: [], paths: []) }
        let destination = try temporaryDirectory.create()
        let result = try await ExtractionService.extract(payloads, from: session, to: destination,
            progress: progress, didProcess: didProcess)
        try check(result)
        if progress.isCancelled { throw CancellationError() }
        let urls = try payloads.map { payload in
            try ExtractionPath.components(payload.path).reduce(destination) { $0.appendingPathComponent($1) }
        }
        return Prepared(urls: urls, paths: payloads.map(\.path))
    }

    /// 成功するまで pasteboard に触れない。URL の寿命は次回起動時の sweep が管理する。
    static func copy(_ payloads: [ArchiveEntryPayload], from session: ArchiveSession,
                     to pasteboard: NSPasteboard, progress: Progress,
                     temporaryDirectory: ExtractionTemporaryDirectory = ExtractionTemporaryDirectory(),
                     didProcess: (@Sendable (Int) -> Void)? = nil) async throws -> [URL] {
        let prepared = try await prepare(payloads, from: session, progress: progress,
            temporaryDirectory: temporaryDirectory, didProcess: didProcess)
        if progress.isCancelled || Task.isCancelled { throw CancellationError() }
        guard !prepared.urls.isEmpty else { return [] }
        let urls = prepared.urls
        let text = prepared.paths.joined(separator: "\n")
        let items = urls.enumerated().map { index, url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            // 一つ目は全選択の文字列にし、テキストの通常の paste でも全項目を得る。
            item.setString(index == 0 ? text : prepared.paths[index], forType: .string)
            return item
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { throw ExtractionFailure.refused("クリップボードへ書き込めません") }
        return urls
    }
}
