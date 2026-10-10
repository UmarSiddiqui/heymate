//
//  CompanionManager+AgentLibrary.swift
//  HeyMate
//
//  History actions for finished agent runs: drop a card, or move its
//  workspace folder to Trash and then drop the card. Undo lists only the
//  snapshots the ledger already stored.
//

import Foundation

extension CompanionManager {

    /// Drops a finished run from the Agents list and reloads `agentRuns`.
    /// The workspace folder stays on disk. A run that is still in progress
    /// stays in the store.
    @discardableResult
    func deleteAgentRun(runID: UUID) -> Bool {
        let didDelete = agentRunStore.delete(id: runID)
        agentRuns = agentRunStore.loadAll()
        if didDelete {
            agentRevealErrorText = ""
        }
        return didDelete
    }

    /// Moves the run's workspace folder to Trash, then removes the list entry.
    /// A missing folder is reported and the list entry stays so it can be
    /// removed on its own.
    func moveAgentFolderToTrash(runID: UUID) {
        agentRevealErrorText = ""
        guard let run = agentRunStore.run(id: runID), run.status.isTerminal else { return }

        let workspacePath = run.workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true)
        var isDirectory: ObjCBool = false
        let folderExists = !workspacePath.isEmpty
            && FileManager.default.fileExists(atPath: workspaceURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
        guard folderExists else {
            agentRevealErrorText = Self.missingAgentFolderMessage
            return
        }

        do {
            try FileManager.default.trashItem(at: workspaceURL, resultingItemURL: nil)
        } catch {
            agentRevealErrorText = error.localizedDescription
            return
        }

        if !deleteAgentRun(runID: runID) {
            agentRevealErrorText = "The folder was moved to Trash, but this run is still listed."
        }
    }

    /// Ready snapshots the ledger actually has, newest first.
    func readyAgentUndoEntries() -> [AgentUndoEntry] {
        agentUndoLedger.readyEntries()
    }

    func restoreAgentUndoEntry(entryID: UUID) {
        agentUndoErrorText = ""
        do {
            let restoredEntry = try agentUndoLedger.undo(entryID: entryID)
            _ = agentRunStore.update(id: restoredEntry.runID) { current in
                current.latestAction = "Undone — previous workspace restored"
                current.summary = "Previous workspace restored. Post-agent version kept in Undo Ledger recovery."
                current.appendActivity(kind: .status, text: current.summary)
            }
            agentRuns = agentRunStore.loadAll()
            latestAgentUndoEntry = agentUndoLedger.latestReadyEntry()
        } catch {
            agentUndoErrorText = error.localizedDescription
        }
    }

    static let missingAgentFolderMessage = "Folder missing. You can still remove this run from the list."
}
