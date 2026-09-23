import CryptoKit
import Darwin
import Foundation
import GyoshukuKit
import KaitoKit

/// An input set, independent of the output name, schedule and publication target (also used by M6).
nonisolated struct ArchiveVolumeInput: Sendable {
    let layout: ArchiveVolumeLayout
    let expected: ArchiveSetIdentity
    let oldVolumes: [VolumePublishJournalRecord.OldVolume]
    let usesHashes: Bool

    init(layout: ArchiveVolumeLayout, expected: ArchiveSetIdentity) throws {
        let layout = try layout.publicationLayout()
        self.layout = layout; self.expected = expected; usesHashes = false
        // Save As has no rollback baseline to hash: take one immutable, fd-checked streaming snapshot.
        oldVolumes = expected.volumes.map { .init($0, sha256: nil) }
        try verify(nil, requiresAssembledSet: false)
    }

    init(layout: ArchiveVolumeLayout, expected: ArchiveSetIdentity,
         oldVolumes: [VolumePublishJournalRecord.OldVolume], usesHashes: Bool) {
        self.layout = layout; self.expected = expected; self.oldVolumes = oldVolumes; self.usesHashes = usesHashes
    }

    func verify(_ set: ArchiveVolumeSet?, requiresAssembledSet: Bool = true,
                checkCancellation: () throws -> Void = {}, hashes: Bool = true) throws {
        try checkCancellation()
        if let set {
            guard ArchiveSetIdentity(volumeSet: set) == expected else { throw VolumePublishError.setChanged }
        } else if requiresAssembledSet, expected.volumes.count != 1 { throw VolumePublishError.setChanged }
        guard try ArchiveSetIdentity.capture(layout: layout) == expected else { throw VolumePublishError.setChanged }
        let parent = try VolumePublishDirectory(layout.gateURL.deletingLastPathComponent())
        for volume in oldVolumes {
            guard try volume.matches(in: parent, useHash: hashes && usesHashes, checkCancellation: checkCancellation) else { throw VolumePublishError.setChanged }
        }
    }

    /// Stream, with fd and path checks before and after each member. Never follows a substituted symlink.
    func copy(to workURL: URL, progress: Progress, didRead: (Int) -> Void = { _ in }) throws {
        func checkCancellation() throws { try ArchiveImportPlan.checkCancellation(progress) }
        try verify(nil, requiresAssembledSet: false, checkCancellation: checkCancellation, hashes: false)
        let parent = try VolumePublishDirectory(layout.gateURL.deletingLastPathComponent())
        let work = try VolumePublishDirectory(VolumePublishFS.canonicalParent(of: workURL))
        let output = try work.openFile(workURL.lastPathComponent, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(output) }
        var offset: UInt64 = 0
        for volume in oldVolumes {
            try checkCancellation()
            guard try volume.matches(in: parent, useHash: false) else { throw VolumePublishError.setChanged }
            let fd = try parent.openFile(volume.name)
            defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, let path = try parent.info(volume.name),
                  VolumePublishFS.sameFile(before, path) else { throw VolumePublishError.setChanged }
            var copied: UInt64 = 0, hash = SHA256()
            while copied < volume.size {
                try checkCancellation()
                let data = try VolumePublishFS.read(fd, length: Int(min(1024 * 1024, volume.size - copied)), offset: copied)
                hash.update(data: data)
                try VolumePublishFS.write(output, data: data, offset: offset + copied)
                copied += UInt64(data.count)
                didRead(data.count)
            }
            try checkCancellation()
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard !usesHashes || digest == volume.sha256,
                  fstat(fd, &after) == 0, VolumePublishTransaction.Stamp(before) == VolumePublishTransaction.Stamp(after),
                  let pathAfter = try parent.info(volume.name),
                  VolumePublishTransaction.Stamp(after) == VolumePublishTransaction.Stamp(pathAfter),
                  try volume.matches(in: parent, useHash: false) else { throw VolumePublishError.setChanged }
            offset += copied
        }
        try verify(nil, requiresAssembledSet: false, checkCancellation: checkCancellation, hashes: false)
        try VolumePublishFS.sync(output)
    }
}

nonisolated enum ArchiveSplitWorkProducer {
    struct Result: Sendable { let recompressedZIP: Bool }

    /// Produces a complete single archive W. The verifier is called BEFORE any pending edit is replayed.
    /// Overwrite passes publication.verifyAssembledInput; a new-set caller can pass source.verify.
    static func produce(source: ArchiveVolumeInput, workURL: URL, mode: ArchiveCapabilities.Mode,
                        password: String?, options: WriterOptions, plan: ArchiveSaveReplayPlan,
                        progress: Progress, verifyAssembledInput: (ArchiveVolumeSet?) throws -> Void) throws -> Result {
        try plan.validate()
        switch mode {
        case .inPlace:
            try source.copy(to: workURL, progress: progress)
            let updater: ArchiveUpdater
            do { updater = try ArchiveUpdater.open(url: workURL, options: options) }
            catch let error as UpdaterError where isStructuralRefusal(error) {
                try FileManager.default.removeItem(at: workURL)
                try rewrite(source: source, workURL: workURL, format: .zip, password: password, options: options,
                            plan: plan, progress: progress, verifyAssembledInput: verifyAssembledInput)
                return Result(recompressedZIP: true)
            }
            try plan.replay(on: updater, progress: progress)
            try ArchiveImportPlan.checkCancellation(progress)
            try updater.commit()
        case .rewrite(let format):
            try rewrite(source: source, workURL: workURL, format: format, password: password, options: options,
                        plan: plan, progress: progress, verifyAssembledInput: verifyAssembledInput)
        }
        return Result(recompressedZIP: false)
    }

    private static func isStructuralRefusal(_ error: UpdaterError) -> Bool {
        switch error {
        case .editingRefused, .invalidArchive, .nonRelocatableEntry: true
        case .invalidEntryIndex, .sourceChanged, .invalidState: false
        }
    }

    static func produce(existing: ArchiveCreationPlan.Existing, workURL: URL,
                        format: GyoshukuKit.ArchiveFormat, options: WriterOptions,
                        plan: ArchiveSaveReplayPlan, progress: Progress, didRead: (Int) -> Void = { _ in }) throws -> Result {
        let expected = try existing.identity ?? ArchiveSetIdentity.capture(url: existing.url, layout: existing.volumeLayout)
        if let layout = existing.volumeLayout, case .numbered = layout.scheme {
            let input = try ArchiveVolumeInput(layout: layout, expected: expected)
            let joined = workURL.deletingLastPathComponent().appendingPathComponent("input-" + UUID().uuidString + "-" + layout.gateURL.deletingPathExtension().lastPathComponent)
            defer { try? FileManager.default.removeItem(at: joined) }
            try input.copy(to: joined, progress: progress, didRead: didRead)
            try rewrite(sourceURL: joined, workURL: workURL, format: format, password: existing.password,
                options: options, plan: plan, progress: progress) { set in
                    guard set == nil else { throw VolumePublishError.setChanged }
                    try input.verify(nil, requiresAssembledSet: false, checkCancellation: { try ArchiveImportPlan.checkCancellation(progress) })
                }
            try input.verify(nil, requiresAssembledSet: false, checkCancellation: { try ArchiveImportPlan.checkCancellation(progress) })
            return Result(recompressedZIP: false)
        }
        func verify(_ set: ArchiveVolumeSet?) throws {
            if let set {
                guard ArchiveSetIdentity(volumeSet: set) == expected else { throw VolumePublishError.setChanged }
            } else if expected.volumes.count != 1 { throw VolumePublishError.setChanged }
            guard try ArchiveSetIdentity.capture(url: existing.url, layout: existing.volumeLayout) == expected else {
                throw VolumePublishError.setChanged
            }
        }
        try plan.validate()
        try rewrite(sourceURL: existing.url, workURL: workURL, format: format, password: existing.password,
                    options: options, plan: plan, progress: progress, verifyAssembledInput: verify)
        return Result(recompressedZIP: false)
    }

    private static func rewrite(source: ArchiveVolumeInput, workURL: URL, format: GyoshukuKit.ArchiveFormat,
                                password: String?, options: WriterOptions, plan: ArchiveSaveReplayPlan,
                                progress: Progress, verifyAssembledInput: (ArchiveVolumeSet?) throws -> Void) throws {
        try rewrite(sourceURL: source.layout.gateURL, workURL: workURL, format: format, password: password,
                    options: options, plan: plan, progress: progress) { set in
            try ArchiveImportPlan.checkCancellation(progress)
            try verifyAssembledInput(set)
        }
    }

    private static func rewrite(sourceURL: URL, workURL: URL, format: GyoshukuKit.ArchiveFormat,
                                password: String?, options: WriterOptions, plan: ArchiveSaveReplayPlan,
                                progress: Progress, verifyAssembledInput: (ArchiveVolumeSet?) throws -> Void) throws {
        if ArchiveDeferredTarWriter.isNeeded(format: format, options: options) {
            try ArchiveDeferredTarWriter.write(source: sourceURL, password: password, output: workURL,
                format: format, options: options, plan: plan, progress: progress, verifyAssembledInput: { set in
                    try verifyAssembledInput(set)
                })
        } else {
            let rewriter = try ArchiveRewriter.open(url: sourceURL, password: password,
                                                  output: workURL, format: format, options: options)
            try verifyAssembledInput(rewriter.volumeSet)
            try plan.replay(on: rewriter, progress: progress)
            try rewriter.commit { _, _ in try ArchiveImportPlan.checkCancellation(progress) }
        }
    }

    static func validate(_ reader: ArchiveReader, plan: ArchiveSaveReplayPlan) throws {
        // Rewriters may reorder additions and omit the nameless tar root. Compare normalized multisets.
        let expected = plan.projected.map { ArchiveEditPlan.key($0.name) }.filter { !$0.isEmpty }.sorted()
        let actual = reader.entries.map { ArchiveEditPlan.key($0.name) }.filter { !$0.isEmpty }.sorted()
        guard actual == expected else { throw VolumePublishError.validationFailed }
    }
}
