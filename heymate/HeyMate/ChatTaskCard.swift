import AppKit
import SwiftUI

/// Presentation derives from persisted jobs; it never infers ownership from text.
nonisolated enum ChatTaskPresentation {
    static func belongs(_ run: AgentRun, to chat: ChatSession, defaultMateID: UUID) -> Bool {
        let owners = [run.chatOwner, run.chatOwner?.requester].compactMap { $0 }
        return owners.contains { $0.chatID == chat.id && $0.mateID == (chat.mateID ?? defaultMateID) }
    }

    static func noticeTitle(_ status: AgentRunStatus) -> String {
        switch status {
        case .succeeded: return "Result ready"
        case .failed: return "Task failed"
        case .cancelled: return "Task stopped"
        case .awaitingPlanApproval: return "Plan needs approval"
        case .waitingForApproval: return "Permission needed"
        default: return "Task in progress"
        }
    }

    static func icon(_ status: AgentRunStatus) -> String {
        switch status {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "stop.circle"
        case .awaitingPlanApproval, .waitingForApproval: return "hand.raised.fill"
        default: return "ellipsis.circle"
        }
    }

    static func progress(_ run: AgentRun) -> [AgentActivityEntry] {
        run.activity.filter { $0.kind == .progress || $0.kind == .status }
    }

    static func elapsed(_ run: AgentRun) -> String? {
        guard let end = run.finishedAt, let start = run.startedAt, end >= start else { return nil }
        let seconds = Int(end.timeIntervalSince(start))
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    static func artifactURL(_ path: String, workspace: URL) -> URL? {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("[local path]"), !value.contains("[REDACTED]") else { return nil }
        if let url = URL(string: value), let scheme = url.scheme {
            return ["https", "http"].contains(scheme.lowercased()) && url.host != nil ? url : nil
        }
        return URL(fileURLWithPath: value, relativeTo: workspace).standardizedFileURL
    }
}

struct TaskProgressDisclosure: View {
    let run: AgentRun
    @State private var expanded = false
    @State private var revealedCount = 40

    var body: some View {
        let entries = ChatTaskPresentation.progress(run)
        if !entries.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if entries.count > revealedCount {
                            Button("Earlier updates (\(entries.count - revealedCount))") { revealedCount += 40 }
                                .buttonStyle(.plain).font(DS.Fonts.caption)
                        }
                        ForEach(entries.suffix(revealedCount)) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                                    .font(DS.Fonts.micro).monospacedDigit()
                                    .foregroundStyle(DS.Colors.textTertiary)
                                    .frame(width: 54, alignment: .leading)
                                Text(AgentReceiptPrivacy.privateAnswer(entry.text))
                                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                .frame(height: min(240, CGFloat(min(entries.count, revealedCount)) * 48 + 12))
            } label: {
                Text("\(entries.count) progress \(entries.count == 1 ? "update" : "updates")")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            }
            .accessibilityLabel("Progress for \(run.title), \(entries.count) updates")
        }
    }
}

struct ChatTaskCard: View {
    let run: AgentRun
    let mateName: String
    @ObservedObject var manager: CompanionManager
    var initiallyExpanded = false
    var artifactPaths: [String] = []
    @State private var expanded = false
    @State private var showsFollowUp = false
    @State private var followUp = ""
    @State private var feedback: String?

    private var current: AgentRun { manager.agentRuns.first { $0.id == run.id } ?? run }
    private var tint: Color { current.status == .failed || current.status.needsUser ? DS.Colors.warningText : DS.Colors.accent }
    private var answer: String { AgentReplyBlocks.extract(from: FloatingAgentReportContent.answer(for: current)).spokenText }
    private var artifacts: [URL] {
        let blocks = AgentReplyBlocks.extract(from: current.privateFinalResult ?? current.summary)
        var seen = Set<URL>()
        return (artifactPaths + (current.privateArtifactPaths ?? []) + blocks.presentedArtifacts).compactMap {
            ChatTaskPresentation.artifactURL($0, workspace: current.workspaceURL)
        }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        let presentedApproval = current
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: ChatTaskPresentation.icon(current.status)).foregroundStyle(tint)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 4) {
                    Text(current.title).font(DS.Fonts.reading.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(mateName)
                        Text("·")
                        Text(FloatingAgentPresentation.statusLabel(current.status))
                        if let elapsed = ChatTaskPresentation.elapsed(current) { Text("· \(elapsed)") }
                    }.font(DS.Fonts.caption).foregroundStyle(DS.Colors.textTertiary)
                }
                Spacer(minLength: 0)
                if let date = current.finishedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(DS.Fonts.micro).foregroundStyle(DS.Colors.textTertiary)
                }
            }
            if current.status == .waitingForApproval {
                AgentApprovalDetails(run: current)
                HStack {
                    Button("Allow once") { manager.resolvePresentedApproval(run: presentedApproval, approve: true) }
                    Button("Deny") { manager.resolvePresentedApproval(run: presentedApproval, approve: false) }
                }
            }
            if current.status.isTerminal {
                if expanded {
                    ChatMarkdownText(text: answer)
                } else {
                    Text(answer).font(DS.Fonts.reading).lineSpacing(3).lineLimit(3)
                        .foregroundStyle(DS.Colors.textSecondary)
                }
                // Keep the exact deliverable address visible even when the
                // answer is collapsed; the private chat owns these references.
                ForEach(Array(artifacts.filter(\.isFileURL).prefix(4)), id: \.absoluteString) { url in
                    Text(AgentWorkResults.verifiedFile(url) ? url.path : url.path + " (missing or unreadable)")
                        .font(DS.Fonts.code).foregroundStyle(DS.Colors.textSecondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button(expanded ? "Hide result" : "Open result") { expanded.toggle() }
                    Button("Follow up") { showsFollowUp.toggle() }
                        .disabled(!manager.canSendAgentFollowUp(runID: current.id))
                    if current.status == .failed {
                        Button("Retry") {
                            feedback = manager.retryTask(runID: current.id)
                                ? "Retry accepted for planning. Writes still require approval."
                                : manager.agentRevealErrorText
                        }
                        .disabled(!manager.canSendAgentFollowUp(runID: current.id))
                    }
                }.buttonStyle(.plain).font(DS.Fonts.caption.weight(.medium)).foregroundStyle(DS.Colors.accent)
                if showsFollowUp {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Continue this task…", text: $followUp, axis: .vertical)
                            .lineLimit(1...4).textFieldStyle(.plain).font(DS.Fonts.reading)
                            .padding(10).background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Follow up on \(current.title)")
                        Button("Send follow-up", action: sendFollowUp)
                            .disabled(followUp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                    }
                }
                if expanded {
                    ForEach(artifacts, id: \.absoluteString) { url in
                        Button {
                            if url.isFileURL && !FileManager.default.fileExists(atPath: url.path) {
                                feedback = "Artifact is no longer available."
                            } else if !NSWorkspace.shared.open(url) { feedback = "Couldn't open this artifact." }
                        } label: {
                            Label(url.isFileURL ? url.lastPathComponent : (url.host ?? "Open link"),
                                  systemImage: url.isFileURL ? "doc" : "link")
                                .font(DS.Fonts.caption).lineLimit(1)
                        }.buttonStyle(.plain).help(url.isFileURL ? url.path : url.absoluteString)
                    }
                    Button("Show task files in Finder") { manager.revealAgentFolder(runID: current.id) }
                        .buttonStyle(.plain).font(DS.Fonts.caption)
                    if let changes = current.workspaceChangeSummary {
                        Text("Files: \(changes.addedCount) added · \(changes.modifiedCount) modified · \(changes.deletedCount) deleted")
                            .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                        ForEach(changes.displayedChanges, id: \.path) { change in
                            Text("\(change.kind.rawValue): \(change.path)")
                                .font(DS.Fonts.code).foregroundStyle(DS.Colors.textSecondary)
                                .textSelection(.enabled)
                        }
                        if changes.omittedDisplayPathCount > 0 {
                            Text("\(changes.omittedDisplayPathCount) more changed files")
                                .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textTertiary)
                        }
                    }
                }
            } else {
                Text(AgentReceiptPrivacy.privateAnswer(current.latestAction))
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary).lineLimit(2)
            }
            TaskProgressDisclosure(run: current)
            if let feedback {
                Text(feedback).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                    .textSelection(.enabled).accessibilityLabel(feedback)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(DS.Colors.textPrimary)
        .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        .overlay { CueShimmer(subject: run.id.uuidString).clipShape(RoundedRectangle(cornerRadius: 18)) }
        .cueGlow(.permissionAsk, subject: run.id.uuidString, cornerRadius: 18)
        .cueMotion(.jobStarted, .jobDone, .surprised, subject: run.id.uuidString)
        .onAppear { if initiallyExpanded { expanded = true } }
        .onChange(of: current.resultDeliveryKey) { _, _ in showsFollowUp = false; feedback = nil }
    }

    private func sendFollowUp() {
        let instruction = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        if manager.sendAgentFollowUp(runID: current.id, instruction: instruction) {
            followUp = ""; showsFollowUp = false
            feedback = "Follow-up accepted for processing."
        } else { feedback = manager.agentRevealErrorText }
    }
}

struct TaskUpdatesPopover: View {
    @ObservedObject var manager: CompanionManager
    let onOpened: () -> Void
    @State private var error: String?

    private var approvals: [AgentRun] {
        manager.agentRuns.filter { run in
            run.status.needsUser && run.chatOwner != nil && manager.mates.contains {
                $0.id == run.chatOwner?.mateID && !$0.archived
            }
        }.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Task updates").font(DS.Fonts.title)
            if approvals.isEmpty && manager.taskNotices.isEmpty {
                Text("You're caught up. Results and approval requests appear here.")
                    .font(DS.Fonts.body).foregroundStyle(DS.Colors.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(approvals) { run in updateRow(run, notice: nil) }
                        ForEach(manager.taskNotices) { notice in
                            if let run = manager.agentRuns.first(where: { notice.matches($0) }) {
                                updateRow(run, notice: notice)
                            }
                        }
                    }
                }.frame(maxHeight: 380)
            }
            if let error { Text(error).font(DS.Fonts.caption).foregroundStyle(DS.Colors.warningText) }
            Text("Dismissing an update keeps its task and result in chat.")
                .font(DS.Fonts.micro).foregroundStyle(DS.Colors.textTertiary)
        }.padding(18).frame(width: 340).foregroundStyle(DS.Colors.textPrimary)
    }

    private func updateRow(_ run: AgentRun, notice: FloatingAgentNotice?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if manager.openTaskChat(runID: run.id) { onOpened() }
                else { error = "Original chat is unavailable. Task history has been kept." }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: ChatTaskPresentation.icon(run.status))
                        .foregroundStyle(run.status.needsUser || run.status == .failed ? DS.Colors.warningText : DS.Colors.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ChatTaskPresentation.noticeTitle(run.status)).font(DS.Fonts.caption.weight(.semibold))
                        Text(run.title).font(DS.Fonts.body).lineLimit(2)
                        if let mate = manager.mates.first(where: { $0.id == run.chatOwner?.mateID }) {
                            Text(mate.name).font(DS.Fonts.micro).foregroundStyle(DS.Colors.textTertiary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Open original task chat")
            if let notice {
                Button { manager.dismissTaskNotice(id: notice.id) } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Dismiss update for \(run.title)")
            }
        }.padding(10).background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 12))
    }
}
