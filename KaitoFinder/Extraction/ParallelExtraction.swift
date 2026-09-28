import Foundation
import KaitoKit
import Synchronization

nonisolated enum ExtractionExecution: Sendable {
    case automatic, serial, parallel(workers: Int)

    func workerCount(entries: [ArchiveEntry], hasSources: Bool) -> Int {
        if case .serial = self { return 1 }
        // 不明サイズの累積制限は reader 間で共有できない。
        guard !hasSources, entries.allSatisfy({
            ($0.kind == .file || $0.kind == .directory) && $0.pendingID == nil && $0.uncompressedSize != nil
        }) else { return 1 }
        let files = entries.filter { $0.kind == .file }
        let buckets = files.filter { $0.solidGroup < 0 }.count
            + Set(files.filter { $0.solidGroup >= 0 }.map(\.solidGroup)).count
        let requested: Int
        switch self {
        case .serial: return 1
        case .automatic:
            let minimum: UInt64 = 8 * 1024 * 1024
            let bytes = files.reduce(UInt64(0)) { min(minimum, $0 + min(minimum, $1.uncompressedSize ?? 0)) }
            guard files.count >= 64, bytes >= minimum else { return 1 }
            requested = min(ProcessInfo.processInfo.activeProcessorCount, 8)
        case .parallel(let workers): requested = workers
        }
        return max(1, min(requested, buckets))
    }
}

nonisolated final class ParallelExtraction: Sendable {
    struct File: Sendable {
        let position: Int
        let entry: ArchiveEntry
        let components: [String]
    }

    private struct Resources {
        let reader: ArchiveReader
        let output: ExtractionDestination
    }

    private final class Position: Sendable {
        let value = Mutex(0)
    }

    private final class Worker: Sendable {
        let resources: Mutex<Resources>
        let position: Position

        init(reader: sending ArchiveReader, destination: URL, quarantine: Data?, readOnly: Bool, nameSyntax: ExtractionPath.NameSyntax,
             counter: ExtractionProgress, didWrite: (@Sendable (Int) -> Void)?) throws {
            let position = Position()
            self.position = position
            let output = try ExtractionDestination(url: destination, quarantine: quarantine, readOnly: readOnly, nameSyntax: nameSyntax) { count in
                counter.wrote(count, at: position.value.withLock { $0 })
                didWrite?(count)
            }
            resources = Mutex(Resources(reader: reader, output: output))
        }
    }

    private let workers: [Worker]
    private let counter: ExtractionProgress
    private let didProcess: (@Sendable (Int) -> Void)?

    init(reader: ArchiveReader, destination: URL, quarantine: Data?, readOnly: Bool, nameSyntax: ExtractionPath.NameSyntax, count: Int,
         counter: ExtractionProgress, didWrite: (@Sendable (Int) -> Void)?,
         didProcess: (@Sendable (Int) -> Void)?) throws {
        self.counter = counter
        self.didProcess = didProcess
        workers = try (0..<count).map { _ in
            try Worker(reader: reader.reopen(), destination: destination, quarantine: quarantine,
                       readOnly: readOnly, nameSyntax: nameSyntax, counter: counter, didWrite: didWrite)
        }
    }

    static func orderedFiles(_ entries: [ArchiveEntry], mapping: ExtractionService.OutputMapping) -> Set<Int> {
        // 衝突する葉と file-as-parent は、失敗時の削除も含めて書庫順で確定する。
        let paths = entries.map { entry in
            (try? mapping.components(entry.name))?.map {
                $0.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    .precomposedStringWithCanonicalMapping
            } ?? []
        }
        var leaves: [String: [Int]] = [:]
        for (entry, path) in zip(entries, paths) where entry.kind == .file && !path.isEmpty {
            leaves[path.joined(separator: "/"), default: []].append(entry.index)
        }
        var orderedPaths = Set<String>()
        for (entry, path) in zip(entries, paths) {
            var prefix = ""
            for (offset, part) in path.enumerated() {
                prefix += (prefix.isEmpty ? "" : "/") + part
                guard let indices = leaves[prefix] else { continue }
                if offset < path.count - 1 || entry.kind == .directory || indices.count > 1 {
                    orderedPaths.insert(prefix)
                }
            }
        }
        var ordered = Set<Int>()
        for path in orderedPaths { ordered.formUnion(leaves[path] ?? []) }
        // 衝突のある group も分断しない。
        let groups = Set(entries.filter { ordered.contains($0.index) && $0.solidGroup >= 0 }.map(\.solidGroup))
        ordered.formUnion(entries.filter { groups.contains($0.solidGroup) }.map(\.index))
        return ordered
    }

    static func buckets(_ files: [File]) -> [[File]] {
        var buckets: [[File]] = [], groups: [Int: Int] = [:]
        for file in files {
            let group = file.entry.solidGroup
            if group >= 0, let index = groups[group] { buckets[index].append(file) }
            else {
                if group >= 0 { groups[group] = buckets.count }
                buckets.append([file])
            }
        }
        return buckets
    }

    func run(_ files: [File], progress: Progress, cancelled: Bool = false) -> ExtractionResult {
        let buckets = Self.buckets(files)
        let next = Mutex(0), stopped = Mutex(cancelled), results = Mutex(ExtractionResult())
        let group = DispatchGroup()
        for worker in workers.prefix(buckets.count) {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [counter, didProcess] in
                defer { group.leave() }
                worker.resources.withLock { resources in
                    var buffer = [UInt8](repeating: 0, count: ExtractionService.streamBufferSize)
                    func checkCancellation() throws {
                        if progress.isCancelled || stopped.withLock({ $0 }) { throw CancellationError() }
                    }
                    while true {
                        let index = next.withLock { value in
                            defer { value += 1 }
                            return value
                        }
                        guard index < buckets.count else { return }
                        for file in buckets[index] {
                            do {
                                try checkCancellation()
                                worker.position.value.withLock { $0 = file.position }
                                try resources.output.file(file.components, entry: file.entry,
                                    stream: resources.reader.stream(file.entry), buffer: &buffer,
                                    createParents: false, checkCancellation: checkCancellation)
                                let item = try ExtractionService.written(file.entry, components: file.components,
                                                                         output: resources.output)
                                results.withLock { $0.written.append(item) }
                            } catch is CancellationError {
                                stopped.withLock { $0 = true }
                                return
                            } catch {
                                let failure = ExtractionResult.Failure(entryIndex: file.entry.index, name: file.entry.name,
                                                                       reason: ArchiveErrorText.describe(error))
                                results.withLock { $0.failures.append(failure) }
                            }
                            counter.finishedEntry(at: file.position)
                            didProcess?(file.entry.index)
                        }
                    }
                }
            }
        }
        // GCD worker に Swift Task の取消しを伝える。呼出元は全 worker の終了まで保持する。
        while group.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            if Task.isCancelled || progress.isCancelled { stopped.withLock { $0 = true } }
        }
        return results.withLock { result in
            result.cancelled = stopped.withLock { $0 } || progress.isCancelled || Task.isCancelled
            return result
        }
    }
}
