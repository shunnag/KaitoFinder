import Darwin
import Foundation
import KaitoKit

nonisolated struct ExtractionSelection: Sendable {
    let entries: [ArchiveEntry]

    init(entries: [ArchiveEntry]) {
        self.entries = entries.sorted { $0.index < $1.index }
    }

    // UI の参照型はここで値へ変換し、worker へ持ち込まない。
    @MainActor init(nodes: [EntryNode]) {
        var pending = nodes
        var selected: [Int: ArchiveEntry] = [:]
        while let node = pending.popLast() {
            for entry in node.representedEntries { selected[entry.index] = entry }
            pending.append(contentsOf: node.children)
        }
        entries = selected.values.sorted { $0.index < $1.index }
    }
}

nonisolated struct ExtractionResult: Sendable {
    struct WrittenItem: Sendable {
        struct Identity: Equatable, Sendable {
            let device: UInt64
            let inode: UInt64

            init(_ info: stat) {
                device = UInt64(bitPattern: Int64(info.st_dev))
                inode = UInt64(info.st_ino)
            }
        }

        let entryIndex: Int?
        let url: URL
        let identity: Identity?

        init(entryIndex: Int?, url: URL, identity: Identity? = nil) {
            self.entryIndex = entryIndex
            self.url = url
            self.identity = identity
        }

        func matches(_ info: stat) -> Bool {
            identity == nil || identity == Identity(info)
        }
    }
    struct Failure: Sendable {
        let entryIndex: Int
        let name: String
        let reason: String
    }
    var written: [WrittenItem] = []
    var failures: [Failure] = []
    var cancelled = false
}

nonisolated enum ExtractionFailure: Error, CustomStringConvertible {
    case refused(String)
    case system(Int32)

    var description: String {
        switch self {
        case .refused(let reason): reason
        case .system(let code): String(localized: "POSIX \(code): \(String(cString: strerror(code)))")
        }
    }
}

nonisolated enum ExtractionService {
    /// 出力 root は既存の実ディレクトリ。選択の書庫内相対パスを維持する。
    /// 呼出側は完了まで root を排他的に所有する。既存の葉は上書きしない。
    /// M1a は要求全体を一 worker にまとめ、solid group と部分木を分断しない。
    /// 進捗は処理済み entry 数（失敗を含む）。didProcess は同じ worker で同期的に呼ぶ。
    /// reader/root の準備失敗だけを throw し、entry の失敗と取り消しは戻り値で報告する。
    @concurrent static func extract(
        _ selection: ExtractionSelection,
        from session: ArchiveSession,
        to destination: URL,
        progress: Progress = Progress(totalUnitCount: 0),
        didProcess: (@Sendable (Int) -> Void)? = nil
    ) async throws -> ExtractionResult {
        if session.usesPendingReading {
            guard let snapshot = session.pendingReadSnapshot else { throw ArchiveEntryPayload.staleSelection }
            return try await extract(selection.entries.map { snapshot.payload(for: $0, archive: session.sourceURL) },
                                     from: session, to: destination, progress: progress, didProcess: didProcess)
        }
        progress.kind = .file
        progress.setUserInfoObject(Progress.FileOperationKind.copying, forKey: .fileOperationKindKey)
        progress.setUserInfoObject(destination, forKey: .fileURLKey)
        progress.totalUnitCount = Int64(selection.entries.count)
        progress.completedUnitCount = 0
        progress.setUserInfoObject(selection.entries.count, forKey: .fileTotalCountKey)
        progress.setUserInfoObject(0, forKey: .fileCompletedCountKey)
        let snapshot = try await session.extractionSnapshot()
        // この同期呼出しの中で reader と全 stream の寿命が閉じる。
        return try run(selection.entries, reader: snapshot.reader, destination: destination,
                       quarantine: snapshot.quarantine, progress: progress, didProcess: didProcess)
    }

    /// 世代の再解決と reader の取得は session 内で不可分に行う。
    @concurrent static func extract(
        _ payloads: [ArchiveEntryPayload], from session: ArchiveSession, to destination: URL,
        progress: Progress, promisedItem: ArchiveEntryPayload? = nil,
        readOnly: Bool = false, didWrite: (@Sendable (Int) -> Void)? = nil,
        didProcess: (@Sendable (Int) -> Void)? = nil
    ) async throws -> ExtractionResult {
        if progress.isCancelled || Task.isCancelled { throw CancellationError() }
        if session.usesPendingReading || payloads.contains(where: { $0.revision != nil }) {
            return try await extractPending(payloads, from: session, to: destination, progress: progress,
                promisedItem: promisedItem, readOnly: readOnly, didWrite: didWrite, didProcess: didProcess)
        }
        let snapshot = try await session.resolveForExtraction(payloads)
        if readOnly {
            for entry in snapshot.selection.entries {
                let capability = EntryReadCapability(entry: entry, isDirectory: entry.kind == .directory,
                                                     format: snapshot.reader.format)
                if let reason = capability.reason { throw ExtractionFailure.refused(reason) }
            }
        }
        progress.kind = .file
        progress.totalUnitCount = Int64(snapshot.selection.entries.count)
        progress.completedUnitCount = 0
        progress.setUserInfoObject(Progress.FileOperationKind.copying, forKey: .fileOperationKindKey)
        progress.setUserInfoObject(destination, forKey: .fileURLKey)
        progress.setUserInfoObject(snapshot.selection.entries.count, forKey: .fileTotalCountKey)
        progress.setUserInfoObject(0, forKey: .fileCompletedCountKey)
        let root: URL
        let mapping: OutputMapping
        if let item = promisedItem {
            guard destination.isFileURL else { throw ExtractionFailure.refused(String(localized: "出力先はfile URLが必要です。")) }
            let parent = try ExtractionDestination(url: destination.deletingLastPathComponent(), quarantine: snapshot.quarantine)
            let leaf = [destination.lastPathComponent]
            try parent.validate(leaf)
            if item.isDirectory {
                if progress.isCancelled || Task.isCancelled { throw CancellationError() }
                try parent.directory(leaf, explicit: true)
                root = destination
                mapping = .subtree(try ExtractionPath.components(item.path))
            } else {
                root = destination.deletingLastPathComponent()
                mapping = .file(leaf)
            }
        } else {
            root = destination
            mapping = .archive
        }
        return try run(snapshot.selection.entries, reader: snapshot.reader, destination: root,
                       quarantine: snapshot.quarantine, progress: progress, mapping: mapping,
                       readOnly: readOnly, didWrite: didWrite, didProcess: didProcess)
    }

    @concurrent private static func extractPending(
        _ payloads: [ArchiveEntryPayload], from session: ArchiveSession, to destination: URL,
        progress: Progress, promisedItem: ArchiveEntryPayload?, readOnly: Bool,
        didWrite: (@Sendable (Int) -> Void)?, didProcess: (@Sendable (Int) -> Void)?
    ) async throws -> ExtractionResult {
        let snapshot = try await session.resolvePendingForExtraction(payloads)
        defer { withExtendedLifetime(snapshot.lease) {} }
        let entries = snapshot.selection.entries
        if readOnly {
            for entry in entries {
                if let reason = EntryReadCapability(entry: entry, isDirectory: entry.kind == .directory,
                                                    format: snapshot.reader.format).reason { throw ExtractionFailure.refused(reason) }
            }
        }
        progress.kind = .file
        progress.totalUnitCount = Int64(entries.count)
        progress.completedUnitCount = 0
        progress.setUserInfoObject(Progress.FileOperationKind.copying, forKey: .fileOperationKindKey)
        progress.setUserInfoObject(destination, forKey: .fileURLKey)
        progress.setUserInfoObject(entries.count, forKey: .fileTotalCountKey)
        progress.setUserInfoObject(0, forKey: .fileCompletedCountKey)
        let root: URL, mapping: OutputMapping
        var virtualRootParent: ExtractionDestination?
        if let item = promisedItem {
            guard payloads.contains(item), destination.isFileURL else { throw ArchiveEntryPayload.staleSelection }
            let parent = try ExtractionDestination(url: destination.deletingLastPathComponent(), quarantine: snapshot.quarantine)
            let leaf = [destination.lastPathComponent]
            try parent.validate(leaf)
            if item.isDirectory {
                try ArchiveImportPlan.checkCancellation(progress)
                try parent.directory(leaf, explicit: true)
                root = destination
                mapping = .subtree(try ExtractionPath.components(item.path))
                if item.entryIndex == nil { virtualRootParent = parent }
            } else { root = destination.deletingLastPathComponent(); mapping = .file(leaf) }
        } else { root = destination; mapping = .archive }
        let result = try run(entries, reader: snapshot.reader, destination: root, quarantine: snapshot.quarantine,
                       progress: progress, mapping: mapping, readOnly: readOnly, didWrite: didWrite,
                       didProcess: didProcess, sources: snapshot.snapshot.sources)
        if let virtualRootParent {
            // finalizer の root と同じ実パスを使う。/var と /private/var 等を混在させると
            // 相対成分の切り出しがずれ、約束したフォルダではなく親の mode を変更してしまう。
            try virtualRootParent.finishSynthesizedDirectory(virtualRootParent.url([destination.lastPathComponent]))
        }
        return result
    }

    private enum OutputMapping {
        case archive, subtree([String]), file([String])

        func components(_ name: String) throws -> [String] {
            let parts = try ExtractionPath.components(name)
            switch self {
            case .archive: return parts
            case .file(let leaf): return leaf
            case .subtree(let prefix):
                guard parts.starts(with: prefix) else { throw ExtractionFailure.refused(String(localized: "部分木の外の項目です。")) }
                return Array(parts.dropFirst(prefix.count))
            }
        }
    }

    private static func run(
        _ entries: [ArchiveEntry], reader: ArchiveReader, destination: URL,
        quarantine: Data?, progress: Progress, mapping: OutputMapping = .archive,
        readOnly: Bool = false, didWrite: (@Sendable (Int) -> Void)? = nil, didProcess: (@Sendable (Int) -> Void)?,
        sources: [Int: ArchivePendingReadSnapshot.Source]? = nil
    ) throws -> ExtractionResult {
        let output = try ExtractionDestination(url: destination, quarantine: quarantine, readOnly: readOnly, didWrite: didWrite)
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        var result = ExtractionResult()
        var claimed = Set<String>()
        var directories: [(ArchiveEntry, [String])] = []
        var materialized: [Int: [String]] = [:]
        func checkCancellation() throws {
            if progress.isCancelled || Task.isCancelled { throw CancellationError() }
        }
        for entry in entries {
            do {
                try checkCancellation()
                let original: ArchiveEntry
                let staged: ArchivePendingChanges.PendingAddition?
                switch sources?[entry.index] {
                case .base(let base): original = base; staged = nil; output.useQuarantine(quarantine)
                case .staged(let addition):
                    original = entry; staged = addition
                    try addition.stagedStamp.verify()
                    output.useQuarantine(quarantine)
                case .folder: original = entry; staged = nil; output.useQuarantine(quarantine)
                case nil: original = entry; staged = nil
                }
                if sources == nil || original.pendingID == nil {
                    guard reader.entries.indices.contains(original.index), reader.entries[original.index] == original else {
                        throw ExtractionFailure.refused(String(localized: "選択がこのアーカイブのentryと一致しません。"))
                    }
                }
                let components = try mapping.components(entry.name)
                let key = components.joined(separator: "/").precomposedStringWithCanonicalMapping
                // 最初の名前を予約し、失敗しても後続の同名 entry へ差し替えない。
                // Unicode 正規化で同じ名前も含む。大文字小文字の衝突は O_EXCL で防ぐ。
                guard claimed.insert(key).inserted else {
                    throw ExtractionFailure.refused(String(localized: "重複する出力名です（アーカイブ順で最初のentryを優先）。"))
                }
                // promise の明示フォルダ entry は今回作成した root 自身を表す。
                if components.isEmpty {
                    guard entry.kind == .directory else { throw ExtractionFailure.refused(String(localized: "rootがフォルダではありません。")) }
                } else { try output.validate(components) }
                switch entry.kind {
                case .directory:
                    if entry.pendingID == nil { try drain(reader.stream(original), buffer: &buffer, checkCancellation: checkCancellation) }
                    if !components.isEmpty { try output.directory(components, explicit: true) }
                    directories.append((entry, components))
                case .file:
                    if let staged {
                        try output.stagedFile(components, entry: entry, addition: staged, buffer: &buffer, checkCancellation: checkCancellation)
                    } else {
                        try output.file(components, entry: entry, stream: reader.stream(original), buffer: &buffer,
                                        checkCancellation: checkCancellation)
                    }
                    materialized[entry.index] = components
                case .symlink:
                    let target: String
                    if let staged {
                        target = try FileManager.default.destinationOfSymbolicLink(atPath: staged.stagedURL.path)
                        try staged.stagedStamp.verify()
                    } else if let retained = entry.formatSpecific["linkPath"] {
                        try drain(reader.stream(original), buffer: &buffer, checkCancellation: checkCancellation)
                        target = retained
                    } else if entry.formatSpecific["linkTargetStoredAsData"] == "true" {
                        var data = Data()
                        try consume(reader.stream(original), buffer: &buffer, checkCancellation: checkCancellation) { bytes in
                            guard data.count + bytes.count <= 16_384 else {
                                throw ExtractionFailure.refused(String(localized: "シンボリックリンクのtargetが長すぎます。"))
                            }
                            data.append(contentsOf: bytes)
                        }
                        guard let decoded = String(data: data, encoding: .utf8) else {
                            throw ExtractionFailure.refused(String(localized: "リンクのtargetがUTF-8ではありません。"))
                        }
                        target = decoded
                    } else {
                        throw ExtractionFailure.refused(String(localized: "リンクのtargetがありません。"))
                    }
                    try output.symlink(components, target: target, staged: staged)
                case .hardlink:
                    if sources != nil {
                        // 改名・削除済みの target も基底 index で辿る。Save の rewriter と同じ本文を独立して運ぶ。
                        var target = original
                        while target.kind == .hardlink, (target.compressedSize ?? target.uncompressedSize ?? 0) == 0 {
                            guard let index = target.formatSpecific["hardLinkTargetIndex"].flatMap(Int.init),
                                  index >= 0, index < target.index, reader.entries.indices.contains(index) else {
                                throw ArchiveEntryPayload.staleSelection
                            }
                            target = reader.entries[index]
                        }
                        try output.file(components, entry: entry, stream: reader.stream(target), buffer: &buffer,
                                        checkCancellation: checkCancellation)
                        materialized[entry.index] = components
                        break
                    }
                    // 本体付き hard link は既存 inode の内容を書き換えず、独立ファイルにする。
                    if (entry.compressedSize ?? entry.uncompressedSize ?? 0) > 0 {
                        try output.file(components, entry: entry, stream: reader.stream(entry), buffer: &buffer,
                                        checkCancellation: checkCancellation)
                    } else {
                        guard let index = entry.formatSpecific["hardLinkTargetIndex"].flatMap(Int.init),
                              let target = materialized[index], index < entry.index,
                              let targetName = entry.formatSpecific["linkPath"],
                              try mapping.components(targetName) == target else {
                            throw ExtractionFailure.refused(String(localized: "同じreaderとrootで先に展開したhard link targetがありません。"))
                        }
                        try drain(reader.stream(entry), buffer: &buffer, checkCancellation: checkCancellation)
                        try output.hardlink(components, target: target)
                    }
                    materialized[entry.index] = components
                case .other:
                    throw ExtractionFailure.refused(String(localized: "このentryの種類は展開できません。"))
                }
                let url = output.url(components)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
                result.written.append(.init(entryIndex: entry.index, url: url, identity: .init(info)))
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                result.failures.append(.init(entryIndex: entry.index, name: entry.name,
                                             reason: ArchiveErrorText.describe(error)))
            }
            progress.completedUnitCount += 1
            progress.setUserInfoObject(Int(progress.completedUnitCount), forKey: .fileCompletedCountKey)
            didProcess?(entry.index)
        }
        // 取り消し時も作成済みの directory の属性を仕上げる。
        for (entry, components) in directories.sorted(by: { $0.1.count > $1.1.count }) {
            do {
                if sources != nil {
                    switch sources?[entry.index] {
                    case .staged(let addition):
                        try addition.stagedStamp.verify()
                        output.useQuarantine(quarantine)
                    case .folder: output.useQuarantine(quarantine)
                    default: output.useQuarantine(quarantine)
                    }
                }
                try output.finishDirectory(components, entry: entry, appliesQuarantine: sources != nil)
            }
            catch {
                result.failures.append(.init(entryIndex: entry.index, name: entry.name,
                                             reason: String(localized: "ディレクトリ属性: \(ArchiveErrorText.describe(error))。")))
            }
        }
        let explicitDirectories = Set(directories.map { output.url($0.1).path })
        for directory in output.createdDirectories.sorted(by: { $0.pathComponents.count > $1.pathComponents.count })
            where !explicitDirectories.contains(directory.path) {
            do { try output.finishSynthesizedDirectory(directory) }
            catch {
                result.failures.append(.init(entryIndex: -1, name: directory.lastPathComponent,
                    reason: String(localized: "ディレクトリ属性: \(ArchiveErrorText.describe(error))。")))
            }
        }
        result.cancelled = result.cancelled || progress.isCancelled || Task.isCancelled
        let explicit = Set(result.written.map { $0.url.path })
        result.written += output.createdDirectories.filter { !explicit.contains($0.path) }
            .map { ExtractionResult.WrittenItem(entryIndex: nil, url: $0) }
        return result
    }

    static func consume(_ stream: EntryStream, checkCancellation: () throws -> Void,
                        body: (UnsafeRawBufferPointer) throws -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        try consume(stream, buffer: &buffer, checkCancellation: checkCancellation, body: body)
    }

    static func consume(_ stream: EntryStream, buffer: inout [UInt8], checkCancellation: () throws -> Void,
                        body: (UnsafeRawBufferPointer) throws -> Void) throws {
        while true {
            try checkCancellation()
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { break }
            try buffer.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
        }
        try checkCancellation()
    }

    private static func drain(_ stream: EntryStream, buffer: inout [UInt8], checkCancellation: () throws -> Void) throws {
        try consume(stream, buffer: &buffer, checkCancellation: checkCancellation) { _ in }
    }
}
