import Darwin
import Foundation

nonisolated extension StagingRegistry {
    @concurrent static func removeSnapshotInBackground(_ url: URL) async throws { try removeSnapshot(url) }

    static func copySnapshot(from source: URL, to target: URL, isDirectory: Bool,
                             progress: Progress = Progress(), allowsClone: Bool = true,
                             didCopy: (@Sendable (Int) -> Void)? = nil) throws {
        try ArchiveImportPlan.checkCancellation(progress)
        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
        var complete = false
        defer { if !complete { try? removeSnapshot(target) } }
        if isDirectory {
            // 子は planner の列挙単位で確保する。ACL・flags は即時追加と同様に格納しない。
            guard mkdir(target.path, 0o700) == 0 else { throw ExtractionFailure.system(errno) }
        } else if info.st_mode & S_IFMT == S_IFLNK {
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: source.path)
            guard symlink(destination, target.path) == 0 else { throw ExtractionFailure.system(errno) }
        } else {
            // schg を複製すると一般ユーザでは解除できない。flag 付き入力は本文だけを運ぶ。
            let cloned = allowsClone && info.st_flags == 0 && clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0
            if !cloned {
                let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard input >= 0 else { throw ExtractionFailure.system(errno) }
                defer { close(input) }
                let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard output >= 0 else { throw ExtractionFailure.system(errno) }
                defer { close(output) }
                var buffer = [UInt8](repeating: 0, count: Self.copyBufferSize)
                while true {
                    try ArchiveImportPlan.checkCancellation(progress)
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count >= 0 else { throw ExtractionFailure.system(errno) }
                    if count == 0 { break }
                    try buffer.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < count {
                            try ArchiveImportPlan.checkCancellation(progress)
                            let written = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), count - offset)
                            if written < 0, errno == EINTR { continue }
                            guard written > 0 else { throw ExtractionFailure.system(written == 0 ? EIO : errno) }
                            offset += written
                        }
                    }
                    didCopy?(count)
                }
            }
        }
        try clearRemovalRestrictions(target)
        try copyExtendedAttributes(from: source, to: target, progress: progress)
        // 所有者は sourceStamp に記録する。実ファイルの所有者や ACL を持ち出さない。
        guard lchmod(target.path, info.st_mode & 0o7777) == 0 else { throw ExtractionFailure.system(errno) }
        var times = [info.st_atimespec, info.st_mtimespec]
        guard utimensat(AT_FDCWD, target.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else { throw ExtractionFailure.system(errno) }
        try ArchiveImportPlan.checkCancellation(progress)
        complete = true
    }

    static func copyExtendedAttributes(from source: URL, to target: URL, progress: Progress,
        setValue: (URL, String, Data) throws -> Void = { url, name, data in
            let status = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            guard status == 0 else { throw ExtractionFailure.system(errno) }
        }) throws {
        let size = listxattr(source.path, nil, 0, XATTR_NOFOLLOW)
        if size < 0, errno == ENOTSUP || errno == EPERM { return }
        guard size >= 0 else { throw ExtractionFailure.system(errno) }
        var names = [CChar](repeating: 0, count: size)
        let count = names.withUnsafeMutableBufferPointer { listxattr(source.path, $0.baseAddress, $0.count, XATTR_NOFOLLOW) }
        guard count >= 0 else { throw ExtractionFailure.system(errno) }
        for bytes in names.prefix(count).split(separator: 0) {
            try ArchiveImportPlan.checkCancellation(progress)
            let name = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            do {
                let size = getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                guard size >= 0 else { throw ExtractionFailure.system(errno) }
                var data = Data(count: size)
                let count = data.withUnsafeMutableBytes { getxattr(source.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
                guard count >= 0 else { throw ExtractionFailure.system(errno) }
                try setValue(target, name, Data(data.prefix(count)))
            } catch ExtractionFailure.system(let code) where name != ExtractionQuarantine.name
                && [EPERM, EACCES, ENOTSUP, ENOATTR].contains(code) {
                // file provider の保護属性などは即時 writer も格納しない。本文の予約は続ける。
                continue
            }
        }
    }

    static func clearRemovalRestrictions(_ url: URL) throws {
        guard lchflags(url.path, 0) == 0 else { throw ExtractionFailure.system(errno) }
        guard let empty = acl_init(0) else { throw ExtractionFailure.system(errno) }
        defer { acl_free(UnsafeMutableRawPointer(empty)) }
        if acl_set_link_np(url.path, ACL_TYPE_EXTENDED, empty) != 0, errno != ENOTSUP {
            throw ExtractionFailure.system(errno)
        }
    }

    static func removeSnapshot(_ url: URL) throws {
        ArchiveReservationDiagnostics.record(.stagingDeletion)
        do { try FileManager.default.removeItem(at: url) }
        catch {
            var info = stat()
            if lstat(url.path, &info) != 0, errno == ENOENT { return }
            // 旧版で作られた退避物も回収する。symlink の宛先には触れない。
            func clear(_ item: URL) throws {
                var info = stat()
                guard lstat(item.path, &info) == 0 else { throw ExtractionFailure.system(errno) }
                try clearRemovalRestrictions(item)
                if info.isDirectory {
                    guard chmod(item.path, (info.st_mode & 0o777) | 0o700) == 0 else { throw ExtractionFailure.system(errno) }
                    for child in try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) { try clear(child) }
                }
            }
            try clear(url)
            try FileManager.default.removeItem(at: url)
        }
    }
}
