import AppKit
import KaitoKit
import XCTest
@testable import KaitoFinder

nonisolated final class DocumentTypesTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func declaration() throws -> [String: Any] {
        try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: repository.appendingPathComponent("KaitoFinder/Info.plist")),
            format: nil) as? [String: Any])
    }

    func testEveryReadableFormatHasDeclaredDocumentIdentifiers() throws {
        // allCases とも比較し、KaitoKit に形式が増えたときに宣言漏れを検出する。
        let expected: [KaitoKit.ArchiveFormat: [String]] = [
            .zip: ["public.zip-archive", "com.winzip.zipx-archive"],
            .rar: ["com.rarlab.rar-archive"],
            .sevenZip: ["org.7-zip.7-zip-archive"],
            .lha: ["public.lha-archive"],
            .stuffIt: ["com.stuffit.archive.sit"],
            .stuffItX: ["com.stuffit.archive.sitx"],
            .tar: ["public.tar-archive", "org.gnu.gnu-zip-tar-archive"],
            .cpio: ["public.cpio-archive"],
            .ar: ["com.shunnag.KaitoFinder.ar-archive", "org.debian.deb-archive"],
            .iso: ["public.iso-image"],
            .cab: ["com.microsoft.cab"],
            .rpm: ["com.redhat.rpm-archive"],
            .xar: ["com.apple.xar-archive", "com.apple.installer-package-archive"],
            .gzip: ["org.gnu.gnu-zip-archive"],
            .bzip2: ["public.bzip2-archive"],
            .xz: ["org.tukaani.xz-archive", "org.tukaani.tar-xz-archive"],
            .zstd: ["org.zstandard.zstd-archive"],
            .lz4: ["com.shunnag.KaitoFinder.lz4-archive"],
            .lzma: ["org.tukaani.lzma-archive"],
            .compress: ["public.z-archive"],
            .dmg: ["com.apple.disk-image-udif"],
            .udf: ["com.shunnag.KaitoFinder.udf-image"],
            .wim: ["com.shunnag.KaitoFinder.wim-archive"],
            .compoundFile: ["com.shunnag.KaitoFinder.msi-archive", "com.microsoft.msi-installer"],
            .chm: ["com.shunnag.KaitoFinder.chm-archive"],
            .arj: ["com.shunnag.KaitoFinder.arj-archive", "cx.c3.arj-archive"],
            .macBinary: ["com.apple.macbinary-archive"],
            .appleSingle: ["com.apple.applesingle-archive"],
            .binHex: ["com.apple.binhex-archive"],
            .lzip: ["com.shunnag.KaitoFinder.lzip-archive"],
            .brotli: ["com.shunnag.KaitoFinder.brotli-archive"],
            .pbzx: ["com.shunnag.KaitoFinder.pbzx-archive"]
        ]
        XCTAssertEqual(Set(expected.keys), Set(KaitoKit.ArchiveFormat.allCases))
        let documents = try XCTUnwrap(declaration()["CFBundleDocumentTypes"] as? [[String: Any]])
        let declared = Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        for format in KaitoKit.ArchiveFormat.allCases {
            let identifiers = try XCTUnwrap(expected[format], format.rawValue)
            XCTAssertFalse(identifiers.isEmpty, format.rawValue)
            XCTAssertTrue(Set(identifiers).isSubset(of: declared), format.rawValue)
        }
        XCTAssertEqual(declared, Set(expected.values.flatMap { $0 }).union([ArchiveDocumentController.splitVolumeType]))
        for (name, identifiers) in [
            "ZIP": expected[.zip], "XZ": expected[.xz], "ar": expected[.ar],
            "Compound File": expected[.compoundFile], "ARJ": expected[.arj]
        ] {
            let document = try XCTUnwrap(documents.first { $0["CFBundleTypeName"] as? String == name })
            XCTAssertEqual(document["LSItemContentTypes"] as? [String], identifiers, name)
        }
    }

    func testImportedExtensionsAndFallbackBindings() throws {
        let imports = try XCTUnwrap(declaration()["UTImportedTypeDeclarations"] as? [[String: Any]])
        let documents = try XCTUnwrap(declaration()["CFBundleDocumentTypes"] as? [[String: Any]])
        let expected = [
            "org.zstandard.zstd-archive": ["zst", "tzst"],
            "com.shunnag.KaitoFinder.lz4-archive": ["lz4"],
            "org.tukaani.tar-xz-archive": ["txz"],
            "com.winzip.zipx-archive": ["zipx"],
            "org.debian.deb-archive": ["deb"],
            "com.stuffit.archive.sit": ["sit", "sea"],
            "com.stuffit.archive.sitx": ["sitx"],
            "com.microsoft.cab": ["cab"],
            "public.zip-archive": ["zip", "zipx", "cbz"],
            "org.tukaani.xz-archive": ["xz", "txz"],
            "org.tukaani.lzma-archive": ["lzma", "tlz"],
            "com.shunnag.KaitoFinder.ar-archive": ["ar", "a", "deb"],
            "com.shunnag.KaitoFinder.udf-image": ["udf"],
            "com.shunnag.KaitoFinder.wim-archive": ["wim", "swm"],
            "com.shunnag.KaitoFinder.msi-archive": ["msi"],
            "com.microsoft.msi-installer": ["msi"],
            "com.shunnag.KaitoFinder.chm-archive": ["chm"],
            "com.shunnag.KaitoFinder.arj-archive": ["arj"],
            "cx.c3.arj-archive": ["arj"],
            "com.shunnag.KaitoFinder.lzip-archive": ["lz"],
            "com.shunnag.KaitoFinder.brotli-archive": ["br", "tbr"],
            "com.shunnag.KaitoFinder.pbzx-archive": ["pbzx"]
        ]
        for (identifier, extensions) in expected {
            let matches = imports.filter { $0["UTTypeIdentifier"] as? String == identifier }
            XCTAssertEqual(matches.count, 1, identifier)
            let imported = try XCTUnwrap(matches.first)
            let tags = try XCTUnwrap(imported["UTTypeTagSpecification"] as? [String: Any])
            XCTAssertEqual(tags["public.filename-extension"] as? [String], extensions, identifier)
            let conforms = try XCTUnwrap(imported["UTTypeConformsTo"] as? [String])
            XCTAssertTrue(Set(["public.data", "public.archive"]).isSubset(of: Set(conforms)), identifier)
            if identifier == "org.zstandard.zstd-archive" {
                XCTAssertEqual(imported["UTTypeDescription"] as? String, "Zstandard")
            }
            if identifier.hasPrefix("com.shunnag.KaitoFinder.") {
                let document = try XCTUnwrap(documents.first {
                    ($0["LSItemContentTypes"] as? [String] ?? []).contains(identifier)
                })
                XCTAssertEqual(imported["UTTypeDescription"] as? String, document["CFBundleTypeName"] as? String, identifier)
            }
        }
    }

    func testDocumentRolesAndHandlerRanksRespectBuiltInOpeners() throws {
        let expected = [
            "ZIP": "Alternate", "tar": "Alternate", "gzip": "Alternate", "bzip2": "Alternate",
            "XZ": "Alternate", "UNIX compress": "Alternate", "cpio": "Alternate",
            "ISO 9660": "Alternate", "xar": "Alternate", "Installer Package": "Alternate",
            "7-Zip": "Default", "RAR": "Default", "LHA": "Default", "ar": "Default",
            "CAB": "Default", "RPM": "Default", "LZMA": "Default", "StuffIt": "Default",
            "StuffIt X": "Default", "Zstandard": "Default", "LZ4": "Default",
            "Apple Disk Image": "Alternate",
            "UDF": "Alternate",
            "WIM": "Default",
            "Compound File": "Default",
            "CHM": "Default",
            "ARJ": "Default",
            "MacBinary": "Alternate",
            "AppleSingle": "Alternate",
            "BinHex": "Alternate",
            "lzip": "Default",
            "Brotli": "Default",
            "pbzx": "Default",
            ArchiveDocumentController.splitVolumeType: "None"
        ]
        let documents = try XCTUnwrap(declaration()["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertEqual(documents.count, expected.count)
        XCTAssertEqual(Set(documents.compactMap { $0["CFBundleTypeName"] as? String }), Set(expected.keys))
        for document in documents {
            let name = try XCTUnwrap(document["CFBundleTypeName"] as? String)
            XCTAssertEqual(document["LSHandlerRank"] as? String, expected[name], name)
            XCTAssertEqual(document["CFBundleTypeRole"] as? String, "Viewer", name)
            XCTAssertEqual(document["NSDocumentClass"] as? String, "$(PRODUCT_MODULE_NAME).ArchiveDocument", name)
        }
    }

    func testSplitVolumeTypeIsExportedWithoutFinderExtensionTags() throws {
        let plist = try declaration(), identifier = ArchiveDocumentController.splitVolumeType
        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let matches = documents.filter { ($0["LSItemContentTypes"] as? [String] ?? []).contains(identifier) }
        XCTAssertEqual(matches.count, 1)
        let document = try XCTUnwrap(matches.first)
        XCTAssertEqual(document["LSItemContentTypes"] as? [String], [identifier])
        XCTAssertNil(document["CFBundleTypeExtensions"])
        let exports = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let exported = exports.filter { $0["UTTypeIdentifier"] as? String == identifier }
        XCTAssertEqual(exported.count, 1)
        let type = try XCTUnwrap(exported.first)
        XCTAssertEqual(Set(try XCTUnwrap(type["UTTypeConformsTo"] as? [String])), Set(["public.data", "public.archive"]))
        XCTAssertNil(type["UTTypeTagSpecification"])
        let imports = try XCTUnwrap(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertFalse(imports.contains { $0["UTTypeIdentifier"] as? String == identifier })
        for declaration in imports + exports {
            let tags = declaration["UTTypeTagSpecification"] as? [String: Any]
            for suffix in tags?["public.filename-extension"] as? [String] ?? [] {
                XCTAssertFalse(ArchiveSplitVolume.isOpenableName("archive." + suffix), suffix)
            }
        }
        // 実ファイルに付かない内部型も含め、既存の Services と文書型の集合の一致を保つ。
        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let service = try XCTUnwrap(services.first { $0["NSMessage"] as? String == "extractArchives" })
        XCTAssertEqual(Set(try XCTUnwrap(service["NSSendFileTypes"] as? [String])),
                       Set(documents.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }))
    }

    func testDisplayNamesCoverEveryReadableFormat() throws {
        let expected: [KaitoKit.ArchiveFormat: String] = [
            .zip: "ZIP", .rar: "RAR", .sevenZip: "7z", .lha: "LHA", .stuffIt: "StuffIt",
            .stuffItX: "StuffIt X", .tar: "tar", .cpio: "cpio", .ar: "ar", .iso: "ISO 9660",
            .cab: "CAB", .rpm: "RPM", .xar: "xar", .gzip: "gzip", .bzip2: "bzip2", .xz: "xz",
            .zstd: "Zstandard", .lz4: "LZ4", .lzma: "LZMA", .compress: "UNIX compress",
            .dmg: "Apple Disk Image",
            .udf: "UDF",
            .wim: "WIM",
            .compoundFile: "Compound File",
            .chm: "CHM",
            .arj: "ARJ",
            .macBinary: "MacBinary",
            .appleSingle: "AppleSingle",
            .binHex: "BinHex",
            .lzip: "lzip",
            .brotli: "Brotli",
            .pbzx: "pbzx"
        ]
        XCTAssertEqual(Set(expected.keys), Set(KaitoKit.ArchiveFormat.allCases))
        // 指定表記の LZMA も rawValue の大文字化と一致する。
        let uppercaseNames: Set<KaitoKit.ArchiveFormat> = [.zip, .rar, .lha, .cab, .rpm, .lzma, .lz4, .udf, .wim, .chm, .arj]
        for format in KaitoKit.ArchiveFormat.allCases {
            XCTAssertEqual(format.displayName, try XCTUnwrap(expected[format]), format.rawValue)
            XCTAssertFalse(format.displayName.isEmpty, format.rawValue)
            XCTAssertEqual(format.displayName == format.rawValue.uppercased(), uppercaseNames.contains(format), format.rawValue)
        }
    }

    @MainActor func testNewDocumentTypesOpenByContentAndUseDisplayNames() async throws {
        let directory = try ArchiveTestDirectory(), app = Bundle(for: ArchiveDocument.self)
        let japanese = try XCTUnwrap(Bundle(url: XCTUnwrap(app.url(forResource: "ja", withExtension: "lproj"))))
        let english = try XCTUnwrap(Bundle(url: XCTUnwrap(app.url(forResource: "en", withExtension: "lproj"))))
        let fixtures = repository.deletingLastPathComponent().appendingPathComponent("KaitoKit/Tests/Fixtures")
        // 隣接 checkout に収録された小さな fixture を使い、専用の読み込み経路が不要なことを確認する。
        let cases: [(String, String, KaitoKit.ArchiveFormat, String, String)] = [
            ("stuffit/testfile.stuffit7.win.sit.b64", "sit", .stuffIt, "com.stuffit.archive.sit", "StuffIt"),
            ("stuffit/testfile.stuffit_deluxe_2010.win.basic.sitx.b64", "sitx", .stuffItX, "com.stuffit.archive.sitx", "StuffIt X"),
            ("zstd/one-l1.zst.b64", "zst", .zstd, "org.zstandard.zstd-archive", "Zstandard"),
            ("lz4-frame/tiny.lz4.b64", "lz4", .lz4, "com.shunnag.KaitoFinder.lz4-archive", "LZ4")
        ]
        for (fixture, fileExtension, format, identifier, name) in cases {
            let encoded = try Data(contentsOf: fixtures.appendingPathComponent(fixture))
            let bytes = try XCTUnwrap(Data(base64Encoded: encoded, options: .ignoreUnknownCharacters))
            let archive = directory.url.appendingPathComponent("archive." + fileExtension)
            try bytes.write(to: archive)
            let document = ArchiveDocument()
            addTeardownBlock { @MainActor in
                document.close()
                await document.undoCleanup?.value
                await document.materializationCleanup?.value
                await document.sessionCleanup?.value
                withExtendedLifetime(directory) {}
            }
            try document.read(from: archive, ofType: identifier)
            let session = try XCTUnwrap(document.session)
            XCTAssertEqual(session.format, format)
            let entries = await session.entries()
            XCTAssertFalse(entries.isEmpty, fixture)
            let capability = session.capabilities
            XCTAssertNil(capability.mode)
            XCTAssertEqual(capability.refusal, .format(name))
            XCTAssertEqual(capability.readOnlyReason(bundle: japanese), "\(name)アーカイブは変更できません。")
            XCTAssertEqual(capability.readOnlyReason(bundle: english), "\(name) archives cannot be modified.")
            XCTAssertEqual(ArchiveConversionNotice.formatName(for: session), name)
        }
        let compress = ArchiveCapabilities.inspect(url: directory.url.appendingPathComponent("archive.Z"), format: .compress)
        XCTAssertEqual(compress.readOnlyReason(bundle: japanese), "UNIX compressアーカイブは変更できません。")
    }

    func testSaveTypesDeclareCanonicalExtensionsBeforeAliases() throws {
        let imports = try XCTUnwrap(declaration()["UTImportedTypeDeclarations"] as? [[String: Any]])
        for (identifier, extensions, parent) in [
            ("com.shunnag.KaitoFinder.save-tar-gzip", ["tar.gz", "tgz"], "org.gnu.gnu-zip-archive"),
            ("com.shunnag.KaitoFinder.save-tar-bzip2", ["tar.bz2", "tbz2", "tbz"], "public.bzip2-archive"),
            ("com.shunnag.KaitoFinder.save-tar-xz", ["tar.xz", "txz"], "org.tukaani.xz-archive"),
            ("com.shunnag.KaitoFinder.save-tbz", ["tbz2", "tbz"], "public.bzip2-archive"),
            ("com.shunnag.KaitoFinder.lzh-archive", ["lzh", "lha"], "public.lha-archive")
        ] {
            let type = try XCTUnwrap(imports.first { $0["UTTypeIdentifier"] as? String == identifier })
            let tags = try XCTUnwrap(type["UTTypeTagSpecification"] as? [String: Any])
            XCTAssertEqual(tags["public.filename-extension"] as? [String], extensions)
            XCTAssertTrue((type["UTTypeConformsTo"] as? [String] ?? []).contains(parent))
        }
    }

}
