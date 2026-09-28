import CryptoKit
import Darwin
import Foundation
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
        #if DEBUG
        let span = ArchiveStageDiagnostics.begin(.splitInputCopy)
        defer { span?.end() }
        #endif
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
            // hash と比べない入力でも、fd・path・stamp の前後の照合は必ず残す。
            var copied: UInt64 = 0
            var hash: SHA256? = usesHashes ? SHA256() : nil
            #if DEBUG
            if usesHashes { ArchiveTestCounters.splitInputHashes.get()?.increment() }
            #endif
            while copied < volume.size {
                try checkCancellation()
                let data = try VolumePublishFS.read(fd, length: Int(min(VolumePublishFS.hashChunkSize, volume.size - copied)), offset: copied)
                hash?.update(data: data)
                try VolumePublishFS.write(output, data: data, offset: offset + copied)
                copied += UInt64(data.count)
                didRead(data.count)
            }
            try checkCancellation()
            let digest = hash.map { VolumePublishFS.hex($0.finalize()) }
            guard !usesHashes || digest == volume.sha256,
                  fstat(fd, &after) == 0, VolumeFileStamp(before) == VolumeFileStamp(after),
                  let pathAfter = try parent.info(volume.name),
                  VolumeFileStamp(after) == VolumeFileStamp(pathAfter),
                  try volume.matches(in: parent, useHash: false) else { throw VolumePublishError.setChanged }
            offset += copied
        }
        try verify(nil, requiresAssembledSet: false, checkCancellation: checkCancellation, hashes: false)
        try VolumePublishFS.sync(output)
    }
}
