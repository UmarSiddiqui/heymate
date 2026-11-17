import SwiftUI

struct MateInboxQuestionRow: View {
    let item: MateInboxItem
    let work: MateInboxWork?
    let answer: (String) -> Bool
    let open: () -> Void
    let dismiss: () -> Void
    var dismissTitle = "Dismiss"
    @State private var reply = ""
    @State private var couldNotResume = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.mateName).font(DS.Fonts.caption.weight(.semibold))
            if let work, !work.title.isEmpty {
                Text(work.title).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            }
            switch item.kind {
            case .question(let prompt, let defaultAnswer, let choices):
                Text(prompt).font(DS.Fonts.body)
                if let defaultAnswer {
                    Button("Use suggested answer: \(defaultAnswer)") { submit(defaultAnswer) }
                        .font(DS.Fonts.caption)
                }
                ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                    Button(choice) { submit(choice) }.font(DS.Fonts.caption)
                }
                HStack {
                    TextField("Your answer", text: $reply)
                        .onSubmit { submit(reply) }
                    Button("Reply and resume") { submit(reply) }
                        .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.font(DS.Fonts.caption)
            case .signIn(let site, _, let reason, _):
                Text("Sign in to \(site)").font(DS.Fonts.body)
                if !reason.isEmpty { Text(reason).font(DS.Fonts.caption) }
                Button("I've signed in") { submit("Signed in") }.font(DS.Fonts.caption)
            case .routineFailed(_, let summary):
                Text("Routine couldn't finish").font(DS.Fonts.body)
                Text(MateInboxWork.safeText(summary, limit: 260)).font(DS.Fonts.caption)
                Button("Retry task") { submit("Retry this task from the last verified step.") }.font(DS.Fonts.caption)
            case .appliedChange, .proposal:
                EmptyView()
            }
            if let work, let result = work.result, !result.isEmpty {
                Text(result).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary).lineLimit(3)
            }
            if let work { MateInboxSteps(steps: work.steps) }
            HStack {
                Button("Open chat", action: open)
                Spacer()
                Button(dismissTitle, action: dismiss)
            }.font(DS.Fonts.caption)
            if couldNotResume {
                Text("This chat is still working or no longer available. Your answer hasn't been sent.")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.warningText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 12))
    }

    private func submit(_ value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        couldNotResume = !answer(value)
    }
}

struct MateInboxWorkRow: View {
    let work: MateInboxWork
    var open: (() -> Void)?
    var perform: ((MateInboxWork.Action, String) -> Bool)?
    var pendingItem: MateInboxItem?
    var answer: ((UUID, String) -> Bool)?
    var earlierAttempts: [MateInboxWork] = []
    var openAttempt: ((MateInboxWork) -> Void)?
    @State private var showContinuation = false
    @State private var showFollowUp = false
    @State private var followUp = ""
    @State private var couldNotStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(work.mateName).font(DS.Fonts.caption.weight(.semibold))
                Text(work.displayState.title).font(DS.Fonts.caption)
                    .foregroundStyle(work.displayState == .failed || work.displayState == .needsInput
                        ? DS.Colors.warningText : DS.Colors.textSecondary)
                Spacer()
                Text(work.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(DS.Fonts.micro).foregroundStyle(DS.Colors.textTertiary)
            }
            Text(work.title.isEmpty ? "Mate task" : work.title).font(DS.Fonts.body).lineLimit(2)
            if (work.displayState == .failed || work.displayState == .stopped), let step = work.lastFailedStep {
                Label(step.displayTitle, systemImage: "exclamationmark.circle")
                    .font(DS.Fonts.caption.weight(.semibold)).foregroundStyle(DS.Colors.warningText)
                if let failure = step.failure {
                    Text(failure.message).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                }
            }
            if work.state == .running {
                if let plan = work.plan, !plan.isEmpty {
                    Text(plan).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary).lineLimit(3)
                }
                Label(work.currentStep?.displayTitle ?? "Preparing the next step", systemImage: "ellipsis.circle")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.accent)
                if work.finishedStepCount > 0 {
                    Text("\(work.finishedStepCount) steps finished").font(DS.Fonts.caption)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
            } else if let result = work.result, !result.isEmpty {
                Text(result).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary).lineLimit(3)
            } else if let step = work.steps.last, step.state != .failed {
                Text(step.displayTitle).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary).lineLimit(2)
            }
            MateInboxSteps(steps: work.steps)
            if let perform {
                HStack(spacing: 8) {
                    ForEach(work.actions, id: \.title) { action in
                        Button(action.title) {
                            if action == .followUp {
                                showFollowUp.toggle()
                            } else if action == .resume, pendingItem != nil {
                                showContinuation.toggle()
                            } else {
                                couldNotStart = !perform(action, "")
                            }
                        }
                    }
                }.font(DS.Fonts.caption)
                if showContinuation, let pendingItem, let answer, let open {
                    MateInboxQuestionRow(item: pendingItem, work: nil, answer: { answer(pendingItem.id, $0) },
                        open: open, dismiss: { showContinuation = false }, dismissTitle: "Close")
                }
                if showFollowUp {
                    HStack {
                        TextField("What should this Mate do next?", text: $followUp)
                            .onSubmit { sendFollowUp(perform) }
                        Button("Send") { sendFollowUp(perform) }
                            .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.font(DS.Fonts.caption)
                }
                if couldNotStart {
                    Text("Couldn’t start. Check if the original chat is available and idle.")
                        .font(DS.Fonts.caption).foregroundStyle(DS.Colors.warningText)
                }
            }
            if let open {
                Button(work.resultKey != nil ? "Open result" : "Open chat", action: open)
                    .font(DS.Fonts.caption)
            }
            if !earlierAttempts.isEmpty {
                DisclosureGroup("Earlier attempts (\(earlierAttempts.count))") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(earlierAttempts) { attempt in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(attempt.displayState.title) · \(attempt.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .fontWeight(.semibold)
                                if let result = attempt.result {
                                    Text(result).foregroundStyle(DS.Colors.textSecondary).lineLimit(3)
                                }
                                MateInboxSteps(steps: attempt.steps)
                                if let openAttempt, attempt.resultKey != nil {
                                    Button("Open earlier result") { openAttempt(attempt) }
                                }
                            }
                        }
                    }.padding(.top, 6)
                }.font(DS.Fonts.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: work.id) { _, _ in
            showContinuation = false
            showFollowUp = false
            followUp = ""
            couldNotStart = false
        }
    }

    private func sendFollowUp(_ perform: (MateInboxWork.Action, String) -> Bool) {
        guard !followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        couldNotStart = !perform(.followUp, followUp)
        if !couldNotStart {
            followUp = ""
            showFollowUp = false
        }
    }
}

struct MateInboxSteps: View {
    let steps: [MateInboxWork.Step]

    var body: some View {
        if !steps.isEmpty {
            DisclosureGroup("Steps (\(steps.count))") {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 6) {
                            Text(step.date.formatted(date: .omitted, time: .shortened))
                                .font(DS.Fonts.micro).foregroundStyle(DS.Colors.textTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(step.displayTitle)
                                if let failure = step.failure {
                                    Text(failure.message).foregroundStyle(DS.Colors.textSecondary)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(step.state.title)
                                .foregroundStyle(step.state == .failed ? DS.Colors.warningText : DS.Colors.textSecondary)
                        }
                    }
                }.padding(.top, 6)
            }.font(DS.Fonts.caption)
        }
    }
}
