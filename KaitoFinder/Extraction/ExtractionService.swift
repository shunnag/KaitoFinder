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
        let entryIndex: Int?
        let url: URL
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
        case .system(let code): "POSIX \(code): \(String(cString: strerror(code)))"
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
        didProcess: (@Sendable (Int) -> Void)? = nil
    ) async throws -> ExtractionResult {
        if progress.isCancelled || Task.isCancelled { throw CancellationError() }
        let snapshot = try await session.resolveForExtraction(payloads)
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
            guard destination.isFileURL else { throw ExtractionFailure.refused("出力先は file URL が必要です") }
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
                       quarantine: snapshot.quarantine, progress: progress, mapping: mapping, didProcess: didProcess)
    }

    private enum OutputMapping {
        case archive, subtree([String]), file([String])

        func components(_ name: String) throws -> [String] {
            let parts = try ExtractionPath.components(name)
            switch self {
            case .archive: return parts
            case .file(let leaf): return leaf
            case .subtree(let prefix):
                guard parts.starts(with: prefix) else { throw ExtractionFailure.refused("部分木の外の項目です") }
                return Array(parts.dropFirst(prefix.count))
            }
        }
    }

    private static func run(
        _ entries: [ArchiveEntry], reader: ArchiveReader, destination: URL,
        quarantine: Data?, progress: Progress, mapping: OutputMapping = .archive, didProcess: (@Sendable (Int) -> Void)?
    ) throws -> ExtractionResult {
        let output = try ExtractionDestination(url: destination, quarantine: quarantine)
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
                guard reader.entries.indices.contains(entry.index), reader.entries[entry.index] == entry else {
                    throw ExtractionFailure.refused("選択がこの書庫の entry と一致しません")
                }
                let components = try mapping.components(entry.name)
                let key = components.joined(separator: "/").precomposedStringWithCanonicalMapping
                // 最初の名前を予約し、失敗しても後続の同名 entry へ差し替えない。
                // Unicode 正規化で同じ名前も含む。大文字小文字の衝突は O_EXCL で防ぐ。
                guard claimed.insert(key).inserted else {
                    throw ExtractionFailure.refused("重複する出力名です（書庫順で最初の entry を優先）")
                }
                // promise の明示フォルダ entry は今回作成した root 自身を表す。
                if components.isEmpty {
                    guard entry.kind == .directory else { throw ExtractionFailure.refused("root がフォルダではありません") }
                } else { try output.validate(components) }
                switch entry.kind {
                case .directory:
                    try drain(reader.stream(entry), checkCancellation: checkCancellation)
                    if !components.isEmpty { try output.directory(components, explicit: true) }
                    directories.append((entry, components))
                case .file:
                    try output.file(components, entry: entry, stream: reader.stream(entry),
                                    checkCancellation: checkCancellation)
                    materialized[entry.index] = components
                case .symlink:
                    let target: String
                    if let retained = entry.formatSpecific["linkPath"] {
                        try drain(reader.stream(entry), checkCancellation: checkCancellation)
                        target = retained
                    } else if entry.formatSpecific["linkTargetStoredAsData"] == "true" {
                        var data = Data()
                        try consume(reader.stream(entry), checkCancellation: checkCancellation) { bytes in
                            guard data.count + bytes.count <= 16_384 else {
                                throw ExtractionFailure.refused("シンボリックリンクの target が長すぎます")
                            }
                            data.append(contentsOf: bytes)
                        }
                        guard let decoded = String(data: data, encoding: .utf8) else {
                            throw ExtractionFailure.refused("リンクの target が UTF-8 ではありません")
                        }
                        target = decoded
                    } else {
                        throw ExtractionFailure.refused("リンクの target がありません")
                    }
                    try output.symlink(components, target: target)
                case .hardlink:
                    // 本体付き hard link は既存 inode の内容を書き換えず、独立ファイルにする。
                    if (entry.compressedSize ?? entry.uncompressedSize ?? 0) > 0 {
                        try output.file(components, entry: entry, stream: reader.stream(entry),
                                        checkCancellation: checkCancellation)
                    } else {
                        guard let index = entry.formatSpecific["hardLinkTargetIndex"].flatMap(Int.init),
                              let target = materialized[index], index < entry.index,
                              let targetName = entry.formatSpecific["linkPath"],
                              try mapping.components(targetName) == target else {
                            throw ExtractionFailure.refused("同じ reader と root で先に展開した hard link target がありません")
                        }
                        try drain(reader.stream(entry), checkCancellation: checkCancellation)
                        try output.hardlink(components, target: target)
                    }
                    materialized[entry.index] = components
                case .other:
                    throw ExtractionFailure.refused("この entry の種類は展開できません")
                }
                result.written.append(.init(entryIndex: entry.index, url: output.url(components)))
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                result.failures.append(.init(entryIndex: entry.index, name: entry.name,
                                             reason: String(describing: error)))
            }
            progress.completedUnitCount += 1
            progress.setUserInfoObject(Int(progress.completedUnitCount), forKey: .fileCompletedCountKey)
            didProcess?(entry.index)
        }
        // 取り消し時も作成済みの directory の属性を仕上げる。
        for (entry, components) in directories.sorted(by: { $0.1.count > $1.1.count }) {
            do { try output.finishDirectory(components, entry: entry) }
            catch {
                result.failures.append(.init(entryIndex: entry.index, name: entry.name,
                                             reason: "ディレクトリ属性: \(error)"))
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
        while true {
            try checkCancellation()
            let count = try buffer.withUnsafeMutableBytes { try stream.read(into: $0) }
            guard count > 0 else { break }
            try buffer.withUnsafeBytes { try body(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
        }
        try checkCancellation()
    }

    private static func drain(_ stream: EntryStream, checkCancellation: () throws -> Void) throws {
        try consume(stream, checkCancellation: checkCancellation) { _ in }
    }
}
