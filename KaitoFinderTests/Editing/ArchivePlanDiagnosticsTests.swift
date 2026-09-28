import Foundation
import KaitoKit
import Synchronization
import XCTest
@testable import KaitoFinder

nonisolated final class ArchivePlanDiagnosticsTests: XCTestCase {
    #if DEBUG
    @MainActor func testImmediatePlansAndChecksHaveBalancedSeparateSpans() async throws {
        for operation in ["append", "folder", "rename", "remove", "move"] {
            let fixture = try ScenarioFixture(script: """
            with zipfile.ZipFile(p, 'w') as z:
                z.writestr('a', b'a'); z.writestr('target/keep', b'keep')
            """)
            let session = try ArchiveSession(url: fixture.archive), trace = Trace()
            let entries = await session.entries()
            let entry = try XCTUnwrap(entries.first { $0.name == "a" })
            let selection = ArchiveEditSelection(path: entry.name, isDirectory: false, entries: [entry])
            let source = try fixture.file("added")
            try await ArchiveStageDiagnostics.observer.withValue({ trace.record($0) }) {
                switch operation {
                case "append": _ = try await session.append(urls: [source], to: "", progress: Progress())
                case "folder": _ = try await session.createFolder(in: "", baseName: "new", progress: Progress())
                case "rename": _ = try await session.rename(selection, to: "renamed", progress: Progress())
                case "remove": _ = try await session.remove([selection], progress: Progress())
                default: _ = try await session.move([selection], to: "target", progress: Progress(), resolveConflict: nil)
                }
            }
            trace.check(validations: 1)
            XCTAssertNil(ArchiveStageDiagnostics.observer.get())
            await session.close()
        }
    }

    @MainActor func testConflictWaitsAreExcludedIncludingThrowAndCancellation() async throws {
        enum Failure: Error { case resolver }
        for moving in [false, true] {
            for outcome in ["replace", "skip", "throw", "cancel"] {
                let fixture = try ScenarioFixture(script: """
                with zipfile.ZipFile(p, 'w') as z:
                    z.writestr('a', b'a'); z.writestr('b', b'b')
                    z.writestr('target/a', b'old-a'); z.writestr('target/b', b'old-b')
                """)
                let session = try ArchiveSession(url: fixture.archive), trace = Trace(), progress = Progress()
                let before = try Data(contentsOf: fixture.archive)
                let entries = await session.entries()
                let selections = entries.filter { $0.name == "a" || $0.name == "b" }.map {
                    ArchiveEditSelection(path: $0.name, isDirectory: false, entries: [$0])
                }
                let sources = try [fixture.file("incoming/a"), fixture.file("incoming/b")]
                var calls = 0
                let resolver: ArchiveImportConflict.Resolver = { _ in
                    calls += 1
                    XCTAssertFalse(trace.isPlanning)
                    await Task.yield()
                    XCTAssertFalse(trace.isPlanning)
                    if calls == 2 {
                        if outcome == "throw" { throw Failure.resolver }
                        if outcome == "cancel" { progress.cancel() }
                    }
                    return .init(choice: outcome == "skip" ? .skip : .replace)
                }
                do {
                    try await ArchiveStageDiagnostics.observer.withValue({ trace.record($0) }) {
                        if moving {
                            _ = try await session.move(selections, to: "target", progress: progress, resolveConflict: resolver)
                        } else {
                            _ = try await session.append(urls: sources, to: "target", progress: progress, resolveConflict: resolver)
                        }
                    }
                    XCTAssertTrue(outcome == "replace" || outcome == "skip")
                } catch {
                    if outcome == "throw" { XCTAssertTrue(error is Failure) }
                    else { XCTAssertEqual(outcome, "cancel"); XCTAssertTrue(error is CancellationError) }
                }
                XCTAssertEqual(calls, 2)
                trace.check(validations: outcome == "replace" ? 1 : 0)
                if outcome != "replace" { XCTAssertEqual(try Data(contentsOf: fixture.archive), before) }
                await session.close()
            }
        }
    }

    @MainActor func testRejectedPlanEndsItsSpanWithoutMutating() async throws {
        let fixture = try ScenarioFixture(), session = try ArchiveSession(url: fixture.archive), trace = Trace()
        let entries = await session.entries(), before = try Data(contentsOf: fixture.archive)
        let entry = try XCTUnwrap(entries.first)
        do {
            try await ArchiveStageDiagnostics.observer.withValue({ trace.record($0) }) {
                _ = try await session.rename(.init(path: entry.name, isDirectory: false, entries: [entry]),
                                             to: "../invalid", progress: Progress())
            }
            XCTFail("Invalid name was accepted")
        } catch { XCTAssertEqual(error as? ArchiveEditError, .invalidName("../invalid")) }
        trace.check(validations: 0)
        XCTAssertEqual(try Data(contentsOf: fixture.archive), before)
        await session.close()
    }

    private final class Trace: Sendable {
        private struct State {
            var active: [UUID: ArchiveStageDiagnostics.Stage] = [:]
            var ended: [ArchiveStageDiagnostics.Stage: Int] = [:]
        }
        private let state = Mutex(State())

        var isPlanning: Bool { state.withLock { $0.active.values.contains(.planBuild) } }

        func record(_ event: ArchiveStageDiagnostics.Event) {
            state.withLock { value in
                switch event {
                case let .began(id, stage):
                    if stage == .planBuild { XCTAssertFalse(value.active.values.contains(.planBuild)) }
                    if stage == .planValidation {
                        XCTAssertTrue(value.active.values.contains(.mutate))
                        XCTAssertFalse(value.active.values.contains(.planBuild))
                    }
                    XCTAssertNil(value.active.updateValue(stage, forKey: id))
                case let .ended(id, stage, _):
                    XCTAssertEqual(value.active.removeValue(forKey: id), stage)
                    value.ended[stage, default: 0] += 1
                }
            }
        }

        func check(validations: Int) {
            state.withLock { value in
                XCTAssertTrue(value.active.isEmpty)
                XCTAssertGreaterThan(value.ended[.planBuild, default: 0], 0)
                XCTAssertEqual(value.ended[.planValidation, default: 0], validations)
                for stage in [ArchiveStageDiagnostics.Stage.representabilityDifferential] {
                    XCTAssertNil(value.ended[stage])
                }
            }
        }
    }
    #endif
}
