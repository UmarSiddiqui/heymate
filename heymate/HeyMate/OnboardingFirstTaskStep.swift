import SwiftUI

/// Original onboarding choreography built on the real chat/task pipeline.
/// No demo backend, automatic approval, fake completion, or second task store.
struct OnboardingFirstTaskStep: View {
    @ObservedObject var tour: OnboardingTour
    @ObservedObject var manager: CompanionManager
    @State private var request = "Help me plan one small task I can finish today. Ask what I want to get done."
    @State private var chatID: UUID?
    @State private var oldMessageIDs: Set<UUID> = []
    @State private var oldRunIDs: Set<UUID> = []
    @State private var error: String?

    private var run: AgentRun? {
        guard let chatID else { return nil }
        return manager.agentRuns.first { !oldRunIDs.contains($0.id) && $0.chatOwner?.chatID == chatID }
    }
    private var answer: ChatMessage? {
        guard manager.currentChat.id == chatID else { return nil }
        return manager.currentChat.messages.last { $0.role == .assistant && !oldMessageIDs.contains($0.id) && !$0.text.isEmpty }
    }
    private var completedKey: String {
        if let run, run.status.isTerminal { return run.resultDeliveryKey }
        guard run == nil, !manager.isResponseInFlight else { return "" }
        return answer?.id.uuidString ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your first real task").font(.title2)
            Text("Request · progress · approval when needed · result").font(.caption).foregroundStyle(.secondary)
            if chatID == nil {
                TextEditor(text: $request).frame(height: 110)
                Button("Send request") {
                    oldMessageIDs = Set(manager.currentChat.messages.map(\.id))
                    oldRunIDs = Set(manager.agentRuns.map(\.id))
                    if manager.sendTypedMessage(request) {
                        chatID = manager.currentChat.id
                        error = nil
                    } else { error = "Could not send yet. Your request is still here; check AI setup or try again." }
                }.buttonStyle(.borderedProminent)
                    .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if let run {
                ScrollView {
                    ChatTaskCard(run: run, mateName: "Your mate", manager: manager, initiallyExpanded: true)
                }.frame(maxHeight: 290)
            } else if let answer {
                ScrollView { Text(answer.visibleText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260)
                if manager.isResponseInFlight { ProgressView("Receiving your result…").controlSize(.small) }
            } else if manager.isResponseInFlight {
                ProgressView("Working on your request…").controlSize(.small)
            } else {
                Text("Request sent. Follow its progress in chat; this tour can continue whenever you like.")
            }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            Button("Skip this task") { tour.skipFirstTask() }.font(.caption)
            if chatID != nil { Text("Skipping leaves your request and any approval in chat.").font(.caption).foregroundStyle(.secondary) }
        }.padding(30)
        .onChange(of: completedKey) { _, key in if !key.isEmpty { tour.firstTaskFinished() } }
    }
}
