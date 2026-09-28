import Foundation

nonisolated struct ArchiveHardware: Sendable, Equatable {
    var processors: Int
    var memory: UInt64

    static var current: Self {
        .init(processors: ProcessInfo.processInfo.activeProcessorCount, memory: ProcessInfo.processInfo.physicalMemory)
    }

    var automaticCompressionThreads: Int {
        // GK の resolvedCompressionThreads は internal のため、同じ式をここに写す。
        max(1, min(processors, 8, Int(memory >> 30)))
    }

    static func estimatedLZMA2Memory(threads: Int) -> UInt64 {
        UInt64(30 + 135 * threads) * (1 << 20)
    }
}
