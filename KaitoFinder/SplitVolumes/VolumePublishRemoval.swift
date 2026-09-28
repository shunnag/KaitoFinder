import Darwin
import Foundation

/// 開いてあるディレクトリからの相対名でだけ再帰的に削除する。symlink はたどらない。
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
              current.isDirectory, held.st_dev == current.st_dev, held.st_ino == current.st_ino else {
            throw VolumePublishError.setChanged
        }
    }

    static func discard(_ staging: VolumePublishDirectory, parent: VolumePublishDirectory,
                        operations: VolumePublishOperations, isNetworkVolume: Bool = false) throws {
        let name = staging.url.lastPathComponent
        guard stagingName(name) == name else { throw VolumePublishError.unsafePath(name) }
        let tombstone = name + ".discard"
        try requireIdentity(staging, in: parent, name: name)
        try parent.requireAbsent(tombstone)
        var result = operations.renameStaging(parent.fd, name, tombstone, UInt32(RENAME_EXCL))
        if result != 0, errno == ENOTSUP || errno == EOPNOTSUPP {
            // 巻の rename の代替経路（VolumeExclusiveRename.move）と同じく、非協調 writer との既知の競合が残る。
            try parent.requireAbsent(tombstone)
            result = operations.renameStaging(parent.fd, name, tombstone, 0)
        }
        if result != 0 {
            let failure = errno
            guard isNetworkVolume, failure == EBUSY || failure == EACCES else { throw VolumePublishError.system(failure) }
            // 呼び出し側は処分してよいことを証明済みで、独立した staging lock を持っている。journal を最後まで残し、
            // 中断しても同じ証明をやり直せるようにする。journal を消す時点で、予約した領域はすでに空になっている。
            try requireIdentity(staging, in: parent, name: name)
            try remove(name, from: parent, operations: operations)
            try parent.sync(full: true)
            return
        }
        try requireIdentity(staging, in: parent, name: tombstone)
        try parent.sync(full: true) // 削除の許可（.discard への改名）を、索引や journal とは独立に durable にする。
        try remove(tombstone, from: parent, operations: operations)
        try parent.sync(full: true)
    }

    static func remove(_ name: String, from parent: VolumePublishDirectory,
                       operations: VolumePublishOperations) throws {
        try VolumePublishFS.checkName(name)
        try operations.willRemove(parent.url.appendingPathComponent(name))
        guard let info = try parent.info(name) else { return }
        if info.isDirectory {
            let child = try parent.directory(name) // openat(O_DIRECTORY | O_NOFOLLOW) で開く。
            try requireIdentity(child, in: parent, name: name)
            // 予約した部分木の中でも、ほかの項目をすべて消すまで journal は残す。
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
            // symlink もそれ自体を unlink する。参照先は開かない。
            guard unlinkat(parent.fd, name, 0) == 0 else { throw VolumePublishError.system(errno) }
        }
        try operations.didRemove(parent.url.appendingPathComponent(name))
    }
}
