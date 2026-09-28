import Darwin
import Foundation
import Synchronization

nonisolated final class VolumePublishLock: Sendable {
    private let descriptor: Mutex<Int32>
    private let directory: VolumePublishDirectory
    private let name: String
    init(directory: VolumePublishDirectory, name: String, create: Bool = true) throws {
        let fd = try directory.openFile(name, flags: O_RDWR | (create ? O_CREAT : 0))
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno; close(fd)
            if error == EWOULDBLOCK { throw VolumePublishError.ownerAlive }
            throw VolumePublishError.system(error)
        }
        // A sweep may unlink an unlocked file after open but before flock. Never own an old inode.
        var held = stat()
        do {
            guard fstat(fd, &held) == 0, let current = try directory.info(name),
                  held.st_dev == current.st_dev, held.st_ino == current.st_ino else { throw VolumePublishError.ownerAlive }
        } catch { close(fd); throw error }
        self.directory = directory; self.name = name; descriptor = Mutex(fd)
    }
    func release() { descriptor.withLock { if $0 >= 0 { close($0); $0 = -1 } } }
    deinit { release() }

    private func remove() throws {
        try descriptor.withLock { fd in
            var held = stat()
            guard fd >= 0, fstat(fd, &held) == 0 else { throw VolumePublishError.alreadyUsed }
            guard let current = try directory.info(name) else { return }
            guard held.st_dev == current.st_dev, held.st_ino == current.st_ino else { throw VolumePublishError.setChanged }
            guard unlinkat(directory.fd, name, 0) == 0 else { throw VolumePublishError.system(errno) }
            try directory.sync()
        }
    }

    func removeIfResolved(_ stagingName: String, parent: VolumePublishDirectory, index: RecoverableWorkIndex) throws {
        guard let base = VolumePublishRemoval.stagingName(stagingName),
              try parent.info(base) == nil, try parent.info(base + ".discard") == nil,
              try !index.entries().contains(where: { URL(fileURLWithPath: $0.stagingPath).lastPathComponent == base }) else { return }
        try remove() // Unlink before releasing flock, after both work and hint have gone.
    }

    /// This is a released, read-only ownership probe, never a staging lock held across set acquisition.
    static func stagingIsOwned(_ name: String, directory: URL) throws -> Bool {
        guard let base = VolumePublishRemoval.stagingName(name) else { throw VolumePublishError.unsafePath(name) }
        do {
            let lock = try VolumePublishLock(directory: VolumePublishFS.supportDirectory(directory), name: base + ".lock", create: false)
            lock.release()
            return false
        } catch VolumePublishError.ownerAlive { return true }
        catch VolumePublishError.system(ENOENT) { return false }
    }

    static func sweepStagingLocks(index: RecoverableWorkIndex) throws {
        let directory = try VolumePublishFS.supportDirectory(index.stagingLocksURL)
        for name in try directory.names() where name.hasSuffix(".lock") {
            let base = String(name.dropLast(5))
            guard VolumePublishRemoval.stagingName(base) == base else { continue }
            do {
                let lock = try VolumePublishLock(directory: directory, name: name, create: false)
                defer { lock.release() }
                // Registration precedes mkdir. An indexed or live pre-S1 staging must retain its lock.
                guard try !index.entries().contains(where: { URL(fileURLWithPath: $0.stagingPath).lastPathComponent == base }) else { continue }
                try lock.remove()
            } catch VolumePublishError.ownerAlive { continue }
            catch VolumePublishError.system(ENOENT) { continue }
        }
    }

    /// Local support lock survives journal closure, path rebasing, and the entire S1 window.
    static func stagingLock(_ name: String, directory: URL) throws -> VolumePublishLock {
        guard let base = VolumePublishRemoval.stagingName(name) else { throw VolumePublishError.unsafePath(name) }
        return try VolumePublishLock(directory: VolumePublishFS.supportDirectory(directory), name: base + ".lock")
    }

    static func setLock(volumeUUID: String, gateInode: UInt64?, parent: URL, gate: String,
                        directory: URL) throws -> VolumePublishLock {
        // gate inode は世代ごとに変わる。現在の親と名前で全世代・gate 不在時も競合させる。
        let parentDirectory = try VolumePublishDirectory(parent)
        var info = stat()
        guard fstat(parentDirectory.fd, &info) == 0 else { throw VolumePublishError.system(errno) }
        let key = volumeUUID + ":" + String(info.st_ino) + ":" + gate.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
        return try VolumePublishLock(directory: VolumePublishFS.supportDirectory(directory),
                                     name: VolumePublishFS.digest(Data(key.utf8)) + ".lock")
    }
}
