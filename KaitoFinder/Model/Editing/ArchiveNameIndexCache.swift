import GyoshukuKit
import Synchronization

/// ArchiveSession が持つ名前索引の置き場。世代と形式が一致する索引だけを返し、
/// 同じ世代では表現可能性を証明済みの索引を、より新しい世代の索引を優先して保持する。
/// 索引の構築や reader の参照は行わず、actor が渡した値を預かるだけ。
nonisolated final class ArchiveNameIndexCache: Sendable {
    #if DEBUG
    /// 真の間は索引を返さず、預かりもしない。索引なしの経路と結果が一致することをテストが確かめる。
    static let disabledForTesting = TaskLocal<Bool>(wrappedValue: false)
    #endif

    private let storage = Mutex<ArchiveNameIndex?>(nil)

    func index(generation: UInt64, format: GyoshukuKit.ArchiveFormat) -> ArchiveNameIndex? {
        #if DEBUG
        if Self.disabledForTesting.get() { return nil }
        #endif
        return storage.withLock { index in
            guard let index, index.generation == generation, index.format == format else { return nil }
            return index
        }
    }

    func adopt(_ index: ArchiveNameIndex) {
        #if DEBUG
        if Self.disabledForTesting.get() { return }
        #endif
        storage.withLock { stored in
            if let stored {
                if stored.generation > index.generation { return }
                if stored.generation == index.generation, stored.representable || !index.representable { return }
            }
            stored = index
        }
    }

    /// 予約の検証が占有表を持つときだけ、証明済みの索引として預かる。
    func adopt(validation: ArchiveReservationValidation?, generation: UInt64) {
        guard let validation, let occupancy = validation.occupancy else { return }
        adopt(.init(generation: generation, format: validation.format, entryCount: validation.base.count,
                    containsHardLinks: false, occupancy: occupancy, representable: true))
    }

    func clear() { storage.withLock { $0 = nil } }
}
