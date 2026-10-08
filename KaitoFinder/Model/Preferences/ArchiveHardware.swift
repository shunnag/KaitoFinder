import Foundation
import GyoshukuKit

nonisolated struct ArchiveHardware: Sendable, Equatable {
    var processors: Int
    var memory: UInt64
    // テストでは自動値だけを注入し、CPU 構成や電力状態に依存させない。
    var automaticThreads: Int? = nil

    static var current: Self {
        .init(processors: ProcessInfo.processInfo.activeProcessorCount, memory: ProcessInfo.processInfo.physicalMemory)
    }

    func automaticCompressionThreads(powerPolicy: CompressionPowerPolicy = .reduceInLowPowerMode) -> Int {
        automaticThreads ?? WriterOptions.automaticCompressionThreads(powerPolicy: powerPolicy)
    }

    static func estimatedLZMA2Memory(threads: Int) -> UInt64 {
        UInt64(30 + 135 * threads) * (1 << 20)
    }
}
