//
//  CompanionManager+MemoryEdit.swift
//  HeyMate
//
//  Replacing the text of one stored memory. Deletion stays on CompanionManager.
//

import Foundation

extension CompanionManager {
    /// Replaces one memory's text and refreshes the published list.
    /// Blank text is ignored by the repository, so the stored record stays.
    func updateMemory(id: UUID, text: String) {
        memoryRepository.update(id: id, text: text)
        memoryItems = memoryRepository.loadAll()
    }
}
