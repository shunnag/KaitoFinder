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
        let parent = try VolumePublishDirectory(layout.gateURL.deletingLastPathComponent())
        let hashes = try VolumePublishFS.volumeInfo(parent).needsOldHashes
        self.layout = layout; self.expected = expected; usesHashes = hashes
        oldVolumes = try expected.volumes.map {
            .init($0, sha256: hashes ? try VolumePublishFS.hash(parent, $0.fileName) : nil)
        }
        try verify(nil, requiresAssembledSet: false)
    }

    init(layout: ArchiveVolumeLayout, expected: ArchiveSetIdentity,
         oldVolumes: [VolumePublishJournalRecord.OldVolume], usesHashes: Bool) {
        self.layout = layout; self.expected = expected; self.oldVolumes = oldVolumes; self.usesHashes = usesHashes
    }

    func verify(_ set: ArchiveVolumeSet?, requiresAssembledSet: Bool = true) throws {
        if let set {
            guard ArchiveSetIdentity(volumeSet: set) == expected else { throw VolumePublishError.setChanged }
        } else if requiresAssembledSet, expected.volumes.count != 1 { throw VolumePublishError.setChanged }
        guard try ArchiveSetIdentity.capture(layout: layout) == expected else { throw VolumePublishError.setChanged }
        let parent = try VolumePublishDirectory(layout.gateURL.deletingLastPathComponent())
        for volume in oldVolumes {
            guard try volume.matches(in: parent, useHash: usesHashes) else { throw VolumePublishError.setChanged }
        }
    }

    /// Stream, with fd and path checks before and after each member. Never follows a substituted symlink.
    func copy(to workURL: URL, progress: Progress) throws {
        try verify(nil, requiresAssembledSet: false)
        let parent = try VolumePublishDirectory(layout.gateURL.deletingLastPathComponent())
        let work = try VolumePublishDirectory(VolumePublishFS.canonicalParent(of: workURL))
        let output = try work.openFile(workURL.lastPathComponent, flags: O_WRONLY | O_CREAT | O_EXCL)
        defer { close(output) }
        var offset: UInt64 = 0
        for volume in oldVolumes {
            try ArchiveImportPlan.checkCancellation(progress)
            guard try volume.matches(in: parent, useHash: usesHashes) else { throw VolumePublishError.setChanged }
            let fd = try parent.openFile(volume.name)
            defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, let path = try parent.info(volume.name),
                  VolumePublishFS.sameFile(before, path) else { throw VolumePublishError.setChanged }
            var copied: UInt64 = 0
            while copied < volume.size {
                try ArchiveImportPlan.checkCancellation(progress)
                let data = try VolumePublishFS.read(fd, length: Int(min(1024 * 1024, volume.size - copied)), offset: copied)
                try VolumePublishFS.write(output, data: data, offset: offset + copied)
                copied += UInt64(data.count)
            }
            guard fstat(fd, &after) == 0, VolumePublishFS.sameFile(before, after),
                  try volume.matches(in: parent, useHash: usesHashes) else { throw VolumePublishError.setChanged }
            offset += copied
        }
        try verify(nil, requiresAssembledSet: false)
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
            catch UpdaterError.editingRefused {
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

    private static func rewrite(source: ArchiveVolumeInput, workURL: URL, format: GyoshukuKit.ArchiveFormat,
                                password: String?, options: WriterOptions, plan: ArchiveSaveReplayPlan,
                                progress: Progress, verifyAssembledInput: (ArchiveVolumeSet?) throws -> Void) throws {
        if ArchiveDeferredTarWriter.isNeeded(format: format, options: options) {
            try ArchiveDeferredTarWriter.write(source: source.layout.gateURL, password: password, output: workURL,
                format: format, options: options, plan: plan, progress: progress, verifyAssembledInput: { set in
                    try source.verify(set)
                    try verifyAssembledInput(set)
                })
        } else {
            let rewriter = try ArchiveRewriter.open(url: source.layout.gateURL, password: password,
                                                  output: workURL, format: format, options: options)
            try source.verify(rewriter.volumeSet)
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
