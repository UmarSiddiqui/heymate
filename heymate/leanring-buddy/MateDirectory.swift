//
//  MateDirectory.swift
//  leanring-buddy
//
//  Mates and routines for the one CompanionManager. Chats stay in
//  FileChatHistoryStore; this type only assigns them a mate.
//

import Foundation

@MainActor
final class MateDirectory {
    let mateStore: FileMateStore
    let routineStore: FileMateRoutineStore
    private(set) var mates: [Mate]
    private(set) var routines: [MateRoutine]
    var activeMateID: UUID

    var defaultMateID: UUID { mateStore.defaultMateID }

    init(
        mateStore: FileMateStore,
        routineStore: FileMateRoutineStore,
        chatHistoryStore: FileChatHistoryStore
    ) {
        self.mateStore = mateStore
        self.routineStore = routineStore
        self.mates = mateStore.loadAll()
        self.activeMateID = mateStore.defaultMateID
        chatHistoryStore.migrateNilMateIDs(to: mateStore.defaultMateID)
        self.routines = routineStore.loadAll()
    }

    func replaceMates(_ mates: [Mate]) {
        self.mates = mates
    }

    func reload() {
        mates = mateStore.loadAll()
        routines = routineStore.loadAll()
    }

    @discardableResult
    func upsertMate(_ mate: Mate) -> Bool {
        guard mateStore.upsert(mate) else { return false }
        mates = mateStore.loadAll()
        return true
    }

    func archiveMate(id: UUID) {
        mateStore.archive(id: id)
        mates = mateStore.loadAll()
        routines = routines.map { routine in
            guard routine.mateID == id else { return routine }
            let paused = MateRoutineAccounting.pauseForArchivedMate(routine)
            routineStore.upsert(paused)
            return paused
        }
    }

    @discardableResult
    func deleteMate(id: UUID) -> Bool {
        let removed = mateStore.delete(id: id)
        guard removed else { return false }
        routineStore.deleteAll(mateID: id)
        mates = mateStore.loadAll()
        routines = routineStore.loadAll()
        if mates.contains(where: { $0.id == activeMateID }) == false {
            activeMateID = defaultMateID
        }
        return true
    }

    func unarchiveMate(id: UUID) {
        guard var mate = mates.first(where: { $0.id == id }) else { return }
        mate.archived = false
        mate.updatedAt = Date()
        guard mateStore.upsert(mate) else { return }
        mates = mateStore.loadAll()
        routines = routines.map { routine in
            guard routine.mateID == id, routine.pausedReason == MateRoutineAccounting.archivedPauseReason else {
                return routine
            }
            let resumed = MateRoutineAccounting.resume(routine, now: Date(), calendar: .current)
            routineStore.upsert(resumed)
            return resumed
        }
    }

    func setPinned(id: UUID, pinned: Bool) {
        guard var mate = mates.first(where: { $0.id == id }) else { return }
        mate.pinned = pinned
        mate.updatedAt = Date()
        _ = mateStore.upsert(mate)
        mates = mateStore.loadAll()
    }

    func markRead(id: UUID) {
        guard var mate = mates.first(where: { $0.id == id }) else { return }
        guard mate.unreadCount != 0 else { return }
        mate.unreadCount = 0
        mate.updatedAt = Date()
        _ = mateStore.upsert(mate)
        mates = mateStore.loadAll()
    }

    func markUnread(id: UUID) {
        guard var mate = mates.first(where: { $0.id == id }) else { return }
        mate.unreadCount = max(mate.unreadCount, 1)
        mate.updatedAt = Date()
        _ = mateStore.upsert(mate)
        mates = mateStore.loadAll()
    }

    func incrementUnread(id: UUID) {
        guard var mate = mates.first(where: { $0.id == id }) else { return }
        mate.unreadCount += 1
        mate.updatedAt = Date()
        _ = mateStore.upsert(mate)
        mates = mateStore.loadAll()
    }

    func updateFolderPath(id: UUID, path: String) {
        guard var mate = mates.first(where: { $0.id == id }) else { return }
        guard mate.folderPath != path else { return }
        mate.folderPath = path
        mate.updatedAt = Date()
        _ = mateStore.upsert(mate)
        mates = mateStore.loadAll()
    }

    func clearFolderPath(id: UUID) {
        guard var mate = mates.first(where: { $0.id == id }) else { return }
        guard mate.folderPath != nil else { return }
        mate.folderPath = nil
        mate.updatedAt = Date()
        _ = mateStore.upsert(mate)
        mates = mateStore.loadAll()
    }

    func updateMemoryNote(id: UUID, note: String) {
        guard var mate = mates.first(where: { $0.id == id }) else { return }
        guard mate.memoryNote != note else { return }
        mate.memoryNote = note
        mate.updatedAt = Date()
        _ = mateStore.upsert(mate)
        mates = mateStore.loadAll()
    }

    func addRoutine(_ routine: MateRoutine) {
        routineStore.upsert(routine)
        routines = routineStore.loadAll()
    }

    func deleteRoutine(id: UUID) {
        routineStore.delete(id: id)
        routines = routineStore.loadAll()
    }

    func updateRoutine(_ routine: MateRoutine) {
        routineStore.upsert(routine)
        routines = routineStore.loadAll()
    }

    func pauseRoutine(id: UUID) {
        guard let routine = routines.first(where: { $0.id == id }) else { return }
        updateRoutine(MateRoutineAccounting.pauseManually(routine))
    }

    func resumeRoutine(id: UUID, now: Date, calendar: Calendar) {
        guard let routine = routines.first(where: { $0.id == id }) else { return }
        updateRoutine(MateRoutineAccounting.resume(routine, now: now, calendar: calendar))
    }

    func apply(_ routine: MateRoutine) {
        updateRoutine(routine)
    }
}
