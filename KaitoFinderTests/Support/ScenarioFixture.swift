import AppKit
import CryptoKit
import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

/// シーンごとの入力・出力を隔離し、外部コーパスを使わず実際の書庫を作る。
nonisolated final class ScenarioFixture {
    let directory: ArchiveTestDirectory
    let archive: URL
    var root: URL { directory.url }

    init(script: String = "with zipfile.ZipFile(p, 'w') as z: z.writestr('original.txt', b'original')",
         suffix: String = "zip") throws {
        directory = try ArchiveTestDirectory()
        archive = directory.url.appendingPathComponent("archive." + suffix)
        try Self.python(directory, archive: archive, script: script)
    }

    private static func python(_ directory: ArchiveTestDirectory, archive: URL, script: String) throws {
        try directory.run("/usr/bin/python3", ["-c",
            "import sys, zipfile, tarfile, io, stat, struct, os\np = sys.argv[1]\n" + script, archive.path])
    }

    func pythonArchive(_ name: String, script: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Self.python(directory, archive: url, script: script)
        return url
    }

    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ name: String, bytes: Data = Data("added".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    static func digest(_ url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url)))
    }

    static func contents(_ url: URL) throws -> [String: Data] {
        let reader = try ArchiveReader.open(url: url)
        var result: [String: Data] = [:]
        for entry in reader.entries where entry.kind == .file {
            var bytes = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
            result[entry.name] = bytes
        }
        return result
    }

    static func files(under root: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        return try enumerator.compactMap { item in
            guard let url = item as? URL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return url
        }
    }

    /// `root/` の下の 20 フォルダへ `count` 個のファイル（各 `size` バイト、mode と日時つき）を分けて入れる ZIP の script。
    static func zipScript(count: Int, size: Int) -> String {
        """
        with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            names = ['root/'] + ['root/d%02d/' % n for n in range(20)]
            names += ['root/d%02d/f%05d' % (n % 20, n) for n in range(\(count))]
            for n, name in enumerate(names):
                i = zipfile.ZipInfo(name, (2020, 1, 2, 3, 4, 6))
                i.create_system = 3
                i.compress_type = zipfile.ZIP_DEFLATED
                i.external_attr = ((stat.S_IFDIR | 0o755) if name.endswith('/') else (stat.S_IFREG | 0o640)) << 16
                z.writestr(i, b'' if name.endswith('/') else bytes([n % 251]) * \(size))
        """
    }

    func extract(to destination: URL, session: ArchiveSession? = nil) async throws -> ExtractionResult {
        let source = try session ?? ArchiveSession(url: archive)
        return try await ExtractionService.extract(ExtractionSelection(entries: await source.entries()), from: source, to: destination)
    }
}

extension XCTestCase {
    @MainActor func scenarioDocument(_ fixture: ScenarioFixture, url: URL? = nil,
                                      preferencesStore: ArchivePreferencesStore = .shared) async throws
        -> (ArchiveDocument, ArchiveWindowController) {
        preserveArchiveWindowFrame()
        let document = ArchiveDocument(), source = url ?? fixture.archive
        try document.read(from: source, ofType: "public.zip-archive")
        document.fileURL = source
        let session = try XCTUnwrap(document.session)
        let controller = ArchiveWindowController(preferencesStore: preferencesStore)
        document.addWindowController(controller)
        controller.display(EntryNode.tree(from: await session.entries()), session: session,
                           materializationController: document.materializationController())
        addTeardownBlock { @MainActor in
            document.close()
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            withExtendedLifetime(fixture) {}
        }
        return (document, controller)
    }
}
