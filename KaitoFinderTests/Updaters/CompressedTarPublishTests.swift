import CryptoKit
import Foundation
@_spi(Testing) import GyoshukuKit
@_spi(TarEditLayout) import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class CompressedTarPublishTests: XCTestCase {
    func testImmediateOperationsOnModernAndFrozenLegacyArchives() async throws {
        for format in CompressedTarFixture.formats {
            for legacy in [false, true] {
                let seed = try ArchiveTestDirectory()
                let original = try legacy ? CompressedTarFixture.legacy(seed.url, format: format) : CompressedTarFixture.make(seed.url, format: format)
                let originalReader = try CompressedTarFixture.open(original)
                let entries = originalReader.entries, before = try CompressedTarFixture.groups(originalReader)
                let originalHashes = try CompressedTarFixture.hashes(originalReader)
                let first = try XCTUnwrap(entries.first { $0.kind == .file })
                let last = try XCTUnwrap(entries.last { $0.kind == .file })
                let folder = try XCTUnwrap(entries.first { $0.kind == .directory && $0.name.contains(legacy ? "/small" : "folder") })
                for operation in 0..<9 {
                    let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("edit." + CompressedTarFixture.suffix(format))
                    try FileManager.default.copyItem(at: original, to: archive)
                    let session = try ArchiveSession(url: archive), trace = CompressedTarTrace(), progress = Progress()
                    var expected = originalHashes, names = entries.map(\.name)
                    let leaf = ArchivePath.components(first.name).last!, parent = ArchivePath.components(first.name).dropLast().joined(separator: "/")
                    let renamed = operation == 2 ? "x" + leaf.dropFirst() : "a-much-longer-new-name"
                    let newPath = parent.isEmpty ? String(renamed) : parent + "/" + renamed
                    let folderPath = ArchivePath.components(folder.name).joined(separator: "/")
                    let input = directory.url.appendingPathComponent(operation == 8 ? leaf : "added")
                    try Data([99]).write(to: input)
                    func replace(_ old: String, _ new: String) { expected[new] = expected.removeValue(forKey: old); names = names.map { $0 == old ? new : $0 } }
                    switch operation {
                    case 0, 1:
                        let path = operation == 0 ? first.name : last.name
                        expected.removeValue(forKey: path); names.removeAll { $0 == path }
                    case 2, 3: replace(first.name, newPath)
                    case 4:
                        let prefix = ArchivePath.components(folderPath).dropLast().joined(separator: "/")
                        let target = prefix.isEmpty ? "renamed" : prefix + "/renamed"
                        for entry in entries where entry.name == folder.name || entry.name.hasPrefix(folderPath + "/") {
                            replace(entry.name, target + entry.name.dropFirst(folderPath.count))
                        }
                    case 5: replace(first.name, folderPath + "/" + leaf)
                    case 6: expected["new/"] = Data(); names.append("new/")
                    case 7: expected["added"] = Data(SHA256.hash(data: Data([99]))); names.append("added")
                    default:
                        expected[first.name] = Data(SHA256.hash(data: Data([99])))
                        names.removeAll { $0 == first.name }; names.append(first.name)
                    }
                    let openCount = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
                    try await trace.observing {
                        switch operation {
                        case 0, 1:
                            let result = try await session.remove([TarUpdateFixture.selection(operation == 0 ? first : last)], progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        case 2, 3:
                            let result = try await session.rename(TarUpdateFixture.selection(first), to: String(renamed), progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        case 4:
                            let selected = entries.filter { $0.name == folder.name || $0.name.hasPrefix(folderPath + "/") }
                            let result = try await session.rename(.init(path: folderPath, isDirectory: true, entries: selected), to: "renamed", progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        case 5:
                            let result = try await session.edit(moving: [.init(selection: TarUpdateFixture.selection(first), folder: folderPath)], progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        case 6:
                            let result = try await session.createFolder(in: "", baseName: "new", progress: progress)
                            XCTAssertNil(result.reloadFailure)
                        default:
                            let result = try await session.append(urls: [input], to: operation == 8 ? parent : "", progress: progress, resolveConflict: { _ in .init(choice: .replace) })
                            XCTAssertNil(result.reloadFailure)
                        }
                    }
                    XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - openCount, 1)
                    trace.assertAdopted(); XCTAssertEqual(trace.fullVerifications.value, 0); XCTAssertEqual(trace.rewrites.value, 0)
                    XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
                    let saved = try CompressedTarFixture.open(archive)
                    XCTAssertEqual(saved.entries.map(\.name), names, "\(format)/\(legacy)/\(operation)")
                    XCTAssertEqual(try CompressedTarFixture.hashes(saved), expected)
                    let groups = try CompressedTarFixture.groups(saved)
                    for (name, bytes) in before where expected[name] == originalHashes[name] { XCTAssertEqual(groups[name], bytes, name) }
                    XCTAssertEqual(try XCTUnwrap(saved.tarEditingSnapshot()).image.length % 10240, 0)
                    try CompressedTarFixture.interop(archive, format: format, directory: directory)
                    try ArchiveOracle.assertNoWorkFiles(in: directory.url)
                    await session.close()
                }
            }
        }
    }

    func testThreeConsecutiveSplicesAdoptSnapshots() async throws {
        for format in CompressedTarFixture.formats {
            for legacy in [false, true] {
                let directory = try ArchiveTestDirectory()
                let archive = try legacy ? CompressedTarFixture.legacy(directory.url, format: format) : CompressedTarFixture.make(directory.url, format: format)
                let session = try ArchiveSession(url: archive), trace = CompressedTarTrace()
                let opens = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
                try await trace.observing {
                    for index in 0..<3 { _ = try await session.createFolder(in: "", baseName: "new\(index)", progress: Progress()) }
                }
                XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - opens, 3)
                trace.assertAdopted(3); XCTAssertEqual(trace.fullVerifications.value, 0)
                for strategy in trace.strategies.withLock({ $0 }) { guard case .splice = strategy else { return XCTFail("\(strategy)") } }
                await session.close()
            }
        }
    }

    func testExternalStreamsReencodeOnceAndKeepRawHeaders() async throws {
        for format in CompressedTarFixture.formats {
            let directory = try ArchiveTestDirectory()
            let archive = try CompressedTarFixture.compress(CompressedTarFixture.externalBytes, in: directory, format: format,
                arguments: format == .tarGzip ? ["-6"] : format == .tarXZ ? ["--block-size=1MiB"] : [])
            try await assertExternal(archive, format: format, fallback: false)
        }
    }

    private func assertExternal(_ archive: URL, format: GyoshukuKit.ArchiveFormat, fallback: Bool) async throws {
        let base = try CompressedTarFixture.open(archive), before = try CompressedTarFixture.groups(base)
        let session = try ArchiveSession(url: archive)
        XCTAssertEqual(session.capabilities.editNotice(options: .init(), onSave: false), String(localized: "最初の編集でアーカイブ全体を再圧縮します"))
        XCTAssertEqual(session.capabilities.editNotice(options: .init(), onSave: true), String(localized: "最初の保存でアーカイブ全体を再圧縮します"))
        for index in 0..<2 {
            let trace = CompressedTarTrace()
            try await trace.observing { _ = try await session.createFolder(in: "", baseName: "new\(index)", progress: Progress()) }
            trace.assertAdopted()
            XCTAssertEqual(trace.fullVerifications.value, fallback && index == 0 ? 1 : 0)
            XCTAssertEqual(trace.rewrites.value, 0)
            let strategy = try XCTUnwrap(trace.strategies.withLock { $0.first })
            if index == 0 { guard case .fullEncode = strategy else { return XCTFail("\(strategy)") } }
            else { guard case .splice = strategy else { return XCTFail("\(strategy)") } }
            XCTAssertNil(session.capabilities.editNotice(options: .init(), onSave: false))
            XCTAssertNil(session.capabilities.editNotice(options: .init(), onSave: true))
            let saved = try CompressedTarFixture.open(archive), groups = try CompressedTarFixture.groups(saved)
            XCTAssertEqual(Array(saved.entries.prefix(base.entries.count).map(\.name)), base.entries.map(\.name))
            XCTAssertEqual(saved.entries.last?.name, "new\(index)/")
            for (name, bytes) in before { XCTAssertEqual(groups[name], bytes, name) }
        }
        await session.close()
    }

    func testMissingMapsUseExactlyOneFullVerification() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.tarGzip, .tarXZ] {
            let directory = try ArchiveTestDirectory(), bytes = CompressedTarFixture.externalBytes
            let archive: URL
            if format == .tarGzip {
                let half = bytes.count / 2
                let first = try CompressedTarFixture.compress(bytes.prefix(half), in: directory, format: format, name: "first")
                let second = try CompressedTarFixture.compress(bytes.suffix(from: half), in: directory, format: format, name: "second")
                archive = directory.url.appendingPathComponent("joined.tar.gz")
                try (Data(contentsOf: first) + Data(contentsOf: second)).write(to: archive)
            } else {
                archive = try CompressedTarFixture.compress(bytes, in: directory, format: format)
                let handle = try FileHandle(forWritingTo: archive); try handle.seekToEnd(); try handle.write(contentsOf: Data(count: 4)); try handle.close()
            }
            XCTAssertNil(try CompressedTarFixture.open(archive).tarEditingSnapshot()?.chunkMap)
            try await assertExternal(archive, format: format, fallback: true)
        }
    }

    func testBSDTarGzipAndCRC64XZUseK5ForFirstEdit() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.tarGzip, .tarXZ] {
            let directory = try ArchiveTestDirectory(), raw = directory.url.appendingPathComponent("raw.tar")
            try CompressedTarFixture.externalBytes.write(to: raw)
            let archive = directory.url.appendingPathComponent("bsdtar." + CompressedTarFixture.suffix(format))
            // @raw copies entries through bsdtar, retaining owners, uname, pax and AppleDouble.
            try directory.run(ExternalTool.bsdtar, [format == .tarGzip ? "-czf" : "-cJf", archive.path, "@" + raw.path])
            let base = try CompressedTarFixture.open(archive)
            XCTAssertEqual(base.entries.first?.formatSpecific["uid"], "501")
            XCTAssertEqual(base.entries.first?.formatSpecific["gid"], "20")
            XCTAssertTrue(try CompressedTarFixture.groups(base).values.contains { $0.range(of: Data("alice".utf8)) != nil })
            try await assertExternal(archive, format: format, fallback: false)
        }
    }

    func testDeleteAllThenAppendInImmediateAndDeferredModes() async throws {
        for format in CompressedTarFixture.formats {
            for deferred in [false, true] {
                let directory = try ArchiveTestDirectory(), archive = try CompressedTarFixture.make(directory.url, format: format)
                let session = try ArchiveSession(url: archive), input = directory.url.appendingPathComponent("added")
                try Data([1]).write(to: input)
                for removing in [true, false] {
                    let snapshot = try await session.deferredSnapshot()
                    if deferred {
                        var pending = ArchivePendingChanges()
                        if removing { pending.removals = Set(snapshot.entries.map { .init(index: $0.index, expectedName: $0.name, baseGeneration: snapshot.generation) }) }
                        else {
                            let stamp = try ArchiveImportSourceStamp(input)
                            pending.additions = [.init(id: UUID(), path: "added", stagedURL: input, sourceStamp: stamp, stagedStamp: stamp)]
                        }
                        let publication = ArchiveSavePublication(); defer { publication.finish() }
                        let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
                        XCTAssertNil(result.reloadFailure)
                    } else if removing {
                        let files = snapshot.entries.filter { $0.kind != .directory && !$0.name.hasPrefix("folder/") }
                        let folder = ArchiveEditSelection(path: "folder", isDirectory: true, entries: snapshot.entries.filter { $0.name.hasPrefix("folder/") })
                        let result = try await session.remove(files.map(TarUpdateFixture.selection) + [folder], progress: Progress())
                        XCTAssertNil(result.reloadFailure)
                    } else { _ = try await session.append(urls: [input], to: "", progress: Progress()) }
                    XCTAssertEqual(session.capabilities.mode, .update(format))
                    XCTAssertEqual(try ArchiveReader.open(url: archive).entries.map(\.name), removing ? [] : ["added"])
                }
                await session.close()
            }
        }
    }

    func testPOSIXNamesAndCanonicalCollision() async throws {
        for format in CompressedTarFixture.formats {
            let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("names." + CompressedTarFixture.suffix(format))
            let writer = try ArchiveWriter.create(url: archive, format: format)
            for name in ["first", "cafe\u{301}", "last"] { try writer.add(data: Data([1]), as: name) }; try writer.finish()
            let session = try ArchiveSession(url: archive), entries = await session.entries()
            _ = try await session.rename(TarUpdateFixture.selection(entries[0]), to: "back\\slash:colon", progress: Progress())
            _ = try await session.createFolder(in: "", baseName: "folder\\name:colon", progress: Progress())
            do { _ = try await session.rename(TarUpdateFixture.selection(entries[2]), to: "caf\u{e9}", progress: Progress()); XCTFail("NFC collision") }
            catch { XCTAssertTrue(error is ArchiveEditError) }
            XCTAssertTrue(try ArchiveReader.open(url: archive).entries.contains { $0.name == "back\\slash:colon" })
            await session.close()
        }
    }
}
