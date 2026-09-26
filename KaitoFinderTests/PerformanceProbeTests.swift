import AppKit
@_spi(Testing) import GyoshukuKit
@_spi(TarEditLayout) import KaitoKit
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

    @MainActor func testSearchFilterWhenEnabled() async throws {
        #if DEBUG
        let configuration = try ArchiveProbeConfiguration()
        preserveArchiveWindowFrame()
        ArchiveProbeTrace.line("PROBE-SEARCH-HEADER\tentries\tnames\ttransition\tstage\tms")
        for japanese in [false, true] {
            let entries = (0..<configuration.entries).map { index in
                archiveColumnEntry(japanese ? "資料\(index / 100)/文書\(index).txt" : "d\(index / 100)/file\(index).txt",
                                   index: index, size: 1)
            }
            let defaults = try ArchivePreferencesTestDefaults()
            let controller = ArchiveWindowController(preferencesStore: ArchivePreferencesStore(defaults: defaults.defaults))
            defer { controller.close() }
            let root = EntryNode.tree(from: entries)
            controller.showWindow(nil)
            controller.display(root)
            let broad = japanese ? "文書" : "file", narrow = broad + String(configuration.entries - 1)
            let names = japanese ? "ja" : "ascii"
            let queries = [broad, narrow, "", narrow, "zzz", "", broad, ""] + (japanese ? [] : ["資料9", ""])
            await ArchiveWindowController.filterExecution.withValue(.automatic) {
                for (index, query) in queries.enumerated() {
                    let previous = controller.filterQuery
                    let transition = "\(index + 1):\(previous.isEmpty ? "empty" : previous)->\(query.isEmpty ? "empty" : query)"
                    let rows = controller.outlineView.numberOfRows
                    let stages = Mutex<[ArchiveStageDiagnostics.Stage: Duration]>([:])
                    var requestTime = Duration.zero
                    let start = ContinuousClock.now
                    await ArchiveStageDiagnostics.observer.withValue({ event in
                        if case .ended(_, let stage, let duration) = event {
                            stages.withLock { $0[stage, default: .zero] += duration }
                        }
                    }) {
                        let requestStart = ContinuousClock.now
                        controller.setFilterQuery(query)
                        requestTime = requestStart.duration(to: .now)
                        await controller.filterTaskForTesting?.value
                    }
                    let elapsed = start.duration(to: .now), measured = stages.withLock { $0 }
                    let compute = measured[.filterCompute, default: .zero]
                    let swap = measured[.filterSwap] ?? (requestTime - compute)
                    let synchronousStart = ContinuousClock.now
                    var synchronous: EntryTreeFilter? = EntryTreeFilter(root: root, query: query)
                    let synchronousTime = synchronousStart.duration(to: .now)
                    ArchiveBackgroundRelease.release(&synchronous)
                    for (stage, duration) in [("filter_request", requestTime), ("filter_compute", compute), ("filter_swap", swap),
                                              ("elapsed", elapsed), ("synchronous_compute", synchronousTime)] {
                        Self.searchProbeLine(configuration.entries, names: names, transition: transition, stage: stage, duration: duration)
                    }
                    ArchiveProbeTrace.line("PROBE-SEARCH-ROWS\t\(configuration.entries)\t\(names)\t\(transition)\t\(rows)\t\(controller.outlineView.numberOfRows)")
                    XCTAssertEqual(controller.filterQuery, query)
                }
                for query in [narrow, broad] {
                    controller.setFilterQuery(query)
                    await controller.filterTaskForTesting?.value
                    let tree = EntryNode.tree(from: entries), transition = "display:\(query)"
                    let stages = Mutex<[Duration]>([]), mainFilters = ArchiveTestCounter()
                    var prepared: EntryTreeFilter?
                    await ArchiveStageDiagnostics.observer.withValue({ event in
                        if case .ended(_, .filterCompute, let duration) = event { stages.withLock { $0.append(duration) } }
                    }) {
                        prepared = await EntryTreeFilter.build(root: tree, configuration: controller.filterConfiguration)
                    }
                    Self.searchProbeLine(configuration.entries, names: names, transition: transition, stage: "filter_compute",
                                         duration: stages.withLock { $0.reduce(.zero, +) })
                    let rows = controller.outlineView.numberOfRows
                    let start = ContinuousClock.now
                    ArchiveTestCounters.mainThreadFilters.withValue(mainFilters) { controller.display(tree, preparedFilter: prepared) }
                    Self.searchProbeLine(configuration.entries, names: names, transition: transition, stage: "display", duration: start.duration(to: .now))
                    ArchiveProbeTrace.line("PROBE-SEARCH\t\(configuration.entries)\t\(names)\t\(transition)\tmain_thread_filters\t\(mainFilters.value)")
                    ArchiveProbeTrace.line("PROBE-SEARCH-ROWS\t\(configuration.entries)\t\(names)\t\(transition)\t\(rows)\t\(controller.outlineView.numberOfRows)")
                    let synchronousStart = ContinuousClock.now
                    var synchronous: EntryTreeFilter? = EntryTreeFilter(root: tree, query: query)
                    Self.searchProbeLine(configuration.entries, names: names, transition: transition, stage: "synchronous_compute", duration: synchronousStart.duration(to: .now))
                    ArchiveBackgroundRelease.release(&synchronous)
                    ArchiveBackgroundRelease.release(&prepared)
                    XCTAssertEqual(mainFilters.value, 0)
                    XCTAssertEqual(controller.preparedFilterMissesForTesting, 0)
                }
            }
            withExtendedLifetime(root) {}
        }
        #else
        throw XCTSkip("Stage probes require DEBUG")
        #endif
    }

    #if DEBUG
    private static func searchProbeLine(_ entries: Int, names: String, transition: String, stage: String, duration: Duration) {
        let milliseconds = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        let value = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), milliseconds)
        ArchiveProbeTrace.line("PROBE-SEARCH\t\(entries)\t\(names)\t\(transition)\t\(stage)\t\(value)")
    }
    #endif

    @MainActor func testArchiveOpeningWhenEnabled() async throws {
        #if DEBUG
        let configuration = try ArchiveProbeConfiguration()
        ArchiveProbeTrace.header()
        preserveArchiveWindowFrame()
        for format in configuration.formats {
            for kind in ArchiveProbeFixture.Kind.allCases {
                let fixture = try await ArchiveProbeFixtures.fixture(kind, format: format, configuration: configuration)
                try await probeOpening(fixture)
            }
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

    @MainActor func testSplitSavesWhenEnabled() async throws {
        #if DEBUG
        let configuration = try ArchiveProbeConfiguration()
        ArchiveProbeTrace.header()
        for format in configuration.formats where [.zip, .tarGzip].contains(format) {
            let fixture = try await ArchiveProbeFixtures.splitFixture(format: format, configuration: configuration)
            guard fixture.volumes.count > 1 else { throw XCTSkip("Use a larger payload or smaller split volume for split probes") }
            for operation in SplitOperation.allCases {
                try await probeSplit(operation, fixture: fixture, configuration: configuration)
            }
        }
        #else
        throw XCTSkip("Stage probes require DEBUG")
        #endif
    }

    @MainActor func testTenConsecutiveCompressedTarEditsWhenEnabled() async throws {
        #if DEBUG
        let configuration = try ArchiveProbeConfiguration()
        ArchiveProbeTrace.header()
        for format in configuration.formats where [.tarGzip, .tarBzip2, .tarXZ].contains(format) {
            for kind in ArchiveProbeFixture.Kind.allCases {
                let fixture = try await ArchiveProbeFixtures.fixture(kind, format: format, configuration: configuration)
                try await withDocument(fixture, mode: .immediate) { document, controller, archive, _ in
                    for index in 1...10 {
                        let trace = ArchiveProbeTrace(fixture: fixture, mode: "consecutive", operation: "new_folder_\(index)")
                        try await Self.traced(trace, output: archive) {
                            try await ArchiveSession.willAdoptReaderForTesting.withValue({ output in
                                if let snapshot = output.reader?.tarEditingSnapshot() {
                                    // K5 exposes the resulting ByteSource, including materialized images after its leaf/fragment limit.
                                    let storage = String(reflecting: type(of: snapshot.image))
                                    ArchiveProbeTrace.line("PROBE-SPLICE-IMAGE\t\(format.rawValue)\t\(kind.rawValue)\t\(index)\t\(storage)\t\(snapshot.image.length)")
                                }
                            }) {
                                let result = try await document.createFolder(in: "", baseName: "consecutive-\(index)", progress: Progress())
                                XCTAssertNil(result.reloadFailure)
                            }
                        }
                        trace.requireRoute(placement: configuration.additionPosition)
                        trace.require([.readerAdoption]); trace.forbid([.reloadOpen])
                        try await waitForRenameIndex(controller)
                    }
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
            for method in methods {
                let plain = try await ArchiveProbeFixtures.fixture(kind, format: method.format, configuration: configuration)
                try await probeImmediatePassword(.set, fixture: plain, output: method)
                let encrypted = try await ArchiveProbeFixtures.fixture(kind, format: method.format,
                    configuration: configuration, encryption: method)
                for output in methods where output.format == method.format {
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

    private enum SplitOperation: String, CaseIterable {
        case addFile = "add_file", deleteEnd = "delete_end", saveRename = "save_rename"
    }

    @MainActor private func withSplitDocument(_ fixture: ArchiveProbeSplitFixture, mode: ArchivePreferences.SaveBehavior,
        configuration: ArchiveProbeConfiguration,
        _ body: @MainActor (ArchiveDocument, URL, URL) async throws -> Void) async throws {
        let directory = try ArchiveTestDirectory(), local = try volumePublishTestURL(directory.url)
        let root = local.appendingPathComponent("set", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for volume in fixture.volumes {
            try FileManager.default.copyItem(at: volume, to: root.appendingPathComponent(volume.lastPathComponent))
        }
        let gate = root.appendingPathComponent(try XCTUnwrap(fixture.volumes.first).lastPathComponent)
        let defaults = try ArchivePreferencesTestDefaults(), store = ArchivePreferencesStore(defaults: defaults.defaults)
        store.preferences = ArchivePreferences()
        store.preferences.saveBehavior = mode
        store.preferences.additionPosition = configuration.additionPosition
        let index = RecoverableWorkIndex(fileURL: local.appendingPathComponent("support/index.json"))
        let metadata = ArchiveVolumeMetadataStore(fileURL: local.appendingPathComponent("support/metadata.json"))
        let document = ArchiveDocument(undoStack: ArchiveUndoStack(), preferencesStore: store,
            volumeMetadataStore: metadata, volumeRecoveryIndex: index)
        defer { document.close(); withExtendedLifetime((directory, defaults)) {} }
        do {
            try document.read(from: gate, ofType: ArchiveDocumentController.splitVolumeType)
            document.fileURL = gate; document.fileType = ArchiveDocumentController.splitVolumeType
            document.fileModificationDate = try FileManager.default.attributesOfItem(atPath: gate.path)[.modificationDate] as? Date
            document.splitMutationConfirmation = { _ in .alertFirstButtonReturn }
            document.splitSaveHooks.operations.coordinate = { _, _, queue, acquired in queue.addOperation { acquired(nil) } }
            document.splitSaveHooks.operations.trash = { url in
                let destination = local.appendingPathComponent("trash-" + UUID().uuidString)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            }
            XCTAssertEqual(document.session?.volumeLayout?.volumes.count, fixture.volumes.count)
            try await body(document, gate, local)
            XCTAssertTrue(try index.entries().isEmpty)
            await document.prepareForTermination()
        } catch {
            await document.prepareForTermination()
            throw error
        }
    }

    @MainActor private func probeSplit(_ operation: SplitOperation, fixture: ArchiveProbeSplitFixture,
                                      configuration: ArchiveProbeConfiguration) async throws {
        let deferred = operation == .saveRename, payload = fixture.payload
        try await withSplitDocument(fixture, mode: deferred ? .onSave : .immediate, configuration: configuration) { document, gate, local in
            let selected = try await node(deferred ? payload.firstPath : payload.lastPath, document: document)
            let source = local.appendingPathComponent("added.txt")
            try Data([43]).write(to: source)
            let originalNames = try await document.projectedEntries().map(\.name)
            let renamed = ArchivePath.components(payload.firstPath).dropLast().joined(separator: "/") + "/renamed.txt"
            if deferred {
                _ = try await document.rename(selected, to: "renamed.txt", progress: Progress())
                XCTAssertTrue(document.isDocumentEdited)
            }
            let trace = ArchiveProbeTrace(fixture: payload, mode: deferred ? "deferred_split" : "immediate_split", operation: operation.rawValue)
            do {
                try await ArchiveStageDiagnostics.observer.withValue({ trace.record($0) }) {
                    let total = ArchiveStageDiagnostics.begin(.total)
                    defer { total?.end() }
                    switch operation {
                    case .addFile:
                        let result = try await document.append(urls: [source], to: "", progress: Progress())
                        XCTAssertTrue(result.failures.isEmpty); XCTAssertNil(result.reloadFailure)
                        XCTAssertEqual(result.addedPaths, ["added.txt"])
                    case .deleteEnd:
                        let result = try await document.remove([selected], progress: Progress())
                        XCTAssertTrue(result.published); XCTAssertNil(result.reloadFailure)
                    case .saveRename:
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                            document.save(to: gate, ofType: ArchiveDocumentController.splitVolumeType, for: .saveOperation) { error in
                                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                            }
                        }
                        await document.waitForDeferredPreparationForTesting()
                    }
                }
                trace.finish(outputs: document.session?.volumeLayout?.volumes.map(\.url) ?? [])
            } catch {
                trace.finish(outputs: document.session?.volumeLayout?.volumes.map(\.url) ?? [], status: "error")
                throw error
            }
            trace.require([.total, .splitMetadataDigest, .splitCopy,
                           .splitStagedProof, .splitStagedReader, .splitStagedRecheck,
                           .splitPlacedProof, .splitPlacedReader, .splitPlacedRecheck])
            trace.forbid([.splitWorkValidation])
            if payload.format == .zip { trace.require([.splitInputCopy]) }
            else { trace.forbid([.splitInputCopy]) }
            if deferred { trace.forbid([.splitDisposeProof]); trace.requireSaveValidation() }
            else { trace.require([.splitDisposeProof]) }
            XCTAssertNil(document.splitSaveFailure); XCTAssertNil(document.deferredReloadFailure)
            XCTAssertNotNil(document.splitSaveResult)
            XCTAssertTrue(document.pendingChanges.isEmpty); XCTAssertFalse(document.isDocumentEdited)
            let expected: [String]
            switch operation {
            case .addFile: expected = originalNames + ["added.txt"]
            case .deleteEnd: expected = originalNames.filter { $0 != payload.lastPath }
            case .saveRename: expected = originalNames.map { $0 == payload.firstPath ? renamed : $0 }
            }
            let reader = try ArchiveReader.open(url: gate, options: .kaitoFinder())
            XCTAssertEqual(reader.entries.map(\.name).sorted(), expected.sorted())
            if operation != .deleteEnd {
                let entry = try XCTUnwrap(reader.entries.first { $0.name == (deferred ? renamed : "added.txt") })
                var bytes = Data()
                try ExtractionService.consume(reader.stream(entry), checkCancellation: {}) { bytes.append(contentsOf: $0) }
                XCTAssertEqual(bytes, deferred ? try ArchiveProbePayload.data(file: 0, size: payload.payloadMiB * 1_048_576 / 64) : Data([43]))
            }
        }
    }

    @MainActor private func probeOpening(_ fixture: ArchiveProbeFixture) async throws {
        let documents = try XCTUnwrap(NSDocumentController.shared as? ArchiveDocumentController)
        let recordsRecents = documents.recordsRecentDocuments, preferences = ArchivePreferencesStore.shared.preferences
        documents.recordsRecentDocuments = false
        ArchivePreferencesStore.shared.preferences.saveBehavior = .immediate
        ArchivePreferencesStore.shared.preferences.additionPosition = try ArchiveProbeConfiguration().additionPosition
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
        store.preferences.additionPosition = try ArchiveProbeConfiguration().additionPosition
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
                // 既知の鍵で header を解除するか開き直し、本文の全件認証は計測する編集入口に残す。
                if document.isPasswordLocked { try await document.unlock(password: password) }
                else { try await document.switchBackingFile(to: archive, password: password) }
            }
            let entries = try await document.projectedEntries()
            let root = await EntryNode.build(from: entries, format: fixture.format.writerFormat, indexingEdits: mode == .immediate)
            let controller = ArchiveWindowController(preferencesStore: store)
            document.addWindowController(controller)
            let session = try XCTUnwrap(document.session)
            XCTAssertTrue(session.capabilities.canEdit, fixture.format.rawValue)
            let warmIndex = ProcessInfo.processInfo.environment["KAITOFINDER_PROBE_WARM_INDEX"] == "1"
            controller.display(root, session: session, generation: session.generation, indexingRenames: warmIndex)
            if warmIndex { try await waitForRenameIndex(controller) }
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
                let result = try await document.updatePassword(action, settings: Self.passwordSettings(output, headers: fixture.kind == .payload), progress: Progress())
                XCTAssertNil(result.reloadFailure)
            }
            trace.require([.total, .passwordVerification, .commit, .verificationOpen, .entryComparison,
                           .publish, .reload, .readerAdoption, .capabilityProbe, .treeBuild, .display])
            trace.forbid([.reloadOpen])
            if fixture.format == .zip { trace.require([.outputProbe]); trace.forbid([.workCopy]) }
            trace.requireRoute(placement: try ArchiveProbeConfiguration().additionPosition)
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
                let result = try await document.updatePassword(.change, settings: Self.passwordSettings(output, headers: fixture.kind == .payload), progress: Progress())
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
            XCTAssertEqual(document.pendingChanges.outputEncryption, Self.passwordSettings(output, headers: fixture.kind == .payload))
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
            save.require([.total, .passwordVerification, .replayPlan, .representabilityDifferential, .replay, .commit,
                          .verificationOpen, .entryComparison, .publish, .reload, .readerAdoption, .capabilityProbe,
                          .editingInstall, .editingPrepare, .treeBuild, .display])
            save.require([.saveSheet])
            save.requireSaveValidation()
            save.forbid([.reloadOpen])
            if fixture.format == .zip { save.require([.outputProbe]); save.forbid([.workCopy, .updaterPreparation]) }
            save.requireRoute(placement: try ArchiveProbeConfiguration().additionPosition)
            XCTAssertNil(document.deferredReloadFailure)
            XCTAssertTrue(document.pendingChanges.isEmpty)
            let actual = try await document.projectedEntries().map(\.name).sorted()
            XCTAssertEqual(actual, expected)
            try await Self.checkPasswordOutput(archive, fixture: fixture, encryption: output, renamed: true)
        }
    }

    private static func passwordSettings(_ encryption: ProbeArchiveEncryption?, headers: Bool) -> ArchiveEncryptionSettings {
        encryption?.settings(password: "probe-updated-key", headers: headers) ?? .init()
    }

    @concurrent private static func checkPasswordOutput(_ archive: URL, fixture: ArchiveProbeFixture,
                                                        encryption: ProbeArchiveEncryption?, renamed: Bool = false) async throws {
        let reader = try ArchiveReader.open(url: archive, options: .kaitoFinder(password: passwordSettings(encryption, headers: fixture.kind == .payload).password))
        XCTAssertEqual(reader.entries.count, fixture.entryCount)
        XCTAssertTrue(reader.entries.allSatisfy { $0.isEncrypted == (encryption != nil) })
        if fixture.format == .zip {
            XCTAssertTrue(reader.entries.allSatisfy { $0.formatSpecific["encryption"] == (encryption?.zipEntryMethod ?? "none") })
        } else {
            XCTAssertTrue(reader.entries.allSatisfy { $0.formatSpecific["emptyStream"] == "false" })
            if encryption != nil, fixture.kind == .payload {
                XCTAssertThrowsError(try ArchiveReader.open(url: archive, options: .kaitoFinder()))
            } else {
                XCTAssertNoThrow(try ArchiveReader.open(url: archive, options: .kaitoFinder()))
            }
        }
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
            trace.require([.total, .planBuild, .mutate, .planValidation, .commit, .verificationOpen, .entryComparison, .publish,
                           .reload, .readerAdoption, .capabilityProbe, .treeBuild, .display,
                           fixture.format.editorStage(placement: try ArchiveProbeConfiguration().additionPosition)])
            trace.forbid([.reloadOpen])
            trace.requireRoute(placement: try ArchiveProbeConfiguration().additionPosition)
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
            trace.require([.total, .replayPlan, .representabilityDifferential, .replay, .commit, .verificationOpen,
                           .entryComparison, .publish, .reload, .readerAdoption, .capabilityProbe,
                           .editingInstall, .editingPrepare, .treeBuild, .display,
                           fixture.format.editorStage(placement: try ArchiveProbeConfiguration().additionPosition)])
            trace.require([.saveSheet])
            trace.requireSaveValidation()
            trace.forbid([.reloadOpen])
            trace.requireRoute(placement: try ArchiveProbeConfiguration().additionPosition)
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
                var preferences = ArchivePreferences()
                preferences.additionPosition = try ArchiveProbeConfiguration().additionPosition
                let options = preferences.writerOptions(for: fixture.format.writerFormat)
                // Session opening is measured separately. Keep the independent reader out of a nested measurement closure.
                let compressedReader = try [.tarGzip, .tarBzip2, .tarXZ].contains(fixture.format) && preferences.additionPosition == .end
                    ? ArchiveReader.open(url: input, options: .kaitoFinder()) : nil
                let total = ArchiveStageDiagnostics.begin(.total)
                defer { total?.end() }
                let editor: any ArchiveEditing
                if fixture.format == .zip {
                    editor = try ArchiveStageDiagnostics.measure(.updaterOpen) { try ArchiveUpdater.open(url: input, options: options) }
                } else if fixture.format.editorStage(placement: preferences.additionPosition) == .updaterOpen, fixture.format == .tar {
                    editor = try ArchiveStageDiagnostics.measure(.updaterOpen) {
                        try TarUpdater.open(url: input, output: output, options: options)
                    }
                } else if fixture.format == .lha, preferences.additionPosition == .end {
                    editor = try ArchiveStageDiagnostics.measure(.updaterOpen) {
                        try LHAUpdater.open(url: input, output: output, options: options)
                    }
                } else if fixture.format == .sevenZip, preferences.additionPosition == .end {
                    editor = try ArchiveStageDiagnostics.measure(.updaterOpen) {
                        try SevenZipUpdater.open(url: input, password: fixture.password, output: output, options: options)
                    }
                } else if let compressedReader {
                    let span = ArchiveStageDiagnostics.begin(.updaterOpen)
                    defer { span?.end() }
                    editor = try CompressedTarUpdater.open(reader: compressedReader, output: output,
                        format: fixture.format.writerFormat, options: options)
                } else {
                    editor = try ArchiveStageDiagnostics.measure(.rewriterOpen) {
                        try ArchiveRewriter.open(url: input, output: output, format: fixture.format.writerFormat, options: options)
                    }
                }
                try ArchiveStageDiagnostics.measure(.remove) { try editor.remove(entriesAt: [index]) }
                try ArchiveStageDiagnostics.measure(.commit) { try editor.commit() }
                if let updater = editor as? CompressedTarUpdater {
                    trace.recordSplice(try XCTUnwrap(updater.lastCommitStatistics))
                }
                if let updater = editor as? SevenZipUpdater {
                    trace.recordSevenZip(try XCTUnwrap(updater.lastCommitStatistics))
                }
            }
            trace.finish(output: output)
        } catch { trace.finish(output: output, status: "error"); throw error }
        trace.require([.total, .remove, .commit])
        trace.requireRoute(placement: try ArchiveProbeConfiguration().additionPosition)
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
                return try await ArchiveImportTransaction.didCommitCompressedTarUpdaterForTesting.withValue({ updater in
                    trace.recordSplice(try XCTUnwrap(updater.lastCommitStatistics))
                }) {
                    try await ArchiveImportTransaction.didCommitSevenZipUpdaterForTesting.withValue({ updater in
                        trace.recordSevenZip(try XCTUnwrap(updater.lastCommitStatistics))
                    }) { try await action() }
                }
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
