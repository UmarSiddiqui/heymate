//
//  MateHeartbeatViews.swift
//  HeyMate
//
//  The heartbeat's proposal in Waiting on You (Approve, Skip, Adjust). Its
//  per-mate settings live in agent settings › Proactive
//  (MateSettingsProactivePane.swift).
//

import SwiftUI

struct MateProposalRow: View {
    let item: MateInboxItem
    let proposal: MateHeartbeatProposal
    let act: (MateHeartbeatAction) -> Bool
    @State private var actionError: String?
    @State private var showsInstructions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(item.mateName).font(DS.Fonts.caption.weight(.semibold))
                Text("Proposes").font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
                Spacer()
                Text(proposal.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(DS.Fonts.micro).foregroundStyle(DS.Colors.textTertiary)
                Button {
                    MateSettingsRouter.shared.open(mateID: item.mateID, section: .proactive)
                } label: {
                    Image(systemName: "gearshape").font(DS.Glyph.small).foregroundStyle(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Check-in settings for \(item.mateName)")
                .accessibilityLabel("Check-in settings for \(item.mateName)")
            }
            Text(proposal.title).font(DS.Fonts.body)
            Text(proposal.whyNow).font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            if let needsApproval = proposal.needsApproval {
                Label(needsApproval, systemImage: "hand.raised")
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.textSecondary)
            }
            DisclosureGroup("Task instructions", isExpanded: $showsInstructions) {
                Text(proposal.prompt).font(DS.Fonts.caption).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }.font(DS.Fonts.caption)
            HStack {
                if item.isQueuedProposal {
                    Label("Queued until \(item.mateName) is free", systemImage: "clock")
                        .foregroundStyle(DS.Colors.textSecondary)
                    Spacer()
                    Button("Cancel") {
                        actionError = act(.skip) ? nil : "Couldn’t cancel this proposal. Try again."
                    }
                } else {
                    Button("Approve") {
                        actionError = act(.approve) ? nil : "Couldn’t approve this proposal. Try again."
                    }
                    Button("Adjust") { actionError = act(.adjust) ? nil : "Couldn’t open a draft for this proposal. Try again." }
                    Spacer()
                    Button("Skip") { actionError = act(.skip) ? nil : "Couldn’t skip this proposal. Try again." }
                }
            }.font(DS.Fonts.caption)
            if let actionError {
                Text(actionError)
                    .font(DS.Fonts.caption).foregroundStyle(DS.Colors.warningText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 12))
    }
}
