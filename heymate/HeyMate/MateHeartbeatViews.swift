//
//  MateHeartbeatViews.swift
//  HeyMate
//
//  The heartbeat's two surfaces: a proposal in Waiting on You (Approve,
//  Skip, Adjust), and the per-mate switch in agent settings with when it
//  last checked in, how often, and Check now. Settings here save at once.
//

import SwiftUI

struct MateProposalRow: View {
    let item: MateInboxItem
    let proposal: MateHeartbeatProposal
    let act: (MateHeartbeatAction) -> Bool
    @State private var couldNotStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(item.mateName).font(DS.Fonts.caption.weight(.semibold))
                Text("Proposes").font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                Text(proposal.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(DS.Fonts.micro).foregroundStyle(DS.Colors.textTertiary)
            }
            Text(proposal.title).font(DS.Fonts.body)
            Text(proposal.whyNow).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            if let needsApproval = proposal.needsApproval {
                Label(needsApproval, systemImage: "hand.raised")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            }
            DisclosureGroup("Message it would send") {
                Text(proposal.prompt).font(DS.Fonts.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }.font(DS.Fonts.caption)
            HStack {
                Button("Approve") { couldNotStart = !act(.approve) }
                Button("Adjust") { _ = act(.adjust) }
                Spacer()
                Button("Skip") { _ = act(.skip) }
            }.font(DS.Fonts.caption)
            if couldNotStart {
                Text("\(item.mateName) is busy or its chat is unavailable. Nothing was sent.")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.warningText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MateHeartbeatSection: View {
    let mate: Mate
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject private var store = MateHeartbeatStore.shared
    @State private var notice: String?

    var body: some View {
        let entry = store.mate(mate.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Check-ins")
                    .font(DS.Fonts.sectionLabel)
                    .foregroundColor(DS.Colors.textTertiary)
                Text("Looks for work it could do, up to twice a day")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Toggle("Propose work on its own", isOn: Binding(
                get: { companionManager.isHeartbeatEnabled(for: mate) },
                set: { companionManager.setHeartbeatEnabled($0, mateID: mate.id) }
            ))
            .disabled(!store.state.globalEnabled || mate.archived)
            HStack(spacing: 10) {
                Text(summary(entry))
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if store.runningMateID == mate.id {
                    ProgressView().controlSize(.small)
                }
                Button("Check now") { notice = companionManager.runMateHeartbeatNow(mateID: mate.id) }
                    .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                    .disabled(store.runningMateID != nil || mate.archived)
            }
            if let notice {
                Text(notice).font(DS.Fonts.caption).foregroundColor(DS.Colors.warningText)
            }
            Toggle("Allow check-ins for every agent", isOn: Binding(
                get: { store.state.globalEnabled },
                set: { companionManager.setHeartbeatsEnabledGlobally($0) }
            ))
            .font(DS.Fonts.caption)
            Text("Each check-in is one short, read-only turn on your plan. It never reads your screen, clipboard or mail bodies.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summary(_ entry: MateHeartbeatMateState) -> String {
        guard let last = entry.lastRunAt else { return "No check-ins yet." }
        let count = entry.runCount == 1 ? "1 check-in" : "\(entry.runCount) check-ins"
        let when = last.formatted(.relative(presentation: .named))
        return "Last checked in \(when) · \(count) so far" + (entry.lastStatus.map { " · \($0)" } ?? "")
    }
}
