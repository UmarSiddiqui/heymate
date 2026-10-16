import SwiftUI

extension CompanionManager {
    /// The clicked UI must still describe the exact approval now pending.
    /// Existing handlers retain runtime/opaque-token validation beneath this.
    func resolvePresentedApproval(run: AgentRun, approve: Bool) {
        guard let current = agentRuns.first(where: { $0.id == run.id }),
              current.status == .waitingForApproval, !run.pendingApprovalID.isEmpty,
              current.pendingApprovalID == run.pendingApprovalID,
              current.detachedAttemptID == run.detachedAttemptID, current.chatOwner == run.chatOwner else { return }
        if approve { approveAgent(runID: run.id) } else { denyAgent(runID: run.id) }
    }
}

struct AgentApprovalDetails: View {
    let run: AgentRun
    var body: some View {
        if let details = run.pendingApprovalDetails {
            ScrollView {
                Text(details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180).accessibilityLabel("Approval request details")
        }
    }
}

struct LiveExecutionInputButton: View {
    let run: AgentRun
    @ObservedObject var manager: CompanionManager
    @State private var reviewing = false
    @State private var reviewSnapshot: AgentRun?
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        Button(run.liveSteeringAvailable ? "Update now" : "Queue update") { reviewSnapshot = run; reviewing = true }
            .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
            .sheet(isPresented: $reviewing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Update “\(run.title)”").font(.headline)
                    Text(run.liveSteeringAvailable
                         ? "Send to this active Codex execution turn. Pending actions still need their own approval."
                         : "This executor queues updates after its current step. The next plan still needs approval.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $draft).frame(height: 150)
                    if let error { Text(error).foregroundStyle(.orange) }
                    HStack {
                        Button("Cancel") { reviewing = false }
                        Spacer()
                        Button("Send update") {
                            guard let expected = reviewSnapshot, let current = manager.agentRuns.first(where: { $0.id == expected.id }),
                                  current.status == .running, current.detachedAttemptID == expected.detachedAttemptID,
                                  current.chatOwner == expected.chatOwner else {
                                error = "Task changed. Close this review and check its current state; your input remains here."
                                return
                            }
                            if manager.sendAgentFollowUp(runID: run.id, instruction: draft) {
                                draft = ""; error = nil; reviewing = false
                            } else { error = "Could not submit update. Your input remains here." }
                        }.buttonStyle(.borderedProminent)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(24).frame(width: 500)
            }
    }
}
