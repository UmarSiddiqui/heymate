//
//  ConnectorToolApprovalCard.swift
//  HeyMate
//
//  "The model wants to call this connector tool. Yes or no?" Asked as a
//  question, in the same card language as a job approval in the notch:
//  the permission-ask cue glows the card and springs the tapback off
//  Allow, while the voice says the same question out loud. The raw tool
//  and arguments stay behind Details. No default-highlighted Allow that
//  Return could trigger by accident.
//

import SwiftUI

struct ConnectorToolApprovalCard: View {
    let request: ConnectorToolApprovalRequest
    /// When the card stops waiting. Nil hides the countdown.
    var expiresAt: Date? = nil
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(DS.Glyph.regular)
                    .foregroundColor(DS.Colors.textSecondary)
                    .cueMotion(.permissionAsk, subject: cueSubject)
                Text("\(request.connectorDisplayName) needs your OK")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let expiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(countdown(until: expiresAt, at: context.date))
                            .font(DS.Fonts.numeric)
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }

            Text(ConnectorToolCallDescription.spokenQuestion(for: request))
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
                HStack(spacing: 6) {
                    Text("Details")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(request.risk.displayName)
                        .font(DS.Fonts.statusWord)
                        .foregroundColor(request.risk.tintColor)
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Not now", action: onDeny)
                    .buttonStyle(DSSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)

                Button("Allow", action: onApprove)
                    .buttonStyle(DSPrimaryButtonStyle())
                    .cueMotion(.permissionAsk, part: .prop, subject: cueSubject)
                    // No .defaultAction: approving a connector call should
                    // take a deliberate click, not a stray Return keypress.
            }
        }
        .padding(14)
        .background(Color.black, in: cardShape)
        .dsSurface(.card)
        .cueGlow(.permissionAsk, subject: cueSubject, cornerRadius: DS.CornerRadius.extraLarge)
        .overlay(alignment: .topTrailing) {
            CueProp(kind: .tapback, subject: cueSubject)
                .offset(x: 6, y: -6)
        }
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ConnectorToolCallDescription.spokenQuestion(for: request))
    }

    @State private var showsDetails = false

    /// Matches the subject `ConnectorToolCoordinator` fires its cue with.
    private var cueSubject: String { request.id.uuidString }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
    }

    private func countdown(until expiresAt: Date, at now: Date) -> String {
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now).rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
