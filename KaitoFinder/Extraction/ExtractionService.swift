import Darwin
import Foundation
import KaitoKit
import Synchronization

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

nonisolated enum ExtractionService {
    /// entry の本文を読む・書く緩衝の長さ。
    static let streamBufferSize = 128 << 10

    /// 出力 root は既存の実ディレクトリ。選択の書庫内相対パスを維持する。
    /// 呼出側は完了まで root を排他的に所有する。既存の葉は上書きしない。
    /// solid group は分断しない。callback は各 worker で同期的に呼ぶ。
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
        progress.beginFileCopy(to: destination)
        // snapshot の取得（パスワード準備を含む）を待つ間も件数を確定表示する。run の ExtractionProgress が上書きする。
        progress.totalUnitCount = Int64(selection.entries.count)
        progress.completedUnitCount = 0
        progress.setUserInfoObject(selection.entries.count, forKey: .fileTotalCountKey)
        progress.setUserInfoObject(0, forKey: .fileCompletedCountKey)
        let snapshot = try await session.extractionSnapshot(progress: progress)
        // この同期呼出しの中で reader と全 stream の寿命が閉じる。
        return try run(selection.entries, reader: snapshot.reader, destination: destination,
                       quarantine: snapshot.quarantine, progress: progress,
                       mapping: .init(scope: .archive, syntax: .init(snapshot.reader.format)), didProcess: didProcess)
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
        let snapshot = try await session.resolveForExtraction(payloads, progress: progress)
        if readOnly {
            for entry in snapshot.selection.entries {
                let capability = EntryReadCapability(entry: entry, isDirectory: entry.kind == .directory,
                                                     format: snapshot.reader.format)
                if let reason = capability.reason { throw ExtractionFailure.refused(reason) }
            }
        }
        progress.beginFileCopy(to: destination)
        return try extractResolved(snapshot.selection.entries, reader: snapshot.reader, to: destination,
            quarantine: snapshot.quarantine, progress: progress, promisedItem: promisedItem,
            readOnly: readOnly, didWrite: didWrite, didProcess: didProcess)
    }

    @concurrent private static func extractPending(
        _ payloads: [ArchiveEntryPayload], from session: ArchiveSession, to destination: URL,
        progress: Progress, promisedItem: ArchiveEntryPayload?, readOnly: Bool,
        didWrite: (@Sendable (Int) -> Void)?, didProcess: (@Sendable (Int) -> Void)?
    ) async throws -> ExtractionResult {
        let snapshot = try await session.resolvePendingForExtraction(payloads, progress: progress)
        defer { withExtendedLifetime(snapshot.lease) {} }
        let entries = snapshot.selection.entries
        if readOnly {
            for entry in entries {
                if let reason = EntryReadCapability(entry: entry, isDirectory: entry.kind == .directory,
                                                    format: snapshot.reader.format).reason { throw ExtractionFailure.refused(reason) }
            }
        }
        progress.beginFileCopy(to: destination)
        if let promisedItem {
            guard payloads.contains(promisedItem), destination.isFileURL else { throw ArchiveEntryPayload.staleSelection }
        }
        return try extractResolved(entries, reader: snapshot.reader, to: destination, quarantine: snapshot.quarantine,
            progress: progress, promisedItem: promisedItem, readOnly: readOnly, didWrite: didWrite,
            didProcess: didProcess, sources: snapshot.snapshot.sources)
    }

    static func extractResolved(
        _ entries: [ArchiveEntry], reader: ArchiveReader, to destination: URL, quarantine: Data?,
        progress: Progress, promisedItem: ArchiveEntryPayload? = nil, readOnly: Bool = false,
        didWrite: (@Sendable (Int) -> Void)? = nil, didProcess: (@Sendable (Int) -> Void)? = nil,
        sources: ArchivePendingReadSnapshot.Sources? = nil,
        execution: ExtractionExecution = .automatic
    ) throws -> ExtractionResult {
        let syntax = ExtractionPath.NameSyntax(reader.format)
        let root: URL, scope: OutputMapping.Scope
        var virtualRootParent: ExtractionDestination?
        if let item = promisedItem {
            guard destination.isFileURL else { throw ExtractionFailure.refused(String(localized: "出力先はfile URLが必要です。")) }
            let parent = try ExtractionDestination(url: destination.deletingLastPathComponent(), quarantine: quarantine, nameSyntax: syntax)
            let leaf = [destination.lastPathComponent]
            try parent.validate(leaf)
            if item.isDirectory {
                try ArchiveImportPlan.checkCancellation(progress)
                try parent.directory(leaf, explicit: true)
                root = destination
                scope = .subtree(try ExtractionPath.components(item.path, syntax: syntax))
                if item.entryIndex == nil { virtualRootParent = parent }
            } else { root = destination.deletingLastPathComponent(); scope = .file(leaf) }
        } else { root = destination; scope = .archive }
        let mapping = OutputMapping(scope: scope, syntax: syntax)
        let result = try run(entries, reader: reader, destination: root, quarantine: quarantine,
            progress: progress, mapping: mapping, readOnly: readOnly, didWrite: didWrite,
            didProcess: didProcess, sources: sources, execution: execution)
        if let virtualRootParent {
            // /var と /private/var を混在させず、親と同じ実パスで root を仕上げる。
            try virtualRootParent.finishSynthesizedDirectory(virtualRootParent.url([destination.lastPathComponent]))
        }
        return result
    }

    struct OutputMapping {
        enum Scope { case archive, subtree([String]), file([String]) }
        let scope: Scope
        let syntax: ExtractionPath.NameSyntax

        func components(_ name: String) throws -> [String] {
            let parts = try ExtractionPath.components(name, syntax: syntax)
            switch scope {
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
        quarantine: Data?, progress: Progress, mapping: OutputMapping,
        readOnly: Bool = false, didWrite: (@Sendable (Int) -> Void)? = nil, didProcess: (@Sendable (Int) -> Void)?,
        sources: ArchivePendingReadSnapshot.Sources? = nil,
        execution: ExtractionExecution = .automatic
    ) throws -> ExtractionResult {
        let counter = ExtractionProgress(entries: entries, progress: progress)
        let position = Mutex(0)
        let output = try ExtractionDestination(url: destination, quarantine: quarantine, readOnly: readOnly, nameSyntax: mapping.syntax) { count in
            counter.wrote(count, at: position.withLock { $0 })
            didWrite?(count)
        }
        let workerCount = execution.workerCount(entries: entries, hasSources: sources != nil)
        let parallel = workerCount > 1 ? try? ParallelExtraction(reader: reader, destination: destination,
            quarantine: quarantine, readOnly: readOnly, nameSyntax: mapping.syntax, count: workerCount, counter: counter,
            didWrite: didWrite, didProcess: didProcess) : nil
        let orderedFiles = parallel == nil ? Set<Int>() : ParallelExtraction.orderedFiles(entries, mapping: mapping)
        var planned: [ParallelExtraction.File] = []
        var buffer = [UInt8](repeating: 0, count: streamBufferSize)
        var result = ExtractionResult()
        var claimed = Set<String>()
        var directories: [(ArchiveEntry, [String])] = []
        var materialized: [Int: [String]] = [:]
        func checkCancellation() throws {
            if progress.isCancelled || Task.isCancelled { throw CancellationError() }
        }
        for (offset, entry) in entries.enumerated() {
            position.withLock { $0 = offset }
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
                    if parallel != nil, !orderedFiles.contains(entry.index) {
                        try output.prepareParents(for: components) { _ = try reader.stream(original) }
                        planned.append(.init(position: offset, entry: entry, components: components))
                        continue
                    }
                    if let staged {
                        try output.stagedFile(components, entry: entry, addition: staged, buffer: &buffer, checkCancellation: checkCancellation)
                    } else {
                        try output.file(components, entry: entry, stream: reader.stream(original), buffer: &buffer,
                                        checkCancellation: checkCancellation)
                    }
                    materialized[entry.index] = components
                case .symlink:
                    let target = try symlinkTarget(entry, original: original, staged: staged, reader: reader,
                                                   buffer: &buffer, checkCancellation: checkCancellation)
                    try output.symlink(components, target: target, staged: staged)
                case .hardlink:
                    try extractHardlink(entry, original: original, components: components, output: output, reader: reader,
                                        mapping: mapping, hasSources: sources != nil, materialized: &materialized,
                                        buffer: &buffer, checkCancellation: checkCancellation)
                case .other:
                    throw ExtractionFailure.refused(String(localized: "このentryの種類は展開できません。"))
                }
                result.written.append(try written(entry, components: components, output: output))
            } catch is CancellationError {
                result.cancelled = true
                break
            } catch {
                result.failures.append(.init(entryIndex: entry.index, name: entry.name,
                                             reason: ArchiveErrorText.describe(error)))
            }
            counter.finishedEntry(at: offset)
            didProcess?(entry.index)
        }
        if let parallel {
            buffer = []
            let files = parallel.run(planned, progress: progress, cancelled: result.cancelled || Task.isCancelled)
            result.written += files.written
            result.failures += files.failures
            result.cancelled = result.cancelled || files.cancelled
            result.written.sort { $0.entryIndex! < $1.entryIndex! }
            result.failures.sort { $0.entryIndex < $1.entryIndex }
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

    /// symlink の宛先。退避物はリンク自身から、reader の entry は formatSpecific か本文（UTF-8、16 KiB まで）から読む。
    private static func symlinkTarget(_ entry: ArchiveEntry, original: ArchiveEntry, staged: ArchivePendingChanges.PendingAddition?,
                                      reader: ArchiveReader, buffer: inout [UInt8], checkCancellation: () throws -> Void) throws -> String {
        if let staged {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: staged.stagedURL.path)
            try staged.stagedStamp.verify()
            return target
        }
        if let retained = entry.formatSpecific["linkPath"] {
            try drain(reader.stream(original), buffer: &buffer, checkCancellation: checkCancellation)
            return retained
        }
        if entry.formatSpecific["linkTargetStoredAsData"] == "true" {
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
            return decoded
        }
        throw ExtractionFailure.refused(String(localized: "リンクのtargetがありません。"))
    }

    /// hard link。保留中の読み取り（sources あり）では基底 index で target を辿り、本文を独立ファイルとして書く。
    /// 本体付きの link も独立ファイル。本体なしの link は同じ root で先に展開した target へ linkat する。
    private static func extractHardlink(_ entry: ArchiveEntry, original: ArchiveEntry, components: [String],
                                        output: ExtractionDestination, reader: ArchiveReader, mapping: OutputMapping,
                                        hasSources: Bool, materialized: inout [Int: [String]],
                                        buffer: inout [UInt8], checkCancellation: () throws -> Void) throws {
        if hasSources {
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
            return
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
    }

    static func written(_ entry: ArchiveEntry, components: [String], output: ExtractionDestination) throws
        -> ExtractionResult.WrittenItem {
        let url = output.url(components)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
        return .init(entryIndex: entry.index, url: url, identity: .init(info))
    }

    static func consume(_ stream: EntryStream, checkCancellation: () throws -> Void,
                        body: (UnsafeRawBufferPointer) throws -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: streamBufferSize)
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

/// Finder 風のファイルコピーとして表示するための種別と出力先。件数と単位は ExtractionProgress が受け持つ。
nonisolated extension Progress {
    func beginFileCopy(to destination: URL) {
        kind = .file
        setUserInfoObject(Progress.FileOperationKind.copying, forKey: .fileOperationKindKey)
        setUserInfoObject(destination, forKey: .fileURLKey)
    }
}

nonisolated final class ExtractionProgress: Sendable {
    let progress: Progress
    private let units: [Int64]?
    private struct State {
        var items = 0
        var credited: [Int: Int64] = [:]
    }
    private let state = Mutex(State())

    static func byteUnits(_ entries: [ArchiveEntry]) -> [Int64]? {
        var total: Int64 = 0, units: [Int64] = []
        for entry in entries {
            guard let size = entry.uncompressedSize, let bytes = Int64(exactly: size) else { return nil }
            let unit = entry.kind == .directory || entry.kind == .symlink ? 1 : max(1, bytes)
            let next = total.addingReportingOverflow(unit)
            guard !next.overflow else { return nil }
            total = next.partialValue
            units.append(unit)
        }
        return units
    }

    init(entries: [ArchiveEntry], progress: Progress) {
        self.progress = progress
        units = Self.byteUnits(entries)
        progress.totalUnitCount = units?.reduce(0, +) ?? Int64(entries.count)
        progress.completedUnitCount = 0
        progress.setUserInfoObject(entries.count, forKey: .fileTotalCountKey)
        progress.setUserInfoObject(0, forKey: .fileCompletedCountKey)
    }

    func wrote(_ count: Int, at position: Int? = nil) {
        guard let units else { return }
        state.withLock { state in
            let index = position ?? state.items
            let increment = min(Int64(count), units[index] - state.credited[index, default: 0])
            state.credited[index, default: 0] += increment
            progress.completedUnitCount += increment
        }
    }

    func finishedEntry(at position: Int? = nil) {
        state.withLock { state in
            let index = position ?? state.items
            let unit = units?[index] ?? 1
            progress.completedUnitCount += unit - (state.credited.removeValue(forKey: index) ?? 0)
            state.items += 1
            // 短い本文や失敗も処理済みとして数える。完了順には依存しない。
            progress.setUserInfoObject(state.items, forKey: .fileCompletedCountKey)
        }
    }
}
