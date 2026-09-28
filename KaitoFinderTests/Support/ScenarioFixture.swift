import AppKit
import Foundation
import KaitoKit
import XCTest
@testable import KaitoFinder

/// シーンごとの入力・出力を隔離し、外部コーパスを使わず実際の書庫を作る。
nonisolated final class ScenarioFixture {
    let directory: ArchiveTestDirectory
    let archive: URL
    var root: URL { directory.url }

    /// `script` は `p`（書庫の path）を受け取って `archive.<suffix>` を書く Python。`arguments` は
    /// `sys.argv[2:]` として script へ渡す。
    init(script: String = "with zipfile.ZipFile(p, 'w') as z: z.writestr('original.txt', b'original')",
         suffix: String = "zip", arguments: [String] = []) throws {
        directory = try ArchiveTestDirectory()
        archive = directory.url.appendingPathComponent("archive." + suffix)
        try Self.python(directory, archive: archive, script: script, arguments: arguments)
    }

    /// `names` の項目を入れた ZIP。file の内容はそれぞれの名前で、`/` で終わる名前は directory にする。
    /// `tar` なら同じ名前の file を入れた tar を LZMA_Alone で包んだ archive.tar.lzma（読み取り専用の形式）にする。
    nonisolated static func withEntries(_ names: [String] = ["a.txt", "b.txt", "c.txt"], tar: Bool = false) throws -> ScenarioFixture {
        try ScenarioFixture(script: """
        names = sys.argv[2:]
        if p.endswith('.tar.lzma'):
            with tarfile.open(p, 'w') as a:
                for name in names:
                    item = tarfile.TarInfo(name)
                    data = name.encode()
                    item.size = len(data)
                    a.addfile(item, io.BytesIO(data))
            import lzma; raw=open(p,'rb').read(); open(p,'wb').write(lzma.compress(raw,format=lzma.FORMAT_ALONE))
        else:
            with zipfile.ZipFile(p, 'w', compression=zipfile.ZIP_DEFLATED) as a:
                for name in names:
                    a.writestr(name, b'' if name.endswith('/') else name.encode())
        """, suffix: tar ? "tar.lzma" : "zip", arguments: names)
    }

    private static func python(_ directory: ArchiveTestDirectory, archive: URL, script: String, arguments: [String]) throws {
        try directory.run(ExternalTool.python3, ["-c",
            "import sys, zipfile, tarfile, io, stat, struct, os\np = sys.argv[1]\n" + script, archive.path] + arguments)
    }

    /// fixture の中の `name` へ、`init` と同じ前置きの `script` で書く。同じ名前なら既存の file を置き換える。
    func pythonArchive(_ name: String, script: String, arguments: [String] = []) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Self.python(directory, archive: url, script: script, arguments: arguments)
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

    static func digest(_ url: URL) throws -> Data { try ArchiveOracle.digest(url) }

    /// KaitoKit の既定の ReaderOptions で開いた、通常ファイルの内容。
    static func contents(_ url: URL) throws -> [String: Data] { try ArchiveOracle.contents(url) }

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

    /// 書庫の全項目を `destination` へ展開する。`session` を省くと新しい session で開く。
    func extract(to destination: URL, session: ArchiveSession? = nil, progress: Progress = Progress(totalUnitCount: 0),
                 didProcess: (@Sendable (Int) -> Void)? = nil) async throws -> ExtractionResult {
        let source = try session ?? ArchiveSession(url: archive)
        return try await ExtractionService.extract(ExtractionSelection(entries: await source.entries()), from: source,
                                                   to: destination, progress: progress, didProcess: didProcess)
    }
}

extension XCTestCase {
    /// 一覧を名前順に全展開し、入力可能な文書を teardown まで保持する。
    @MainActor func interface(_ fixture: ScenarioFixture, stack: ArchiveUndoStack = ArchiveUndoStack()) async throws
        -> (ArchiveDocument, ArchiveWindowController) {
        let document = ArchiveDocument(undoStack: stack)
        try document.read(from: fixture.archive, ofType: "archive")
        let controller = ArchiveWindowController()
        document.addWindowController(controller)
        let session = try XCTUnwrap(document.session)
        let snapshot = await session.snapshot()
        controller.display(EntryNode.tree(from: snapshot.entries), session: session, generation: snapshot.generation)
        controller.outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        controller.outlineView.expandItem(nil, expandChildren: true)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.makeFirstResponder(controller.outlineView)
        closeDocumentAfterTest(document, controller: controller, retaining: fixture)
        return (document, controller)
    }

    /// 書庫に保存された全項目の名前を返す。
    nonisolated func names(_ fixture: ScenarioFixture) throws -> Set<String> {
        Set(try ArchiveReader.open(url: fixture.archive).entries.map(\.name))
    }

    /// teardown で `document` を閉じ、閉じる前に `controller` が持っていた操作とロック解除の Task、文書の undo・実体化・
    /// session の後片付けの完了を待つ。`owner`（fixture や設定の suite）はそれまで保持する。
    @MainActor func closeDocumentAfterTest(_ document: ArchiveDocument, controller: ArchiveWindowController?,
                                           retaining owner: Any?) {
        addTeardownBlock { @MainActor in
            // close() は操作を取り消すだけなので、その時点の Task を先に取り出して終わりまで待つ。
            let extraction = controller?.extractionTask, unlock = controller?.unlockTask
            document.close()
            await extraction?.value
            await unlock?.value
            await document.undoCleanup?.value
            await document.materializationCleanup?.value
            await document.sessionCleanup?.value
            withExtendedLifetime(owner) {}
        }
    }

    /// `fixture` の書庫（`url` を渡せばその file）を文書として開き、一覧を表示したウインドウと組にして返す。
    /// 文書は teardown で `closeDocumentAfterTest` が閉じる。
    @MainActor func scenarioDocument(_ fixture: ScenarioFixture, url: URL? = nil,
                                      preferencesStore: ArchivePreferencesStore = .shared) async throws
        -> (ArchiveDocument, ArchiveWindowController) {
        let document = ArchiveDocument(), source = url ?? fixture.archive
        try document.read(from: source, ofType: "public.zip-archive")
        document.fileURL = source
        let session = try XCTUnwrap(document.session)
        let controller = ArchiveWindowController(preferencesStore: preferencesStore)
        document.addWindowController(controller)
        controller.display(EntryNode.tree(from: await session.entries()), session: session,
                           materializationController: document.materializationController())
        closeDocumentAfterTest(document, controller: controller, retaining: fixture)
        return (document, controller)
    }
}
