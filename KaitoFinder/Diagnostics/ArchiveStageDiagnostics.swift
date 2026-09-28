import Foundation

/// 処理段階の所要時間を、開始と終了の組（span）として observer に知らせる。observer がなければ時計も読まない。
/// 同じ Diagnostics/ の ArchiveReservationDiagnostics は予約の出来事と実行スレッドを、
/// ArchiveTestCounters は経路を通った回数を知らせ、時間は測らない。
nonisolated enum ArchiveStageDiagnostics {
    enum Stage: String, Sendable {
        case workCopy = "work_copy", updaterOpen = "updater_open", rewriterOpen = "rewriter_open"
        case mutate, replay, commit, verificationOpen = "verification_open", entryComparison = "entry_comparison"
        case publish, reload, reloadOpen = "reload_open", capabilityProbe = "capability_probe"
        case readerAdoption = "reader_adoption", outputProbe = "output_probe", saveSheet = "save_sheet"
        case planKeys = "plan_keys", representabilityProbe = "representability_probe"
        case replayPlan = "replay_plan", validateRepresentability = "validate_representability"
        case editingInstall = "editing_install", editingPrepare = "editing_prepare", updaterPreparation = "updater_preparation"
        case treeBuild = "tree_build", display
        case passwordVerification = "password_verification"
        case total, remove, fixtureBuild = "fixture_build"
        case splitWorkValidation = "split_work_validation", splitMetadataDigest = "split_metadata_digest"
        case splitCopy = "split_copy"
        case splitStagedProof = "split_staged_proof", splitStagedReader = "split_staged_reader", splitStagedRecheck = "split_staged_recheck"
        case splitPlacedProof = "split_placed_proof", splitPlacedReader = "split_placed_reader", splitPlacedRecheck = "split_placed_recheck"
        case splitDisposeProof = "split_dispose_proof", splitInputCopy = "split_input_copy"
        case planBuild = "plan_build", planValidation = "plan_validation"
        case nameIndexBuild = "name_index_build", nameIndexAdvance = "name_index_advance"
        case representabilityDifferential = "representability_differential"
        case filterRequest = "filter_request", filterCompute = "filter_compute", filterSwap = "filter_swap"
    }

    #if DEBUG
    enum Event: Sendable {
        case began(UUID, Stage)
        case ended(UUID, Stage, Duration)
    }

    static let observer = TaskLocal<(@Sendable (Event) -> Void)?>(wrappedValue: nil)

    struct Span: Sendable {
        let id: UUID
        let stage: Stage
        let start: ContinuousClock.Instant
        let observer: @Sendable (Event) -> Void

        func end() { observer(.ended(id, stage, start.duration(to: .now))) }
    }

    static func begin(_ stage: Stage) -> Span? {
        guard let observer = observer.get() else { return nil }
        let id = UUID()
        observer(.began(id, stage))
        return Span(id: id, stage: stage, start: .now, observer: observer)
    }
    #endif

    // Release ではクロック・TaskLocal・コールバックを生成しない。
    @inline(__always) static func measure<Value>(_ stage: Stage, _ body: () throws -> Value) rethrows -> Value {
        #if DEBUG
        let span = begin(stage)
        defer { span?.end() }
        #endif
        return try body()
    }
}
