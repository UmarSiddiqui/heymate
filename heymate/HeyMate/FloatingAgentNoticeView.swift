import SwiftUI

nonisolated struct FloatingAgentNoticeItem: Identifiable {
    let notice: FloatingAgentNotice
    let run: AgentRun
    let mateName: String
    var id: UUID { notice.id }
}

struct FloatingAgentNoticeCard: View {
    let run: AgentRun
    let mateName: String
    let onReport: () -> Void
    let onDismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.companionMotionSuppressed) private var motionSuppressed
    @Environment(\.companionSnapshotRendering) private var snapshotRendering
    @State private var hovered = false

    private var tint: Color { run.status == .failed ? DS.Colors.warningText : DS.Colors.accent }
    private var title: String { run.status == .failed ? "Task needs attention" : "Result ready" }

    var body: some View {
        HStack(spacing: 8) {
            if hovered || snapshotRendering {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "message.fill").foregroundStyle(tint)
                        Text(title).font(DS.Fonts.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                            .help("Dismiss update").accessibilityLabel("Dismiss update for \(run.title)")
                    }
                    Text(run.title).font(DS.Fonts.body.weight(.medium)).lineLimit(1)
                    Button("Open task report", action: onReport)
                        .font(DS.Fonts.caption).foregroundStyle(tint)
                        .help("Open the full task report")
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(tint.opacity(0.32), lineWidth: 0.8))
            } else {
                Spacer(minLength: 0)
                Button(action: onReport) {
                    Image(systemName: "message.fill").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(tint).frame(width: 44, height: 44)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(tint).frame(width: 7, height: 7).padding(5)
                        }
                }
                .help("\(mateName): \(run.title). Open task report")
                .accessibilityLabel("\(mateName), \(title), \(run.title). Open task report")
            }
        }
        .buttonStyle(.plain)
        .frame(height: 84)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion || motionSuppressed ? nil : .easeInOut(duration: 0.22), value: hovered)
        .accessibilityAction(named: Text("Open task report"), onReport)
        .accessibilityAction(named: Text("Dismiss update"), onDismiss)
    }
}

struct FloatingAgentReportView: View {
    let run: AgentRun
    let mateName: String
    @Environment(\.companionSnapshotRendering) private var snapshotRendering

    private var answer: String { FloatingAgentReportContent.answer(for: run) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: run.status == .failed ? "exclamationmark.bubble" : "checkmark.bubble")
                    .font(.system(size: 22)).foregroundStyle(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.title).font(DS.Fonts.title)
                    Text("\(mateName) · \(FloatingAgentPresentation.statusLabel(run.status))")
                        .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                }
            }
            Divider()
            if snapshotRendering { reportText }
            else { ScrollView { reportText } }
        }
        .padding(24).frame(minWidth: 440, maxWidth: .infinity, minHeight: 320,
                           maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(DS.Colors.textPrimary).background(Color.black)
    }

    private var reportText: some View {
        Text(answer).font(DS.Fonts.body).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

nonisolated enum FloatingAgentReportContent {
    static func answer(for run: AgentRun) -> String {
        if run.status == .failed {
            for candidate in [run.privateFinalResult, run.error] {
                guard let candidate else { continue }
                let safe = AgentReceiptPrivacy.privateAnswer(candidate)
                if !safe.isEmpty { return safe }
            }
            return "The task failed without additional error details. No completed result is available."
        }
        guard let answer = run.finalAnswer,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AgentFinalResult.missingMessage
        }
        return answer
    }
}
