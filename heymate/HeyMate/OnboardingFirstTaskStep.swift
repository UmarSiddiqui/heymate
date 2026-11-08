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
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                Text("Your first real task")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Ask for something small. You'll see it work, approve anything that needs you, then get the result.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            .padding(.top, 22)
            Spacer(minLength: 0)
            Group {
                if chatID == nil {
                    TextEditor(text: $request)
                        .font(DS.Fonts.bodyLarge)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(height: 96)
                        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).fill(DS.Colors.surface1))
                        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                            .strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
                    Button("Send request") {
                        oldMessageIDs = Set(manager.currentChat.messages.map(\.id))
                        oldRunIDs = Set(manager.agentRuns.map(\.id))
                        if manager.sendTypedMessage(request) {
                            chatID = manager.currentChat.id
                            error = nil
                        } else { error = "Could not send yet. Your request is still here; check AI setup or try again." }
                    }
                    .dsCapsuleButtonStyle(.secondary)
                    .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if let run {
                    ScrollView {
                        ChatTaskCard(run: run, mateName: "Your mate", manager: manager, initiallyExpanded: true)
                    }.frame(maxHeight: 260)
                } else if let answer {
                    ScrollView {
                        Text(answer.visibleText)
                            .font(DS.Fonts.bodyLarge)
                            .foregroundColor(DS.Colors.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 240)
                    if manager.isResponseInFlight { ProgressView("Receiving your result…").controlSize(.small) }
                } else if manager.isResponseInFlight {
                    ProgressView("Working on your request…").controlSize(.small)
                } else {
                    OnboardingStatusLine(text: "Request sent. Follow it in chat; the tour can go on whenever you like.", isDone: false)
                }
            }
            .frame(maxWidth: 500)
            if let error {
                Text(error).font(DS.Fonts.caption).foregroundColor(DS.Colors.warningText)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if chatID != nil {
                    Text("Skipping leaves your request and any approval in chat.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Button("Skip this task") { tour.skipFirstTask() }
                    .dsCapsuleButtonStyle(.quiet)
            }
            .opacity(tour.isStepDone ? 0 : 1)
        }
        .onChange(of: completedKey) { _, key in if !key.isEmpty { tour.firstTaskFinished() } }
    }
}
