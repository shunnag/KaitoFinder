import Foundation
import KaitoKit

@MainActor final class ArchiveRenameValidation {
    nonisolated private struct Name: Hashable, Sendable {
        let text: String
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.text.utf8.elementsEqual(rhs.text.utf8) }
        func hash(into hasher: inout Hasher) { hasher.combine(text) }
    }
    private let selection: Result<ArchiveEditSelection, any Error>
    private let entries: [ArchiveEntry]
    private let occupancy: ArchivePathOccupancy.Overlay?
    private var cached: [Name: Result<ArchiveEditPlan, any Error>] = [:]
    private(set) var validationCount = 0
    private(set) var lastValidationMilliseconds = 0.0

    init(selection: ArchiveEditSelection, entries: [ArchiveEntry], state: ArchiveReservationState? = nil,
         occupancy: ArchivePathOccupancy.Overlay? = nil) {
        self.selection = Result { try state?.projection.selection(selection) ?? selection }
        self.entries = state?.projection.planningEntries ?? entries
        self.occupancy = state?.occupancy ?? occupancy
    }

    func plan(for name: String) throws -> ArchiveEditPlan {
        // String の辞書は正準等価を同一視するため、入力した UTF-8 で区別する。
        let key = Name(text: name)
        if let result = cached[key] { return try result.get() }
        let start = ContinuousClock.now
        validationCount += 1
        let result = Result {
            try ArchiveEditPlan.build(removing: [],
                renaming: [.init(selection: try selection.get(), name: name)],
                existing: entries, occupancy: occupancy)
        }
        let elapsed = start.duration(to: .now).components
        lastValidationMilliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        cached[key] = result
        return try result.get()
    }
}

nonisolated struct ArchiveValidatedRename: Sendable {
    let plan: ArchiveEditPlan
    let generation: UInt64
    let revision: UInt64
    let session: ObjectIdentifier
}
