import Foundation
@_spi(TarEditLayout) @_spi(SevenZipEditLayout) import KaitoKit
import Synchronization

nonisolated enum FinderArchiveLimits {
    static let entry: UInt64 = 1 << 40
    static let total: UInt64 = 4 << 40
    static let expansion = ArchiveExpansionLimit(minimumAllowance: 1 << 30, maximumRatio: 1024)
    static let decodeMemory = ParallelDecodeMemoryBudget(capacity: ProcessInfo.processInfo.physicalMemory / 2)

    static var readLimits: ReadLimits { ReadLimits(maxEntrySize: entry, maxTotalUncompressedSize: total) }
}

nonisolated extension ReaderOptions {
    static func kaitoFinderVerification(password: String? = nil, defaults: UserDefaults = .standard,
                                        hardware: ArchiveHardware = .current) -> ReaderOptions {
        var options = kaitoFinder(password: password, defaults: defaults, hardware: hardware)
        options.lazyLocalHeaders = false
        return options
    }

    #if DEBUG
    /// テストが書庫を開いた回数を数えるためのもの（GyoshukuKit 内部の open は含まない）。
    static let kaitoFinderOpenCount = Mutex<Int>(0)
    #endif

    /// 大容量書庫の絶対上限と、実際の入力長に応じた総展開量の上限を併用する。
    /// 圧縮 tar の一時展開は KaitoKit の inMemorySingleFileLimit（既定 64 MiB）で
    /// メモリからディスクへ切り替わり、stagingFreeSpaceReserve（既定 1 GiB）を残す。
    /// stagingFreeSpaceReserve は既定を保ち、辞書上限だけは展開設定を適用する。
    static func kaitoFinder(password: String? = nil, defaults: UserDefaults = .standard,
                            hardware: ArchiveHardware = .current) -> ReaderOptions {
        #if DEBUG
        kaitoFinderOpenCount.withLock { $0 += 1 }
        #endif
        // .merge は __MACOSX/._name を隠して index を詰め直し、resource fork を
        // name/..namedfork/rsrc として公開する。削除で ArchiveUpdater.remove(entriesAt:) に
        // 渡す index と ArchiveCapabilities の entry 数を GyoshukuKit（.expose）に合わせる。
        // 表示と編集を .expose に統一し、Finder 製 ZIP の __MACOSX も一覧にそのまま見せる。
        var options = ReaderOptions(limits: FinderArchiveLimits.readLimits,
                                    password: password, appleDoublePolicy: .expose)
        options.expansionLimit = FinderArchiveLimits.expansion
        options.limits.maxDictionarySize = ArchivePreferencesStore.effectiveDictionarySize(defaults: defaults, hardware: hardware)
        // 圧縮と共通の「電力の使用方針」は、自動の復号並列数だけに適用する。
        options.decodePowerPolicy = ArchivePreferencesStore.storedPowerPolicy(defaults: defaults).decodePolicy
        options.recordsTarEditLayout = true
        options.recordsSevenZipEditLayout = true
        return options
    }
}

nonisolated extension ArchiveReader {
    static func openForFinder(url: URL, options: ReaderOptions) throws -> sending ArchiveReader {
        try ParallelDecodeMemoryBudget.$active.withValue(FinderArchiveLimits.decodeMemory) {
            try open(url: url, options: options)
        }
    }

    static func openForFinder(source: any ByteSource, sourceURL: URL?, options: ReaderOptions) throws -> sending ArchiveReader {
        try ParallelDecodeMemoryBudget.$active.withValue(FinderArchiveLimits.decodeMemory) {
            try open(source: source, sourceURL: sourceURL, options: options)
        }
    }

    func reopenForFinder(workers: Int = 1) throws -> sending ArchiveReader {
        let budget = FinderArchiveLimits.decodeMemory
        let result = try ParallelDecodeMemoryBudget.$active.withValue(budget) {
            let reader = workers <= 1 ? try reopen() : try reopen(parallelDecodeMemory: UInt64(budget.capacity / workers))
            return ArchiveReaderTransfer(reader)
        }
        return result.take()
    }
}

/// Transfers exclusive ownership across a task-local or thread boundary.
nonisolated final class ArchiveReaderTransfer: Sendable {
    private let reader: Mutex<ArchiveReader?>
    init(_ reader: sending ArchiveReader) { self.reader = Mutex(reader) }
    func take() -> sending ArchiveReader {
        reader.withLock { reader in
            let result = reader!
            reader = nil
            return result
        }
    }
}
