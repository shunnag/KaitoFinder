import Darwin
import Foundation
import KaitoKit

/// root を呼出側が排他的に所有する間だけ使う、同期 worker 専用の出力先。
/// パスの実体検査に加え、各成分を descriptor 相対・NOFOLLOW で開く。
/// キャッシュは「1 インスタンス = 1 つの同期 worker」に依存する（§12-4 の並列展開では worker ごとに作る）。
nonisolated final class ExtractionDestination {
    private let root: URL
    private let descriptor: Int32
    private let quarantine: Data?
    private let permissionMask: mode_t
    private let readOnly: Bool
    private let didWrite: (@Sendable (Int) -> Void)?
    private(set) var createdDirectories: [URL] = []
    private var createdDirectoryPaths = Set<String>()
    private var identities: [String: (dev_t, ino_t)] = [:]
    private var cachedParent: (components: [String], descriptor: Int32)?
    private var cachedValidatedParent: [String]?
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    init(url: URL, quarantine: Data?, readOnly: Bool = false,
         didWrite: (@Sendable (Int) -> Void)? = nil) throws {
        self.readOnly = readOnly
        self.didWrite = didWrite
        guard url.isFileURL else { throw ExtractionFailure.refused(String(localized: "出力先はfile URLが必要です。")) }
        guard let resolvedRoot = ExtractionPath.resolvedPath(url.path) else {
            throw ExtractionFailure.refused(String(localized: "出力先の実パスを解決できません。"))
        }
        // 元のパスを NOFOLLOW で開き、root 自身の symlink を拒否する（祖先の別名は許す）。
        descriptor = Darwin.open(url.path, Self.directoryFlags)
        guard descriptor >= 0 else { throw ExtractionFailure.system(errno) }
        // target と同じ正規化を使い、Foundation による /private の省略と混在させない。
        root = URL(fileURLWithPath: resolvedRoot, isDirectory: true)
        self.quarantine = quarantine
        permissionMask = ExtractionPermissions.processMask
    }

    deinit {
        if let cachedParent { Darwin.close(cachedParent.descriptor) }
        Darwin.close(descriptor)
    }

    func url(_ components: [String]) -> URL {
        root.appendingPathComponent(components.joined(separator: "/"))
    }

    func validate(_ components: [String]) throws {
        let candidate = url(components)
        // containment検査のENOENT以外の失敗を「外側のパス」と誤報しない。
        // どの親も作る前に、終端NULを含むPATH_MAXと各成分のNAME_MAXを確認する。
        guard components.allSatisfy({ $0.utf8.count <= Int(NAME_MAX) }),
              candidate.path.utf8.count < Int(PATH_MAX) else {
            throw ExtractionFailure.system(ENAMETOOLONG)
        }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  !$0.utf8.contains(0) && !$0.utf8.contains(47) && !$0.utf8.contains(92) }) else {
            throw ExtractionFailure.refused(String(localized: "出力先の外へ解決されるパスです。"))
        }
        let parent = Array(components.dropLast())
        if parent != cachedValidatedParent {
            // root は init で検証済み。連続する兄弟では親の実体検査を共有する。
            guard parent.isEmpty || ExtractionPath.isInside(url(parent), root: root) else {
                // root 自身へ戻る親リンク等は従来の葉までの検査を保ち、NOFOLLOW の拒否理由を変えない。
                guard ExtractionPath.isInside(candidate, root: root) else {
                    throw ExtractionFailure.refused(String(localized: "出力先の外へ解決されるパスです。"))
                }
                return
            }
            cachedValidatedParent = parent
        }
        var info = stat()
        let exists = lstat(candidate.path, &info) == 0
        // 既存 symlink の葉と、ENOENT 以外の検査失敗は従来と同じ理由で拒否する。
        guard exists ? ExtractionPath.isInside(candidate, root: root) : errno == ENOENT else {
            throw ExtractionFailure.refused(String(localized: "出力先の外へ解決されるパスです。"))
        }
    }

    private func parentDescriptor(for components: [String]) throws -> Int32 {
        if let cachedParent, cachedParent.components == components { return cachedParent.descriptor }
        if let cachedParent { close(cachedParent.descriptor) }
        cachedParent = nil
        let parent = try openDirectory(components, create: true)
        cachedParent = (components, parent)
        return parent
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
                throw ExtractionFailure.refused(String(localized: "出力先に既存の項目があります。"))
            }
            guard errno == ENOENT else { throw ExtractionFailure.system(errno) }
        }
        let directory = try openDirectory(components, create: true)
        close(directory)
    }

    func file(_ components: [String], entry: ArchiveEntry, stream: EntryStream, buffer: inout [UInt8],
              checkCancellation: () throws -> Void) throws {
        let parent = try parentDescriptor(for: Array(components.dropLast()))
        let leaf = components.last!
        // 同名の既存ファイル、symlink、別 entry は絶対に上書きしない。
        let file = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw ExtractionFailure.system(errno) }
        var complete = false
        defer {
            close(file)
            if !complete { unlinkat(parent, leaf, 0) }
        }
        // 0600 のまま quarantine を先に適用し、CRC 検証完了後だけ既定の mode へ広げる。
        // 属性設定失敗時も未検証 payload を公開しない。宣言サイズで read を止めない。
        try ExtractionQuarantine.apply(quarantine, toDescriptor: file)
        try ExtractionService.consume(stream, buffer: &buffer, checkCancellation: checkCancellation) { bytes in
            var offset = 0
            while offset < bytes.count {
                try checkCancellation()
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ExtractionFailure.system(count == 0 ? EIO : errno) }
                offset += count
            }
            didWrite?(bytes.count)
        }
        try attributes(entry, descriptor: file)
        // プレビューと外部オープンは所有者の読み取りだけを許す。公開前、同じ fd で適用する。
        if readOnly {
            try ArchiveTemporaryCopy.mark(descriptor: file)
            if fchmod(file, 0o400) != 0 { throw ExtractionFailure.system(errno) }
        }
        try checkCancellation()
        var info = stat()
        guard fstat(file, &info) == 0 else { throw ExtractionFailure.system(errno) }
        identities[components.joined(separator: "/")] = (info.st_dev, info.st_ino)
        complete = true
    }

    func symlink(_ components: [String], target: String) throws {
        guard !target.isEmpty, !target.utf8.contains(0) else {
            throw ExtractionFailure.refused(String(localized: "シンボリックリンクのtargetが空またはNULを含みます。"))
        }
        let parentComponents = Array(components.dropLast())
        let parent = try parentDescriptor(for: parentComponents)
        // target の .. は先に潰さず、既存リンクの解決後に実ディレクトリを辿る。
        // 未作成の a/.. は拒否するため、後続 entry でも解釈を変更できない。
        let targetPath = target.hasPrefix("/") ? target : url(parentComponents).path + "/" + target
        guard let resolved = ExtractionPath.resolvedPath(targetPath, requireExistingParents: true),
              resolved == root.path || ExtractionPath.isInside(URL(fileURLWithPath: resolved), root: root),
              resolved != url(components).path else {
            throw ExtractionFailure.refused(String(localized: "シンボリックリンクのtargetが安全な出力先へ解決されません。"))
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
                    throw ExtractionFailure.refused(String(localized: "シンボリックリンクが自分自身を参照します。"))
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
            throw ExtractionFailure.refused(String(localized: "hard link targetのinodeが展開時と一致しません。"))
        }
        let parent = try parentDescriptor(for: Array(components.dropLast()))
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

    func finishSynthesizedDirectory(_ url: URL) throws {
        let components = Array(url.pathComponents.dropFirst(root.pathComponents.count))
        let directory = try openDirectory(components, create: false)
        defer { close(directory) }
        guard fchmod(directory, 0o777 & ~permissionMask) == 0 else { throw ExtractionFailure.system(errno) }
    }

    private func attributes(_ entry: ArchiveEntry, descriptor: Int32) throws {
        if let date = entry.modificationDate {
            // APFS の Int64 ナノ秒範囲へ飽和し、検証済みの本文を日時だけで捨てない。
            let value = date.timeIntervalSince1970
            let seconds = value.isNaN ? 0 : min(9_223_372_036, max(-9_223_372_036, value))
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
                         timespec(tv_sec: Int(floor(seconds)), tv_nsec: Int((seconds - floor(seconds)) * 1_000_000_000))]
            guard futimens(descriptor, &times) == 0 else { throw ExtractionFailure.system(errno) }
        }
        // 特殊ビットを除去し、格納 mode のない項目にも起動時の umask を反映する。
        // 格納 mode のない readOnly ファイルは、この後に 0400 とするまで 0600 を保つ。
        let mode = entry.posixPermissions.map { mode_t($0 & 0o777) }
            ?? (entry.kind == .directory ? 0o777 : readOnly ? nil : 0o666)
        if let mode, fchmod(descriptor, mode & ~permissionMask) != 0 {
            throw ExtractionFailure.system(errno)
        }
    }
}
