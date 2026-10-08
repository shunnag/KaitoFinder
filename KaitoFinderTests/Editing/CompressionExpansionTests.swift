import Foundation
import GyoshukuKit
@_spi(SevenZipEditLayout) import KaitoKit
import UniformTypeIdentifiers
import XCTest
@testable import KaitoFinder

/// 保存パネルのモデルと作成・編集経路を、パネルを表示せずに検証する。
nonisolated final class CompressionExpansionTests: XCTestCase {
    @MainActor func testEveryFormatMethodAndNumericLevelMapsToWriterOptions() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let controller = ArchiveSavePanelController(store: store)
        XCTAssertEqual(ArchivePreferences.formats.count, 13)
        for (index, format) in ArchivePreferences.formats.enumerated() {
            controller.selectFormat(at: index)
            let methods = controller.methods
            for methodIndex in methods.isEmpty ? [0] : Array(methods.indices) {
                controller.selectMethod(at: methodIndex)
                let method = controller.method
                let numeric = controller.usesZstd ? Array(1...19) : controller.startsAtZero ? Array(0...9) : Array(1...9)
                let stored = !controller.usesZstd && [.zip, .sevenZip, .lha].contains(format)
                XCTAssertEqual(controller.levels.map(\.rawValue), controller.isLevelEnabled ? (stored ? [-1] : []) + numeric : [6])
                for levelIndex in controller.levels.indices {
                    controller.selectLevel(at: levelIndex)
                    let level = controller.level.rawValue, options = controller.writerOptions
                    switch format {
                    case .zip:
                        let expected: CompressionMethod = switch method {
                        case .bzip2: .bzip2
                        case .lzma: .lzma
                        case .xz: .xz
                        case .zstd: .zstd
                        case .ppmd: .ppmd
                        default: .deflate
                        }
                        XCTAssertEqual(options.compressionMethod, level == -1 ? .stored : expected)
                    case .sevenZip:
                        let expected: SevenZipCompressionMethod = switch method {
                        case .lzma: .lzma
                        case .deflate: .deflate
                        case .bzip2: .bzip2
                        case .ppmd: .ppmd
                        default: .lzma2
                        }
                        XCTAssertEqual(options.sevenZipMethod, level == -1 ? .copy : expected)
                    case .lha:
                        XCTAssertEqual(options.lhaMethod, level == -1 ? .stored : method == .lh6 ? .lh6 : method == .lh7 ? .lh7 : .lh5)
                        if level != -1 { XCTAssertEqual(options.lhaLevel, level) }
                    default: break
                    }
                    guard controller.isLevelEnabled, level != -1 else { continue }
                    if controller.usesZstd {
                        XCTAssertEqual(options.zstdLevel, level)
                    } else if [.zip, .sevenZip].contains(format) && method == .ppmd {
                        XCTAssertEqual(options.ppmdLevel, level)
                    } else if controller.startsAtZero {
                        let apple = format == .tarXZ || format == .zip && method == .xz || format == .sevenZip && method == .lzma2
                        XCTAssertEqual(options.lzmaLevel, apple && level == 6 ? nil : level, "\(format) / \(method) / \(level)")
                    } else if format == .tarGzip || [.zip, .sevenZip].contains(format) && method == .deflate {
                        XCTAssertEqual(options.deflateLevel, level)
                    } else if format == .tarBzip2 || [.zip, .sevenZip].contains(format) && method == .bzip2 {
                        XCTAssertEqual(options.bzip2Level, level)
                    }
                }
            }
        }
    }

    @MainActor func testMethodCompatibilityAndChoicesAreRememberedPerFormat() throws {
        let suite = try ArchivePreferencesTestDefaults(), controller = ArchiveSavePanelController(defaults: suite.defaults)
        XCTAssertFalse(controller.showsZipCompatibilityNote)
        controller.selectMethod(at: 1)
        controller.selectLevel(at: 3)
        XCTAssertEqual(controller.method, .bzip2)
        XCTAssertEqual(controller.level.rawValue, 3)
        XCTAssertTrue(controller.showsZipCompatibilityNote)
        controller.selectLevel(at: 0)
        XCTAssertFalse(controller.showsZipCompatibilityNote)
        controller.selectFormat(at: ArchivePreferences.formats.firstIndex(of: .sevenZip)!)
        controller.selectMethod(at: 1)
        controller.selectLevel(at: 1)
        XCTAssertEqual(controller.level, .zero)
        controller.selectFormat(at: 0)
        XCTAssertEqual(controller.method, .bzip2)
        XCTAssertEqual(controller.level, .none)
        controller.selectFormat(at: ArchivePreferences.formats.firstIndex(of: .sevenZip)!)
        XCTAssertEqual(controller.method, .lzma)
        XCTAssertEqual(controller.level, .zero)
    }

    @MainActor func testNewDefaultsRoundTripAndLegacyKeysKeepTheirMeaning() throws {
        let suite = try ArchivePreferencesTestDefaults(), defaults = suite.defaults
        defaults.set("stored", forKey: "ArchiveZipMethod")
        defaults.set(8, forKey: "ArchiveZipLevel")
        defaults.set(3, forKey: "ArchiveTarGzipLevel")
        defaults.set(7, forKey: "ArchiveTarBzip2Level")
        let store = ArchivePreferencesStore(defaults: defaults)
        XCTAssertEqual(store.preferences.zipMethod, .stored)
        XCTAssertEqual(store.preferences.zipLevel, 8)
        XCTAssertEqual(store.preferences.tarGzipLevel, 3)
        XCTAssertEqual(store.preferences.tarBzip2Level, 7)
        XCTAssertNil(store.preferences.writerOptions(for: .tarXZ).lzmaLevel)
        XCTAssertNil(store.preferences.writerOptions(for: .sevenZip).lzmaLevel)
        for level in 0...9 {
            var value = store.preferences
            value.zipMethod = .xz
            value.zipLZMALevel = level
            value.tarXZLevel = level
            value.tarLzipLevel = level
            value.tarLZMALevel = level
            value.sevenZipMethod = .lzma
            value.sevenZipLevel = level
            value.lhaMethod = .lh7
            value.lhaLevel = max(1, level)
            store.preferences = value
            XCTAssertEqual(ArchivePreferencesStore(defaults: defaults).preferences, value)
            XCTAssertEqual(value.writerOptions(for: .zip).lzmaLevel, level == 6 ? nil : level)
            XCTAssertEqual(value.writerOptions(for: .tarXZ).lzmaLevel, level == 6 ? nil : level)
            XCTAssertEqual(value.writerOptions(for: .tarLzip).lzmaLevel, level)
            XCTAssertEqual(value.writerOptions(for: .tarLZMA).lzmaLevel, level)
            XCTAssertEqual(value.writerOptions(for: .sevenZip).lzmaLevel, level)
            XCTAssertEqual(value.writerOptions(for: .lha).lhaLevel, max(1, level))
        }
        for method in ArchivePreferences.SevenZipMethod.allCases {
            store.preferences.sevenZipMethod = method
            XCTAssertEqual(ArchivePreferencesStore(defaults: defaults).preferences.sevenZipMethod, method)
        }
        for method in ArchivePreferences.LhaMethod.allCases {
            store.preferences.lhaMethod = method
            XCTAssertEqual(ArchivePreferencesStore(defaults: defaults).preferences.lhaMethod, method)
        }
        store.preferences.sevenZipLevel = -1
        store.preferences.lhaLevel = -1
        XCTAssertEqual(store.preferences.writerOptions(for: .sevenZip).sevenZipMethod, .copy)
        XCTAssertEqual(store.preferences.writerOptions(for: .lha).lhaMethod, .stored)
        let keys = [ArchivePreferencesStore.Key.zipLZMALevel, ArchivePreferencesStore.Key.tarXZLevel, ArchivePreferencesStore.Key.tarLzipLevel, ArchivePreferencesStore.Key.tarLZMALevel, ArchivePreferencesStore.Key.sevenZipLevel, ArchivePreferencesStore.Key.lhaLevel]
        for invalid: Any in [-2, 10, true, 1.5, "6", Data([0])] {
            for key in keys { defaults.set(invalid, forKey: key) }
            let value = store.preferences
            XCTAssertEqual([value.zipLZMALevel, value.tarXZLevel, value.tarLzipLevel, value.tarLZMALevel, value.sevenZipLevel, value.lhaLevel], Array(repeating: 6, count: 6))
        }
        defaults.set("unknown", forKey: ArchivePreferencesStore.Key.sevenZipMethod)
        defaults.set("unknown", forKey: ArchivePreferencesStore.Key.lhaMethod)
        XCTAssertEqual(store.preferences.sevenZipMethod, .lzma2)
        XCTAssertEqual(store.preferences.lhaMethod, .lh5)
    }

    @MainActor func testPreferencesEditorPersistsEachFormatWithoutChangingDefaultFormat() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let model = PreferencesViewModel(store: store)
        for format in PreferencesViewModel.additionalFormats {
            let controller = model.compressionController(for: format)
            for methodIndex in controller.methods.isEmpty ? [0] : Array(controller.methods.indices) {
                controller.selectMethod(at: methodIndex)
                for levelIndex in controller.levels.indices {
                    controller.selectLevel(at: levelIndex)
                    model.changeCompressionDefault(controller)
                    let restored = model.compressionController(for: format)
                    XCTAssertEqual(restored.method, controller.method)
                    XCTAssertEqual(restored.level, controller.level)
                    XCTAssertEqual(store.preferences.defaultFormat, .zip)
                }
            }
        }
        store.preferences.zipLevel = 8
        model.selectZipMethod(at: 4)
        model.changeZipLevel(to: 0)
        XCTAssertEqual(store.preferences.zipLZMALevel, 0)
        XCTAssertEqual(store.preferences.zipLevel, 8)
        model.selectZipMethod(at: 0)
        XCTAssertEqual(model.zipLevelLabel, "8")
        store.preferences.sevenZipMethod = .deflate
        suite.defaults.set(0, forKey: ArchivePreferencesStore.Key.sevenZipLevel)
        XCTAssertEqual(store.preferences.sevenZipLevel, 6)
    }

    @MainActor func testSelectedMethodsCreateValidPayloadsThroughAppPlan() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("repeat.txt")
        let bytes = Data(repeating: 65, count: 8192)
        try bytes.write(to: source)
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.zipSkipsCompressedTypes = false
        let creator = ArchiveCreationController(store: store)
        for format in [GyoshukuKit.ArchiveFormat.zip, .sevenZip, .lha] {
            let controller = ArchiveSavePanelController(store: store)
            controller.selectFormat(at: ArchivePreferences.formats.firstIndex(of: format)!)
            for methodIndex in controller.methods.indices {
                controller.selectMethod(at: methodIndex)
                for level in [ArchiveSavePanelController.Level.none, .normal].filter({ controller.levels.contains($0) }) {
                    controller.selectLevel(at: controller.levels.firstIndex(of: level)!)
                    let output = directory.url.appendingPathComponent("method-\(methodIndex)-\(level.rawValue)." + controller.filenameExtension)
                    let plan = creator.creationPlan(sources: [source], destination: output, format: format,
                        level: controller.level, method: controller.method)
                    _ = try ArchiveCreationTransaction.run(plan: plan, progress: Progress())
                    let reader = try ArchiveReader.open(url: output), entry = try XCTUnwrap(reader.entries.first)
                    XCTAssertEqual(try reader.read(entry), bytes)
                    if format == .zip && level != .none && [.zstd, .ppmd].contains(controller.method) {
                        XCTAssertEqual(entry.methodDescription, controller.method == .zstd ? "zstd" : "ppmd")
                    }
                    if level == .none { XCTAssertEqual(entry.compressedSize, UInt64(bytes.count)) }
                    else { XCTAssertLessThan(try XCTUnwrap(entry.compressedSize), UInt64(bytes.count)) }
                }
            }
        }
    }

    @MainActor func testSingleFileAvailabilityNamesAndDefaultFormatPersistence() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("report.pdf")
        try Data("single file".utf8).write(to: source)
        let folder = directory.url.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let package = directory.url.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let link = directory.url.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertTrue(ArchiveCreationPlan.canCompressSingleFile([source]))
        for sources in [[], [folder], [package], [link], [source, source], [source, folder], [directory.url.appendingPathComponent("missing")]] {
            XCTAssertFalse(ArchiveCreationPlan.canCompressSingleFile(sources))
        }
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.defaultFormat = .sevenZip
        let controller = ArchiveSavePanelController(store: store, sources: [source])
        XCTAssertTrue(controller.offersSingleStream)
        XCTAssertFalse(ArchiveSavePanelController(store: store, sources: [source], allowsSingleStream: false).offersSingleStream)
        var name = "report.pdf.7z", previous = "7z"
        for (index, stream) in ArchiveCreationPlan.singleStreamFormats.enumerated() {
            controller.selectFormat(at: ArchivePreferences.formats.count + 2 + index)
            let suffix = ArchiveCreationPlan.filenameExtension(for: stream)
            XCTAssertEqual(controller.singleStreamFormat, stream)
            name = controller.filenameByChangingFormat(name, previousExtension: previous)
            XCTAssertEqual(name, "report.pdf." + suffix)
            previous = suffix
            XCTAssertEqual(store.preferences.defaultFormat, .sevenZip)
            XCTAssertNil(ArchiveSavePanelController(store: store, sources: [source]).singleStreamFormat)
            XCTAssertTrue(controller.methods.isEmpty)
        }
        XCTAssertEqual(ArchiveSavePanelController.filenameStem("photos.tar.Z", format: .tarCompress), "photos")
        for format in ArchivePreferences.formats {
            let suffix = ArchiveCreationPlan.filenameExtension(for: format)
            XCTAssertTrue(ArchiveCreationPlan.hasAcceptedExtension(directory.url.appendingPathComponent("a." + suffix.uppercased()), for: format))
            XCTAssertEqual(ArchiveCreationPlan.archiveStem(for: directory.url.appendingPathComponent("a." + suffix)), "a")
        }
        for format in [GyoshukuKit.ArchiveFormat.tarLzip, .tarLZMA] {
            XCTAssertFalse(ArchiveCreationPlan.acceptedExtensions(for: format).contains("tlz"))
        }
    }

    @MainActor func testFormatChangesReplaceTypedArchiveExtensionsAndPreserveSingleStreamStem() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("report.pdf")
        try Data("single file".utf8).write(to: source)
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let controller = ArchiveSavePanelController(store: store, sources: [source])
        controller.selectFormat(at: ArchivePreferences.formats.firstIndex(of: .tarGzip)!)
        XCTAssertEqual(controller.filenameByChangingFormat("keep.tar.gz", previousExtension: "zip"), "keep.tar.gz")
        controller.selectFormat(at: ArchivePreferences.formats.firstIndex(of: .zip)!)
        XCTAssertEqual(controller.filenameByChangingFormat("keep.tar.gz", previousExtension: "tar.gz"), "keep.zip")
        controller.selectFormat(at: ArchivePreferences.formats.firstIndex(of: .sevenZip)!)
        XCTAssertEqual(controller.filenameByChangingFormat("photos.tgz", previousExtension: "zip"), "photos.7z")
        controller.selectFormat(at: ArchivePreferences.formats.count + 2 + ArchiveCreationPlan.singleStreamFormats.firstIndex(of: .xz)!)
        XCTAssertEqual(controller.filenameByChangingFormat("report.pdf.gz", previousExtension: "gz"), "report.pdf.xz")
        controller.selectFormat(at: ArchivePreferences.formats.firstIndex(of: .tarGzip)!)
        XCTAssertEqual(controller.filenameByChangingFormat("notes", previousExtension: "zip"), "notes.tar.gz")
    }

    @MainActor func testSavePanelRestoresCanonicalHiddenExtensionCase() throws {
        let directory = try ArchiveTestDirectory(), suite = try ArchivePreferencesTestDefaults()
        let store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.defaultFormat = .tarCompress
        let save = ArchiveSavePanel(sources: [directory.url.appendingPathComponent("review")], store: store)
        save.panel.directoryURL = directory.url
        save.panel.isExtensionHidden = true
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review.tar.z", confirmed: true), "review.tar.Z")
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review.tar.Z.tar.z", confirmed: true), "review.tar.Z.tar.Z")
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review", confirmed: true), "review.tar.Z")
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review.tar.Z", confirmed: true), "review.tar.Z")
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review.tar.z.backup", confirmed: true), "review.tar.z.backup")
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review.tar.z", confirmed: false), "review.tar.z")
        save.panel.isExtensionHidden = false
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review.tar.z", confirmed: true), "review.tar.z")
        save.formatPopup.selectItem(at: try XCTUnwrap(ArchivePreferences.formats.firstIndex(of: .tarGzip)))
        save.changeFormat(save.formatPopup)
        save.panel.isExtensionHidden = true
        XCTAssertEqual(save.controller.filenameExtension, "tar.gz")
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review.tar.gz", confirmed: true), "review.tar.gz")
    }

    @MainActor func testSavePanelRestoresSingleStreamCompressExtensionCase() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("report.pdf")
        try Data("single file".utf8).write(to: source)
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.defaultFormat = .tarCompress
        let save = ArchiveSavePanel(sources: [source], store: store)
        save.panel.directoryURL = directory.url
        let index = try XCTUnwrap(ArchiveCreationPlan.singleStreamFormats.firstIndex(of: .compress))
        save.formatPopup.selectItem(at: ArchivePreferences.formats.count + 2 + index)
        save.changeFormat(save.formatPopup)
        save.panel.isExtensionHidden = true
        XCTAssertEqual(save.controller.singleStreamFormat, .compress)
        XCTAssertEqual(save.controller.filenameExtension, "Z")
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "report.pdf.z", confirmed: true), "report.pdf.Z")
    }

    @MainActor func testSavePanelExtensionCaseCorrectionRequiresSameExistingFile() throws {
        let directory = try ArchiveTestDirectory(), suite = try ArchivePreferencesTestDefaults()
        let store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.defaultFormat = .tarCompress
        let save = ArchiveSavePanel(sources: [], store: store)
        save.panel.directoryURL = directory.url
        save.panel.isExtensionHidden = true
        let canonical = directory.url.appendingPathComponent("review.tar.Z")
        let original = directory.url.appendingPathComponent("review.tar.z")
        let bytes = Data("existing canonical file".utf8)
        try bytes.write(to: canonical)
        // 区別するボリュームでは別ファイルを保護し、最後に同じファイルへのリンクも確かめる。
        if !FileManager.default.fileExists(atPath: original.path) {
            XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review.tar.z", confirmed: true), "review.tar.z")
            try Data("separate file".utf8).write(to: original)
            XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review.tar.z", confirmed: true), "review.tar.z")
            try FileManager.default.removeItem(at: original)
            try FileManager.default.linkItem(at: canonical, to: original)
        }
        XCTAssertEqual(save.panel(save.panel, userEnteredFilename: "review.tar.z", confirmed: true), "review.tar.Z")
        XCTAssertEqual(try Data(contentsOf: canonical), bytes)
    }

    @MainActor func testSingleStreamsCreateThroughAppPlanAndRemainReadOnly() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("report.pdf")
        let bytes = Data("single stream\0日本語\n".utf8) + Data(repeating: 65, count: 4096)
        try bytes.write(to: source)
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.tarPreservesOwnerIDs = true
        let creator = ArchiveCreationController(store: store)
        for stream in ArchiveCreationPlan.singleStreamFormats {
            let output = source.appendingPathExtension(ArchiveCreationPlan.filenameExtension(for: stream))
            let plan = creator.creationPlan(sources: [source], destination: output, format: ArchiveCreationPlan.archiveFormat(for: stream), singleStreamFormat: stream)
            XCTAssertFalse(plan.options.preserveOwnerIDs)
            let progress = Progress()
            XCTAssertEqual(try ArchiveCreationTransaction.run(plan: plan, progress: progress), output)
            let reader = try ArchiveReader.open(url: output, options: .kaitoFinder())
            XCTAssertEqual(reader.entries.count, 1)
            XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), bytes)
            XCTAssertFalse(ArchiveCapabilities.inspect(reader: reader, url: output).canEdit)
            XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        }
        XCTAssertEqual(store.preferences.defaultFormat, .zip)
    }

    @MainActor func testAllArchiveFormatsCreateAndConvertThroughAppPlan() throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("note.txt")
        let bytes = Data("archive contents\0日本語\n".utf8)
        try bytes.write(to: source)
        let suite = try ArchivePreferencesTestDefaults(), creator = ArchiveCreationController(store: ArchivePreferencesStore(defaults: suite.defaults))
        let original = directory.url.appendingPathComponent("original.zip")
        _ = try ArchiveCreationTransaction.run(plan: creator.creationPlan(sources: [source], destination: original, format: .zip), progress: Progress())
        let entries = try ArchiveReader.open(url: original).entries
        for format in ArchivePreferences.formats {
            for converts in [false, true] {
                let output = directory.url.appendingPathComponent((converts ? "converted." : "created.") + ArchiveCreationPlan.filenameExtension(for: format))
                let plan = creator.creationPlan(sources: converts ? [] : [source], destination: output, format: format,
                    existing: converts ? .init(url: original, password: nil, entries: entries) : nil)
                _ = try ArchiveCreationTransaction.run(plan: plan, progress: Progress())
                let reader = try ArchiveReader.open(url: output)
                XCTAssertEqual(reader.entries.map(\.name), ["note.txt"])
                XCTAssertEqual(try reader.read(XCTUnwrap(reader.entries.first)), bytes)
            }
        }
    }

    @MainActor func testNewTarFormatsAddRenameReplaceDeleteThroughRewriter() async throws {
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("old.txt")
        try Data("original".utf8).write(to: source)
        var preferences = ArchivePreferences()
        preferences.tarLzipLevel = 0
        preferences.tarLZMALevel = 0
        for format in [GyoshukuKit.ArchiveFormat.tarZstd, .tarLZMA, .tarLzip, .tarLZ4, .tarBrotli, .tarCompress] {
            let archive = directory.url.appendingPathComponent("edited." + ArchiveCreationPlan.filenameExtension(for: format))
            _ = try ArchiveCreationTransaction.run(plan: .init(sources: [source], destination: archive, format: format, options: preferences.writerOptions(for: format)), progress: Progress())
            let saved = preferences
            let session = try ArchiveSession(url: archive, writerOptions: { saved.writerOptions(for: $0) })
            XCTAssertEqual(session.capabilities.mode, .rewrite(format))
            XCTAssertNil(session.capabilities.readOnlyReason)
            let addition = directory.url.appendingPathComponent("added.txt")
            try Data("added".utf8).write(to: addition)
            let appended = try await session.append(urls: [addition], to: "", progress: Progress())
            XCTAssertTrue(appended.failures.isEmpty)
            let old = try await selection("old.txt", in: session)
            _ = try await session.rename(old, to: "renamed.txt", progress: Progress())
            let replacement = directory.url.appendingPathComponent("renamed.txt")
            try Data("replacement".utf8).write(to: replacement)
            let replaced = try await session.append(urls: [replacement], to: "", progress: Progress(), resolveConflict: { _ in .init(choice: .replace) })
            XCTAssertTrue(replaced.failures.isEmpty)
            _ = try await session.remove([selection("added.txt", in: session)], progress: Progress())
            XCTAssertEqual(try ArchiveOracle.contents(archive), ["renamed.txt": Data("replacement".utf8)])
            XCTAssertEqual(try ArchiveReader.open(url: archive).format, .tar)
            XCTAssertEqual(session.capabilities.mode, .rewrite(format))
        }
    }

    @MainActor func testZstdAndPPMdDefaultsUseIndependentKeysAndRejectInvalidValues() throws {
        let suite = try ArchivePreferencesTestDefaults(), defaults = suite.defaults
        let store = ArchivePreferencesStore(defaults: defaults), model = PreferencesViewModel(store: store)
        XCTAssertEqual(store.preferences.tarZstdLevel, 3)
        XCTAssertEqual(store.preferences.zipZstdLevel, 3)
        XCTAssertEqual(store.preferences.zipPPMdLevel, 6)
        XCTAssertEqual(store.preferences.sevenZipPPMdLevel, 6)
        XCTAssertFalse(store.preferences.sevenZipSolid)
        XCTAssertEqual(store.preferences.sevenZipFilter, .none)
        for level in 1...19 {
            var value = store.preferences
            value.defaultFormat = .tarZstd
            value.tarZstdLevel = level
            value.zipZstdLevel = level
            value.zipPPMdLevel = min(9, level)
            value.sevenZipPPMdLevel = min(9, level)
            value.zipMethod = .zstd
            value.sevenZipMethod = .ppmd
            value.sevenZipSolid = true
            value.sevenZipFilter = .delta
            store.preferences = value
            XCTAssertEqual(ArchivePreferencesStore(defaults: defaults).preferences, value)
            XCTAssertEqual(value.writerOptions(for: .tarZstd).zstdLevel, level)
            XCTAssertEqual(value.writerOptions(for: .zip).zstdLevel, level)
            XCTAssertEqual(value.writerOptions(for: .sevenZip).ppmdLevel, min(9, level))
        }
        store.preferences.zipLevel = 8
        store.preferences.zipLZMALevel = 2
        model.selectZipMethod(at: PreferencesViewModel.zipMethods.firstIndex(of: .ppmd)!)
        model.changeZipLevel(to: 4)
        model.selectZipMethod(at: PreferencesViewModel.zipMethods.firstIndex(of: .zstd)!)
        model.changeZipLevel(to: 17)
        XCTAssertEqual(model.zipLevelLabel, "17")
        XCTAssertEqual(store.preferences.zipPPMdLevel, 4)
        XCTAssertEqual(store.preferences.zipLZMALevel, 2)
        XCTAssertEqual(store.preferences.zipLevel, 8)
        let keys = [ArchivePreferencesStore.Key.tarZstdLevel, ArchivePreferencesStore.Key.zipZstdLevel,
                    ArchivePreferencesStore.Key.zipPPMdLevel, ArchivePreferencesStore.Key.sevenZipPPMdLevel]
        for invalid: Any in [-1, 0, 20, true, 1.5, "3", Data([0])] {
            for key in keys { defaults.set(invalid, forKey: key) }
            XCTAssertEqual(store.preferences.tarZstdLevel, 3)
            XCTAssertEqual(store.preferences.zipZstdLevel, 3)
            XCTAssertEqual(store.preferences.zipPPMdLevel, 6)
            XCTAssertEqual(store.preferences.sevenZipPPMdLevel, 6)
        }
        defaults.set(10, forKey: ArchivePreferencesStore.Key.zipPPMdLevel)
        defaults.set(10, forKey: ArchivePreferencesStore.Key.sevenZipPPMdLevel)
        XCTAssertEqual(store.preferences.zipPPMdLevel, 6)
        XCTAssertEqual(store.preferences.sevenZipPPMdLevel, 6)
        var invalid = store.preferences
        invalid.tarZstdLevel = 0; invalid.zipZstdLevel = 20
        invalid.zipPPMdLevel = 10; invalid.sevenZipPPMdLevel = -1
        store.preferences = invalid
        XCTAssertEqual(store.preferences.tarZstdLevel, 3)
        XCTAssertEqual(store.preferences.zipZstdLevel, 3)
        XCTAssertEqual(store.preferences.zipPPMdLevel, 6)
        XCTAssertEqual(store.preferences.sevenZipPPMdLevel, 6)
        for invalid: Any in [1, "true", Data([0])] {
            // @YES と @1 の等価判定で書き込みが省かれないよう、元の値を除く。
            defaults.removeObject(forKey: ArchivePreferencesStore.Key.sevenZipSolid)
            defaults.set(invalid, forKey: ArchivePreferencesStore.Key.sevenZipSolid)
            XCTAssertFalse(store.preferences.sevenZipSolid)
        }
        defaults.set("unknown", forKey: ArchivePreferencesStore.Key.sevenZipFilter)
        XCTAssertEqual(store.preferences.sevenZipFilter, .none)
    }

    @MainActor func testZstdLevelLabelsAndSingleStreamTypeAndTarAliases() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let directory = try ArchiveTestDirectory(), source = directory.url.appendingPathComponent("note.txt")
        try Data("source".utf8).write(to: source)
        store.preferences.tarZstdLevel = 13
        let controller = ArchiveSavePanelController(store: store, sources: [source])
        controller.selectFormat(at: ArchivePreferences.formats.firstIndex(of: .tarZstd)!)
        XCTAssertEqual(controller.writerOptions.zstdLevel, 13)
        XCTAssertEqual(controller.allowedContentTypes, [try XCTUnwrap(UTType("com.shunnag.KaitoFinder.save-tar-zstd"))])
        XCTAssertEqual(controller.acceptedExtensions, ["tar.zst", "tzst"])
        XCTAssertEqual(ArchiveSavePanelController.filenameStem("archive.TZST", format: .tarZstd), "archive")
        XCTAssertEqual(ArchiveSavePanelController.filenameByChangingFormat("archive.tzst", to: .zip), "archive.zip")
        controller.selectFormat(at: ArchivePreferences.formats.count + 2 + ArchiveCreationPlan.singleStreamFormats.firstIndex(of: .zstd)!)
        XCTAssertEqual(controller.singleStreamFormat, .zstd)
        XCTAssertEqual(controller.filenameExtension, "zst")
        XCTAssertEqual(controller.allowedContentTypes, [try XCTUnwrap(UTType("org.zstandard.zstd-archive"))])
        XCTAssertEqual(controller.writerOptions.zstdLevel, 13)
        XCTAssertFalse(controller.levels.contains(.none))
        let bundle = try LocalizationAcceptance.bundle("ja")
        XCTAssertEqual(ArchiveSavePanelController.Level.fast.title(bundle: bundle, zstd: true), "1（最速）")
        XCTAssertEqual(ArchiveSavePanelController.Level.three.title(bundle: bundle, zstd: true), "3（標準）")
        XCTAssertEqual(ArchiveSavePanelController.Level.nineteen.title(bundle: bundle, zstd: true), "19（最高）")
        XCTAssertEqual(ArchiveSavePanelController.Level.normal.title(bundle: bundle, zstd: true), "6")
    }

    @MainActor func testSevenZipSolidAndFiltersPersistAndReachCreatedArchive() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        let model = PreferencesViewModel(store: store), creator = ArchiveCreationController(store: store)
        let directory = try ArchiveTestDirectory()
        // 自動判定にも渡せる x86_64 の Mach-O header を付ける。
        let bytes = Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1]) + Data(repeating: 0, count: 24)
            + Data(repeating: 65, count: 4096)
        let sources = ["first.bin", "second.bin"].map { directory.url.appendingPathComponent($0) }
        for source in sources { try bytes.write(to: source) }
        for solid in [false, true] {
            for filter in ArchivePreferences.SevenZipFilter.allCases {
                let controller = model.compressionController(for: .sevenZip)
                controller.selectMethod(at: controller.methods.firstIndex(of: .ppmd)!)
                controller.selectLevel(at: controller.levels.firstIndex(of: .normal)!)
                controller.sevenZipSolid = solid
                controller.sevenZipFilter = filter
                model.changeCompressionDefault(controller)
                let restored = model.compressionController(for: .sevenZip)
                XCTAssertEqual(restored.sevenZipSolid, solid)
                XCTAssertEqual(restored.sevenZipFilter, filter)
                XCTAssertEqual(restored.writerOptions.sevenZipSolid, solid ? .on(blockSize: nil, filesPerBlock: nil) : .off)
                XCTAssertEqual(restored.writerOptions.sevenZipFilter, filter.writerMode)
                XCTAssertNil(restored.writerOptions.ppmdOrder)
                XCTAssertNil(restored.writerOptions.ppmdMemoryMiB)
                let output = directory.url.appendingPathComponent("options-\(solid)-\(filter.rawValue).7z")
                let plan = creator.creationPlan(sources: sources, destination: output, format: .sevenZip,
                    level: restored.level, method: restored.method, sevenZipSolid: solid, sevenZipFilter: filter)
                XCTAssertEqual(plan.options.sevenZipSolid, restored.writerOptions.sevenZipSolid)
                XCTAssertEqual(plan.options.sevenZipFilter, filter.writerMode)
                _ = try ArchiveCreationTransaction.run(plan: plan, progress: Progress())
                var readOptions = ReaderOptions.kaitoFinder()
                readOptions.recordsSevenZipEditLayout = true
                let reader = try ArchiveReader.open(url: output, options: readOptions)
                for entry in reader.entries { XCTAssertEqual(try reader.read(entry), bytes) }
                let snapshot = try XCTUnwrap(reader.sevenZipEditingSnapshot())
                XCTAssertEqual(snapshot.folders.count, solid ? 1 : 2)
                for folder in snapshot.folders {
                    XCTAssertEqual(folder.substreamIndices.count, solid ? 2 : 1)
                    XCTAssertTrue(folder.coders.contains { $0.methodID == [3, 4, 1] })
                    let filterID: [UInt8]? = switch filter {
                    case .none: nil
                    case .auto, .bcjX86: [3, 3, 1, 3]
                    case .arm64: [10]
                    case .delta: [3]
                    }
                    if let filterID {
                        let coder = try XCTUnwrap(folder.coders.first { $0.methodID == filterID })
                        if filter == .delta { XCTAssertEqual(coder.properties, [3]) }
                    } else { XCTAssertEqual(folder.coders.count, 1) }
                }
                controller.selectFormat(at: ArchivePreferences.formats.firstIndex(of: .zip)!, persistsDefault: false)
                XCTAssertFalse(controller.showsSevenZipOptions)
                XCTAssertEqual(controller.writerOptions.sevenZipSolid, .off)
                XCTAssertEqual(controller.writerOptions.sevenZipFilter, .none)
            }
        }
        // 保存パネルの指定は、その時点の設定を上書きして作成計画まで届く。
        let overridden = creator.creationPlan(sources: sources, destination: directory.url.appendingPathComponent("override.7z"),
            format: .sevenZip, sevenZipSolid: false, sevenZipFilter: .bcjX86)
        XCTAssertEqual(overridden.options.sevenZipSolid, .off)
        XCTAssertEqual(overridden.options.sevenZipFilter, .bcjX86)
    }

    @MainActor func testNewCompressionDefaultsReachSessionEdits() async throws {
        let directory = try ArchiveTestDirectory()
        let sources = ["first.txt", "second.txt"].map { directory.url.appendingPathComponent($0) }
        let bytes = Data(repeating: 65, count: 2048)
        for source in sources { try bytes.write(to: source) }
        for (index, format) in [GyoshukuKit.ArchiveFormat.zip, .zip, .sevenZip, .tarZstd].enumerated() {
            var preferences = ArchivePreferences()
            preferences.zipMethod = index == 0 ? .zstd : .ppmd
            preferences.zipZstdLevel = 1
            preferences.zipPPMdLevel = 2
            preferences.sevenZipMethod = .ppmd
            preferences.sevenZipPPMdLevel = 3
            preferences.sevenZipSolid = true
            preferences.sevenZipFilter = .delta
            preferences.tarZstdLevel = 4
            preferences.zipSkipsCompressedTypes = false
            let output = directory.url.appendingPathComponent("edit-options-\(index)." + ArchiveCreationPlan.filenameExtension(for: format))
            let writer = try ArchiveWriter.create(url: output, format: format)
            try writer.add(data: Data("original".utf8), as: "old.txt")
            try writer.finish()
            let saved = preferences
            let session = try ArchiveSession(url: output, writerOptions: { saved.writerOptions(for: $0) })
            let options = session.writerOptions(format)
            XCTAssertEqual(options.zstdLevel, format == .tarZstd ? 4 : format == .zip ? 1 : 3)
            XCTAssertEqual(options.ppmdLevel, format == .zip ? 2 : format == .sevenZip ? 3 : 6)
            let result = try await session.append(urls: sources, to: "", progress: Progress())
            XCTAssertTrue(result.failures.isEmpty)
            var readOptions = ReaderOptions.kaitoFinder()
            readOptions.recordsSevenZipEditLayout = true
            let reader = try ArchiveReader.open(url: output, options: readOptions)
            XCTAssertEqual(Set(reader.entries.map(\.name)), Set(["old.txt", "first.txt", "second.txt"]))
            for entry in reader.entries where entry.name != "old.txt" {
                XCTAssertEqual(try reader.read(entry), bytes)
                if format == .zip { XCTAssertEqual(entry.methodDescription, index == 0 ? "zstd" : "ppmd") }
            }
            if format == .sevenZip {
                let snapshot = try XCTUnwrap(reader.sevenZipEditingSnapshot())
                let newFolder = try XCTUnwrap(snapshot.folders.last)
                XCTAssertEqual(newFolder.substreamIndices.count, 2)
                XCTAssertTrue(newFolder.coders.contains { $0.methodID == [3, 4, 1] })
                XCTAssertEqual(newFolder.coders.first { $0.methodID == [3] }?.properties, [3])
            }
            if format == .tarZstd { XCTAssertEqual(session.capabilities.mode, .rewrite(.tarZstd)) }
            await session.close()
        }
    }

    @MainActor func testNewZipMethodsUseTheirDefaultsAndCompatibilityNote() throws {
        let suite = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: suite.defaults)
        store.preferences.zipZstdLevel = 3
        store.preferences.zipPPMdLevel = 7
        let controller = ArchiveSavePanelController(store: store)
        for method in [ArchiveSavePanelController.Method.zstd, .ppmd] {
            controller.selectMethod(at: controller.methods.firstIndex(of: method)!)
            XCTAssertTrue(controller.showsZipCompatibilityNote)
            XCTAssertEqual(controller.level.rawValue, method == .zstd ? 3 : 7)
        }
        controller.selectMethod(at: controller.methods.firstIndex(of: .zstd)!)
        controller.selectLevel(at: controller.levels.firstIndex(of: .nineteen)!)
        controller.selectMethod(at: controller.methods.firstIndex(of: .ppmd)!)
        XCTAssertEqual(controller.level.rawValue, 7)
        controller.selectMethod(at: controller.methods.firstIndex(of: .zstd)!)
        XCTAssertEqual(controller.level.rawValue, 19)
    }

    @MainActor private func selection(_ name: String, in session: ArchiveSession) async throws -> ArchiveEditSelection {
        let entries = await session.entries()
        var nodes = [EntryNode.tree(from: entries)]
        while let node = nodes.popLast() {
            if node.path == name { return ArchiveEditSelection(node) }
            nodes.append(contentsOf: node.children)
        }
        throw ArchiveEditError.staleSelection
    }

    func testExpandedStringsHaveAllTwentySixTranslations() throws {
        let strings = try LocalizationAcceptance.catalog().strings
        for key in ["Zstandard", "PPMd", "x86 (BCJ)", "ARM64", "Delta", "tar.zst", "3（標準）", "19（最高）", "ソリッド圧縮", "フィルタ", "なし", "自動", "tar.lz", "tar.lzma", "tar.lz4", "tar.br", "tar.Z", "0（最速）", "1（最速）", "6（標準）", "9（最高）",
                    "1 ファイルの圧縮", "この形式は圧縮レベルを選べません", "このZIPはmacOSのアーカイブユーティリティやunzipでは開けません"] {
            let localizations = try XCTUnwrap(strings[key]).localizations
            XCTAssertEqual(Set(localizations.keys), Set(LocalizationAcceptance.languages))
            for unit in localizations.values { XCTAssertEqual(unit.stringUnit.state, "translated") }
        }
    }
}
