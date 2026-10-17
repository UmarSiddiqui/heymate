import SwiftUI

/// Only a newly completed, previously observed job can trigger a reaction.
/// Loading history or receiving another mate's result never replays it.
struct MateCompletionReaction: Equatable {
    let runID: UUID
    let expression: MateFaceExpression

    static func next(previous: [AgentRun], current: [AgentRun], mateID: UUID) -> Self? {
        let oldStatuses = Dictionary(previous.map { ($0.id, $0.status) }, uniquingKeysWith: { _, latest in latest })
        let completed = current.filter { run in
            run.chatOwner?.mateID == mateID
                && (run.status == .succeeded || run.status == .failed)
                && oldStatuses[run.id].map { !$0.isTerminal } == true
        }.max { left, right in
            let leftDate = left.finishedAt ?? left.createdAt
            let rightDate = right.finishedAt ?? right.createdAt
            return leftDate == rightDate ? left.id.uuidString < right.id.uuidString : leftDate < rightDate
        }
        return completed.map { Self(runID: $0.id, expression: .agent($0.status)) }
    }
}

struct LiveMateFaceView: View {
    let mate: Mate
    let size: CGFloat
    @ObservedObject var manager: CompanionManager
    var isComposerCompanion = false
    @State private var reaction: MateCompletionReaction?
    @State private var reactionTask: Task<Void, Never>?
    /// The latest finished job as a one-shot reaction. Kept after the 2 s
    /// expression ends so the face's inbox can still deliver it once shown.
    @State private var finishEvent: MateReactionEvent?

    var body: some View {
        Group {
            if isComposerCompanion && BlobatarCharacter.contains(MateFace.selectionToken(for: mate)) {
                BlobatarLiveView(mate: mate, token: MateFace.selectionToken(for: mate), size: size,
                                 expression: manager.state.isIdle ? reaction?.expression ?? .idle : .live(manager.state),
                                 reactionEvent: finishEvent, interactive: true, restsOnSurface: true)
            } else if isComposerCompanion {
                MiloCompanionView(mate: mate, size: size,
                                  expression: manager.state.isIdle ? reaction?.expression ?? .idle : .live(manager.state),
                                  reactionEvent: finishEvent, interactive: true)
            } else {
                MateFaceView(mate: mate, size: size,
                             expression: manager.state.isIdle ? reaction?.expression ?? .idle : .live(manager.state),
                             reactionEvent: finishEvent, interactive: true)
            }
        }
            .onChange(of: manager.agentRuns) { previous, current in
                guard manager.state.isIdle,
                      let next = MateCompletionReaction.next(previous: previous, current: current, mateID: mate.id) else { return }
                reactionTask?.cancel()
                reaction = next
                if let status = manager.agentRuns.first(where: { $0.id == next.runID })?.status,
                   let finish = MateFaceReaction.forFinished(status) {
                    finishEvent = MateReactionEvent(id: next.runID.uuidString, reaction: finish)
                }
                reactionTask = Task {
                    do { try await Task.sleep(for: .seconds(2)) }
                    catch { return }
                    reaction = nil
                    reactionTask = nil
                }
            }
            .onChange(of: manager.state) { _, state in
                if !state.isIdle { clearReaction() }
            }
            .onChange(of: mate.id) { _, _ in clearReaction() }
            .onDisappear(perform: clearReaction)
    }

    private func clearReaction() {
        reactionTask?.cancel()
        reactionTask = nil
        reaction = nil
    }
}
