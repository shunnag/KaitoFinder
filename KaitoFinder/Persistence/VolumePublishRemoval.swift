import Darwin
import Foundation

/// Only recursively removes entries relative to already-open directories. Never traverses symlinks.
nonisolated enum VolumePublishRemoval {
    static func stagingName(_ name: String) -> String? {
        let base = name.hasSuffix(".discard") ? String(name.dropLast(8)) : name
        guard base.hasPrefix(VolumePublishFS.stagingPrefix),
              UUID(uuidString: String(base.dropFirst(VolumePublishFS.stagingPrefix.count))) != nil else { return nil }
        return base
    }

    static func requireIdentity(_ directory: VolumePublishDirectory, in parent: VolumePublishDirectory, name: String) throws {
        var held = stat()
        guard fstat(directory.fd, &held) == 0, let current = try parent.info(name),
              current.st_mode & S_IFMT == S_IFDIR, held.st_dev == current.st_dev, held.st_ino == current.st_ino else {
            throw VolumePublishError.setChanged
        }
    }

    static func discard(_ staging: VolumePublishDirectory, parent: VolumePublishDirectory,
                        operations: VolumePublishOperations) throws {
        let name = staging.url.lastPathComponent
        guard stagingName(name) == name else { throw VolumePublishError.unsafePath(name) }
        let tombstone = name + ".discard"
        try requireIdentity(staging, in: parent, name: name)
        try parent.requireAbsent(tombstone)
        if renameatx_np(parent.fd, name, parent.fd, tombstone, UInt32(RENAME_EXCL)) != 0 {
            guard errno == ENOTSUP || errno == EOPNOTSUPP else { throw VolumePublishError.system(errno) }
            // Same documented noncooperating-writer race as the volume rename fallback.
            try parent.requireAbsent(tombstone)
            guard renameat(parent.fd, name, parent.fd, tombstone) == 0 else { throw VolumePublishError.system(errno) }
        }
        try requireIdentity(staging, in: parent, name: tombstone)
        try parent.sync(full: true) // Durable deletion authorization, independent of the index/journal.
        try remove(tombstone, from: parent, operations: operations)
        try parent.sync(full: true)
    }

    static func remove(_ name: String, from parent: VolumePublishDirectory,
                       operations: VolumePublishOperations) throws {
        try VolumePublishFS.checkName(name)
        try operations.willRemove(parent.url.appendingPathComponent(name))
        guard let info = try parent.info(name) else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            let child = try parent.directory(name) // openat(O_DIRECTORY | O_NOFOLLOW)
            try requireIdentity(child, in: parent, name: name)
            // Keep the journal until all other entries are gone, even within reserved subtrees.
            let names = try child.names().sorted { lhs, rhs in
                if lhs == VolumePublishJournal.fileName { return false }
                if rhs == VolumePublishJournal.fileName { return true }
                return lhs < rhs
            }
            for entry in names { try remove(entry, from: child, operations: operations) }
            try child.sync()
            try requireIdentity(child, in: parent, name: name)
            guard unlinkat(parent.fd, name, AT_REMOVEDIR) == 0 else { throw VolumePublishError.system(errno) }
        } else {
            // This also unlinks a symlink itself; it never opens its target.
            guard unlinkat(parent.fd, name, 0) == 0 else { throw VolumePublishError.system(errno) }
        }
        try operations.didRemove(parent.url.appendingPathComponent(name))
    }
}
