//
//  ComputerUseApprovalCard.swift
//  HeyMate
//
//  "I'm about to do this. How far does the yes go?"
//
//  Not now, this time, this chat, or always. Always is a standing yes to
//  synthesized input, so it is never the Return key and never the button
//  a stray keypress would hit. No countdown.
//

import SwiftUI

struct ComputerUseApprovalCard: View {
    let request: ComputerUseRequest
    /// Hidden when there is no conversation to attach a "this chat" yes to.
    var offersConversationGrant = false
    let onDeny: () -> Void
    let onGrant: (ComputerUseConsentScope) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(DS.Glyph.regular)
                    .foregroundColor(riskColor)
                Text("Approve this?")
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer(minLength: 0)
                Text(request.action.risk.displayName)
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(riskColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(riskColor.opacity(0.16)))
            }

            Text(request.action.approvalDescription)
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if !request.statedReason.isEmpty {
                Text(request.statedReason)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Not now", action: onDeny)
                        .buttonStyle(DSSecondaryButtonStyle())
                        .keyboardShortcut(.cancelAction)

                    Button("This time") { onGrant(.once) }
                        .buttonStyle(DSPrimaryButtonStyle())
                }
                HStack(spacing: 8) {
                    if offersConversationGrant {
                        Button("This chat") { onGrant(.conversation) }
                            .buttonStyle(DSSecondaryButtonStyle())
                    }
                    Button("Always") { onGrant(.always) }
                        .buttonStyle(DSTertiaryButtonStyle())
                    // No .defaultAction on Always — or on the other yeses.
                    // A standing yes to synthesized input must be a click.
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(riskColor.opacity(0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }

    private var riskColor: Color {
        request.action.risk.tintColor
    }
}
