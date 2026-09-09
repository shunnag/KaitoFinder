import Darwin
import Foundation
import KaitoKit

/// root を呼出側が排他的に所有する間だけ使う、同期 worker 専用の出力先。
/// パスの実体検査に加え、各成分を descriptor 相対・NOFOLLOW で開く。
nonisolated final class ExtractionDestination {
    private let root: URL
    private let descriptor: Int32
    private let quarantine: Data?
    private let permissionMask: mode_t
    private(set) var createdDirectories: [URL] = []
    private var createdDirectoryPaths = Set<String>()
    private var identities: [String: (dev_t, ino_t)] = [:]
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    init(url: URL, quarantine: Data?) throws {
        guard url.isFileURL else { throw ExtractionFailure.refused("出力先は file URL が必要です") }
        guard let resolvedRoot = ExtractionPath.resolvedPath(url.path) else {
            throw ExtractionFailure.refused("出力先の実パスを解決できません")
        }
        // 元のパスを NOFOLLOW で開き、root 自身の symlink を拒否する（祖先の別名は許す）。
        descriptor = Darwin.open(url.path, Self.directoryFlags)
        guard descriptor >= 0 else { throw ExtractionFailure.system(errno) }
        // target と同じ正規化を使い、Foundation による /private の省略と混在させない。
        root = URL(fileURLWithPath: resolvedRoot, isDirectory: true)
        self.quarantine = quarantine
        permissionMask = ExtractionPermissions.processMask
    }

    deinit { Darwin.close(descriptor) }

    func url(_ components: [String]) -> URL {
        components.reduce(root) { $0.appendingPathComponent($1) }
    }

    func validate(_ components: [String]) throws {
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  !$0.utf8.contains(0) && !$0.utf8.contains(47) && !$0.utf8.contains(92) }),
              ExtractionPath.isInside(url(components), root: root) else {
            throw ExtractionFailure.refused("出力先の外へ解決されるパスです")
        }
    }

    private func openDirectory(_ components: [String], create: Bool) throws -> Int32 {
        var current = dup(descriptor)
        guard current >= 0 else { throw ExtractionFailure.system(errno) }
        var traversed: [String] = []
        do {
            for component in components {
                traversed.append(component)
                var created = false
                if create {
                    if mkdirat(current, component, 0o700) == 0 { created = true }
                    else if errno != EEXIST { throw ExtractionFailure.system(errno) }
                }
                let next = openat(current, component, Self.directoryFlags)
                guard next >= 0 else { throw ExtractionFailure.system(errno) }
                if created {
                    do { try ExtractionQuarantine.apply(quarantine, toDescriptor: next) }
                    catch {
                        close(next)
                        unlinkat(current, component, AT_REMOVEDIR)
                        throw error
                    }
                    createdDirectories.append(url(traversed))
                    createdDirectoryPaths.insert(traversed.joined(separator: "/"))
                }
                close(current)
                current = next
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    func directory(_ components: [String], explicit: Bool) throws {
        // 今回合成した directory だけを明示 entry に昇格できる。既存の属性は奪わない。
        if explicit, !createdDirectoryPaths.contains(components.joined(separator: "/")) {
            let parent = try openDirectory(Array(components.dropLast()), create: true)
            defer { close(parent) }
            var info = stat()
            if fstatat(parent, components.last!, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                throw ExtractionFailure.refused("出力先に既存の項目があります")
            }
            guard errno == ENOENT else { throw ExtractionFailure.system(errno) }
        }
        let directory = try openDirectory(components, create: true)
        close(directory)
    }

    func file(_ components: [String], entry: ArchiveEntry, stream: EntryStream,
              checkCancellation: () throws -> Void) throws {
        let parent = try openDirectory(Array(components.dropLast()), create: true)
        defer { close(parent) }
        let leaf = components.last!
        // 同名の既存ファイル、symlink、別 entry は絶対に上書きしない。
        let file = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw ExtractionFailure.system(errno) }
        var complete = false
        defer {
            close(file)
            if !complete { unlinkat(parent, leaf, 0) }
        }
        // 属性設定失敗時も未検証 payload を公開しない。宣言サイズで read を止めない。
        try ExtractionQuarantine.apply(quarantine, toDescriptor: file)
        try ExtractionService.consume(stream, checkCancellation: checkCancellation) { bytes in
            var offset = 0
            while offset < bytes.count {
                try checkCancellation()
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ExtractionFailure.system(count == 0 ? EIO : errno) }
                offset += count
            }
        }
        try attributes(entry, descriptor: file)
        var info = stat()
        guard fstat(file, &info) == 0 else { throw ExtractionFailure.system(errno) }
        identities[components.joined(separator: "/")] = (info.st_dev, info.st_ino)
        complete = true
    }

    func symlink(_ components: [String], target: String) throws {
        guard !target.isEmpty, !target.utf8.contains(0) else {
            throw ExtractionFailure.refused("シンボリックリンクの target が空または NUL を含みます")
        }
        let parentComponents = Array(components.dropLast())
        let parent = try openDirectory(parentComponents, create: true)
        defer { close(parent) }
        // target の .. は先に潰さず、既存リンクの解決後に実ディレクトリを辿る。
        // 未作成の a/.. は拒否するため、後続 entry でも解釈を変更できない。
        let targetPath = target.hasPrefix("/") ? target : url(parentComponents).path + "/" + target
        guard let resolved = ExtractionPath.resolvedPath(targetPath, requireExistingParents: true),
              resolved == root.path || ExtractionPath.isInside(URL(fileURLWithPath: resolved), root: root),
              resolved != url(components).path else {
            throw ExtractionFailure.refused("シンボリックリンクの target が安全な出力先へ解決されません")
        }
        let leaf = components.last!
        guard symlinkat(target, parent, leaf) == 0 else { throw ExtractionFailure.system(errno) }
        do {
            // 大文字小文字など、文字列が違っても同じ inode を指す自己参照を拒否する。
            var linkInfo = stat(), targetInfo = stat()
            guard fstatat(parent, leaf, &linkInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw ExtractionFailure.system(errno)
            }
            if lstat(resolved, &targetInfo) == 0 {
                guard linkInfo.st_dev != targetInfo.st_dev || linkInfo.st_ino != targetInfo.st_ino else {
                    throw ExtractionFailure.refused("シンボリックリンクが自分自身を参照します")
                }
            } else if errno != ENOENT { throw ExtractionFailure.system(errno) }
            try ExtractionQuarantine.apply(quarantine, to: url(components))
        }
        catch { unlinkat(parent, leaf, 0); throw error }
    }

    func hardlink(_ components: [String], target: [String]) throws {
        let source = try openDirectory(Array(target.dropLast()), create: false)
        defer { close(source) }
        var info = stat()
        guard fstatat(source, target.last!, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ExtractionFailure.system(errno)
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              let identity = identities[target.joined(separator: "/")],
              info.st_dev == identity.0, info.st_ino == identity.1 else {
            throw ExtractionFailure.refused("hard link target の inode が展開時と一致しません")
        }
        let parent = try openDirectory(Array(components.dropLast()), create: true)
        defer { close(parent) }
        guard linkat(source, target.last!, parent, components.last!, 0) == 0 else {
            throw ExtractionFailure.system(errno)
        }
        identities[components.joined(separator: "/")] = identity
    }

    func finishDirectory(_ components: [String], entry: ArchiveEntry) throws {
        let directory = try openDirectory(components, create: false)
        defer { close(directory) }
        try attributes(entry, descriptor: directory)
    }

    private func attributes(_ entry: ArchiveEntry, descriptor: Int32) throws {
        if let date = entry.modificationDate {
            let seconds = date.timeIntervalSince1970
            guard seconds.isFinite, seconds > Double(Int.min), seconds < Double(Int.max) else {
                throw ExtractionFailure.refused("変更日時が範囲外です")
            }
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                         timespec(tv_sec: Int(floor(seconds)), tv_nsec: Int((seconds - floor(seconds)) * 1_000_000_000))]
            guard futimens(descriptor, &times) == 0 else { throw ExtractionFailure.system(errno) }
        }
        if let mode = entry.posixPermissions {
            // 特殊ビットを除去し、fchmod にも起動時の umask を明示的に反映する。
            guard fchmod(descriptor, mode_t(mode & 0o777) & ~permissionMask) == 0 else {
                throw ExtractionFailure.system(errno)
            }
        }
    }
}
