import Foundation
import GyoshukuKit
import UniformTypeIdentifiers

/// 保存形式と圧縮設定を管理する。保存名と拡張子の表示は標準パネルに任せる。
final class ArchiveSavePanelController {
    nonisolated enum Level: Int, CaseIterable, Sendable {
        case none = -1, zero = 0, fast = 1, two, three, four, five, normal, seven, high, maximum
        case ten, eleven, twelve, thirteen, fourteen, fifteen, sixteen, seventeen, eighteen, nineteen

        func title(bundle: Bundle = .main, startsAtZero: Bool = false, zstd: Bool = false) -> String {
            switch self {
            case .none: return String(localized: "圧縮しない", bundle: bundle)
            case .zero: return String(localized: "0（最速）", bundle: bundle)
            case .fast where !startsAtZero: return String(localized: "1（最速）", bundle: bundle)
            case .three where zstd: return String(localized: "3（標準）", bundle: bundle)
            case .nineteen where zstd: return String(localized: "19（最高）", bundle: bundle)
            case .normal where !zstd: return String(localized: "6（標準）", bundle: bundle)
            case .maximum where !zstd: return String(localized: "9（最高）", bundle: bundle)
            default: return String(rawValue)
            }
        }

        func applying(to options: WriterOptions, format: GyoshukuKit.ArchiveFormat) -> WriterOptions {
            var options = options
            let level = rawValue
            switch format {
            case .zip:
                if self == .none { options.compressionMethod = .stored }
                else {
                    if options.compressionMethod == .stored { options.compressionMethod = .deflate }
                    switch options.compressionMethod {
                    case .deflate: options.deflateLevel = level
                    case .bzip2: options.bzip2Level = level
                    case .lzma, .xz: options.lzmaLevel = ArchivePreferences.lzmaOption(level, apple: options.compressionMethod == .xz)
                    case .zstd: options.zstdLevel = level
                    case .ppmd: options.ppmdLevel = level
                    case .stored: break
                    }
                }
            case .sevenZip:
                if self == .none { options.sevenZipMethod = .copy }
                else {
                    if options.sevenZipMethod == .copy { options.sevenZipMethod = .lzma2 }
                    switch options.sevenZipMethod {
                    case .deflate: options.deflateLevel = level
                    case .bzip2: options.bzip2Level = level
                    case .lzma, .lzma2: options.lzmaLevel = ArchivePreferences.lzmaOption(level, apple: options.sevenZipMethod == .lzma2)
                    case .ppmd: options.ppmdLevel = level
                    case .copy: break
                    }
                }
            case .lha:
                if self == .none { options.lhaMethod = .stored }
                else {
                    if options.lhaMethod == .stored { options.lhaMethod = .lh5 }
                    options.lhaLevel = level
                }
            case .tarZstd: options.zstdLevel = level
            case .tarGzip: options.deflateLevel = level
            case .tarBzip2: options.bzip2Level = level
            case .tarXZ, .tarLZMA, .tarLzip: options.lzmaLevel = ArchivePreferences.lzmaOption(level, apple: format == .tarXZ)
            case .tar, .tarLZ4, .tarBrotli, .tarCompress: break
            }
            return options
        }
    }

    nonisolated enum Method: String, Sendable {
        case deflate = "Deflate", bzip2 = "BZip2", lzma = "LZMA", xz = "XZ", lzma2 = "LZMA2"
        case zstd = "Zstandard", ppmd = "PPMd"
        case lh5, lh6, lh7

        func title(bundle: Bundle = .main) -> String {
            switch self {
            case .zstd: String(localized: "Zstandard", bundle: bundle)
            case .ppmd: String(localized: "PPMd", bundle: bundle)
            default: rawValue
            }
        }

        func applying(to options: WriterOptions, format: GyoshukuKit.ArchiveFormat) -> WriterOptions {
            var options = options
            if format == .zip {
                options.compressionMethod = switch self {
                case .bzip2: .bzip2
                case .lzma: .lzma
                case .xz: .xz
                case .zstd: .zstd
                case .ppmd: .ppmd
                default: .deflate
                }
            } else if format == .sevenZip {
                options.sevenZipMethod = switch self {
                case .lzma: .lzma
                case .deflate: .deflate
                case .bzip2: .bzip2
                case .ppmd: .ppmd
                default: .lzma2
                }
            } else if format == .lha {
                options.lhaMethod = switch self {
                case .lh6: .lh6
                case .lh7: .lh7
                default: .lh5
                }
            }
            return options
        }
    }

    static let formats = ArchivePreferences.formats
    static var panelContentTypes: [UTType] {
        formats.map(contentType(for:)) + ArchiveCreationPlan.singleStreamFormats.map(contentType(for:))
            + ["public.lha-archive", "org.gnu.gnu-zip-tar-archive", "com.shunnag.KaitoFinder.save-tbz", "org.tukaani.tar-xz-archive",
               "com.shunnag.KaitoFinder.save-taz"].compactMap { UTType($0) }
    }
    private let store: ArchivePreferencesStore
    let offersSingleStream: Bool
    private(set) var format: GyoshukuKit.ArchiveFormat
    private(set) var singleStreamFormat: SingleStreamFormat?
    private(set) var method: Method = .deflate
    private(set) var level: Level = .normal
    var sevenZipSolid: Bool
    var sevenZipFilter: ArchivePreferences.SevenZipFilter
    private var choices: [String: (Method, Level)] = [:]
    private var methodLevels: [String: Level] = [:]

    init(store: ArchivePreferencesStore = .shared, sources: [URL] = [], allowsSingleStream: Bool = true) {
        self.store = store
        offersSingleStream = allowsSingleStream && ArchiveCreationPlan.canCompressSingleFile(sources)
        format = store.preferences.defaultFormat
        sevenZipSolid = store.preferences.sevenZipSolid
        sevenZipFilter = store.preferences.sevenZipFilter
        resetChoice()
    }

    convenience init(defaults: UserDefaults) { self.init(store: ArchivePreferencesStore(defaults: defaults)) }

    var selectedIndex: Int {
        if let singleStreamFormat { return Self.formats.count + 2 + ArchiveCreationPlan.singleStreamFormats.firstIndex(of: singleStreamFormat)! }
        return Self.formats.firstIndex(of: format)!
    }
    var filenameExtension: String {
        singleStreamFormat.map { ArchiveCreationPlan.filenameExtension(for: $0) } ?? ArchiveCreationPlan.filenameExtension(for: format)
    }
    var acceptedExtensions: [String] {
        singleStreamFormat == nil ? ArchiveCreationPlan.acceptedExtensions(for: format) : [filenameExtension.lowercased()]
    }
    var allowedContentTypes: [UTType] {
        [singleStreamFormat.map { Self.contentType(for: $0) } ?? Self.contentType(for: format)]
    }
    var explicitFilenameContentType: UTType { singleStreamFormat == nil ? Self.explicitFilenameContentType(for: format) : allowedContentTypes[0] }
    var methods: [Method] {
        guard singleStreamFormat == nil else { return [] }
        switch format {
        case .zip: return [.deflate, .bzip2, .lzma, .xz, .zstd, .ppmd]
        case .sevenZip: return [.lzma2, .lzma, .deflate, .bzip2, .ppmd]
        case .lha: return [.lh5, .lh6, .lh7]
        default: return []
        }
    }
    var selectedMethodIndex: Int { methods.firstIndex(of: method) ?? 0 }
    var showsZipCompatibilityNote: Bool { singleStreamFormat == nil && format == .zip && method != .deflate && level != .none }
    var isLevelEnabled: Bool { ![.tar, .tarLZ4, .tarBrotli, .tarCompress].contains(format) }
    var startsAtZero: Bool {
        [.tarXZ, .tarLZMA, .tarLzip].contains(format)
            || format == .zip && [.lzma, .xz].contains(method)
            || format == .sevenZip && [.lzma, .lzma2].contains(method)
    }
    var usesZstd: Bool { format == .tarZstd || format == .zip && method == .zstd }
    var showsSevenZipOptions: Bool { singleStreamFormat == nil && format == .sevenZip }
    var levels: [Level] {
        guard isLevelEnabled else { return [.normal] }
        let numeric = (usesZstd ? 1...19 : startsAtZero ? 0...9 : 1...9).map { Level(rawValue: $0)! }
        return !usesZstd && singleStreamFormat == nil && [.zip, .sevenZip, .lha].contains(format) ? [.none] + numeric : numeric
    }
    var selectedLevelIndex: Int { levels.firstIndex(of: level) ?? 0 }
    var writerOptions: WriterOptions {
        let defaults = store.preferences.writerOptions(for: format)
        var options = level.applying(to: method.applying(to: defaults, format: format), format: format)
        if showsSevenZipOptions {
            options.sevenZipSolid = sevenZipSolid ? .on(blockSize: nil, filesPerBlock: nil) : .off
            options.sevenZipFilter = sevenZipFilter.writerMode
        }
        if singleStreamFormat != nil {
            options.preserveOwnerIDs = false
            options.password = nil
            options.encryptsSevenZipHeaders = false
        }
        return options
    }

    func selectLevel(at index: Int) {
        guard isLevelEnabled, levels.indices.contains(index) else { return }
        level = levels[index]
        rememberChoice()
    }

    func selectMethod(at index: Int) {
        guard methods.indices.contains(index) else { return }
        rememberChoice()
        method = methods[index]
        if let saved = methodLevels[methodChoiceKey] { level = saved }
        else if method == .zstd { level = Level(rawValue: store.preferences.zipZstdLevel) ?? .three }
        else if method == .ppmd {
            let value = format == .zip ? store.preferences.zipPPMdLevel : store.preferences.sevenZipPPMdLevel
            level = Level(rawValue: value) ?? .normal
        }
        if !levels.contains(level) { level = usesZstd ? .three : .normal }
        rememberChoice()
    }

    private var methodChoiceKey: String { filenameExtension + ":" + method.rawValue }

    private func rememberChoice() {
        choices[filenameExtension] = (method, level)
        methodLevels[methodChoiceKey] = level
    }

    private func resetChoice() {
        if let choice = choices[filenameExtension] { (method, level) = choice; return }
        let preferences = store.preferences
        let options = preferences.writerOptions(for: format)
        let value: Int
        switch format {
        case .zip:
            method = switch options.compressionMethod {
            case .bzip2: .bzip2
            case .lzma: .lzma
            case .xz: .xz
            case .zstd: .zstd
            case .ppmd: .ppmd
            default: .deflate
            }
            value = options.compressionMethod == .stored ? -1 : method == .zstd ? options.zstdLevel : method == .ppmd ? options.ppmdLevel : (startsAtZero ? options.lzmaLevel ?? 6 : method == .bzip2 ? options.bzip2Level : options.deflateLevel)
        case .sevenZip:
            method = switch preferences.sevenZipMethod {
            case .lzma: .lzma
            case .deflate: .deflate
            case .bzip2: .bzip2
            case .ppmd: .ppmd
            default: .lzma2
            }
            value = options.sevenZipMethod == .copy ? -1 : method == .ppmd ? options.ppmdLevel : (startsAtZero ? options.lzmaLevel ?? 6 : method == .bzip2 ? options.bzip2Level : options.deflateLevel)
        case .lha:
            method = preferences.lhaMethod == .lh6 ? .lh6 : preferences.lhaMethod == .lh7 ? .lh7 : .lh5
            value = options.lhaMethod == .stored ? -1 : options.lhaLevel
        case .tarZstd: value = options.zstdLevel
        case .tarGzip: value = options.deflateLevel
        case .tarBzip2: value = options.bzip2Level
        default: value = options.lzmaLevel ?? 6
        }
        level = Level(rawValue: value) ?? .normal
    }

    static func title(for format: GyoshukuKit.ArchiveFormat, bundle: Bundle = .main) -> String {
        switch format {
        case .zip: String(localized: "ZIP", bundle: bundle)
        case .tar: String(localized: "tar", bundle: bundle)
        case .tarGzip: String(localized: "tar.gz", bundle: bundle)
        case .tarBzip2: String(localized: "tar.bz2", bundle: bundle)
        case .tarXZ: String(localized: "tar.xz", bundle: bundle)
        case .tarZstd: String(localized: "tar.zst", bundle: bundle)
        case .tarLzip: String(localized: "tar.lz", bundle: bundle)
        case .tarLZMA: String(localized: "tar.lzma", bundle: bundle)
        case .tarLZ4: String(localized: "tar.lz4", bundle: bundle)
        case .tarBrotli: String(localized: "tar.br", bundle: bundle)
        case .tarCompress: String(localized: "tar.Z", bundle: bundle)
        case .sevenZip: String(localized: "7z", bundle: bundle)
        case .lha: String(localized: "LHA", bundle: bundle)
        }
    }

    static func contentType(for format: GyoshukuKit.ArchiveFormat) -> UTType {
        let identifier: String
        switch format {
        case .zip: return .zip
        case .tar: identifier = "public.tar-archive"
        case .tarGzip: identifier = "com.shunnag.KaitoFinder.save-tar-gzip"
        case .tarBzip2: identifier = "com.shunnag.KaitoFinder.save-tar-bzip2"
        case .tarXZ: identifier = "com.shunnag.KaitoFinder.save-tar-xz"
        case .tarZstd: identifier = "com.shunnag.KaitoFinder.save-tar-zstd"
        case .tarLzip: identifier = "com.shunnag.KaitoFinder.save-tar-lzip"
        case .tarLZMA: identifier = "com.shunnag.KaitoFinder.save-tar-lzma"
        case .tarLZ4: identifier = "com.shunnag.KaitoFinder.save-tar-lz4"
        case .tarBrotli: identifier = "com.shunnag.KaitoFinder.save-tar-brotli"
        case .tarCompress: identifier = "com.shunnag.KaitoFinder.save-tar-compress"
        case .sevenZip: identifier = "org.7-zip.7-zip-archive"
        case .lha: identifier = "com.shunnag.KaitoFinder.lzh-archive"
        }
        return UTType(identifier) ?? UTType(filenameExtension: ArchiveCreationPlan.filenameExtension(for: format)) ?? .data
    }

    static func contentType(for format: SingleStreamFormat) -> UTType {
        let identifier: String = switch format {
        case .gzip: "org.gnu.gnu-zip-archive"
        case .bzip2: "public.bzip2-archive"
        case .xz: "org.tukaani.xz-archive"
        case .zstd: "org.zstandard.zstd-archive"
        case .lzma: "org.tukaani.lzma-archive"
        case .lzip: "com.shunnag.KaitoFinder.lzip-archive"
        case .lz4: "com.shunnag.KaitoFinder.lz4-archive"
        case .brotli: "com.shunnag.KaitoFinder.brotli-archive"
        case .compress: "public.z-archive"
        }
        return UTType(identifier) ?? UTType(filenameExtension: ArchiveCreationPlan.filenameExtension(for: format)) ?? .data
    }

    static func explicitFilenameContentType(for format: GyoshukuKit.ArchiveFormat) -> UTType {
        switch format {
        case .tarGzip: contentType(for: SingleStreamFormat.gzip)
        case .tarBzip2: contentType(for: SingleStreamFormat.bzip2)
        case .tarXZ: contentType(for: SingleStreamFormat.xz)
        case .tarZstd: contentType(for: SingleStreamFormat.zstd)
        case .tarLzip: contentType(for: SingleStreamFormat.lzip)
        case .tarLZMA: contentType(for: SingleStreamFormat.lzma)
        case .tarLZ4: contentType(for: SingleStreamFormat.lz4)
        case .tarBrotli: contentType(for: SingleStreamFormat.brotli)
        case .tarCompress: contentType(for: SingleStreamFormat.compress)
        default: contentType(for: format)
        }
    }

    static func filenameStem(_ filename: String, format: GyoshukuKit.ArchiveFormat) -> String {
        stem(filename, extensions: ArchiveCreationPlan.acceptedExtensions(for: format))
    }

    private static func stem(_ filename: String, extensions: [String]) -> String {
        let suffix = extensions.sorted { $0.count > $1.count }
            .first { filename.count > $0.count + 1 && filename.lowercased().hasSuffix("." + $0.lowercased()) }
        return suffix.map { String(filename.dropLast($0.count + 1)) } ?? filename
    }

    func filenameStem(_ filename: String) -> String { Self.stem(filename, extensions: acceptedExtensions) }

    static func filenameByChangingFormat(_ filename: String, to format: GyoshukuKit.ArchiveFormat) -> String {
        guard !filename.isEmpty else { return filename }
        return stem(filename, extensions: formats.flatMap { ArchiveCreationPlan.acceptedExtensions(for: $0) })
            + "." + ArchiveCreationPlan.filenameExtension(for: format)
    }

    func filenameByChangingFormat(_ filename: String, previousExtension: String) -> String {
        guard !filename.isEmpty else { return filename }
        // 直前の出力拡張子を優先し、一致しなければ既知のアーカイブ拡張子を外す。
        let previousFormat = Self.formats.first { ArchiveCreationPlan.filenameExtension(for: $0).lowercased() == previousExtension.lowercased() }
        let suffixes = previousFormat.map { ArchiveCreationPlan.acceptedExtensions(for: $0) } ?? [previousExtension]
        var name = Self.stem(filename, extensions: suffixes)
        if name == filename {
            name = Self.stem(filename, extensions: Self.formats.flatMap { ArchiveCreationPlan.acceptedExtensions(for: $0) })
        }
        return name + "." + filenameExtension
    }

    func selectFormat(at index: Int, persistsDefault: Bool = true) {
        if Self.formats.indices.contains(index) {
            rememberChoice()
            singleStreamFormat = nil
            format = Self.formats[index]
            resetChoice()
            if persistsDefault { store.preferences.defaultFormat = format }
        } else if offersSingleStream {
            let streamIndex = index - Self.formats.count - 2
            guard ArchiveCreationPlan.singleStreamFormats.indices.contains(streamIndex) else { return }
            rememberChoice()
            singleStreamFormat = ArchiveCreationPlan.singleStreamFormats[streamIndex]
            format = ArchiveCreationPlan.archiveFormat(for: singleStreamFormat!)
            resetChoice()
        }
    }
}
