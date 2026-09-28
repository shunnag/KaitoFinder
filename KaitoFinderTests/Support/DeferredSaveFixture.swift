import AppKit
@_spi(Testing) import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

@MainActor final class DeferredSaveFixture {
    let directory: ArchiveTestDirectory
    let defaults: ArchivePreferencesTestDefaults
    let store: ArchivePreferencesStore
    let archive: URL
    let document: ArchiveDocument
    let original: Data

    init(format: GyoshukuKit.ArchiveFormat = .zip, behavior: ArchivePreferences.SaveBehavior = .onSave,
         quarantine: Data? = nil, secondFolder: Bool = false, files: [(String, String)]? = nil) throws {
        directory = try ArchiveTestDirectory()
        defaults = try ArchivePreferencesTestDefaults()
        store = ArchivePreferencesStore(defaults: defaults.defaults)
        store.preferences.saveBehavior = behavior
        archive = directory.url.appendingPathComponent("original." + ArchiveCreationPlan.filenameExtension(for: format))
        let writer = try ArchiveWriter.create(url: archive, format: format)
        if let files {
            for (name, contents) in files { try writer.add(data: Data(contents.utf8), as: name) }
        } else {
            try writer.add(data: Data("A".utf8), as: "a.txt")
            try writer.add(data: Data("B".utf8), as: "b.txt")
            try writer.addDirectory("folder")
            try writer.add(data: Data("child".utf8), as: "folder/child.txt")
        }
        if secondFolder {
            try writer.addDirectory("other")
            try writer.add(data: Data("sibling".utf8), as: "other/sibling.txt")
        }
        try writer.finish()
        if let quarantine { try ExtractionQuarantine.apply(quarantine, to: archive) }
        original = try Data(contentsOf: archive)
        document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        try document.read(from: archive, ofType: "public.data")
        document.fileURL = archive
        document.fileType = "public.data"
        document.fileModificationDate = try FileManager.default.attributesOfItem(atPath: archive.path)[.modificationDate] as? Date
    }

    func file(_ name: String, contents: String = "new") throws -> URL {
        let url = directory.url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
    func node(_ path: String) async throws -> EntryNode {
        let root = EntryNode.tree(from: try await document.projectedEntries())
        var nodes = [root]
        while let node = nodes.popLast() {
            if node.path == path { return node }
            nodes += node.children
        }
        throw ArchiveEditError.missingFolder(path)
    }
    func save() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            document.save(to: document.fileURL!, ofType: document.fileType!, for: .saveOperation) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
    /// 本番と同じ ReaderOptions（`.kaitoFinder(password:)`）で開いた、通常ファイルの内容。
    nonisolated static func contents(_ url: URL, password: String? = nil) throws -> [String: Data] {
        try ArchiveOracle.contents(url, options: .kaitoFinder(password: password))
    }

    nonisolated static func inventory(_ url: URL) throws -> [String: EntryKind] { try ArchiveOracle.inventory(url) }
}

extension XCTestCase {
    /// フォルダの移動を検査する窓を開く。`a/b/c.txt`・`a/d.txt`・`e.txt`・`.hidden/f.txt` を持つ DeferredSaveFixture を
    /// 名前順で表示し、teardown では名前の編集を終えてから文書を閉じる。
    @MainActor func folderNavigationInterface(behavior: ArchivePreferences.SaveBehavior = .immediate,
                                              opening: ArchivePreferences.FolderOpening = .enter) async throws
        -> (DeferredSaveFixture, ArchiveWindowController) {
        _ = NSApplication.shared
        let fixture = try DeferredSaveFixture(behavior: behavior, files: [
            ("a/b/c.txt", "C"), ("a/d.txt", "D"), ("e.txt", "E"), (".hidden/f.txt", "F")
        ])
        fixture.store.preferences.folderOpening = opening
        let controller = ArchiveWindowController(preferencesStore: fixture.store)
        fixture.document.addWindowController(controller)
        let session = try XCTUnwrap(fixture.document.session)
        controller.display(EntryNode.tree(from: try await fixture.document.projectedEntries()), session: session)
        controller.outlineView.autosaveTableColumns = false
        controller.outlineView.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        closeDocumentAfterTest(fixture.document, controller: controller, retaining: fixture)
        // teardown は登録と逆の順に動くので、文書を閉じる前に名前の編集を終える。
        addTeardownBlock { @MainActor in controller.outlineView.cancelRenaming() }
        return (fixture, controller)
    }
}
