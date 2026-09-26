import CoreFoundation
import Foundation
import GyoshukuKit

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

/// 書き込み処理へ安全に渡せる設定値。展開設定は一括展開の入口から参照する。
nonisolated struct ArchivePreferences: Sendable, Equatable {
    enum ZipMethod: String, Sendable { case deflate, stored }
    enum ExtractionDestination: String, Sendable { case sameFolder, ask }
    enum FolderPolicy: String, Sendable { case always, whenMultipleTopLevelItems, never }
    enum SaveBehavior: String, Sendable, CaseIterable { case immediate, onSave }
    enum OpeningBehavior: String, Sendable, CaseIterable { case system, newTab, newWindow }
    enum FolderOpening: String, Sendable, CaseIterable { case enter, expand }
    enum AdditionPosition: String, Sendable, CaseIterable { case end, beginning }
    enum CarriedOwnerIDPolicy: String, Sendable, CaseIterable { case keep, reset }

    static let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha]
    static let compressionThreadRange = 1...64

    var defaultFormat: GyoshukuKit.ArchiveFormat = .zip
    var compressionThreads = 0
    var zipMethod: ZipMethod = .deflate
    var zipLevel = 6
    var zipSkipsCompressedTypes = true
    var tarGzipLevel = 6
    var tarBzip2Level = 9
    var tarPreservesOwnerIDs = false
    var additionPosition: AdditionPosition = .end
    var tarCarriedOwnerIDs: CarriedOwnerIDPolicy = .keep
    var extractionDestination: ExtractionDestination = .sameFolder
    var folderPolicy: FolderPolicy = .whenMultipleTopLevelItems
    var trashesArchiveAfterExtraction = false
    var revealsExtractedItemsInFinder = false
    var keepsFoldersOnTop = false
    var showsHiddenFiles = false
    var showsWelcomeWindowAtLaunch = true
    var renamesOnClick = true
    var saveBehavior: SaveBehavior = .immediate
    var openingBehavior: OpeningBehavior = .system
    var folderOpening: FolderOpening = .enter
    var excludesDSStore = true
    var excludesHiddenFiles = false

    var importOptions: ArchiveImportPlan.Options {
        .init(excludesDSStore: excludesDSStore, excludesHiddenFiles: excludesHiddenFiles)
    }

    func writerOptions(for format: GyoshukuKit.ArchiveFormat) -> WriterOptions {
        let placement: AdditionPlacement = additionPosition == .end ? .end : .beginning
        let owners: CarriedOwnerIDs = tarCarriedOwnerIDs == .keep ? .keep : .reset
        var options: WriterOptions = switch format {
        case .zip:
            WriterOptions(compressionMethod: zipMethod == .stored ? .stored : .deflate,
                          deflateLevel: Self.clampedLevel(zipLevel),
                          useCompressionHeuristic: zipSkipsCompressedTypes, additionPlacement: .end)
        case .tar, .tarXZ:
            WriterOptions(preserveOwnerIDs: tarPreservesOwnerIDs, additionPlacement: placement, carriedTarOwnerIDs: owners)
        case .tarGzip:
            WriterOptions(deflateLevel: Self.clampedLevel(tarGzipLevel), preserveOwnerIDs: tarPreservesOwnerIDs,
                          additionPlacement: placement, carriedTarOwnerIDs: owners)
        case .tarBzip2:
            WriterOptions(bzip2Level: Self.clampedLevel(tarBzip2Level), preserveOwnerIDs: tarPreservesOwnerIDs,
                          additionPlacement: placement, carriedTarOwnerIDs: owners)
        case .sevenZip, .lha:
            // 固定のエンコーダーへ他形式の設定は持ち込まず、共通の並列数だけを後で写す。
            WriterOptions(additionPlacement: placement)
        }
        if compressionThreads != 0 { options.compressionThreads = compressionThreads }
        return options
    }

    static func clampedLevel(_ level: Int) -> Int { min(9, max(1, level)) }
}

@MainActor final class ArchivePreferencesStore {
    static let shared = ArchivePreferencesStore(defaults: .standard)
    static let didChange = Notification.Name("ArchivePreferencesDidChange")

    enum Key {
        // 保存パネルが従来使っていたキーと拡張子の表現を引き継ぐ。
        static let defaultFormat = "ArchiveCreationFormat"
        static let compressionThreads = "ArchiveCompressionThreads"
        static let zipMethod = "ArchiveZipMethod"
        static let zipLevel = "ArchiveZipLevel"
        static let zipSkipsCompressedTypes = "ArchiveZipSkipsCompressedTypes"
        static let tarGzipLevel = "ArchiveTarGzipLevel"
        static let tarBzip2Level = "ArchiveTarBzip2Level"
        static let tarPreservesOwnerIDs = "ArchiveTarPreservesOwnerIDs"
        static let additionPosition = "ArchiveAdditionPlacement"
        static let tarCarriedOwnerIDs = "ArchiveTarCarriedOwnerIDs"
        static let extractionDestination = "ArchiveExtractionDestination"
        static let folderPolicy = "ArchiveFolderPolicy"
        static let trashesArchiveAfterExtraction = "ArchiveTrashesArchiveAfterExtraction"
        static let revealsExtractedItemsInFinder = "ArchiveRevealsExtractedItems"
        static let keepsFoldersOnTop = "ArchiveKeepsFoldersOnTop"
        static let showsHiddenFiles = "ArchiveShowsHiddenFiles"
        static let showsWelcomeWindowAtLaunch = "ArchiveShowsWelcomeAtLaunch"
        static let renamesOnClick = "ArchiveRenamesOnClick"
        static let saveBehavior = "ArchiveSaveBehavior"
        static let openingBehavior = "ArchiveOpeningBehavior"
        static let folderOpening = "ArchiveFolderOpening"
        static let excludesDSStore = "ArchiveExcludesDSStore"
        static let excludesHiddenFiles = "ArchiveExcludesHiddenFiles"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    var preferences: ArchivePreferences {
        get {
            var value = ArchivePreferences()
            let savedFormat = defaults.string(forKey: Key.defaultFormat)
            value.defaultFormat = ArchivePreferences.formats.first {
                ArchiveCreationPlan.filenameExtension(for: $0) == savedFormat
            } ?? value.defaultFormat
            value.compressionThreads = threads(forKey: Key.compressionThreads)
            value.zipMethod = defaults.string(forKey: Key.zipMethod).flatMap(ArchivePreferences.ZipMethod.init(rawValue:))
                ?? value.zipMethod
            value.zipLevel = level(forKey: Key.zipLevel)
            value.zipSkipsCompressedTypes = boolean(forKey: Key.zipSkipsCompressedTypes, fallback: value.zipSkipsCompressedTypes)
            value.tarGzipLevel = level(forKey: Key.tarGzipLevel)
            value.tarBzip2Level = level(forKey: Key.tarBzip2Level, fallback: 9)
            value.tarPreservesOwnerIDs = boolean(forKey: Key.tarPreservesOwnerIDs, fallback: value.tarPreservesOwnerIDs)
            value.additionPosition = defaults.string(forKey: Key.additionPosition)
                .flatMap(ArchivePreferences.AdditionPosition.init(rawValue:)) ?? value.additionPosition
            value.tarCarriedOwnerIDs = defaults.string(forKey: Key.tarCarriedOwnerIDs)
                .flatMap(ArchivePreferences.CarriedOwnerIDPolicy.init(rawValue:)) ?? value.tarCarriedOwnerIDs
            value.extractionDestination = defaults.string(forKey: Key.extractionDestination)
                .flatMap(ArchivePreferences.ExtractionDestination.init(rawValue:)) ?? value.extractionDestination
            value.folderPolicy = defaults.string(forKey: Key.folderPolicy)
                .flatMap(ArchivePreferences.FolderPolicy.init(rawValue:)) ?? value.folderPolicy
            value.trashesArchiveAfterExtraction = boolean(forKey: Key.trashesArchiveAfterExtraction,
                                                         fallback: value.trashesArchiveAfterExtraction)
            value.revealsExtractedItemsInFinder = boolean(forKey: Key.revealsExtractedItemsInFinder,
                                                        fallback: value.revealsExtractedItemsInFinder)
            value.keepsFoldersOnTop = boolean(forKey: Key.keepsFoldersOnTop, fallback: value.keepsFoldersOnTop)
            value.showsHiddenFiles = boolean(forKey: Key.showsHiddenFiles, fallback: value.showsHiddenFiles)
            value.showsWelcomeWindowAtLaunch = boolean(forKey: Key.showsWelcomeWindowAtLaunch,
                                                      fallback: value.showsWelcomeWindowAtLaunch)
            value.renamesOnClick = boolean(forKey: Key.renamesOnClick, fallback: value.renamesOnClick)
            value.saveBehavior = defaults.string(forKey: Key.saveBehavior)
                .flatMap(ArchivePreferences.SaveBehavior.init(rawValue:)) ?? value.saveBehavior
            value.openingBehavior = defaults.string(forKey: Key.openingBehavior)
                .flatMap(ArchivePreferences.OpeningBehavior.init(rawValue:)) ?? value.openingBehavior
            value.folderOpening = defaults.string(forKey: Key.folderOpening)
                .flatMap(ArchivePreferences.FolderOpening.init(rawValue:)) ?? value.folderOpening
            value.excludesDSStore = boolean(forKey: Key.excludesDSStore, fallback: value.excludesDSStore)
            value.excludesHiddenFiles = boolean(forKey: Key.excludesHiddenFiles, fallback: value.excludesHiddenFiles)
            return value
        }
        set {
            defaults.set(ArchiveCreationPlan.filenameExtension(for: newValue.defaultFormat), forKey: Key.defaultFormat)
            defaults.set(ArchivePreferences.compressionThreadRange.contains(newValue.compressionThreads)
                         ? newValue.compressionThreads : 0, forKey: Key.compressionThreads)
            defaults.set(newValue.zipMethod.rawValue, forKey: Key.zipMethod)
            defaults.set(ArchivePreferences.clampedLevel(newValue.zipLevel), forKey: Key.zipLevel)
            defaults.set(newValue.zipSkipsCompressedTypes, forKey: Key.zipSkipsCompressedTypes)
            defaults.set(ArchivePreferences.clampedLevel(newValue.tarGzipLevel), forKey: Key.tarGzipLevel)
            defaults.set(ArchivePreferences.clampedLevel(newValue.tarBzip2Level), forKey: Key.tarBzip2Level)
            defaults.set(newValue.tarPreservesOwnerIDs, forKey: Key.tarPreservesOwnerIDs)
            defaults.set(newValue.additionPosition.rawValue, forKey: Key.additionPosition)
            defaults.set(newValue.tarCarriedOwnerIDs.rawValue, forKey: Key.tarCarriedOwnerIDs)
            defaults.set(newValue.extractionDestination.rawValue, forKey: Key.extractionDestination)
            defaults.set(newValue.folderPolicy.rawValue, forKey: Key.folderPolicy)
            defaults.set(newValue.trashesArchiveAfterExtraction, forKey: Key.trashesArchiveAfterExtraction)
            defaults.set(newValue.revealsExtractedItemsInFinder, forKey: Key.revealsExtractedItemsInFinder)
            defaults.set(newValue.keepsFoldersOnTop, forKey: Key.keepsFoldersOnTop)
            defaults.set(newValue.showsHiddenFiles, forKey: Key.showsHiddenFiles)
            defaults.set(newValue.showsWelcomeWindowAtLaunch, forKey: Key.showsWelcomeWindowAtLaunch)
            defaults.set(newValue.renamesOnClick, forKey: Key.renamesOnClick)
            defaults.set(newValue.saveBehavior.rawValue, forKey: Key.saveBehavior)
            defaults.set(newValue.openingBehavior.rawValue, forKey: Key.openingBehavior)
            defaults.set(newValue.folderOpening.rawValue, forKey: Key.folderOpening)
            defaults.set(newValue.excludesDSStore, forKey: Key.excludesDSStore)
            defaults.set(newValue.excludesHiddenFiles, forKey: Key.excludesHiddenFiles)
            // 全キーの保存後に同期通知し、次の書き込みが必ず新しい値を読むようにする。
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private func threads(forKey key: String) -> Int {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue),
              number.intValue == 0 || ArchivePreferences.compressionThreadRange.contains(number.intValue) else { return 0 }
        return number.intValue
    }

    private func level(forKey key: String, fallback: Int = 6) -> Int {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              (1...9).contains(number.intValue), number.doubleValue == Double(number.intValue) else { return fallback }
        return number.intValue
    }

    private func boolean(forKey key: String, fallback: Bool) -> Bool {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
        return number.boolValue
    }
}
