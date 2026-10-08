import CoreFoundation
import Foundation
import GyoshukuKit

/// 書き込み処理へ安全に渡せる設定値。展開設定は一括展開の入口から参照する。
nonisolated struct ArchivePreferences: Sendable, Equatable {
    enum ZipMethod: String, Sendable { case deflate, stored, bzip2, lzma, xz, zstd, ppmd }
    enum SevenZipMethod: String, Sendable, CaseIterable { case lzma2, lzma, deflate, bzip2, ppmd, copy }
    enum SevenZipFilter: String, Sendable, CaseIterable {
        case none, auto, bcjX86, arm64, delta

        var writerMode: SevenZipFilterMode {
            switch self {
            case .none: .none
            case .auto: .auto
            case .bcjX86: .bcjX86
            case .arm64: .arm64
            // 32 bit サンプルの同じ byte 位置を差分化する。
            case .delta: .delta(distance: 4)
            }
        }

        func title(bundle: Bundle = .main) -> String {
            switch self {
            case .none: String(localized: "なし", bundle: bundle)
            case .auto: String(localized: "自動", bundle: bundle)
            case .bcjX86: String(localized: "x86 (BCJ)", bundle: bundle)
            case .arm64: String(localized: "ARM64", bundle: bundle)
            case .delta: String(localized: "Delta", bundle: bundle)
            }
        }
    }
    enum LhaMethod: String, Sendable, CaseIterable { case lh5, lh6, lh7, stored }
    enum ExtractionDestination: String, Sendable { case sameFolder, ask }
    enum FolderPolicy: String, Sendable { case always, whenMultipleTopLevelItems, never }
    enum SaveBehavior: String, Sendable, CaseIterable { case immediate, onSave }
    enum OpeningBehavior: String, Sendable, CaseIterable { case system, newTab, newWindow }
    enum FolderOpening: String, Sendable, CaseIterable { case enter, expand }
    enum ListIconSize: String, Sendable, CaseIterable {
        case small, large
        var pointSize: CGFloat { self == .small ? 16 : 32 }
    }
    enum AdditionPosition: String, Sendable, CaseIterable { case end, beginning }
    enum CarriedOwnerIDPolicy: String, Sendable, CaseIterable { case keep, reset }
    enum PowerPolicy: String, Sendable, CaseIterable {
        case reduceInLowPowerMode, reduceInLowPowerModeOrThermalPressure, alwaysUseAllCores

        var writerPolicy: CompressionPowerPolicy {
            switch self {
            case .reduceInLowPowerMode: .reduceInLowPowerMode
            case .reduceInLowPowerModeOrThermalPressure: .reduceInLowPowerModeOrThermalPressure
            case .alwaysUseAllCores: .alwaysUseAllCores
            }
        }

        func title(bundle: Bundle = .main) -> String {
            switch self {
            case .reduceInLowPowerMode: String(localized: "低電力モードで並列数を減らす", bundle: bundle)
            case .reduceInLowPowerModeOrThermalPressure: String(localized: "低電力モードや高温時に並列数を減らす", bundle: bundle)
            case .alwaysUseAllCores: String(localized: "常にすべてのコアを使う", bundle: bundle)
            }
        }
    }

    static let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .tarZstd, .tarLzip, .tarLZMA, .tarLZ4, .tarBrotli, .tarCompress, .sevenZip, .lha]
    static let compressionThreadRange = WriterOptions.compressionThreadsRange
    static let listTextSizeRange = 10...16

    var defaultFormat: GyoshukuKit.ArchiveFormat = .zip
    var compressionThreads = 0
    var powerPolicy: PowerPolicy = .reduceInLowPowerMode
    var zipMethod: ZipMethod = .deflate
    var zipLevel = 6
    var zipLZMALevel = 6
    var zipZstdLevel = 3
    var zipPPMdLevel = 6
    var zipSkipsCompressedTypes = true
    var tarGzipLevel = 6
    var tarBzip2Level = 9
    var tarXZLevel = 6
    var tarZstdLevel = 3
    var tarLzipLevel = 6
    var tarLZMALevel = 6
    var sevenZipMethod: SevenZipMethod = .lzma2
    // -1 は無圧縮。LZMA の 0 と区別して保存する。
    var sevenZipLevel = 6
    var sevenZipPPMdLevel = 6
    var sevenZipSolid = false
    var sevenZipFilter: SevenZipFilter = .none
    var lhaMethod: LhaMethod = .lh5
    var lhaLevel = 6
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
    var listIconSize: ListIconSize = .small
    var listTextSize = 13
    var excludesDSStore = true
    var excludesHiddenFiles = false

    var importOptions: ArchiveImportPlan.Options {
        .init(excludesDSStore: excludesDSStore, excludesHiddenFiles: excludesHiddenFiles)
    }

    func writerOptions(for format: GyoshukuKit.ArchiveFormat) -> WriterOptions {
        let placement: AdditionPlacement = additionPosition == .end ? .end : .beginning
        let owners: CarriedOwnerIDs = tarCarriedOwnerIDs == .keep ? .keep : .reset
        var options = WriterOptions(powerPolicy: powerPolicy.writerPolicy,
                                    additionPlacement: format == .zip ? .end : placement)
        if format.isTarFamily {
            options.preserveOwnerIDs = tarPreservesOwnerIDs
            options.carriedTarOwnerIDs = owners
        }
        switch format {
        case .zip:
            options.compressionMethod = switch zipMethod {
            case .stored: .stored
            case .deflate: .deflate
            case .bzip2: .bzip2
            case .lzma: .lzma
            case .xz: .xz
            case .zstd: .zstd
            case .ppmd: .ppmd
            }
            options.deflateLevel = Self.clampedLevel(zipLevel)
            if zipMethod == .bzip2 { options.bzip2Level = Self.clampedLevel(zipLevel) }
            if zipMethod == .lzma || zipMethod == .xz {
                options.lzmaLevel = Self.lzmaOption(zipLZMALevel, apple: zipMethod == .xz)
            }
            options.zstdLevel = Self.validLevel(zipZstdLevel, range: 1...19, fallback: 3)
            options.ppmdLevel = Self.validLevel(zipPPMdLevel, range: 1...9, fallback: 6)
            options.useCompressionHeuristic = zipSkipsCompressedTypes
        case .tarGzip: options.deflateLevel = Self.clampedLevel(tarGzipLevel)
        case .tarBzip2: options.bzip2Level = Self.clampedLevel(tarBzip2Level)
        case .tarZstd: options.zstdLevel = Self.validLevel(tarZstdLevel, range: 1...19, fallback: 3)
        case .tarXZ: options.lzmaLevel = Self.lzmaOption(tarXZLevel, apple: true)
        case .tarLzip: options.lzmaLevel = Self.lzmaOption(tarLzipLevel)
        case .tarLZMA: options.lzmaLevel = Self.lzmaOption(tarLZMALevel)
        case .sevenZip:
            options.sevenZipMethod = switch sevenZipMethod {
            case .lzma2: .lzma2
            case .lzma: .lzma
            case .deflate: .deflate
            case .bzip2: .bzip2
            case .ppmd: .ppmd
            case .copy: .copy
            }
            options.ppmdLevel = Self.validLevel(sevenZipPPMdLevel, range: 1...9, fallback: 6)
            options.sevenZipSolid = sevenZipSolid ? .on(blockSize: nil, filesPerBlock: nil) : .off
            options.sevenZipFilter = sevenZipFilter.writerMode
            if sevenZipLevel == -1 { options.sevenZipMethod = .copy }
            switch options.sevenZipMethod {
            case .lzma2, .lzma: options.lzmaLevel = Self.lzmaOption(sevenZipLevel, apple: options.sevenZipMethod == .lzma2)
            case .deflate: options.deflateLevel = Self.clampedLevel(sevenZipLevel)
            case .bzip2: options.bzip2Level = Self.clampedLevel(sevenZipLevel)
            case .ppmd, .copy: break
            }
        case .lha:
            options.lhaMethod = switch lhaMethod {
            case .lh5: .lh5
            case .lh6: .lh6
            case .lh7: .lh7
            case .stored: .stored
            }
            if lhaLevel == -1 { options.lhaMethod = .stored }
            options.lhaLevel = Self.clampedLevel(lhaLevel)
        case .tar, .tarLZ4, .tarBrotli, .tarCompress: break
        }
        if compressionThreads != 0 { options.compressionThreads = compressionThreads }
        return options
    }

    static func lzmaOption(_ level: Int, apple: Bool = false) -> Int? {
        let level = min(9, max(0, level))
        return apple && level == 6 ? nil : level
    }

    static func validLevel(_ level: Int, range: ClosedRange<Int>, fallback: Int) -> Int {
        range.contains(level) ? level : fallback
    }

    static func clampedLevel(_ level: Int) -> Int { min(9, max(1, level)) }
}

@MainActor final class ArchivePreferencesStore {
    static let shared = ArchivePreferencesStore(defaults: .standard)
    static let didChange = Notification.Name("ArchivePreferencesDidChange")

    enum Key {
        // 保存パネルと同じキーと拡張子の表現を使う。
        static let defaultFormat = "ArchiveCreationFormat"
        static let compressionThreads = "ArchiveCompressionThreads"
        static let powerPolicy = "ArchiveCompressionPowerPolicy"
        static let sevenZipMethod = "ArchiveSevenZipMethod"
        static let lhaMethod = "ArchiveLhaMethod"
        static let zipMethod = "ArchiveZipMethod"
        static let zipLZMALevel = "ArchiveZipLZMALevel"
        static let zipZstdLevel = "ArchiveZipZstdLevel"
        static let zipPPMdLevel = "ArchiveZipPPMdLevel"
        static let tarZstdLevel = "ArchiveTarZstdLevel"
        static let sevenZipPPMdLevel = "ArchiveSevenZipPPMdLevel"
        static let sevenZipSolid = "ArchiveSevenZipSolid"
        static let sevenZipFilter = "ArchiveSevenZipFilter"
        static let tarXZLevel = "ArchiveTarXZLevel"
        static let tarLzipLevel = "ArchiveTarLzipLevel"
        static let tarLZMALevel = "ArchiveTarLZMALevel"
        static let sevenZipLevel = "ArchiveSevenZipLevel"
        static let lhaLevel = "ArchiveLhaLevel"
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
        static let listIconSize = "ArchiveListIconSize"
        static let listTextSize = "ArchiveListTextSize"
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
            value.powerPolicy = defaults.string(forKey: Key.powerPolicy)
                .flatMap(ArchivePreferences.PowerPolicy.init(rawValue:)) ?? value.powerPolicy
            value.zipMethod = defaults.string(forKey: Key.zipMethod).flatMap(ArchivePreferences.ZipMethod.init(rawValue:))
                ?? value.zipMethod
            value.zipLZMALevel = level(forKey: Key.zipLZMALevel, range: 0...9)
            value.zipZstdLevel = level(forKey: Key.zipZstdLevel, fallback: 3, range: 1...19)
            value.zipPPMdLevel = level(forKey: Key.zipPPMdLevel, fallback: 6, range: 1...9)
            value.tarZstdLevel = level(forKey: Key.tarZstdLevel, fallback: 3, range: 1...19)
            value.sevenZipPPMdLevel = level(forKey: Key.sevenZipPPMdLevel, fallback: 6, range: 1...9)
            value.sevenZipSolid = boolean(forKey: Key.sevenZipSolid, fallback: false)
            value.sevenZipFilter = defaults.string(forKey: Key.sevenZipFilter)
                .flatMap(ArchivePreferences.SevenZipFilter.init(rawValue:)) ?? .none
            value.tarXZLevel = level(forKey: Key.tarXZLevel, range: 0...9)
            value.tarLzipLevel = level(forKey: Key.tarLzipLevel, range: 0...9)
            value.tarLZMALevel = level(forKey: Key.tarLZMALevel, range: 0...9)
            value.sevenZipLevel = level(forKey: Key.sevenZipLevel, range: -1...9)
            value.lhaLevel = level(forKey: Key.lhaLevel, range: -1...9)
            if value.lhaLevel == 0 { value.lhaLevel = 6 }
            value.sevenZipMethod = defaults.string(forKey: Key.sevenZipMethod).flatMap(ArchivePreferences.SevenZipMethod.init(rawValue:)) ?? value.sevenZipMethod
            if value.sevenZipLevel == 0, [.deflate, .bzip2].contains(value.sevenZipMethod) { value.sevenZipLevel = 6 }
            value.lhaMethod = defaults.string(forKey: Key.lhaMethod).flatMap(ArchivePreferences.LhaMethod.init(rawValue:)) ?? value.lhaMethod
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
            value.listIconSize = defaults.string(forKey: Key.listIconSize)
                .flatMap(ArchivePreferences.ListIconSize.init(rawValue:)) ?? value.listIconSize
            if let number = defaults.object(forKey: Key.listTextSize) as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue == Double(number.intValue), ArchivePreferences.listTextSizeRange.contains(number.intValue) {
                value.listTextSize = number.intValue
            }
            value.excludesDSStore = boolean(forKey: Key.excludesDSStore, fallback: value.excludesDSStore)
            value.excludesHiddenFiles = boolean(forKey: Key.excludesHiddenFiles, fallback: value.excludesHiddenFiles)
            return value
        }
        set {
            defaults.set(ArchiveCreationPlan.filenameExtension(for: newValue.defaultFormat), forKey: Key.defaultFormat)
            defaults.set(ArchivePreferences.compressionThreadRange.contains(newValue.compressionThreads)
                         ? newValue.compressionThreads : 0, forKey: Key.compressionThreads)
            defaults.set(newValue.powerPolicy.rawValue, forKey: Key.powerPolicy)
            defaults.set((0...9).contains(newValue.zipLZMALevel) ? newValue.zipLZMALevel : 6, forKey: Key.zipLZMALevel)
            defaults.set(ArchivePreferences.validLevel(newValue.zipZstdLevel, range: 1...19, fallback: 3), forKey: Key.zipZstdLevel)
            defaults.set(ArchivePreferences.validLevel(newValue.zipPPMdLevel, range: 1...9, fallback: 6), forKey: Key.zipPPMdLevel)
            defaults.set(ArchivePreferences.validLevel(newValue.tarZstdLevel, range: 1...19, fallback: 3), forKey: Key.tarZstdLevel)
            defaults.set(ArchivePreferences.validLevel(newValue.sevenZipPPMdLevel, range: 1...9, fallback: 6), forKey: Key.sevenZipPPMdLevel)
            defaults.set(newValue.sevenZipSolid, forKey: Key.sevenZipSolid)
            defaults.set(newValue.sevenZipFilter.rawValue, forKey: Key.sevenZipFilter)
            defaults.set((0...9).contains(newValue.tarXZLevel) ? newValue.tarXZLevel : 6, forKey: Key.tarXZLevel)
            defaults.set((0...9).contains(newValue.tarLzipLevel) ? newValue.tarLzipLevel : 6, forKey: Key.tarLzipLevel)
            defaults.set((0...9).contains(newValue.tarLZMALevel) ? newValue.tarLZMALevel : 6, forKey: Key.tarLZMALevel)
            defaults.set((-1...9).contains(newValue.sevenZipLevel) && (newValue.sevenZipLevel != 0 || ![.deflate, .bzip2].contains(newValue.sevenZipMethod)) ? newValue.sevenZipLevel : 6, forKey: Key.sevenZipLevel)
            defaults.set((newValue.lhaLevel == -1 || (1...9).contains(newValue.lhaLevel)) ? newValue.lhaLevel : 6, forKey: Key.lhaLevel)
            defaults.set(newValue.sevenZipMethod.rawValue, forKey: Key.sevenZipMethod)
            defaults.set(newValue.lhaMethod.rawValue, forKey: Key.lhaMethod)
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
            defaults.set(newValue.listIconSize.rawValue, forKey: Key.listIconSize)
            defaults.set(ArchivePreferences.listTextSizeRange.contains(newValue.listTextSize) ? newValue.listTextSize : 13,
                         forKey: Key.listTextSize)
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

    private func level(forKey key: String, fallback: Int = 6, range: ClosedRange<Int> = 1...9) -> Int {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              range.contains(number.intValue), number.doubleValue == Double(number.intValue) else { return fallback }
        return number.intValue
    }

    private func boolean(forKey key: String, fallback: Bool) -> Bool {
        guard let number = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
        return number.boolValue
    }
}
