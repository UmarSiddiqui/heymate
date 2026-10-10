//
//  CompanionManager+RoutineEdit.swift
//  HeyMate
//
//  Editing a routine keeps its id and mate. The schedule phrase is parsed
//  again so nextRunAt follows the same rules as a new routine.
//

import Foundation

extension CompanionManager {
    /// Nil when the routine was saved. Otherwise the message to show inline.
    func updateRoutine(id: UUID, task: String, schedulePhrase: String) -> String? {
        guard let existing = routines.first(where: { $0.id == id }) else {
            return "That routine is gone."
        }
        guard let updated = existing.editing(
            task: task,
            schedulePhrase: schedulePhrase,
            now: Date(),
            calendar: .current
        ) else {
            return RoutinePhraseParser.invalidScheduleMessage
        }
        mateDirectory.updateRoutine(updated)
        syncMatePublications()
        return nil
    }
}
