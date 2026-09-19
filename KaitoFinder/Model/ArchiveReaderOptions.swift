import KaitoKit
import Synchronization

nonisolated extension ReaderOptions {
    #if DEBUG
    /// テストが書庫を開いた回数を数えるためのもの（GyoshukuKit 内部の open は含まない）。
    static let kaitoFinderOpenCount = Mutex<Int>(0)
    #endif

    /// 項目ごと・全体のサイズ上限を解除し、展開は出力先の空き容量に従う。
    /// 圧縮 tar の一時展開は KaitoKit の inMemorySingleFileLimit（既定 64 MiB）で
    /// メモリからディスクへ切り替わり、stagingFreeSpaceReserve（既定 1 GiB）を残す。
    /// stagingFreeSpaceReserve を含む、その他すべての ReadLimits は既定値を保つ。
    static func kaitoFinder(password: String? = nil) -> ReaderOptions {
        #if DEBUG
        kaitoFinderOpenCount.withLock { $0 += 1 }
        #endif
        return ReaderOptions(limits: ReadLimits(maxEntrySize: .max, maxTotalUncompressedSize: .max), password: password)
    }
}
