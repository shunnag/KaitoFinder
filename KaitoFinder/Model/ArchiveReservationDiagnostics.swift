import Foundation

nonisolated enum ArchiveReservationDiagnostics {
    enum Event: Sendable { case planning, importPlanning, sourceVerification, projection, tree, replayPlan, stagingDeletion, conflictItem, updaterPreparation, baseValidation }
    #if DEBUG
    static let observer = TaskLocal<(@Sendable (Event, Bool) -> Void)?>(wrappedValue: nil)
    #endif

    static func record(_ event: Event) {
        #if DEBUG
        observer.get()?(event, Thread.isMainThread)
        #endif
    }
}
