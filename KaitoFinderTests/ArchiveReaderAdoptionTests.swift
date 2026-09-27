import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchiveReaderAdoptionTests: XCTestCase {
    private static let spellings: [(GyoshukuKit.ArchiveFormat, String)] = [
        (.zip, "zip"), (.zip, "cbz"), (.tar, "tar"), (.tarGzip, "tar.gz"), (.tarGzip, "tgz"),
        (.tarBzip2, "tar.bz2"), (.tarBzip2, "tbz"), (.tarBzip2, "tbz2"),
        (.tarXZ, "tar.xz"), (.tarXZ, "txz"), (.sevenZip, "7z"), (.lha, "lzh"), (.lha, "lha")
    ]

    private func archive(_ root: URL, format: GyoshukuKit.ArchiveFormat = .zip, suffix: String? = nil,
                         settings: ArchiveEncryptionSettings = .init()) throws -> URL {
        let url = root.appendingPathComponent("original." + (suffix ?? ArchiveCreationPlan.filenameExtension(for: format)))
        let writer = try ArchiveWriter.create(url: url, format: format, options: settings.applying(to: .init(), format: format))
        for name in ["keep", "second", "remove", "folder/child"] { try writer.add(data: Data(name.utf8), as: name) }
        try writer.finish()
        return url
    }

    private func check(_ result: ArchiveEditResult) { XCTAssertNil(result.reloadFailure) }
    private func check(_ result: ArchiveImportResult) { XCTAssertNil(result.reloadFailure) }

    private func selection(_ entry: ArchiveEntry) -> ArchiveEditSelection {
        .init(path: entry.name, isDirectory: entry.kind == .directory, entries: [entry])
    }

    private func assertCurrent(_ session: ArchiveSession, password: String? = nil) async throws {
        let entries = await session.entries()
        let fresh = try ArchiveReader.open(url: session.sourceURL, options: .kaitoFinder(password: password))
        XCTAssertEqual(entries, fresh.entries)
        XCTAssertEqual(session.format, fresh.format)
        let expected = ArchiveCapabilities.inspect(reader: fresh, url: session.sourceURL, password: password)
        XCTAssertEqual(session.capabilities.mode, expected.mode)
        XCTAssertEqual(session.capabilities.refusal, expected.refusal)
        let reading = try await session.extractionReader()
        if let entry = entries.first(where: { $0.kind == .file }) {
            XCTAssertEqual(try reading.read(entry), try fresh.read(fresh.entries[entry.index]))
        }
    }

    private func adopting(_ operation: () async throws -> Void, opens: Int = 1) async throws {
        let events = Mutex<[ArchiveReaderAdoption]>([]), stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
        let before = ReaderOptions.kaitoFinderOpenCount.withLock { $0 }
        try await ArchiveSession.readerAdoptionObserver.withValue({ event in events.withLock { $0.append(event) } }) {
            try await ArchiveStageDiagnostics.observer.withValue({ event in
                if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
            }) { try await operation() }
        }
        XCTAssertEqual(events.withLock { $0 }, [.adopted])
        XCTAssertTrue(stages.withLock { $0.contains(.readerAdoption) })
        XCTAssertFalse(stages.withLock { $0.contains(.reloadOpen) })
        XCTAssertEqual(ReaderOptions.kaitoFinderOpenCount.withLock { $0 } - before, opens)
    }

    func testAllFormatsAndSpellingsAdoptEveryImmediateOperation() async throws {
        for (format, suffix) in Self.spellings {
            for operation in 0..<6 {
                let directory = try ArchiveTestDirectory(), url = try archive(directory.url, format: format, suffix: suffix)
                let session = try ArchiveSession(url: url)
                let entries = await session.entries(), target = selection(entries[2])
                let source = directory.url.appendingPathComponent(operation == 5 ? "second" : "added")
                try Data("added bytes".utf8).write(to: source)
                try await adopting {
                    switch operation {
                    case 0: check(try await session.remove([target], progress: Progress()))
                    case 1, 2: check(try await session.rename(target, to: operation == 1 ? "rename" : "longer-rename", progress: Progress()))
                    case 3, 5:
                        let result = try await session.append(urls: [source], to: "", progress: Progress(), resolveConflict: { _ in .init(choice: .replace) })
                        XCTAssertNil(result.reloadFailure)
                    default: check(try await session.createFolder(in: "", baseName: "new-folder", progress: Progress()))
                    }
                }
                try await assertCurrent(session)
                await session.close()
            }
        }
    }

    func testFiveChangeSavesAdoptIncludingPreservedTarOwners() async throws {
        for (format, suffix) in Self.spellings {
            for owners in format == .tar ? [false, true] : [false] {
                let directory = try ArchiveTestDirectory(), url = try archive(directory.url, format: format, suffix: suffix)
                let session = try ArchiveSession(url: url, writerOptions: { _ in
                    var options = WriterOptions(); options.preserveOwnerIDs = owners; return options
                })
                let snapshot = try await session.deferredSnapshot()
                let source = directory.url.appendingPathComponent("added")
                try Data("added bytes".utf8).write(to: source)
                let stamp = try ArchiveImportSourceStamp(source)
                var pending = ArchivePendingChanges()
                pending.renames[.init(index: 0, expectedName: "keep", baseGeneration: 0)] = "renamed"
                pending.removals = [.init(index: 2, expectedName: "remove", baseGeneration: 0), .init(index: 3, expectedName: "folder/child", baseGeneration: 0)]
                pending.createdFolders = [.init(id: UUID(), path: "new/")]
                pending.additions = [.init(id: UUID(), path: "added", stagedURL: source, sourceStamp: stamp, stagedStamp: stamp)]
                let publication = ArchiveSavePublication()
                defer { publication.finish() }
                try await adopting({
                    let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
                    XCTAssertNil(result.reloadFailure)
                }, opens: 1)
                try await assertCurrent(session)
                await session.close()
            }
        }
    }

    func testDittoAppleDoubleUsesExposedEntries() async throws {
        let directory = try ArchiveTestDirectory(), folder = directory.url.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("file")
        try Data("body".utf8).write(to: file)
        try Data("resource".utf8).write(to: URL(fileURLWithPath: file.path + "/..namedfork/rsrc"))
        let url = directory.url.appendingPathComponent("ditto.zip")
        try directory.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, url.path])
        let session = try ArchiveSession(url: url), entries = await session.entries()
        XCTAssertTrue(entries.contains { $0.name.contains("__MACOSX/") && $0.name.contains("._file") })
        try await adopting { check(try await session.createFolder(in: "", baseName: "new", progress: Progress())) }
        try await assertCurrent(session)
        await session.close()
    }

    func testPasswordChangesAndDeferredEncryptionRetainVerification() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip] {
            for fallback in [false, true] {
                let directory = try ArchiveTestDirectory(), url = try archive(directory.url, format: format)
                let session = try ArchiveSession(url: url)
                for action: ArchivePasswordAction in [.set, .change, .remove] {
                    let key = action == .set ? "first-key" : "second-key"
                    let settings = ArchiveEncryptionSettings(password: key, encryptsSevenZipHeaders: true)
                    let events = Mutex<[ArchiveReaderAdoption]>([])
                    try await ArchiveSession.readerAdoptionObserver.withValue({ e in events.withLock { $0.append(e) } }) {
                        try await ArchiveSession.willAdoptReaderForTesting.withValue({ output in
                            if fallback { output.verificationPassword = "mismatched" }
                        }) {
                            let result = try await session.updatePassword(action, settings: settings, progress: Progress())
                            XCTAssertNil(result.reloadFailure)
                        }
                    }
                    XCTAssertEqual(events.withLock { $0 }, [fallback ? .fallback(.password) : .adopted])
                    try await assertCurrent(session, password: action == .remove ? nil : key)
                    if action != .remove { XCTAssertEqual(session.entryVerification?.indices?.count, 4) }
                }
                let snapshot = try await session.deferredSnapshot()
                var pending = ArchivePendingChanges(); pending.outputEncryption = .init(password: "deferred", encryptsSevenZipHeaders: true)
                let publication = ArchiveSavePublication(); defer { publication.finish() }
                try await adopting({
                    let result = try await session.savePending(pending, baseGeneration: snapshot.generation, progress: Progress(), publication: publication)
                    XCTAssertNil(result.reloadFailure)
                }, opens: format == .sevenZip ? 2 : 1)
                let before = ArchiveSession.passwordVerificationBytes.withLock { $0 }
                _ = try await session.preparedPassword()
                XCTAssertEqual(ArchiveSession.passwordVerificationBytes.withLock { $0 }, before)
                try await assertCurrent(session, password: "deferred")
                await session.close()
            }
        }
    }

    func testEncryptedAndPlainZIPDeletionsAdopt() async throws {
        for encryption: ZipEncryption in [.zipCrypto, .aes256] {
            for removing in ["keep", "plain"] {
                let directory = try ArchiveTestDirectory(), url = try archive(directory.url, settings: .init(password: "key", zipEncryption: encryption))
                let updater = try ArchiveUpdater.open(url: url)
                try updater.add(data: Data("plain".utf8), as: "plain", modificationDate: nil, permissions: nil)
                try updater.commit()
                let session = try ArchiveSession(url: url, password: "key"), entries = await session.entries()
                try await adopting { check(try await session.remove([selection(try XCTUnwrap(entries.first { $0.name == removing }))], progress: Progress())) }
                try await assertCurrent(session, password: "key")
                let before = ArchiveSession.passwordVerificationBytes.withLock { $0 }
                _ = try await session.preparedPassword()
                XCTAssertEqual(ArchiveSession.passwordVerificationBytes.withLock { $0 }, before)
                await session.close()
            }
        }
    }

    func testPublishedNameRules() {
        for (format, suffix) in Self.spellings {
            for spelling in [suffix, suffix.uppercased()] {
                XCTAssertTrue(ArchiveVerifiedOutput.usesPublishedName(URL(fileURLWithPath: "/x." + spelling), format: format))
            }
        }
        for name in ["x.zip", "x.ZIP", "x.cbz", "x"] {
            XCTAssertTrue(ArchiveVerifiedOutput.usesPublishedName(URL(fileURLWithPath: "/" + name), format: .zip))
        }
        for name in ["x.zip.001", "x.tar.001", "x.z01", "x.cue", "x.CUE"] {
            for format: GyoshukuKit.ArchiveFormat in [.zip, .sevenZip, .tar] {
                XCTAssertFalse(ArchiveVerifiedOutput.usesPublishedName(URL(fileURLWithPath: "/" + name), format: format))
            }
        }
        for name in ["x.gz", "x.zip"] {
            XCTAssertFalse(ArchiveVerifiedOutput.usesPublishedName(URL(fileURLWithPath: "/" + name), format: .tarGzip))
        }
    }

    func testPostPublicationCancellationReloadsAdoptionAndFallback() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tarGzip, .sevenZip] {
            for fallback in [false, true] {
                let directory = try ArchiveTestDirectory()
                let settings = ArchiveEncryptionSettings(password: format == .sevenZip ? "key" : nil, encryptsSevenZipHeaders: true)
                let url = try archive(directory.url, format: format, settings: settings)
                let session = try ArchiveSession(url: url, password: settings.password), entries = await session.entries()
                let publication = ArchiveSavePublication(); defer { publication.finish() }
                let events = Mutex<[ArchiveReaderAdoption]>([]), removal = selection(entries[2])
                let task = Task {
                    try await ArchiveSavePublication.current.withValue(publication) {
                        try await ArchiveSession.readerAdoptionObserver.withValue({ e in events.withLock { $0.append(e) } }) {
                            try await ArchiveImportTransaction.didPublishForTesting.withValue({ url in
                                if fallback {
                                    let copy = url.appendingPathExtension("replacement")
                                    do { try FileManager.default.copyItem(at: url, to: copy); XCTAssertEqual(rename(copy.path, url.path), 0) }
                                    catch { XCTFail("\(error)") }
                                }
                                withUnsafeCurrentTask { $0?.cancel() }
                            }) { try await session.remove([removal], progress: Progress()) }
                        }
                    }
                }
                let result = try await task.value
                XCTAssertTrue(task.isCancelled)
                XCTAssertTrue(publication.hasPublishedBoundary)
                XCTAssertTrue(result.published)
                XCTAssertNil(result.reloadFailure)
                XCTAssertFalse(session.isInvalidated)
                XCTAssertEqual(events.withLock { $0 }, [fallback ? .fallback(.identity) : .adopted])
                try await assertCurrent(session, password: settings.password)
                if format == .sevenZip { let encryption = await session.encryptionSettings(); XCTAssertTrue(encryption.encryptsSevenZipHeaders) }
                await session.close()
            }
        }
    }

    private struct WeakSource: Sendable {
        weak var source: ArchiveVerifiedFileSource?
    }

    func testFallbackReasonsReleaseOutputBeforeOpening() async throws {
        for reason: ArchiveReaderAdoption.Reason in [.identity, .password, .splitSibling, .descriptor] {
            let directory = try ArchiveTestDirectory(), url = try archive(directory.url)
            let session = try ArchiveSession(url: url), entries = await session.entries()
            let weakSource = Mutex(WeakSource()), released = Mutex(false), events = Mutex<[ArchiveReaderAdoption]>([]), opened = Mutex(false)
            let result = try await ArchiveSession.readerAdoptionObserver.withValue({ e in events.withLock { $0.append(e) } }) {
                try await ArchiveSession.willAdoptReaderForTesting.withValue({ output in
                    weakSource.withLock { $0 = .init(source: output.source) }
                    output.didReleaseForTesting = { released.withLock { $0 = true } }
                    if reason == .password { output.verificationPassword = "different" }
                    if reason == .descriptor {
                        do { let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close() }
                        catch { XCTFail("\(error)") }
                    }
                }) {
                    try await ArchiveStageDiagnostics.observer.withValue({ event in
                        if case .began(_, .reloadOpen) = event {
                            opened.withLock { $0 = true }
                            XCTAssertTrue(released.withLock { $0 })
                            weakSource.withLock { XCTAssertNil($0.source) }
                        }
                    }) {
                        try await ArchiveImportTransaction.didPublishForTesting.withValue({ url in
                            do {
                                if reason == .identity {
                                    let other = url.appendingPathExtension("replacement")
                                    let writer = try ArchiveWriter.create(url: other)
                                    try writer.add(data: Data("replacement".utf8), as: "replacement"); try writer.finish()
                                    XCTAssertEqual(rename(other.path, url.path), 0)
                                }
                                if reason == .splitSibling { try Data([0]).write(to: url.deletingPathExtension().appendingPathExtension("z01")) }
                            } catch { XCTFail("\(error)") }
                        }) { try await session.remove([selection(entries[2])], progress: Progress()) }
                    }
                }
            }
            XCTAssertEqual(events.withLock { $0 }, [.fallback(reason)])
            XCTAssertTrue(opened.withLock { $0 })
            if reason == .descriptor {
                // reload の同一性取得後の変更は、従来どおりその reload 自体が拒否する。
                XCTAssertNotNil(result.reloadFailure)
                try await session.reloadAfterMutation()
            } else { XCTAssertNil(result.reloadFailure) }
            try await assertCurrent(session)
            await session.close()
        }
    }

    func testSingleNumberedFilesAndPostPublishAppendFallback() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tar] {
            let directory = try ArchiveTestDirectory(), url = try archive(directory.url, format: format, suffix: format == .zip ? "zip.001" : "tar.001")
            let session = try ArchiveSession(url: url), entries = await session.entries(), events = Mutex<[ArchiveReaderAdoption]>([])
            let result = try await ArchiveSession.readerAdoptionObserver.withValue({ e in events.withLock { $0.append(e) } }) {
                try await session.remove([selection(entries[2])], progress: Progress())
            }
            XCTAssertNil(result.reloadFailure)
            XCTAssertEqual(events.withLock { $0 }, [.fallback(.noOutput)])
            try await assertCurrent(session)
            await session.close()
        }
        let directory = try ArchiveTestDirectory(), url = try archive(directory.url), session = try ArchiveSession(url: url)
        let events = Mutex<[ArchiveReaderAdoption]>([]), entries = await session.entries()
        let result = try await ArchiveSession.readerAdoptionObserver.withValue({ e in events.withLock { $0.append(e) } }) {
            try await ArchiveImportTransaction.didPublishForTesting.withValue({ url in
                do { let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close() }
                catch { XCTFail("\(error)") }
            }) { try await session.remove([selection(entries[2])], progress: Progress()) }
        }
        XCTAssertEqual(events.withLock { $0 }, [.fallback(.identity)])
        XCTAssertNil(result.reloadFailure)
        try await assertCurrent(session)
        await session.close()
    }

    func testDescriptorBindingRefusesReplacedVerificationPath() async throws {
        let directory = try ArchiveTestDirectory(), url = try archive(directory.url), original = try Data(contentsOf: url)
        let session = try ArchiveSession(url: url), entries = await session.entries()
        do {
            _ = try await ArchiveImportTransaction.didOpenVerificationSourceForTesting.withValue({ work in
                let copy = work.appendingPathExtension("replacement")
                try FileManager.default.copyItem(at: work, to: copy)
                XCTAssertEqual(rename(copy.path, work.path), 0)
            }) { try await session.remove([selection(entries[2])], progress: Progress()) }
            XCTFail("Replaced descriptor was published")
        } catch { XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(session.capabilities.canEdit)
        await session.close()
    }

    func testOutputProbeRejectsSplitTailAndSFXWithoutChangingCapabilities() async throws {
        for damage in 0..<3 {
            let directory = try ArchiveTestDirectory(), url = try archive(directory.url), original = try Data(contentsOf: url)
            let session = try ArchiveSession(url: url), entries = await session.entries()
            do {
                _ = try await ArchiveImportTransaction.didCommitForTesting.withValue({ work in
                    var data = try Data(contentsOf: work), end = data.count - 22
                    if damage == 0 { data[end + 4] = 1 }
                    if damage == 1 { data.append(0) }
                    if damage == 2 {
                        let central = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: end + 16, as: UInt32.self)) }
                        data.insert(contentsOf: [1, 2, 3, 4], at: 0); end += 4
                        withUnsafeBytes(of: (central + 4).littleEndian) { data.replaceSubrange((end + 16)..<(end + 20), with: $0) }
                    }
                    try data.write(to: work)
                    if damage == 0 { XCTAssertThrowsError(try ArchiveReader.open(url: work, options: .kaitoFinderVerification())) }
                }) { try await session.remove([selection(entries[2])], progress: Progress()) }
                XCTFail("Invalid output was published")
            } catch { XCTAssertEqual(error as? ArchivePublicationError, .verificationFailed) }
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertTrue(session.capabilities.canEdit)
            await session.close()
        }
    }

    func testVerifiedSourceClampsReadsAndRejectsNonRegularFiles() throws {
        let directory = try ArchiveTestDirectory(), url = directory.url.appendingPathComponent("bytes")
        try Data([1, 2, 3]).write(to: url)
        let source = try ArchiveVerifiedFileSource(url: url)
        var buffer = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try source.read(into: $0, at: 1) }, 2)
        XCTAssertEqual(Array(buffer.prefix(2)), [2, 3])
        XCTAssertEqual(try buffer.withUnsafeMutableBytes { try source.read(into: $0, at: UInt64.max) }, 0)
        XCTAssertTrue(source.isUnchanged())
        try Data([1, 2, 3, 4]).write(to: url)
        XCTAssertFalse(source.isUnchanged())
        let link = directory.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try ArchiveVerifiedFileSource(url: link))
        XCTAssertThrowsError(try ArchiveVerifiedFileSource(url: directory.url))
    }

    func testHFSAdoption() async throws { try await diskAdoption("HFS+") }
    func testExFATAdoption() async throws { try await diskAdoption("ExFAT") }
    private func diskAdoption(_ fileSystem: String) async throws {
        let disk = try VolumePublishTestDisk(fileSystem), url = try archive(disk.mount)
        let session = try ArchiveSession(url: url), entries = await session.entries(), events = Mutex<[ArchiveReaderAdoption]>([])
        let result = try await ArchiveSession.readerAdoptionObserver.withValue({ e in events.withLock { $0.append(e) } }) {
            try await session.remove([selection(entries[2])], progress: Progress())
        }
        XCTAssertNil(result.reloadFailure)
        XCTAssertTrue(events.withLock { $0 == [.adopted] || (fileSystem == "ExFAT" && $0 == [.fallback(.identity)]) })
        try await assertCurrent(session)
        await session.close()
    }
}
