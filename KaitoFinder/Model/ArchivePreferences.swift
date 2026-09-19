import CoreFoundation
import Foundation
import GyoshukuKit

/// 書き込み処理へ安全に渡せる設定値。展開設定は一括展開の入口から参照する。
nonisolated struct ArchivePreferences: Sendable, Equatable {
    enum ZipMethod: String, Sendable { case deflate, stored }
    enum ExtractionDestination: String, Sendable { case sameFolder, ask }
    enum FolderPolicy: String, Sendable { case always, whenMultipleTopLevelItems, never }
    enum OpeningBehavior: String, Sendable, CaseIterable { case system, newTab, newWindow }

    static let formats: [GyoshukuKit.ArchiveFormat] = [.zip, .tar, .tarGzip, .tarBzip2, .tarXZ, .sevenZip, .lha]

    var defaultFormat: GyoshukuKit.ArchiveFormat = .zip
    var zipMethod: ZipMethod = .deflate
    var zipLevel = 6
    var zipSkipsCompressedTypes = true
    var tarGzipLevel = 6
    var tarBzip2Level = 9
    var tarPreservesOwnerIDs = false
    var extractionDestination: ExtractionDestination = .sameFolder
    var folderPolicy: FolderPolicy = .whenMultipleTopLevelItems
    var trashesArchiveAfterExtraction = false
    var revealsExtractedItemsInFinder = false
    var showsHiddenFiles = false
    var showsWelcomeWindowAtLaunch = true
    var renamesOnClick = true
    var openingBehavior: OpeningBehavior = .system
    var excludesDSStore = true
    var excludesHiddenFiles = false

    var importOptions: ArchiveImportPlan.Options {
        .init(excludesDSStore: excludesDSStore, excludesHiddenFiles: excludesHiddenFiles)
    }

    func writerOptions(for format: GyoshukuKit.ArchiveFormat) -> WriterOptions {
        switch format {
        case .zip:
            WriterOptions(compressionMethod: zipMethod == .stored ? .stored : .deflate,
                          deflateLevel: Self.clampedLevel(zipLevel),
                          useCompressionHeuristic: zipSkipsCompressedTypes)
        case .tar, .tarXZ:
            WriterOptions(preserveOwnerIDs: tarPreservesOwnerIDs)
        case .tarGzip:
            WriterOptions(deflateLevel: Self.clampedLevel(tarGzipLevel), preserveOwnerIDs: tarPreservesOwnerIDs)
        case .tarBzip2:
            WriterOptions(bzip2Level: Self.clampedLevel(tarBzip2Level), preserveOwnerIDs: tarPreservesOwnerIDs)
        case .sevenZip, .lha:
            // 固定のエンコーダーへ、他形式の設定を持ち込まない。
            WriterOptions()
        }
    }

    static func clampedLevel(_ level: Int) -> Int { min(9, max(1, level)) }
}

@MainActor final class ArchivePreferencesStore {
    static let shared = ArchivePreferencesStore(defaults: .standard)
    static let didChange = Notification.Name("ArchivePreferencesDidChange")

    enum Key {
        // 保存パネルが従来使っていたキーと拡張子の表現を引き継ぐ。
        static let defaultFormat = "ArchiveCreationFormat"
        static let zipMethod = "ArchiveZipMethod"
        static let zipLevel = "ArchiveZipLevel"
        static let zipSkipsCompressedTypes = "ArchiveZipSkipsCompressedTypes"
        static let tarGzipLevel = "ArchiveTarGzipLevel"
        static let tarBzip2Level = "ArchiveTarBzip2Level"
        static let tarPreservesOwnerIDs = "ArchiveTarPreservesOwnerIDs"
        static let extractionDestination = "ArchiveExtractionDestination"
        static let folderPolicy = "ArchiveFolderPolicy"
        static let trashesArchiveAfterExtraction = "ArchiveTrashesArchiveAfterExtraction"
        static let revealsExtractedItemsInFinder = "ArchiveRevealsExtractedItems"
        static let showsHiddenFiles = "ArchiveShowsHiddenFiles"
        static let showsWelcomeWindowAtLaunch = "ArchiveShowsWelcomeAtLaunch"
        static let renamesOnClick = "ArchiveRenamesOnClick"
        static let openingBehavior = "ArchiveOpeningBehavior"
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
            value.zipMethod = defaults.string(forKey: Key.zipMethod).flatMap(ArchivePreferences.ZipMethod.init(rawValue:))
                ?? value.zipMethod
            value.zipLevel = level(forKey: Key.zipLevel)
            value.zipSkipsCompressedTypes = boolean(forKey: Key.zipSkipsCompressedTypes, fallback: value.zipSkipsCompressedTypes)
            value.tarGzipLevel = level(forKey: Key.tarGzipLevel)
            value.tarBzip2Level = level(forKey: Key.tarBzip2Level, fallback: 9)
            value.tarPreservesOwnerIDs = boolean(forKey: Key.tarPreservesOwnerIDs, fallback: value.tarPreservesOwnerIDs)
            value.extractionDestination = defaults.string(forKey: Key.extractionDestination)
                .flatMap(ArchivePreferences.ExtractionDestination.init(rawValue:)) ?? value.extractionDestination
            value.folderPolicy = defaults.string(forKey: Key.folderPolicy)
                .flatMap(ArchivePreferences.FolderPolicy.init(rawValue:)) ?? value.folderPolicy
            value.trashesArchiveAfterExtraction = boolean(forKey: Key.trashesArchiveAfterExtraction,
                                                         fallback: value.trashesArchiveAfterExtraction)
            value.revealsExtractedItemsInFinder = boolean(forKey: Key.revealsExtractedItemsInFinder,
                                                        fallback: value.revealsExtractedItemsInFinder)
            value.showsHiddenFiles = boolean(forKey: Key.showsHiddenFiles, fallback: value.showsHiddenFiles)
            value.showsWelcomeWindowAtLaunch = boolean(forKey: Key.showsWelcomeWindowAtLaunch,
                                                      fallback: value.showsWelcomeWindowAtLaunch)
            value.renamesOnClick = boolean(forKey: Key.renamesOnClick, fallback: value.renamesOnClick)
            value.openingBehavior = defaults.string(forKey: Key.openingBehavior)
                .flatMap(ArchivePreferences.OpeningBehavior.init(rawValue:)) ?? value.openingBehavior
            value.excludesDSStore = boolean(forKey: Key.excludesDSStore, fallback: value.excludesDSStore)
            value.excludesHiddenFiles = boolean(forKey: Key.excludesHiddenFiles, fallback: value.excludesHiddenFiles)
            return value
        }
        set {
            defaults.set(ArchiveCreationPlan.filenameExtension(for: newValue.defaultFormat), forKey: Key.defaultFormat)
            defaults.set(newValue.zipMethod.rawValue, forKey: Key.zipMethod)
            defaults.set(ArchivePreferences.clampedLevel(newValue.zipLevel), forKey: Key.zipLevel)
            defaults.set(newValue.zipSkipsCompressedTypes, forKey: Key.zipSkipsCompressedTypes)
            defaults.set(ArchivePreferences.clampedLevel(newValue.tarGzipLevel), forKey: Key.tarGzipLevel)
            defaults.set(ArchivePreferences.clampedLevel(newValue.tarBzip2Level), forKey: Key.tarBzip2Level)
            defaults.set(newValue.tarPreservesOwnerIDs, forKey: Key.tarPreservesOwnerIDs)
            defaults.set(newValue.extractionDestination.rawValue, forKey: Key.extractionDestination)
            defaults.set(newValue.folderPolicy.rawValue, forKey: Key.folderPolicy)
            defaults.set(newValue.trashesArchiveAfterExtraction, forKey: Key.trashesArchiveAfterExtraction)
            defaults.set(newValue.revealsExtractedItemsInFinder, forKey: Key.revealsExtractedItemsInFinder)
            defaults.set(newValue.showsHiddenFiles, forKey: Key.showsHiddenFiles)
            defaults.set(newValue.showsWelcomeWindowAtLaunch, forKey: Key.showsWelcomeWindowAtLaunch)
            defaults.set(newValue.renamesOnClick, forKey: Key.renamesOnClick)
            defaults.set(newValue.openingBehavior.rawValue, forKey: Key.openingBehavior)
            defaults.set(newValue.excludesDSStore, forKey: Key.excludesDSStore)
            defaults.set(newValue.excludesHiddenFiles, forKey: Key.excludesHiddenFiles)
            // 全キーの保存後に同期通知し、次の書き込みが必ず新しい値を読むようにする。
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
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
