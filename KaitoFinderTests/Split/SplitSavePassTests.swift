#if DEBUG
import CryptoKit
import Darwin
import Foundation
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class SplitSavePassTests: XCTestCase {
    private func operations(_ fixture: VolumePublishFixture) -> VolumePublishOperations {
        var operations = VolumePublishOperations()
        operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
        operations.trash = { url in
            let destination = fixture.directory.url.appendingPathComponent("trash-" + UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        return operations
    }

    private func requireAPFS(_ fixture: VolumePublishFixture) throws {
        let volume = try VolumePublishFS.volumeInfo(VolumePublishDirectory(fixture.root))
        try XCTSkipUnless(volume.fileSystem == "apfs" && volume.hazard == nil, "hazard のない APFS が必要")
    }

    private func injectVolume(_ operations: inout VolumePublishOperations, fileSystem: String? = nil, hazard: String?) {
        operations.volumeInfo = { parent in
            let actual = try VolumePublishFS.volumeInfo(parent)
            return .init(uuid: actual.uuid, cacheIdentity: actual.cacheIdentity, fileSystem: fileSystem ?? actual.fileSystem,
                         available: actual.available, hazard: hazard)
        }
    }

    private func assertPasses(parent: URL? = nil, fileSystem: String? = nil, hazard: String? = nil,
                              stamps: Bool, oldHashes: Bool) throws {
        for policy: VolumeOldDisposalPolicy in [.trash, .remove] {
            let fixture = try VolumePublishFixture(parent: parent)
            if stamps { try requireAPFS(fixture) }
            let hashes = Mutex<[URL: Int]>([:]), rechecks = Mutex<[URL: Int]>([:])
            var operations = operations(fixture)
            if fileSystem != nil || hazard != nil { injectVolume(&operations, fileSystem: fileSystem, hazard: hazard) }
            operations.didHash = { url in hashes.withLock { $0[url, default: 0] += 1 } }
            operations.didRecheckStamps = { url in rechecks.withLock { $0[url, default: 0] += 1 } }
            var target = fixture.target(consent: true)
            target.oldVolumeDisposal = policy
            let publication = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(fixture.newBytes.count),
                index: fixture.index, operations: operations)
            defer { publication.cancel() }
            try fixture.newBytes.write(to: publication.workURL)
            _ = try publication.publish(progress: Progress(), validation: { _ in })
            var expectedHashes: [URL: Int] = [:], expectedRechecks: [URL: Int] = [:]
            for (index, volume) in fixture.plan.volumes.enumerated() {
                let staged = publication.stagingURL.appendingPathComponent("new/" + volume.name)
                let placed = fixture.root.appendingPathComponent(volume.name)
                expectedHashes[staged] = stamps ? 1 : 2
                expectedHashes[placed] = (stamps ? 1 : 2) + (policy == .remove ? 1 : 0)
                    + (oldHashes && index < fixture.oldParts.count ? 1 : 0)
                if stamps { expectedRechecks[staged] = 1; expectedRechecks[placed] = 1 }
            }
            XCTAssertEqual(hashes.withLock { $0 }, expectedHashes)
            XCTAssertEqual(rechecks.withLock { $0 }, expectedRechecks)
            try fixture.assertNew()
        }
    }

    func testAPFSDeferredAndImmediatePassCounts() throws {
        XCTAssertTrue(VolumePublishOperations().allowsStampRecheck)
        try assertPasses(stamps: true, oldHashes: false)
    }

    func testFATAndHazardPassCounts() throws {
        try assertPasses(fileSystem: "msdos", hazard: "msdos", stamps: false, oldHashes: true)
        try assertPasses(hazard: "non-local", stamps: false, oldHashes: false)
        try assertPasses(hazard: "file-provider", stamps: false, oldHashes: false)
        try assertPasses(fileSystem: "hfs", stamps: false, oldHashes: false)
    }

    private func diskPasses(_ fileSystem: String, oldHashes: Bool) throws {
        let disk = try VolumePublishTestDisk(fileSystem)
        defer { try? disk.detach() }
        try assertPasses(parent: disk.mount, stamps: false, oldHashes: oldHashes)
    }
    func testHFSPlusPassCountsOnVolume() throws { try diskPasses("HFS+", oldHashes: false) }
    func testFATPassCountsOnVolume() throws { try diskPasses("MS-DOS FAT32", oldHashes: true) }
    func testExFATPassCountsOnVolume() throws { try diskPasses("ExFAT", oldHashes: true) }

    private enum CorruptionMtime: Sendable { case advance, restore, natural }

    private static func corrupt(_ url: URL, mtime: CorruptionMtime = .advance) throws {
        let fd = open(url.path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { throw VolumePublishError.system(errno) }
        defer { close(fd) }
        var before = stat(), after = stat(), byte: UInt8 = 0
        guard fstat(fd, &before) == 0, pread(fd, &byte, 1, 0) == 1 else { throw VolumePublishError.system(errno) }
        byte ^= 1
        guard pwrite(fd, &byte, 1, 0) == 1 else { throw VolumePublishError.system(errno) }
        switch mtime {
        case .natural: break
        case .advance, .restore:
            var modified = before.st_mtimespec
            if case .advance = mtime { modified.tv_sec += 1 }
            let times = [before.st_atimespec, modified]
            guard futimens(fd, times) == 0 else { throw VolumePublishError.system(errno) }
        }
        guard fstat(fd, &after) == 0 else { throw VolumePublishError.system(errno) }
        XCTAssertEqual(after.st_size, before.st_size)
        XCTAssertEqual(after.st_ino, before.st_ino)
        switch mtime {
        case .natural:
            XCTAssertNotEqual(VolumeFileStamp(before), VolumeFileStamp(after))
        case .restore:
            XCTAssertEqual(VolumeFileStamp(before), VolumeFileStamp(after))
        case .advance:
            XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec + 1)
            XCTAssertEqual(after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec)
        }
    }

    func testStagedCorruptionFallsBackBeforeS5() throws {
        for (fat, mtime): (Bool, CorruptionMtime) in [(false, .advance), (false, .natural), (true, .restore)] {
            let fixture = try VolumePublishFixture()
            if !fat { try requireAPFS(fixture) }
            let enteredS5 = Mutex(false), hashes = Mutex<[URL: Int]>([:]), rechecks = Mutex<[URL]>([])
            var operations = operations(fixture)
            if fat { injectVolume(&operations, fileSystem: "msdos", hazard: "msdos") }
            operations.didHash = { url in hashes.withLock { $0[url, default: 0] += 1 } }
            operations.didRecheckStamps = { url in rechecks.withLock { $0.append(url) } }
            let publication = try fixture.begin(consent: fat, operations: operations) { step in
                if step == .s5 { enteredS5.withLock { $0 = true } }
            }
            defer { publication.cancel() }
            let changed = publication.stagingURL.appendingPathComponent("new/" + fixture.plan.volumes[2].name)
            XCTAssertThrowsError(try publication.publish(progress: Progress()) { _ in
                try Self.corrupt(changed, mtime: mtime)
            }) { XCTAssertEqual($0 as? VolumePublishError, .contentMismatch(changed.lastPathComponent)) }
            XCTAssertFalse(enteredS5.withLock { $0 })
            let first = publication.stagingURL.appendingPathComponent("new/" + fixture.plan.gateName)
            XCTAssertEqual(hashes.withLock { $0[first] }, 2, "変更巻より前の巻も全文で証明し直す")
            if fat { XCTAssertTrue(rechecks.withLock { $0.isEmpty }) }
            try fixture.assertOld()
        }
    }

    func testStagedCorruptionWithRestoredStampIsCaughtByPlacedProof() throws {
        let fixture = try VolumePublishFixture(), calls = Mutex(0), steps = Mutex<[VolumePublishStep]>([])
        try requireAPFS(fixture)
        let hashes = Mutex<[URL: Int]>([:]), rechecks = Mutex<[URL: Int]>([:])
        var operations = operations(fixture)
        operations.didHash = { url in hashes.withLock { $0[url, default: 0] += 1 } }
        operations.didRecheckStamps = { url in rechecks.withLock { $0[url, default: 0] += 1 } }
        let publication = try fixture.begin(operations: operations) { step in steps.withLock { $0.append(step) } }
        defer { publication.cancel() }
        // 旧巻の次の名前より後を変え、既存の rollback が旧3巻を戻せる条件にする。
        let changed = fixture.plan.volumes[4].name
        XCTAssertThrowsError(try publication.publish(progress: Progress()) { _ in
            if calls.withLock({ $0 += 1; return $0 }) == 1 {
                try Self.corrupt(publication.stagingURL.appendingPathComponent("new/" + changed), mtime: .restore)
            }
        }) { error in
            guard case VolumePublishError.rolledBack(let underlying, let cleanup, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(underlying, String(describing: VolumePublishError.contentMismatch(changed)))
            XCTAssertNil(cleanup)
        }
        XCTAssertEqual(calls.withLock { $0 }, 1, "S10 は reader を開く前の全文 hash で拒否する")
        XCTAssertTrue(steps.withLock { $0.contains(.s5) && $0.contains(.s9) && !$0.contains(.s10) })
        var expectedHashes: [URL: Int] = [:], expectedRechecks: [URL: Int] = [:]
        for volume in fixture.plan.volumes {
            let staged = publication.stagingURL.appendingPathComponent("new/" + volume.name)
            expectedHashes[staged] = 1
            expectedRechecks[staged] = 1
            if volume.name != changed { expectedHashes[fixture.root.appendingPathComponent(volume.name)] = 1 }
        }
        XCTAssertEqual(hashes.withLock { $0 }, expectedHashes)
        XCTAssertEqual(rechecks.withLock { $0 }, expectedRechecks)
        for (volume, bytes) in zip(try XCTUnwrap(fixture.layout).volumes, fixture.oldParts) {
            XCTAssertEqual(try Data(contentsOf: volume.url), bytes)
        }
        try VolumePublishDirectory(fixture.root).requireAbsent(try XCTUnwrap(fixture.layout).nextVolumeName)
    }

    private func placedCorruption(index: Int, stamps: Bool, old: [Data], new: Data) throws -> (VolumePublishError, [String: Data]) {
        let fixture = try VolumePublishFixture()
        try requireAPFS(fixture)
        let layout = try XCTUnwrap(fixture.layout)
        // 二つの実行で入力 byte を揃え、writer の時刻に依存せず差分を比べる。
        for (volume, bytes) in zip(layout.volumes, old) { try bytes.write(to: volume.url) }
        let target = VolumeSetTarget(parent: fixture.root, layout: layout, expected: try ArchiveSetIdentity.capture(layout: layout),
                                     schedule: fixture.target().schedule)
        let rechecks = Mutex<[URL: Int]>([:])
        var operations = operations(fixture)
        operations.allowsStampRecheck = stamps
        operations.didRecheckStamps = { url in rechecks.withLock { $0[url, default: 0] += 1 } }
        let publication = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(new.count),
            index: fixture.index, operations: operations)
        defer { publication.cancel() }
        try new.write(to: publication.workURL)
        let calls = Mutex(0), name = fixture.plan.volumes[index].name
        var failure: VolumePublishError?
        XCTAssertThrowsError(try publication.publish(progress: Progress()) { _ in
            if calls.withLock({ $0 += 1; return $0 }) == 2 { try Self.corrupt(fixture.root.appendingPathComponent(name)) }
        }) { failure = $0 as? VolumePublishError }
        XCTAssertEqual(calls.withLock { $0 }, 2)
        var expectedRechecks: [URL: Int] = [:]
        if stamps {
            for (position, volume) in fixture.plan.volumes.enumerated() {
                expectedRechecks[publication.stagingURL.appendingPathComponent("new/" + volume.name)] = 1
                if position < index { expectedRechecks[fixture.root.appendingPathComponent(volume.name)] = 1 }
            }
        }
        XCTAssertEqual(rechecks.withLock { $0 }, expectedRechecks)
        let normalized: VolumePublishError
        if index == 0 {
            XCTAssertEqual(failure, .rollbackIncomplete(publication.stagingURL))
            let recovery = VolumePublishRecovery(index: fixture.index, operations: operations).recover(staging: publication.stagingURL)
            guard case .held = recovery else { XCTFail("回復が held にならなかった: \(recovery)"); throw VolumePublishError.validationFailed }
            normalized = .rollbackIncomplete(URL(fileURLWithPath: "/staging"))
        } else {
            guard case .rolledBack(let underlying, let cleanup, let disposal) = try XCTUnwrap(failure) else {
                XCTFail("rolledBack が必要: \(String(describing: failure))"); throw VolumePublishError.validationFailed
            }
            XCTAssertEqual(underlying, String(describing: VolumePublishError.contentMismatch(name)))
            XCTAssertNil(cleanup)
            guard case .trashed = disposal else { XCTFail("試験用 Trash へ移す"); throw VolumePublishError.validationFailed }
            normalized = .rolledBack(underlying: underlying, cleanupFailed: cleanup, disposal: .trashed(URL(fileURLWithPath: "/trash")))
            for (volume, bytes) in zip(layout.volumes, old) { XCTAssertEqual(try Data(contentsOf: volume.url), bytes) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name).path))
        }
        var files: [String: Data] = [:]
        let parent = try VolumePublishDirectory(fixture.root)
        for name in try parent.names() where (try parent.info(name)?.st_mode ?? 0) & S_IFMT == S_IFREG {
            files[name] = try Data(contentsOf: fixture.root.appendingPathComponent(name))
        }
        return (normalized, files)
    }

    func testPlacedCorruptionMatchesFullHashRollbackAndHeldRecovery() throws {
        let fixture = try VolumePublishFixture()
        for index in [4, 0] {
            let optimized = try placedCorruption(index: index, stamps: true, old: fixture.oldParts, new: fixture.newBytes)
            let fullHash = try placedCorruption(index: index, stamps: false, old: fixture.oldParts, new: fixture.newBytes)
            XCTAssertEqual(optimized.0, fullHash.0)
            XCTAssertEqual(optimized.1, fullHash.1)
        }
    }

    func testNextNameCreatedAfterPlacedReaderRollsBack() throws {
        let fixture = try VolumePublishFixture(), calls = Mutex(0)
        try requireAPFS(fixture)
        let publication = try fixture.begin(operations: operations(fixture))
        defer { publication.cancel() }
        XCTAssertThrowsError(try publication.publish(progress: Progress()) { _ in
            if calls.withLock({ $0 += 1; return $0 }) == 2 {
                try Data([42]).write(to: fixture.root.appendingPathComponent(fixture.plan.nextVolumeName))
            }
        }) {
            guard case VolumePublishError.rolledBack(let underlying, _, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(underlying, String(describing: VolumePublishError.nameOccupied(fixture.plan.nextVolumeName)))
        }
        for (volume, bytes) in zip(try XCTUnwrap(fixture.layout).volumes, fixture.oldParts) {
            XCTAssertEqual(try Data(contentsOf: volume.url), bytes)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(fixture.plan.nextVolumeName)), Data([42]))
    }

    func testReaderFailureStillUsesFullHashAtBothBoundaries() throws {
        for boundary in [1, 2] {
            let fixture = try VolumePublishFixture(), calls = Mutex(0), hashes = Mutex<[URL: Int]>([:])
            try requireAPFS(fixture)
            var operations = operations(fixture)
            operations.didHash = { url in hashes.withLock { $0[url, default: 0] += 1 } }
            let publication = try fixture.begin(operations: operations)
            defer { publication.cancel() }
            XCTAssertThrowsError(try publication.publish(progress: Progress()) { _ in
                if calls.withLock({ $0 += 1; return $0 }) == boundary { throw VolumePublishError.validationFailed }
            }) { error in
                if boundary == 1 {
                    XCTAssertEqual(error as? VolumePublishError, .stagedReaderFailed(String(describing: VolumePublishError.validationFailed)))
                } else {
                    guard case VolumePublishError.publishedReaderFailed(let staging, _) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(staging, publication.stagingURL)
                }
            }
            for volume in fixture.plan.volumes {
                let directory = boundary == 1 ? publication.stagingURL.appendingPathComponent("new") : fixture.root
                XCTAssertEqual(hashes.withLock { $0[directory.appendingPathComponent(volume.name)] }, 2)
            }
            if boundary == 1 { try fixture.assertOld() } else { try fixture.assertNew() }
        }
    }

    func testPlacedInodeReplacementWithSameBytesStillRequiresHold() throws {
        let fixture = try VolumePublishFixture(), calls = Mutex(0), hashes = Mutex<[URL: Int]>([:])
        try requireAPFS(fixture)
        var operations = operations(fixture)
        operations.didHash = { url in hashes.withLock { $0[url, default: 0] += 1 } }
        let publication = try fixture.begin(operations: operations)
        defer { publication.cancel() }
        XCTAssertThrowsError(try publication.publish(progress: Progress()) { _ in
            if calls.withLock({ $0 += 1; return $0 }) == 2 {
                let bytes = try Data(contentsOf: fixture.gate)
                try bytes.write(to: fixture.gate, options: .atomic)
            }
        }) { error in
            guard case VolumePublishError.publishedVerificationPending(let staging, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(staging, publication.stagingURL)
        }
        for volume in fixture.plan.volumes { XCTAssertEqual(hashes.withLock { $0[fixture.root.appendingPathComponent(volume.name)] }, 2) }
        try fixture.assertNew()
    }

    @MainActor func testReplacedWorkIsRejectedAtS4WithoutWorkValidation() async throws {
        for format: GyoshukuKit.ArchiveFormat in [.zip, .tarGzip] {
            let fixture = try DeferredSplitSaveFixture(format: format), document = fixture.document
            defer { document.close() }
            let other = fixture.directory.url.appendingPathComponent("other." + ArchiveCreationPlan.filenameExtension(for: format))
            let writer = try ArchiveWriter.create(url: other, format: format)
            try writer.add(data: Data([1]), as: "different.txt")
            try writer.finish()
            let bytes = try Data(contentsOf: other), enteredS5 = Mutex(false)
            let stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
            document.splitSaveHooks.didProduceWork = { try bytes.write(to: $0) }
            document.splitSaveHooks.fault = { step in if step == .s5 { enteredS5.withLock { $0 = true } } }
            document.splitSaveHooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
            _ = try await document.rename(fixture.node("file1.txt"), to: "renamed.txt", progress: Progress())
            do {
                try await ArchiveStageDiagnostics.observer.withValue({ event in
                    if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
                }) { try await fixture.save() }
                XCTFail("不一致の W は公開しない")
            } catch { }
            XCTAssertEqual(document.splitSaveFailure?.kind, .failed)
            XCTAssertEqual(try fixture.parts(), fixture.original)
            XCTAssertFalse(enteredS5.withLock { $0 })
            XCTAssertTrue(stages.withLock { $0.contains(.splitStagedReader) })
            XCTAssertFalse(stages.withLock { $0.contains(.splitWorkValidation) })
        }
    }

    func testSetDigestMatchesDiskMarkersDoneJournalAndStore() throws {
        let fixture = try VolumePublishFixture()
        var target = fixture.target()
        target.writesVolumeMetadata = true
        let publication = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(fixture.newBytes.count),
            index: fixture.index, operations: operations(fixture), fault: { if $0 == .committed { throw SimulatedCrash() } })
        defer { publication.cancel() }
        try fixture.newBytes.write(to: publication.workURL)
        XCTAssertThrowsError(try publication.publish(progress: Progress(), validation: { _ in })) { XCTAssertTrue($0 is SimulatedCrash) }
        let record = try VolumePublishJournal.inspect(VolumePublishDirectory(publication.stagingURL))
        XCTAssertEqual(record.phase, .done)
        let metadata = try XCTUnwrap(record.metadata)
        XCTAssertNoThrow(try metadata.validate())
        var digests = Data()
        for volume in fixture.plan.volumes {
            digests.append(contentsOf: SHA256.hash(data: try Data(contentsOf: fixture.root.appendingPathComponent(volume.name))))
        }
        let expected = SHA256.hash(data: digests).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(metadata.totalSHA256, expected)
        XCTAssertNotEqual(expected, VolumePublishFS.digest(fixture.newBytes))
        for (index, volume) in fixture.plan.volumes.enumerated() {
            let marker = try XCTUnwrap(ArchiveVolumeMetadata.read(ArchiveVolumeMetadata.Marker.self,
                key: ArchiveVolumeMetadata.setKey, at: fixture.root.appendingPathComponent(volume.name)))
            XCTAssertEqual(marker, metadata.marker(at: index))
            XCTAssertEqual(marker.totalSHA256, expected)
        }
        let layout = ArchiveVolumeLayout(scheme: fixture.scheme, volumes: fixture.plan.volumes.map {
            .init(url: fixture.root.appendingPathComponent($0.name), length: $0.length)
        }, openedVolumeIndex: 0)
        let store = ArchiveVolumeMetadataStore(fileURL: try volumePublishTestURL(fixture.directory.url).appendingPathComponent("metadata.json"))
        try store.save(metadata, layout: layout)
        let saved = try XCTUnwrap(store.entry(for: layout.gateURL))
        XCTAssertNoThrow(try saved.publication.validate())
        XCTAssertEqual(saved.publication.totalSHA256, expected)
        XCTAssertEqual(saved.publication.marker(at: 0), metadata.marker(at: 0))
    }

    private func writeXattr(_ bytes: Data, key: String, at url: URL) throws {
        let result = bytes.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw VolumePublishError.system(errno) }
    }

    func testVersion030MarkerLiteralRemainsReadableAndNotMixed() throws {
        let fixture = try VolumePublishFixture()
        let literals = [
            #"{"setUUID":"12345678-1234-1234-1234-123456789abc","generation":1,"index":0,"count":3,"totalSHA256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}"#,
            #"{"setUUID":"12345678-1234-1234-1234-123456789abc","generation":1,"index":1,"count":3,"totalSHA256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}"#,
            #"{"setUUID":"12345678-1234-1234-1234-123456789abc","generation":1,"index":2,"count":3,"totalSHA256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}"#
        ]
        for (volume, literal) in zip(try XCTUnwrap(fixture.layout).volumes, literals) {
            let bytes = Data(literal.utf8)
            XCTAssertNoThrow(try JSONDecoder().decode(ArchiveVolumeMetadata.Marker.self, from: bytes))
            try writeXattr(bytes, key: ArchiveVolumeMetadata.setKey, at: volume.url)
        }
        let reader = try ArchiveReader.open(url: fixture.gate)
        let store = ArchiveVolumeMetadataStore(fileURL: try volumePublishTestURL(fixture.directory.url).appendingPathComponent("metadata.json"))
        XCTAssertFalse(try ArchiveVolumeMetadata.inspect(url: fixture.gate, volumeSet: reader.volumeSet, store: store).mixed)
    }

    func testSetDigestRejectsMalformedHexAndPreservesVolumeOrder() throws {
        let first = VolumePublishJournalRecord.NewVolume(name: "a.001", length: 1, sha256: VolumePublishFS.digest(Data([1])))
        let second = VolumePublishJournalRecord.NewVolume(name: "a.002", length: 1, sha256: VolumePublishFS.digest(Data([2])))
        XCTAssertNotEqual(try ArchiveVolumeMetadata.setDigest([first, second]), try ArchiveVolumeMetadata.setDigest([second, first]))
        for hex in [String(repeating: "0", count: 63), String(repeating: "0", count: 65), String(repeating: "A", count: 64),
                    String(repeating: "g", count: 64), String(repeating: "é", count: 32)] {
            XCTAssertThrowsError(try ArchiveVolumeMetadata.setDigest([.init(name: "a.001", length: 1, sha256: hex)])) {
                XCTAssertEqual($0 as? VolumePublishError, .validationFailed)
            }
        }
    }

    func testGenerationOverflowIsRejectedBeforeSplit() throws {
        let fixture = try VolumePublishFixture(), stages = Mutex<[ArchiveStageDiagnostics.Stage]>([])
        let marker = ArchiveVolumeMetadata.Marker(setUUID: UUID(), generation: .max, index: 0,
                                                  count: fixture.oldParts.count, totalSHA256: String(repeating: "a", count: 64))
        try writeXattr(JSONEncoder().encode(marker), key: ArchiveVolumeMetadata.setKey, at: fixture.gate)
        var target = fixture.target()
        target.writesVolumeMetadata = true
        let publication = try VolumeSetPublication.begin(target, estimatedOutputLength: UInt64(fixture.newBytes.count),
            index: fixture.index, operations: operations(fixture))
        defer { publication.cancel() }
        try fixture.newBytes.write(to: publication.workURL)
        XCTAssertThrowsError(try ArchiveStageDiagnostics.observer.withValue({ event in
            if case .began(_, let stage) = event { stages.withLock { $0.append(stage) } }
        }) { try publication.publish(progress: Progress(), validation: { _ in }) }) {
            XCTAssertEqual($0 as? VolumePublishError, .validationFailed)
        }
        XCTAssertFalse(stages.withLock { $0.contains(.splitCopy) })
        try fixture.assertOld()
    }

    func testInputCopyHashesOnlyWhenRequired() throws {
        for mode in ["save-as", "apfs", "msdos"] {
            let fixture = try VolumePublishFixture(), counter = ArchiveTestCounter()
            try requireAPFS(fixture)
            var operations = operations(fixture)
            if mode == "msdos" { injectVolume(&operations, fileSystem: "msdos", hazard: "msdos") }
            let publication = try VolumeSetPublication.begin(fixture.target(consent: true),
                estimatedOutputLength: UInt64(fixture.newBytes.count), index: fixture.index, operations: operations)
            defer { publication.cancel() }
            let source = try mode == "save-as"
                ? ArchiveVolumeInput(layout: XCTUnwrap(fixture.layout), expected: XCTUnwrap(fixture.expected))
                : XCTUnwrap(publication.input)
            try ArchiveTestCounters.splitInputHashes.withValue(counter) { try source.copy(to: publication.workURL, progress: Progress()) }
            XCTAssertEqual(counter.value, mode == "msdos" ? fixture.oldParts.count : 0)
            XCTAssertEqual(try Data(contentsOf: publication.workURL), fixture.oldBytes)
            try fixture.assertOld()
        }
    }
}
#endif
