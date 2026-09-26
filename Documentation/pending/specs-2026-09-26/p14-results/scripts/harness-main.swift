import Foundation
import Darwin
@_spi(TarEditLayout) import KaitoKit
@_spi(Testing) import GyoshukuKit

// Usage:
//   P14Harness edit <base.tar.xz> <workdir> <label> <threads> <ops-comma|all>
//   P14Harness open <archive.tar.xz> <label> <plain|layout>
// Output: tab-separated lines prefixed with "P14-EDIT" / "P14-OPEN" on stdout.

struct HarnessError: Error, CustomStringConvertible { let description: String }

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func readerOptions(layout: Bool) -> ReaderOptions {
    var options = ReaderOptions(limits: .init(maxEntrySize: .max, maxTotalUncompressedSize: .max), appleDoublePolicy: .expose)
    options.recordsTarEditLayout = layout
    return options
}

func now() -> Double { ProcessInfo.processInfo.systemUptime }
func ms(_ seconds: Double) -> String { String(format: "%.3f", seconds * 1000) }

func load() -> String {
    var values = [Double](repeating: 0, count: 3)
    _ = getloadavg(&values, 3)
    return values.map { String(format: "%.2f", $0) }.joined(separator: "\t")
}

func openLayout(_ url: URL) throws -> ArchiveReader {
    try ArchiveReader.open(source: FileByteSource(url: url), sourceURL: url, options: readerOptions(layout: true))
}

func strategyText(_ strategy: CompressedTarStrategy) -> String {
    switch strategy {
    case .unchanged: return "unchanged"
    case .splice(let carried, let reencoded): return "splice(\(carried),\(reencoded))"
    case .fullEncode(let reason): return "fullEncode(\(reason))"
    }
}

func runEdit(_ arguments: [String]) throws {
    guard arguments.count == 5, let threads = Int(arguments[3]) else {
        throw HarnessError(description: "edit <base> <workdir> <label> <threads> <ops>")
    }
    let base = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    let workdir = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    let label = arguments[2]
    let allOps = ["append", "delete-small", "rename-small-mid", "rename-text256", "rename-first-same"]
    let ops = arguments[4] == "all" ? allOps : arguments[4].split(separator: ",").map(String.init)
    try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    let options = WriterOptions(compressionThreads: threads)

    let baseOpenStart = now()
    let reader = try openLayout(base)
    let baseOpen = now() - baseOpenStart
    guard let snapshot = reader.tarEditingSnapshot() else { throw HarnessError(description: "no tar editing snapshot") }
    let baseChunks = snapshot.chunkMap?.chunks.count ?? -1
    let entries = reader.entries
    let small = entries.filter { $0.kind == .file && $0.name.hasPrefix("small/") }
    let payloadFiles = entries.filter { $0.kind == .file && $0.name.hasPrefix("payload/") }
    let middle = small.isEmpty ? nil : small[small.count / 2]
    let payloadMiddle = payloadFiles.isEmpty ? nil : payloadFiles[payloadFiles.count / 2]
    let text = entries.first(where: { $0.name == "text256.txt" })
    let first = entries[0]
    func need<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw HarnessError(description: "base has no \(what)") }
        return value
    }
    // 名前の先頭 prefix を同じ長さの別名に変える（フォルダ改名の近似: 配下の全 entry を改名）。
    func renameFolder(_ updater: CompressedTarUpdater, prefix: String, to replacement: String) throws -> Int {
        precondition(prefix.count == replacement.count)
        var count = 0
        for entry in entries where entry.name.hasPrefix(prefix) || entry.name == String(prefix.dropLast()) {
            let rest = entry.name.dropFirst(prefix.count)
            let renamed = entry.kind == .directory && rest.isEmpty ? String(replacement.dropLast()) : replacement + rest
            try updater.rename(entryAt: entry.index, to: renamed); count += 1
        }
        return count
    }
    print("P14-BASE\t\(label)\t\(base.lastPathComponent)\tentries=\(entries.count)\tchunks=\(baseChunks)\topen_layout_ms=\(ms(baseOpen))\tmiddle=\(middle?.name ?? "-")\tpayload_middle=\(payloadMiddle?.name ?? "-")\tfirst=\(first.name)\tfirst_kind=\(first.kind)")

    for op in ops {
        let output = workdir.appendingPathComponent("\(label)-\(op).tar.xz")
        try? FileManager.default.removeItem(at: output)
        let updater = try CompressedTarUpdater.open(reader: reader.reopen(), output: output, format: GyoshukuKit.ArchiveFormat.tarXZ, options: options)
        var target = "-"
        let mutateStart = now()
        switch op {
        case "append":
            try updater.add(data: Data(repeating: 65, count: 4096), as: "added.txt", modificationDate: fixedDate)
            target = "added.txt"
        case "delete-small":
            let m = try need(middle, "small/ entries"); try updater.remove(entriesAt: [m.index]); target = m.name
        case "rename-small-mid":
            let m = try need(middle, "small/ entries")
            try updater.rename(entryAt: m.index, to: "renamed/" + String(repeating: "n", count: 160)); target = m.name
        case "rename-text256":
            let tx = try need(text, "text256.txt"); try updater.rename(entryAt: tx.index, to: "renamed-text256.txt"); target = tx.name
        case "rename-first-same":
            // 先頭 member（ディレクトリ "headers/"）を同じ長さの名前に。
            let trimmed = first.name.hasSuffix("/") ? String(first.name.dropLast()) : first.name
            let renamed = "X" + trimmed.dropFirst()
            try updater.rename(entryAt: first.index, to: renamed); target = first.name + "->" + renamed
        case "rename-folder-small":
            let count = try renameFolder(updater, prefix: "small/", to: "smalX/"); target = "small/ x\(count)"
        case "payload-delete-mid":
            let entry = try need(payloadMiddle, "payload/ entries"); try updater.remove(entriesAt: [entry.index]); target = entry.name
        case "payload-rename-mid":
            let entry = try need(payloadMiddle, "payload/ entries")
            try updater.rename(entryAt: entry.index, to: "payload/renamed.txt"); target = entry.name
        case "payload-rename-folder":
            let count = try renameFolder(updater, prefix: "payload/", to: "payloaX/"); target = "payload/ x\(count)"
        default:
            throw HarnessError(description: "unknown op \(op)")
        }
        target += " mutate_ms=" + ms(now() - mutateStart)
        let loadBefore = load()
        let commitStart = now()
        let result = try updater.commit(progress: nil)
        let commit = now() - commitStart
        guard let stats = updater.lastCommitStatistics else { throw HarnessError(description: "no statistics") }

        let k5Start = now()
        let splice = CompressedTarSplice(segments: result.segments.map {
            switch $0 {
            case .encoded(let output): return .encoded(output: output)
            case .reused(let output, let base): return .reused(output: output, base: base)
            }
        })
        let verified = try ArchiveReader.openSplicedCompressedTar(output: FileByteSource(url: output), sourceURL: output,
                                                                  base: snapshot, splice: splice, options: readerOptions(layout: true))
        let k5 = now() - k5Start

        let fullStart = now()
        let full = try openLayout(output)
        let fullOpen = now() - fullStart

        let names = verified.entries.map(\.name)
        guard names == full.entries.map(\.name) else { throw HarnessError(description: "\(op): K5 and full open disagree") }
        let expectedCount = entries.count + (op == "append" ? 1 : (op == "delete-small" || op == "payload-delete-mid") ? -1 : 0)
        guard names.count == expectedCount else { throw HarnessError(description: "\(op): entry count \(names.count) != \(expectedCount)") }
        let outChunks = full.tarEditingSnapshot()?.chunkMap?.chunks.count ?? -1
        let fields: [String] = [
            "P14-EDIT", label, op, String(threads), ms(commit), ms(k5), ms(fullOpen),
            strategyText(result.strategy),
            String(result.reencodedImageBytes), String(result.reencodedOldImageBytes), String(result.carriedCompressedBytes),
            String(stats.carriedChunks), String(stats.reencodedChunks), String(stats.scratchBytes),
            ms(stats.planningSeconds), ms(stats.encodingSeconds), ms(stats.copyingSeconds), ms(stats.selfCheckSeconds),
            String(result.output.size), String(baseChunks), String(outChunks), loadBefore, target,
        ]
        print(fields.joined(separator: "\t"))
        fflush(stdout)
        try FileManager.default.removeItem(at: output)
    }
}

func runOpen(_ arguments: [String]) throws {
    guard arguments.count == 3 else { throw HarnessError(description: "open <archive> <label> <plain|layout>") }
    let url = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    let layout = arguments[2] == "layout"
    let loadBefore = load()
    let start = now()
    let reader = try ArchiveReader.open(source: FileByteSource(url: url), sourceURL: url, options: readerOptions(layout: layout))
    let elapsed = now() - start
    let chunks = reader.tarEditingSnapshot()?.chunkMap?.chunks.count ?? -1
    print(["P14-OPEN", arguments[1], url.lastPathComponent, arguments[2], ms(elapsed), String(reader.entries.count), String(chunks), loadBefore]
        .joined(separator: "\t"))
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    guard let command = arguments.first else { throw HarnessError(description: "edit|open") }
    switch command {
    case "edit": try runEdit(Array(arguments.dropFirst()))
    case "open": try runOpen(Array(arguments.dropFirst()))
    default: throw HarnessError(description: "unknown command \(command)")
    }
} catch {
    FileHandle.standardError.write(Data("P14Harness: \(error)\n".utf8))
    exit(1)
}
