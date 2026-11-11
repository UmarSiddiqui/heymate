//
//  CompanionManager+MateWakes.swift
//  HeyMate
//
//  Agent wakes: turning a Mac-side signal into an offer, and an accepted
//  offer into a turn on that agent. A signal alone never starts work.
//

import AppKit
import Foundation

extension CompanionManager {
    func startMateWakes() {
        mateWakes = mateWakeStore.loadAll()
        mateWakeWatcher.calendarAllowed = { [weak self] in
            self?.connectorStore.connectionState(for: "apple-calendar").isConnected ?? false
        }
        mateWakeWatcher.mailAllowed = { [weak self] in
            self?.connectorStore.connectionState(for: "apple-mail").isConnected ?? false
        }
        mateWakeWatcher.onSignal = { [weak self] signal in self?.considerMateWakeSignal(signal) }
        syncMateWakeSources()
    }

    /// Runs only the sources that a live agent's wake needs.
    func syncMateWakeSources() {
        let live = Set(mates.filter { !$0.archived }.map(\.id))
        let kinds = Set(mateWakes.filter { $0.enabled && live.contains($0.mateID) }.map(\.kind))
        mateWakeWatcher.update(kinds: kinds)
    }

    func wake(for mateID: UUID) -> MateWake? {
        mateWakes.first { $0.mateID == mateID }
    }

    /// One wake per agent. Passing nil removes it.
    func setMateWake(mateID: UUID, kind: MateWakeKind?, match: String = "", task: String = "") {
        // Changing only the filter keeps what the agent was told to do.
        let keptTask = mateWakes.first { $0.mateID == mateID && $0.kind == kind }?.task ?? ""
        for existing in mateWakes where existing.mateID == mateID {
            mateWakeStore.delete(id: existing.id)
        }
        if let kind {
            let cleaned = MateWakeMatcher.cleanedMatch(match)
            let typed = task.trimmingCharacters(in: .whitespacesAndNewlines)
            if !(kind.requiresMatch && cleaned.isEmpty) {
                mateWakeStore.upsert(MateWake.make(
                    mateID: mateID, kind: kind, match: cleaned, task: typed.isEmpty ? keptTask : typed
                ))
            }
        }
        mateWakes = mateWakeStore.loadAll()
        mateWakeOffers.removeAll { $0.mateID == mateID }
        syncMateWakeSources()
    }

    func removeMateWakes(mateID: UUID) {
        mateWakeStore.deleteAll(mateID: mateID)
        mateWakes = mateWakeStore.loadAll()
        mateWakeOffers.removeAll { $0.mateID == mateID }
        syncMateWakeSources()
    }

    func considerMateWakeSignal(_ signal: MateWakeSignal) {
        let pending = MateWakeMatcher.current(mateWakeOffers, now: signal.observedAt)
        guard let offer = MateWakeMatcher.offer(
            for: signal, wakes: mateWakes, mates: mates, pending: pending
        ) else {
            if pending.count != mateWakeOffers.count { mateWakeOffers = pending }
            return
        }
        if let wake = mateWakes.first(where: { $0.id == offer.wakeID }) {
            mateWakeStore.upsert(MateWakeMatcher.recordOffer(wake, signal: signal))
            mateWakes = mateWakeStore.loadAll()
        }
        mateWakeOffers = MateWakeMatcher.current([offer] + pending, now: signal.observedAt)
        // A quiet nudge in the notch. No sound: the person did not ask.
        notchActivityCenter.agentActivity = NotchActivity(
            kind: .agent,
            trailingText: offer.mateName,
            tintHex: "F59E0B",
            expiresAt: Date().addingTimeInterval(20)
        )
    }

    func dismissMateWakeOffer(id: UUID) {
        mateWakeOffers.removeAll { $0.id == id }
    }

    /// The person said yes: hand over the file if there is one, then run the
    /// task on that agent in the background. When the agent is busy the task
    /// waits in its chat box instead, ready to send.
    func acceptMateWakeOffer(id: UUID) {
        guard let offer = mateWakeOffers.first(where: { $0.id == id }) else { return }
        mateWakeOffers.removeAll { $0.id == id }
        guard mates.contains(where: { $0.id == offer.mateID && !$0.archived }) else { return }

        var prompt = offer.prompt
        if let fileURL = offer.fileURL {
            ensureMateFolder(id: offer.mateID)
            guard let path = mateDirectory.mates.first(where: { $0.id == offer.mateID })?.folderPath else {
                agentRevealErrorText = "This agent has no folder to put files in."
                return
            }
            let names = MateFileDrop.copy([fileURL], into: URL(fileURLWithPath: path, isDirectory: true))
            guard !names.isEmpty else {
                agentRevealErrorText = "That file could not be copied. It may have been moved."
                return
            }
            prompt = MateFileDrop.draft(names: names, existing: prompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let now = Date()
        let oneOff = MateRoutine(
            id: UUID(),
            mateID: offer.mateID,
            task: prompt,
            enabled: true,
            schedule: .everyHours(24),
            nextRunAt: now,
            lastRunAt: nil,
            lastStatusMessage: nil,
            consecutiveFailures: 0,
            pausedReason: nil
        )
        switch kickoffRoutine(oneOff, deliverySession: nil, isWake: true) {
        case .started:
            cue(.thumbsUp)
        case .busy, .failed:
            openMate(id: offer.mateID)
            let existing = (currentChat.draftText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            updateCurrentDraft(existing.isEmpty ? prompt : "\(existing)\n\(prompt)")
            openDesktopWindow(section: .chat)
        }
    }
}
