import Darwin
import Foundation

/// pasteboard の URL は終了後も生存させ、次回起動時にだけ掃除する。
/// itemReplacementDirectory は使用しない。root の注入はテスト用。
nonisolated struct ExtractionTemporaryDirectory {
    let root: URL

    init(root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("com.shunnag.KaitoFinder.Extraction", isDirectory: true)) {
        self.root = root
    }

    func create() throws -> URL {
        let directory = try openRoot()
        defer { close(directory) }
        let name = UUID().uuidString
        guard mkdirat(directory, name, 0o700) == 0 else { throw ExtractionFailure.system(errno) }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    func sweepOnLaunch() throws {
        let directory = try openRoot()
        defer { close(directory) }
        try removeChildren(directory)
    }

    private func openRoot() throws -> Int32 {
        guard root.isFileURL else { throw ExtractionFailure.refused("一時領域は file URL が必要です") }
        if mkdir(root.path, 0o700) != 0, errno != EEXIST { throw ExtractionFailure.system(errno) }
        let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ExtractionFailure.system(errno) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            close(directory)
            throw ExtractionFailure.refused("一時領域は現在のユーザー専用の実ディレクトリが必要です")
        }
        return directory
    }

    private func removeChildren(_ directory: Int32) throws {
        // fd を深さ分保持せず、root 相対の成分と訪問状態だけを積む。
        // 各処理の fd は次のディレクトリへ進む前に必ず閉じる。
        var pending: [(components: [String], remove: Bool)] = [([], false)]
        while let step = pending.popLast() {
            let components = step.remove ? Array(step.components.dropLast()) : step.components
            let current = try openDirectory(components, below: directory)
            defer { close(current) }
            if step.remove {
                guard unlinkat(current, step.components.last!, AT_REMOVEDIR) == 0 else {
                    throw ExtractionFailure.system(errno)
                }
                continue
            }
            if !step.components.isEmpty { pending.append((step.components, true)) }
            let copy = dup(current)
            guard copy >= 0 else { throw ExtractionFailure.system(errno) }
            guard let stream = fdopendir(copy) else { close(copy); throw ExtractionFailure.system(errno) }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let item = readdir(stream) else {
                    guard errno == 0 else { throw ExtractionFailure.system(errno) }
                    break
                }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                var info = stat()
                guard fstatat(current, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw ExtractionFailure.system(errno)
                }
                if info.st_mode & S_IFMT == S_IFDIR {
                    // 展開で復元した読み取り専用属性も掃除できる。リンク自身は辿らない。
                    guard fchmodat(current, name, 0o700, AT_SYMLINK_NOFOLLOW) == 0 else {
                        throw ExtractionFailure.system(errno)
                    }
                    pending.append((step.components + [name], false))
                } else if unlinkat(current, name, 0) != 0 { throw ExtractionFailure.system(errno) }
            }
        }
    }

    private func openDirectory(_ components: [String], below root: Int32) throws -> Int32 {
        var current = dup(root)
        guard current >= 0 else { throw ExtractionFailure.system(errno) }
        for component in components {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(current)
            guard next >= 0 else { throw ExtractionFailure.system(code) }
            current = next
        }
        return current
    }
}
