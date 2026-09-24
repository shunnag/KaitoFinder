import AppKit
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class PerformanceProbeTests: XCTestCase {
    @MainActor func testArchiveOpeningWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KAITOFINDER_PERFORMANCE_PROBES"] == "1" else {
            throw XCTSkip("Set KAITOFINDER_PERFORMANCE_PROBES=1 to run archive opening probes")
        }
        let count = Int(environment["KAITOFINDER_PROBE_ENTRIES"] ?? "") ?? 100_000
        guard count >= 1 else { throw XCTSkip("KAITOFINDER_PROBE_ENTRIES must be positive") }
        preserveArchiveWindowFrame()
        let directory = try ArchiveTestDirectory(), archive = directory.url.appendingPathComponent("opening.zip")
        try await Self.writeArchive(archive, count: count, openingLayout: true)
        let documents = try XCTUnwrap(NSDocumentController.shared as? ArchiveDocumentController)
        let recordsRecents = documents.recordsRecentDocuments, preferences = ArchivePreferencesStore.shared.preferences
        documents.recordsRecentDocuments = false
        ArchivePreferencesStore.shared.preferences.saveBehavior = .immediate
        defer {
            documents.recordsRecentDocuments = recordsRecents
            ArchivePreferencesStore.shared.preferences = preferences
        }
        let watcher = MainActorProbe(interval: 0.002)
        defer { watcher.stop() }
        while !watcher.hasSample { try await Task.sleep(for: .milliseconds(1)) }
        let start = ContinuousClock.now
        let opened: (ArchiveDocument, ContinuousClock.Instant)
        do {
            opened = try await withCheckedThrowingContinuation { continuation in
                documents.openDocument(withContentsOf: archive, display: true) { opened, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let document = opened as? ArchiveDocument { continuation.resume(returning: (document, .now)) }
                    else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                }
            }
        } catch { _ = await watcher.finish(); throw error }
        let (document, documentReady) = opened
        defer { document.close(); withExtendedLifetime(directory) {} }
        let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
        let deadline = ContinuousClock.now + .seconds(120)
        while !controller.renameIndexIsReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let worst = await watcher.finish()
        XCTAssertTrue(controller.renameIndexIsReady)
        XCTAssertGreaterThan(controller.outlineView.numberOfRows, 0)
        let displayed = try XCTUnwrap(controller.treeDisplayedAt), indexed = try XCTUnwrap(controller.renameIndexReadyAt)
        print("PROBE immediate open entries=\(count), folders=\((count + 99) / 100)")
        for (label, instant) in [("document ready", documentReady), ("tree displayed / rows visible", displayed),
                                  ("rename index ready", indexed)] {
            print(String(format: "PROBE immediate open %@: %.3f ms", label, Self.milliseconds(start.duration(to: instant))))
        }
        print(String(format: "PROBE immediate open worst main.sync latency (2 ms pings): %.3f ms", worst))
        await document.prepareForTermination()
    }

    @MainActor func testArchiveEditsWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["KAITOFINDER_PERFORMANCE_PROBES"] == "1" else {
            throw XCTSkip("Set KAITOFINDER_PERFORMANCE_PROBES=1 to run archive editing probes")
        }
        let count = Int(environment["KAITOFINDER_PROBE_ENTRIES"] ?? "") ?? 100_000
        guard count >= 2 else { throw XCTSkip("KAITOFINDER_PROBE_ENTRIES must be at least 2") }
        let asserts = environment["KAITOFINDER_PROBE_ASSERT"] == "1"
        let directory = try ArchiveTestDirectory()
        let original = directory.url.appendingPathComponent("original.zip")
        try await Self.writeArchive(original, count: count)
        print("PROBE entries=\(count), timing assertions=\(asserts)")
        preserveArchiveWindowFrame()
        for mode in [ArchivePreferences.SaveBehavior.immediate, .onSave] {
            let label = mode == .onSave ? "deferred" : "immediate"
            let archive = directory.url.appendingPathComponent(label + ".zip")
            try FileManager.default.copyItem(at: original, to: archive)
            let defaults = try ArchivePreferencesTestDefaults()
            let store = ArchivePreferencesStore(defaults: defaults.defaults)
            store.preferences.saveBehavior = mode
            let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
            defer { document.close() }
            try await measure(label + " document read") { try document.read(from: archive, ofType: "public.data") }
            document.fileURL = archive
            document.fileType = "public.data"
            document.fileModificationDate = try FileManager.default.attributesOfItem(atPath: archive.path)[.modificationDate] as? Date
            let entries = try await measure(label + " reservation preparation") { try await document.projectedEntries() }
            let root = await measure(label + " EntryNode.tree") { await Self.tree(entries, indexingEdits: mode == .immediate) }
            let controller = ArchiveWindowController(preferencesStore: store)
            document.addWindowController(controller)
            let session = try XCTUnwrap(document.session)
            await measure(label + " display") { controller.display(root, session: session, generation: session.generation) }
            let file = try XCTUnwrap(root.nodes(at: "d000/s0/f0000000.txt").first)
            let validation = ArchiveRenameValidation(selection: ArchiveEditSelection(file), entries: entries,
                                                     state: document.pendingEditor?.prepared, occupancy: root.editOccupancy)
            for call in 1...3 {
                try await measure(label + " rename-commit validation \(call)", limit: asserts && count <= 100_000 ? 30 : nil) {
                    _ = try validation.plan(for: "renamed.txt")
                }
            }
            XCTAssertEqual(validation.validationCount, 1)
            let limit = asserts && mode == .onSave ? (count <= 100_000 ? 250.0 : 1_500.0) : nil
            let stallLimit = asserts && mode == .onSave ? (count <= 100_000 ? 50.0 : 100.0) : nil
            func reservation<Value>(_ name: String, _ action: @MainActor () async throws -> Value) async throws -> Value {
                try await measure(label + " " + name, limit: limit, monitor: mode == .onSave, stallLimit: stallLimit, action)
            }
            _ = try await reservation("rename") { try await document.rename(file, to: "renamed.txt", progress: Progress()) }
            let deleteFile = try await node("d000/s0/f0000001.txt", document: document)
            _ = try await reservation("delete 1") { try await document.remove([deleteFile], progress: Progress()) }
            _ = try await reservation("new folder") { try await document.createFolder(in: "", baseName: "new", progress: Progress()) }
            let folder = try await node(count >= 2_000 ? "d001" : "d000", document: document)
            _ = try await reservation("delete folder") { try await document.remove([folder], progress: Progress()) }
            let source = directory.url.appendingPathComponent("added.txt")
            try Data([42]).write(to: source)
            _ = try await reservation("add 1 file") {
                try await document.append(urls: [source], to: "", progress: Progress(), resolveConflict: { _ in
                    XCTFail("Unexpected conflict"); return .init(choice: .skip)
                })
            }
            if mode == .onSave {
                try await measure(label + " save") {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        document.save(to: archive, ofType: "public.data", for: .saveOperation) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                }
            } else { print("PROBE immediate deferred save: 0.000 ms (no deferred changes)") }
            await document.prepareForTermination()
        }
        withExtendedLifetime(directory) {}
    }

    @concurrent private static func writeArchive(_ url: URL, count: Int, openingLayout: Bool = false) async throws {
        let writer = try ArchiveWriter.create(url: url, format: .zip)
        let data = Data([42])
        for index in 0..<count {
            let name = openingLayout ? String(format: "d%05d/f%07d.txt", index / 100, index)
                : String(format: "d%03d/s%d/f%07d.txt", index / 1000, (index / 100) % 10, index)
            try writer.add(data: data, as: name)
        }
        try writer.finish()
    }

    @concurrent private static func tree(_ entries: [ArchiveEntry], indexingEdits: Bool = false) async -> EntryNode {
        EntryNode.tree(from: entries, indexingEdits: indexingEdits)
    }

    @MainActor private func node(_ path: String, document: ArchiveDocument) async throws -> EntryNode {
        if let tree = document.pendingEditor?.prepared?.tree { return try XCTUnwrap(tree.nodes(at: path).first) }
        let tree = await Self.tree(try await document.projectedEntries())
        return try XCTUnwrap(tree.nodes(at: path).first)
    }

    @MainActor private func measure<Value>(_ label: String, limit: Double? = nil, monitor: Bool = false,
                                           stallLimit: Double? = nil, _ action: @MainActor () async throws -> Value) async rethrows -> Value {
        let stall = monitor ? MainActorProbe() : nil
        let start = ContinuousClock.now
        let result: Value
        do { result = try await action() }
        catch { _ = await stall?.finish(); throw error }
        let elapsed = Self.milliseconds(start.duration(to: .now))
        let worst = await stall?.finish()
        print(String(format: "PROBE %@: %.3f ms", label, elapsed))
        if let worst { print(String(format: "PROBE %@ MainActor stall: %.3f ms", label, worst)) }
        if let limit { XCTAssertLessThanOrEqual(elapsed, limit, label) }
        if let stallLimit, let worst { XCTAssertLessThanOrEqual(worst, stallLimit, label + " MainActor stall") }
        return result
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private final class MainActorProbe: Sendable {
        private struct State {
            var stopped = false
            var done = false
            var worst = 0.0
            var samples = 0
            var completion: CheckedContinuation<Double, Never>?
        }
        private let state = Mutex(State())

        var hasSample: Bool { state.withLock { $0.samples > 0 } }
        func stop() { state.withLock { $0.stopped = true } }

        init(interval: TimeInterval = 0.001) {
            Thread.detachNewThread { [self] in
                while !state.withLock({ $0.stopped }) {
                    let start = ContinuousClock.now
                    DispatchQueue.main.sync {}
                    let delay = PerformanceProbeTests.milliseconds(start.duration(to: .now))
                    state.withLock { $0.worst = max($0.worst, delay); $0.samples += 1 }
                    Thread.sleep(forTimeInterval: interval)
                }
                let result = state.withLock { value in
                    value.done = true
                    let completion = value.completion
                    value.completion = nil
                    return (completion, value.worst)
                }
                result.0?.resume(returning: result.1)
            }
        }

        @concurrent func finish() async -> Double {
            await withCheckedContinuation { completion in
                let done = state.withLock { value -> Double? in
                    value.stopped = true
                    if value.done { return value.worst }
                    value.completion = completion
                    return nil
                }
                if let done { completion.resume(returning: done) }
            }
        }
    }
}
