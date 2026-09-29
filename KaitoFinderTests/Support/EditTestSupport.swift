import AppKit
import KaitoKit
import XCTest
@testable public import KaitoFinder

/// 編集テストでレコードの保存と文書の undo・redo を照合する。
nonisolated protocol EditTestSupport: XCTestCase {}

extension EditTestSupport {
    func records(_ url: URL) throws -> [String: EditTestFixture.Record] {
        let bytes = try Data(contentsOf: url), reader = try ArchiveReader.open(url: url)
        var result: [String: EditTestFixture.Record] = [:]
        for entry in reader.entries {
            let raw = try XCTUnwrap(reader.rawRecord(of: entry))
            var contents = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { contents.append(contentsOf: $0) }
            result[entry.name] = EditTestFixture.Record(nameBytes: entry.rawName.bytes,
                local: bytes.subdata(in: Int(raw.recordRange.lowerBound)..<Int(raw.recordRange.upperBound)),
                payload: bytes.subdata(in: Int(raw.payloadRange.lowerBound)..<Int(raw.payloadRange.upperBound)),
                contents: contents)
        }
        return result
    }

    func assertCarried(_ before: [String: EditTestFixture.Record], to url: URL, removed: Set<String> = [],
                               renamed: [String: String] = [:]) throws {
        let after = try records(url)
        let expected = before.keys.filter { !removed.contains($0) }.map { renamed[$0] ?? $0 }
        XCTAssertEqual(try ArchiveReader.open(url: url).entries.map(\.name).sorted(), expected.sorted())
        for (name, record) in before where !removed.contains(name) {
            let surviving = try XCTUnwrap(after[renamed[name] ?? name])
            XCTAssertEqual(surviving.contents, record.contents)
            XCTAssertEqual(surviving.payload, record.payload)
            if renamed[name] == nil {
                XCTAssertEqual(surviving.local, record.local)
                XCTAssertEqual(surviving.nameBytes, record.nameBytes)
            }
        }
    }

    @MainActor func node(_ path: String, in session: ArchiveSession) async throws -> EntryNode {
        let entries = await session.entries()
        var pending = [EntryNode.tree(from: entries)]
        while let node = pending.popLast() {
            if node.path == path { return node }
            pending.append(contentsOf: node.children)
        }
        throw ArchiveEditError.staleSelection
    }

    @MainActor func document(_ fixture: EditTestFixture, stack: ArchiveUndoStack = ArchiveUndoStack()) throws -> ArchiveDocument {
        let document = ArchiveDocument(undoStack: stack)
        try document.read(from: fixture.archive, ofType: "zip")
        closeDocumentAfterTest(document, controller: nil, retaining: fixture)
        return document
    }

    @MainActor func undo(_ document: ArchiveDocument) async throws {
        let manager = try XCTUnwrap(document.undoManager)
        XCTAssertTrue(manager.canUndo)
        manager.undo()
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
    }

    @MainActor func redo(_ document: ArchiveDocument) async throws {
        let manager = try XCTUnwrap(document.undoManager)
        XCTAssertTrue(manager.canRedo)
        manager.redo()
        await document.undoTask?.value
        XCTAssertNil(document.undoFailure)
    }
}
