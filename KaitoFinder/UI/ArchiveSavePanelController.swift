import Foundation
import GyoshukuKit
import UniformTypeIdentifiers

/// 保存形式と圧縮設定を管理する。保存名と拡張子の表示は標準パネルに任せる。
final class ArchiveSavePanelController {
    nonisolated enum Level: Int, CaseIterable, Sendable {
        case none = 0, fast = 1, normal = 6, high = 8, maximum = 9

        static func closest(to value: Int) -> Level {
            [.fast, .normal, .high, .maximum].min {
                let left = abs($0.rawValue - value), right = abs($1.rawValue - value)
                return left == right ? $0.rawValue > $1.rawValue : left < right
            }!
        }

        func title(bundle: Bundle = .main) -> String {
            switch self {
            case .none: String(localized: "圧縮しない", bundle: bundle)
            case .fast: String(localized: "速い", bundle: bundle)
            case .normal: String(localized: "標準", bundle: bundle)
            case .high: String(localized: "高い", bundle: bundle)
            case .maximum: String(localized: "最高", bundle: bundle)
            }
        }

        func applying(to options: WriterOptions, format: GyoshukuKit.ArchiveFormat) -> WriterOptions {
            var options = options
            if format == .zip {
                options.compressionMethod = self == .none ? .stored : .deflate
            }
            if (format == .zip || format == .tarGzip), self != .none { options.deflateLevel = rawValue }
            if format == .tarBzip2, self != .none { options.bzip2Level = rawValue }
            return options
        }
    }

    static let formats = ArchivePreferences.formats
    static var panelContentTypes: [UTType] {
        // 手入力された複合拡張子や別名も標準パネルに受理させる。
        // 選択形式との一致は validate で検査する。
        formats.map(contentType(for:)) + [.gzip]
            + ["public.bzip2-archive", "org.tukaani.xz-archive", "public.lha-archive",
               "org.gnu.gnu-zip-tar-archive", "com.shunnag.KaitoFinder.save-tbz", "org.tukaani.tar-xz-archive"]
                .compactMap { UTType($0) }
    }
    private let store: ArchivePreferencesStore
    private(set) var format: GyoshukuKit.ArchiveFormat
    private(set) var level: Level = .normal

    init(store: ArchivePreferencesStore = .shared) {
        self.store = store
        format = store.preferences.defaultFormat
        resetLevel()
    }

    convenience init(defaults: UserDefaults) { self.init(store: ArchivePreferencesStore(defaults: defaults)) }

    var selectedIndex: Int { Self.formats.firstIndex(of: format)! }
    var allowedContentTypes: [UTType] { [Self.contentType(for: format)] }
    var isLevelEnabled: Bool { format == .zip || format == .tarGzip || format == .tarBzip2 }
    var levels: [Level] {
        switch format {
        case .zip: Level.allCases
        case .tarGzip, .tarBzip2: [.fast, .normal, .high, .maximum]
        case .tar, .tarXZ, .sevenZip, .lha: [.normal]
        }
    }
    var selectedLevelIndex: Int { levels.firstIndex(of: level)! }

    func selectLevel(at index: Int) {
        guard isLevelEnabled, levels.indices.contains(index) else { return }
        level = levels[index]
    }

    private func resetLevel() {
        let preferences = store.preferences
        switch format {
        case .zip: level = preferences.zipMethod == .stored ? .none : .closest(to: preferences.zipLevel)
        case .tarGzip: level = .closest(to: preferences.tarGzipLevel)
        case .tarBzip2: level = .closest(to: preferences.tarBzip2Level)
        case .tar, .tarXZ, .sevenZip, .lha: level = .normal
        }
    }

    static func title(for format: GyoshukuKit.ArchiveFormat, bundle: Bundle = .main) -> String {
        switch format {
        case .zip: String(localized: "ZIP", bundle: bundle)
        case .tar: String(localized: "tar", bundle: bundle)
        case .tarGzip: String(localized: "tar.gz", bundle: bundle)
        case .tarBzip2: String(localized: "tar.bz2", bundle: bundle)
        case .tarXZ: String(localized: "tar.xz", bundle: bundle)
        case .sevenZip: String(localized: "7z", bundle: bundle)
        case .lha: String(localized: "LHA", bundle: bundle)
        }
    }

    static func contentType(for format: GyoshukuKit.ArchiveFormat) -> UTType {
        let identifier: String
        switch format {
        case .zip: return .zip
        case .tar: identifier = "public.tar-archive"
        // システムの圧縮型は gz / bz2 / xz しか付けないため、保存時の
        // 優先拡張子が tar.gz / tar.bz2 / tar.xz の型を宣言している。
        case .tarGzip: identifier = "com.shunnag.KaitoFinder.save-tar-gzip"
        case .tarBzip2: identifier = "com.shunnag.KaitoFinder.save-tar-bzip2"
        case .tarXZ: identifier = "com.shunnag.KaitoFinder.save-tar-xz"
        case .sevenZip: identifier = "org.7-zip.7-zip-archive"
        case .lha: identifier = "com.shunnag.KaitoFinder.lzh-archive"
        }
        // 宣言が未登録なら拡張子から解決する。
        let suffix = ArchiveCreationPlan.filenameExtension(for: format)
        return UTType(identifier) ?? UTType(filenameExtension: suffix) ?? .data
    }

    static func explicitFilenameContentType(for format: GyoshukuKit.ArchiveFormat) -> UTType {
        // 拡張子を表示する場合、AppKit は最後の一要素で一致を判定する。
        // .tar.gz などを再度追加させず、手入力済みの完全な名前を受理する。
        switch format {
        case .tarGzip: .gzip
        case .tarBzip2: UTType("public.bzip2-archive")!
        case .tarXZ: UTType("org.tukaani.xz-archive")!
        default: contentType(for: format)
        }
    }

    static func filenameStem(_ filename: String, format: GyoshukuKit.ArchiveFormat) -> String {
        let suffix = ArchiveCreationPlan.acceptedExtensions(for: format)
            .sorted { $0.count > $1.count }
            .first { filename.lowercased().hasSuffix("." + $0) }
        return suffix.map { String(filename.dropLast($0.count + 1)) } ?? filename
    }

    static func filenameByChangingFormat(_ filename: String, to format: GyoshukuKit.ArchiveFormat) -> String {
        guard !filename.isEmpty else { return filename }
        let suffix = formats.flatMap { ArchiveCreationPlan.acceptedExtensions(for: $0) }
            .sorted { $0.count > $1.count }
            .first { filename.count > $0.count + 1 && filename.lowercased().hasSuffix("." + $0) }
        let stem = suffix.map { String(filename.dropLast($0.count + 1)) } ?? filename
        return stem + "." + ArchiveCreationPlan.filenameExtension(for: format)
    }

    func selectFormat(at index: Int) {
        guard Self.formats.indices.contains(index) else { return }
        format = Self.formats[index]
        resetLevel()
        store.preferences.defaultFormat = format
    }
}
