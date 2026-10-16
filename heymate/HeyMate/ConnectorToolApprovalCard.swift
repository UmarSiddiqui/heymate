//
//  ConnectorToolApprovalCard.swift
//  HeyMate
//
//  "The model wants to call this connector tool. Yes or no?" Mirrors
//  `ComputerUseApprovalCard`'s austerity on purpose — the call in plain
//  words, the raw tool and arguments behind Details, two buttons, no
//  default-highlighted Approve that Return could trigger by accident.
//

import SwiftUI

struct ConnectorToolApprovalCard: View {
    let request: ConnectorToolApprovalRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

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
                Text(request.risk.displayName)
                    .font(DS.Fonts.statusWord)
                    .foregroundColor(riskColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(riskColor.opacity(0.16)))
            }

            Text(title)
                .font(DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if request.actions.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(request.actions.enumerated()), id: \.offset) { _, action in
                        Text("• \(action)")
                            .font(DS.Fonts.body)
                            .foregroundColor(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // The raw call stays one click away for anyone who wants to
            // check exactly what will run.
            DisclosureGroup(isExpanded: $showsDetails.withDisclosureSound()) {
                ScrollView {
                    Text("\(request.toolName)\n\n\(request.argumentsSummary)")
                        .font(DS.Fonts.mono)
                        .foregroundColor(DS.Colors.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(.top, 6)
            } label: {
                Text("Details")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
            }

            HStack(spacing: 8) {
                Button("Not now", action: onDeny)
                    .buttonStyle(DSSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)

                Button("Do it", action: onApprove)
                    .buttonStyle(DSPrimaryButtonStyle())
                    // No .defaultAction: approving a connector call should
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

    @State private var showsDetails = false

    /// One action reads as the action itself; several get a count and
    /// the list below. Never the raw tool name.
    private var title: String {
        switch request.actions.count {
        case 0: return "Use \(request.connectorDisplayName)"
        case 1: return request.actions[0]
        default: return "\(request.actions.count) actions with \(request.connectorDisplayName)"
        }
    }

    private var riskColor: Color {
        request.risk.tintColor
    }
}
