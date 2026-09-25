import AppKit
import GyoshukuKit
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class PerformanceProbeTests: XCTestCase {
    override class func tearDown() {
        #if DEBUG
        ArchiveProbeFixtures.removeAll()
        #endif
        super.tearDown()
    }

    @MainActor func testArchiveOpeningWhenEnabled() async throws {
        #if DEBUG
        let configuration = try ArchiveProbeConfiguration()
        ArchiveProbeTrace.header()
        preserveArchiveWindowFrame()
        for format in configuration.formats {
            let fixture = try await ArchiveProbeFixtures.fixture(.entries, format: format, configuration: configuration)
            try await probeOpening(fixture)
        }
        #else
        throw XCTSkip("Stage probes require DEBUG")
        #endif
    }

    @MainActor func testArchiveEditsWhenEnabled() async throws {
        #if DEBUG
        let configuration = try ArchiveProbeConfiguration()
        ArchiveProbeTrace.header()
        preserveArchiveWindowFrame()
        for format in configuration.formats {
            for kind in ArchiveProbeFixture.Kind.allCases {
                let fixture = try await ArchiveProbeFixtures.fixture(kind, format: format, configuration: configuration)
                for operation in ImmediateOperation.allCases {
                    try await probeImmediate(operation, fixture: fixture)
                }
                try await probeDeferred(fixture, renameOnly: false, asserts: configuration.asserts)
                try await probeDeferred(fixture, renameOnly: true, asserts: configuration.asserts)
            }
        }
        #else
        throw XCTSkip("Stage probes require DEBUG")
        #endif
    }

    @MainActor func testArchiveEditorsDirectlyWhenEnabled() async throws {
        #if DEBUG
        let configuration = try ArchiveProbeConfiguration()
        ArchiveProbeTrace.header()
        for format in configuration.formats {
            for kind in ArchiveProbeFixture.Kind.allCases {
                let fixture = try await ArchiveProbeFixtures.fixture(kind, format: format, configuration: configuration)
                for nearStart in [true, false] {
                    try await Self.probeDirect(fixture, nearStart: nearStart)
                }
            }
        }
        #else
        throw XCTSkip("Stage probes require DEBUG")
        #endif
    }

    @MainActor func testArchivePasswordEditsWhenEnabled() async throws {
        #if DEBUG
        let configuration = try ArchiveProbeConfiguration()
        let methods = try ProbeArchiveEncryption.configured()
        ArchiveProbeTrace.header()
        preserveArchiveWindowFrame()
        for kind in ArchiveProbeFixture.Kind.allCases {
            let plain = try await ArchiveProbeFixtures.fixture(kind, format: .zip, configuration: configuration)
            for method in methods {
                try await probeImmediatePassword(.set, fixture: plain, output: method)
                let encrypted = try await ArchiveProbeFixtures.fixture(kind, format: .zip,
                    configuration: configuration, encryption: method)
                for output in methods {
                    try await probeImmediatePassword(.change, fixture: encrypted, output: output)
                    try await probeDeferredPassword(encrypted, output: output)
                }
                try await probeImmediatePassword(.remove, fixture: encrypted, output: nil)
            }
        }
        #else
        throw XCTSkip("Stage probes require DEBUG")
        #endif
    }

    #if DEBUG
    private enum ImmediateOperation: String, CaseIterable {
        case deleteStart = "delete_start", deleteEnd = "delete_end", renameSame = "rename_same_length"
        case renameDifferent = "rename_different_length", renameFolder = "rename_folder", newFolder = "new_folder"
        case addFile = "add_file", replaceFile = "replace_file"
    }

    @MainActor private func probeOpening(_ fixture: ArchiveProbeFixture) async throws {
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
        let trace = ArchiveProbeTrace(fixture: fixture, mode: "immediate", operation: "open")
        var openedDocument: ArchiveDocument?
        defer { openedDocument?.close() }
        try await Self.traced(trace, output: fixture.url) {
            let start = ContinuousClock.now
            let opened: (ArchiveDocument, ContinuousClock.Instant) = try await withCheckedThrowingContinuation { continuation in
                documents.openDocument(withContentsOf: fixture.url, display: true) { opened, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let document = opened as? ArchiveDocument { continuation.resume(returning: (document, .now)) }
                    else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                }
            }
            let (document, ready) = opened
            openedDocument = document
            let controller = try XCTUnwrap(document.windowControllers.first as? ArchiveWindowController)
            try await waitForRenameIndex(controller)
            XCTAssertGreaterThan(controller.outlineView.numberOfRows, 0)
            let displayed = try XCTUnwrap(controller.treeDisplayedAt), indexed = try XCTUnwrap(controller.renameIndexReadyAt)
            for (label, instant) in [("document_ready", ready), ("rows_visible", displayed), ("rename_index_ready", indexed)] {
                print(String(format: "PROBE %@ open %@: %.3f ms", fixture.format.rawValue, label,
                             Self.milliseconds(start.duration(to: instant))))
            }
        }
        let worst = await watcher.finish()
        print(String(format: "PROBE %@ open worst main.sync latency (2 ms pings): %.3f ms", fixture.format.rawValue, worst))
        await openedDocument?.prepareForTermination()
    }

    @MainActor private func withDocument(_ fixture: ArchiveProbeFixture, mode: ArchivePreferences.SaveBehavior,
        _ body: @MainActor (ArchiveDocument, ArchiveWindowController, URL, URL) async throws -> Void) async throws {
        let directory = try ArchiveTestDirectory()
        let archive = directory.url.appendingPathComponent("edit." + fixture.format.rawValue)
        try FileManager.default.copyItem(at: fixture.url, to: archive)
        let defaults = try ArchivePreferencesTestDefaults()
        let store = ArchivePreferencesStore(defaults: defaults.defaults)
        store.preferences = ArchivePreferences()
        store.preferences.saveBehavior = mode
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store)
        defer { document.close(); withExtendedLifetime((directory, defaults)) {} }
        do {
            try document.read(from: archive, ofType: "public.data")
            document.fileURL = archive
            document.fileType = "public.data"
            document.fileModificationDate = try FileManager.default.attributesOfItem(atPath: archive.path)[.modificationDate] as? Date
            if let password = fixture.password {
                let documents = NSDocumentController.shared as? ArchiveDocumentController
                let recordsRecents = documents?.recordsRecentDocuments
                documents?.recordsRecentDocuments = false
                defer { if let recordsRecents { documents?.recordsRecentDocuments = recordsRecents } }
                // 既知の鍵で開き直し、全件の認証は計測する編集入口に残す。
                try await document.switchBackingFile(to: archive, password: password)
            }
            let entries = try await document.projectedEntries()
            let root = await EntryNode.build(from: entries, format: fixture.format.writerFormat, indexingEdits: mode == .immediate)
            let controller = ArchiveWindowController(preferencesStore: store)
            document.addWindowController(controller)
            let session = try XCTUnwrap(document.session)
            XCTAssertTrue(session.capabilities.canEdit, fixture.format.rawValue)
            controller.display(root, session: session, generation: session.generation)
            try await body(document, controller, archive, directory.url)
            await document.prepareForTermination()
        } catch {
            await document.prepareForTermination()
            throw error
        }
    }

    @MainActor private func probeImmediatePassword(_ action: ArchivePasswordAction, fixture: ArchiveProbeFixture,
                                                   output: ProbeArchiveEncryption?) async throws {
        try await withDocument(fixture, mode: .immediate) { document, controller, archive, _ in
            let session = try XCTUnwrap(document.session)
            XCTAssertNil(session.entryVerification)
            let verb: String
            switch action {
            case .set: verb = "set"
            case .change: verb = "change"
            case .remove: verb = "remove"
            }
            let operation = "password_\(verb)_\(fixture.encryption?.rawValue ?? "plain")_to_\(output?.rawValue ?? "plain")"
            let trace = ArchiveProbeTrace(fixture: fixture, mode: "immediate", operation: operation,
                                          reportsPasswordVerification: true)
            try await Self.traced(trace, output: archive) {
                let result = try await document.updatePassword(action, settings: Self.passwordSettings(output), progress: Progress())
                XCTAssertNil(result.reloadFailure)
            }
            trace.require([.total, .passwordVerification, .commit, .verificationOpen, .entryComparison,
                           .publish, .reload, .readerAdoption, .capabilityProbe, .treeBuild, .display])
            trace.forbid([.reloadOpen])
            if fixture.format == .zip { trace.require([.outputProbe]); trace.forbid([.workCopy]) }
            trace.requireEditorOpen()
            XCTAssertEqual(session.hasEncryptedEntries, output != nil)
            XCTAssertTrue(document.undoManager?.canUndo == true)
            try await waitForRenameIndex(controller)
            try await Self.checkPasswordOutput(archive, fixture: fixture, encryption: output)
        }
    }

    @MainActor private func probeDeferredPassword(_ fixture: ArchiveProbeFixture, output: ProbeArchiveEncryption) async throws {
        try await withDocument(fixture, mode: .onSave) { document, _, archive, _ in
            let session = try XCTUnwrap(document.session)
            XCTAssertNil(session.entryVerification)
            let selected = try await node(fixture.firstPath, document: document)
            let transition = "\(try XCTUnwrap(fixture.encryption).rawValue)_to_\(output.rawValue)"
            let password = ArchiveProbeTrace(fixture: fixture, mode: "deferred",
                operation: "reserve_password_change_" + transition, reportsPasswordVerification: true)
            try await Self.traced(password, output: archive) {
                let result = try await document.updatePassword(.change, settings: Self.passwordSettings(output), progress: Progress())
                XCTAssertNil(result.reloadFailure)
            }
            password.require([.total, .passwordVerification])
            let rename = ArchiveProbeTrace(fixture: fixture, mode: "deferred",
                operation: "reserve_password_rename_" + transition, reportsPasswordVerification: true)
            try await Self.traced(rename, output: archive) {
                let result = try await document.rename(selected, to: "renamed.txt", progress: Progress())
                XCTAssertNil(result.reloadFailure)
            }
            rename.require([.total, .passwordVerification])
            XCTAssertEqual(document.pendingChanges.renames.count, 1)
            XCTAssertEqual(document.pendingChanges.outputEncryption, Self.passwordSettings(output))
            let expected = try await document.projectedEntries().map(\.name).sorted()
            let save = ArchiveProbeTrace(fixture: fixture, mode: "deferred",
                operation: "save_password_change_" + transition + "_rename", reportsPasswordVerification: true)
            try await Self.traced(save, output: archive) {
                let sheet = ArchiveStageDiagnostics.begin(.saveSheet)
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        document.save(to: archive, ofType: "public.data", for: .saveOperation) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                    sheet?.end()
                } catch { sheet?.end(); throw error }
                await document.waitForDeferredPreparationForTesting()
            }
            save.require([.total, .passwordVerification, .replayPlan, .validateRepresentability, .replay, .commit,
                          .verificationOpen, .entryComparison, .publish, .reload, .readerAdoption, .capabilityProbe,
                          .editingInstall, .editingPrepare, .treeBuild, .display])
            save.require([.saveSheet, .planKeys, .representabilityProbe])
            save.forbid([.reloadOpen])
            if fixture.format == .zip { save.require([.outputProbe]); save.forbid([.workCopy, .updaterPreparation]) }
            save.requireEditorOpen()
            XCTAssertNil(document.deferredReloadFailure)
            XCTAssertTrue(document.pendingChanges.isEmpty)
            let actual = try await document.projectedEntries().map(\.name).sorted()
            XCTAssertEqual(actual, expected)
            try await Self.checkPasswordOutput(archive, fixture: fixture, encryption: output, renamed: true)
        }
    }

    private static func passwordSettings(_ encryption: ProbeArchiveEncryption?) -> ArchiveEncryptionSettings {
        .init(password: encryption == nil ? nil : "probe-updated-key", zipEncryption: encryption?.method ?? .aes256)
    }

    @concurrent private static func checkPasswordOutput(_ archive: URL, fixture: ArchiveProbeFixture,
                                                        encryption: ProbeArchiveEncryption?, renamed: Bool = false) async throws {
        let reader = try ArchiveReader.open(url: archive, options: .kaitoFinder(password: passwordSettings(encryption).password))
        XCTAssertEqual(reader.entries.count, fixture.entryCount)
        XCTAssertTrue(reader.entries.allSatisfy { $0.isEncrypted == (encryption != nil) })
        XCTAssertTrue(reader.entries.allSatisfy { $0.formatSpecific["encryption"] == (encryption?.entryMethod ?? "none") })
        let first = renamed ? ArchivePath.components(fixture.firstPath).dropLast().joined(separator: "/") + "/renamed.txt" : fixture.firstPath
        if renamed { XCTAssertFalse(reader.entries.contains { $0.name == fixture.firstPath }) }
        // 全件の属性と先頭・末尾の本文を計測外で照合する。
        for (path, payload) in [(first, fixture.kind == .payload), (fixture.lastPath, false)] {
            let entry = try XCTUnwrap(reader.entries.first { $0.name == path })
            var data = Data()
            try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { data.append(contentsOf: $0) }
            let expected = payload ? try ArchiveProbePayload.data(file: 0, size: fixture.payloadMiB * 1_048_576 / 64) : Data([42])
            XCTAssertEqual(data, expected)
        }
    }

    @MainActor private func probeImmediate(_ operation: ImmediateOperation, fixture: ArchiveProbeFixture) async throws {
        try await withDocument(fixture, mode: .immediate) { document, controller, archive, directory in
            let selectedPath = operation == .deleteEnd ? fixture.lastPath
                : (operation == .renameFolder ? fixture.folderPath : fixture.firstPath)
            let selected = try await node(selectedPath, document: document)
            let parent = ArchivePath.components(fixture.firstPath).dropLast().joined(separator: "/")
            let leaf = ArchivePath.components(fixture.firstPath).last!
            let sameLength = "r" + leaf.dropFirst()
            let source = directory.appendingPathComponent(operation == .replaceFile ? leaf : "added.txt")
            try Data([43]).write(to: source)
            let conflicts = Mutex(0)
            let trace = ArchiveProbeTrace(fixture: fixture, mode: "immediate", operation: operation.rawValue)
            try await Self.traced(trace, output: archive) {
                switch operation {
                case .deleteStart, .deleteEnd:
                    let result = try await document.remove([selected], progress: Progress())
                    XCTAssertTrue(result.published); XCTAssertNil(result.reloadFailure)
                case .renameSame, .renameDifferent, .renameFolder:
                    let name = operation == .renameSame ? String(sameLength)
                        : (operation == .renameFolder ? "renamed-folder" : "renamed-with-a-longer-name.txt")
                    let result = try await document.rename(selected, to: name, progress: Progress())
                    XCTAssertTrue(result.published); XCTAssertNil(result.reloadFailure)
                case .newFolder:
                    let result = try await document.createFolder(in: "", baseName: "probe-new", progress: Progress())
                    XCTAssertEqual(result.addedPaths, ["probe-new/"]); XCTAssertNil(result.reloadFailure)
                case .addFile, .replaceFile:
                    let result = try await document.append(urls: [source], to: operation == .replaceFile ? parent : "",
                        progress: Progress(), resolveConflict: { _ in
                            conflicts.withLock { $0 += 1 }
                            return .init(choice: .replace)
                        })
                    XCTAssertTrue(result.failures.isEmpty); XCTAssertNil(result.reloadFailure)
                    XCTAssertEqual(result.addedPaths, [operation == .replaceFile ? fixture.firstPath : "added.txt"])
                }
            }
            trace.require([.total, .mutate, .commit, .verificationOpen, .entryComparison, .publish,
                           .reload, .readerAdoption, .capabilityProbe, .treeBuild, .display,
                           fixture.format == .zip ? .updaterOpen : .rewriterOpen])
            trace.forbid([.reloadOpen])
            if fixture.format == .zip { trace.require([.outputProbe]); trace.forbid([.workCopy]) }
            XCTAssertEqual(conflicts.withLock { $0 }, operation == .replaceFile ? 1 : 0)
            let entries = try await document.projectedEntries()
            let delta = operation == .deleteStart || operation == .deleteEnd ? -1
                : (operation == .newFolder || operation == .addFile ? 1 : 0)
            XCTAssertEqual(entries.count, fixture.entryCount + delta)
            if operation == .replaceFile {
                XCTAssertEqual(entries.filter { $0.name == fixture.firstPath }.map(\.uncompressedSize), [1])
            }
            // 表示後の索引作成を次の操作へ持ち越さない。
            try await waitForRenameIndex(controller)
        }
    }

    @MainActor private func probeDeferred(_ fixture: ArchiveProbeFixture, renameOnly: Bool, asserts: Bool) async throws {
        try await withDocument(fixture, mode: .onSave) { document, _, archive, directory in
            let limit = asserts ? (fixture.entryCount <= 100_000 ? 250.0 : 1_500.0) : nil
            let stallLimit = asserts ? (fixture.entryCount <= 100_000 ? 50.0 : 100.0) : nil
            @MainActor func reserve<Value>(_ name: String, _ action: @MainActor () async throws -> Value) async throws -> Value {
                let trace = ArchiveProbeTrace(fixture: fixture, mode: "deferred",
                    operation: (renameOnly ? "rename_only_" : "five_changes_") + name)
                return try await Self.traced(trace, output: archive) {
                    try await Self.measure("deferred " + name, limit: limit, monitor: true, stallLimit: stallLimit, action)
                }
            }
            let file = try await node(renameOnly ? fixture.firstPath : ArchiveProbeFixture.smallPath(0), document: document)
            let entries = try await document.projectedEntries()
            let validation = ArchiveRenameValidation(selection: ArchiveEditSelection(file), entries: entries,
                state: document.pendingEditor?.prepared, occupancy: document.pendingEditor?.prepared?.tree.editOccupancy)
            for call in 1...3 {
                try await Self.measure("deferred rename-commit validation \(call)", limit: asserts && fixture.entryCount <= 100_000 ? 30 : nil) {
                    _ = try validation.plan(for: "renamed.txt")
                }
            }
            XCTAssertEqual(validation.validationCount, 1)
            _ = try await reserve("reserve_rename") { try await document.rename(file, to: "renamed.txt", progress: Progress()) }
            if !renameOnly {
                let deleted = try await node(ArchiveProbeFixture.smallPath(1), document: document)
                _ = try await reserve("reserve_delete") { try await document.remove([deleted], progress: Progress()) }
                _ = try await reserve("reserve_new_folder") { try await document.createFolder(in: "", baseName: "new", progress: Progress()) }
                let folder = try await node(fixture.smallCount >= 2_000 ? "d001" : "d000", document: document)
                _ = try await reserve("reserve_delete_folder") { try await document.remove([folder], progress: Progress()) }
                let source = directory.appendingPathComponent("added.txt")
                try Data([42]).write(to: source)
                _ = try await reserve("reserve_add") {
                    try await document.append(urls: [source], to: "", progress: Progress(), resolveConflict: { _ in
                        XCTFail("Unexpected conflict"); return .init(choice: .skip)
                    })
                }
            }
            let expected = try await document.projectedEntries().map(\.name).sorted()
            let trace = ArchiveProbeTrace(fixture: fixture, mode: "deferred", operation: renameOnly ? "save_rename_only" : "save_five_changes")
            try await Self.traced(trace, output: archive) {
                let sheet = ArchiveStageDiagnostics.begin(.saveSheet)
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        document.save(to: archive, ofType: "public.data", for: .saveOperation) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                    sheet?.end()
                } catch { sheet?.end(); throw error }
                await document.waitForDeferredPreparationForTesting()
            }
            trace.require([.total, .replayPlan, .validateRepresentability, .replay, .commit, .verificationOpen,
                           .entryComparison, .publish, .reload, .readerAdoption, .capabilityProbe,
                           .editingInstall, .editingPrepare, .treeBuild, .display,
                           fixture.format == .zip ? .updaterOpen : .rewriterOpen])
            trace.require([.saveSheet, .planKeys, .representabilityProbe])
            trace.forbid([.reloadOpen])
            if fixture.format == .zip { trace.require([.outputProbe]); trace.forbid([.workCopy, .updaterPreparation]) }
            XCTAssertNil(document.deferredReloadFailure)
            let saved = try await document.projectedEntries().map(\.name).sorted()
            XCTAssertEqual(saved, expected)
            XCTAssertTrue(document.pendingEditor?.changes.isEmpty == true)
        }
    }

    @concurrent private static func probeDirect(_ fixture: ArchiveProbeFixture, nearStart: Bool) async throws {
        let directory = try ArchiveTestDirectory()
        let input = directory.url.appendingPathComponent("input." + fixture.format.rawValue)
        let output = fixture.format == .zip ? input : directory.url.appendingPathComponent("output." + fixture.format.rawValue)
        try FileManager.default.copyItem(at: fixture.url, to: input)
        let trace = ArchiveProbeTrace(fixture: fixture, mode: "direct", operation: nearStart ? "delete_start" : "delete_end")
        let index = nearStart ? 0 : fixture.entryCount - 1
        do {
            try ArchiveStageDiagnostics.observer.withValue({ trace.record($0) }) {
                try ArchiveStageDiagnostics.measure(.total) {
                    let options = ArchivePreferences().writerOptions(for: fixture.format.writerFormat)
                    let editor: any ArchiveEditing
                    if fixture.format == .zip {
                        editor = try ArchiveStageDiagnostics.measure(.updaterOpen) { try ArchiveUpdater.open(url: input, options: options) }
                    } else {
                        editor = try ArchiveStageDiagnostics.measure(.rewriterOpen) {
                            try ArchiveRewriter.open(url: input, output: output, format: fixture.format.writerFormat, options: options)
                        }
                    }
                    try ArchiveStageDiagnostics.measure(.remove) { try editor.remove(entriesAt: [index]) }
                    try ArchiveStageDiagnostics.measure(.commit) { try editor.commit() }
                }
            }
            trace.finish(output: output)
        } catch { trace.finish(output: output, status: "error"); throw error }
        trace.require([.total, .remove, .commit, fixture.format == .zip ? .updaterOpen : .rewriterOpen])
        let entries = try ArchiveReader.open(url: output).entries
        XCTAssertEqual(entries.count, fixture.entryCount - 1)
        XCTAssertFalse(entries.contains { $0.name == (nearStart ? fixture.firstPath : fixture.lastPath) })
        withExtendedLifetime(directory) {}
    }

    @MainActor private static func traced<Value>(_ trace: ArchiveProbeTrace, output: URL,
        _ action: @MainActor () async throws -> Value) async throws -> Value {
        do {
            let value = try await ArchiveStageDiagnostics.observer.withValue({ trace.record($0) }) {
                let span = ArchiveStageDiagnostics.begin(.total)
                defer { span?.end() }
                return try await action()
            }
            trace.finish(output: output)
            return value
        } catch { trace.finish(output: output, status: "error"); throw error }
    }

    @MainActor private func waitForRenameIndex(_ controller: ArchiveWindowController) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while !controller.renameIndexIsReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(controller.renameIndexIsReady)
    }

    @MainActor private func node(_ path: String, document: ArchiveDocument) async throws -> EntryNode {
        if let tree = document.pendingEditor?.prepared?.tree { return try XCTUnwrap(tree.nodes(at: path).first) }
        let tree = await EntryNode.build(from: try await document.projectedEntries(), indexingEdits: false)
        return try XCTUnwrap(tree.nodes(at: path).first)
    }
    #endif

    @MainActor private static func measure<Value>(_ label: String, limit: Double? = nil, monitor: Bool = false,
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
