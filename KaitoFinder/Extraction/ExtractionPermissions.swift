import Darwin

nonisolated enum ExtractionPermissions {
    // プロセス全体の値なので起動時に一度だけ取得して直ちに戻す。
    // worker ごとに umask(0) を呼ぶと、別 worker の作成権限まで緩めてしまう。
    static let processMask: mode_t = {
        let mask = umask(0)
        umask(mask)
        return mask
    }()
}
