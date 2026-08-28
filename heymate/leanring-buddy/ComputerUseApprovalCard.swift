//
//  ComputerUseApprovalCard.swift
//  leanring-buddy
//
//  "I'm about to do this. Yes or no?"
//
//  Deliberately austere. One sentence for the action, one for why, two
//  buttons, and a risk stripe. No countdown, no default-highlighted
//  Approve button that Return would trigger by accident, and no way to
//  say "always allow" — a standing yes to synthesized input is the thing
//  this card exists to prevent.
//

import SwiftUI

struct ComputerUseApprovalCard: View {
    let request: ComputerUseRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 12, weight: .bold))
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

            HStack(spacing: 8) {
                Button("Not now", action: onDeny)
                    .buttonStyle(DSSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)

                Button("Do it", action: onApprove)
                    .buttonStyle(DSPrimaryButtonStyle())
                    // No .defaultAction: approving synthesized input should
                    // take a deliberate click, not a stray Return keypress.
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
