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

    /// Registers a routine a mate declared in its finished message. Title
    /// matches within that mate. The store is the authority on the next turn.
    func applyDeclaredRoutine(_ request: AgentRoutineRequest, mateID: UUID, now: Date = Date()) {
        let changes = HarnessRoutineDeclaration.changes(
            for: request,
            mateID: mateID,
            existing: routines,
            now: now,
            calendar: .current
        )
        for change in changes {
            switch change {
            case .upsert(let routine):
                mateDirectory.updateRoutine(routine)
            case .delete(let id):
                mateDirectory.deleteRoutine(id: id)
            }
        }
        if !changes.isEmpty {
            syncMatePublications()
        }
    }
}
