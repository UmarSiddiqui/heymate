//
//  MateWakeViews.swift
//  HeyMate
//
//  Where a wake is chosen (the agent builder and agent settings) and where
//  its offers are answered (the notch and the agents rail).
//

import SwiftUI

/// "Nothing" or one kind of wake, an optional filter, and a plain note
/// about what HeyMate watches for it.
struct MateWakeField: View {
    @Binding var kind: MateWakeKind?
    @Binding var match: String

    private var options: [DSMenuOption<MateWakeKind?>] {
        [DSMenuOption<MateWakeKind?>(value: nil, title: "Only when asked")]
            + MateWakeKind.allCases.enumerated().map { index, kind in
                DSMenuOption<MateWakeKind?>(value: kind, title: kind.label, startsGroup: index == 0)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DSMenuPicker(
                accessibilityTitle: "Offers to help when",
                selection: $kind,
                options: options,
                width: 260
            )
            if let kind {
                TextField(kind.matchPrompt, text: $match)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.bodyLarge)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.surface2)
                    )
                    .accessibilityLabel(kind.matchPrompt)
                Text(kind.watchNote + " It asks first, every time.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One offer: who is asking, what for, and a yes or a not now.
struct MateWakeOfferCard: View {
    let offer: MateWakeOffer
    let mate: Mate?
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        // Stacked, not side by side: the notch column is narrow, and a
        // question squeezed beside two buttons loses its subject.
        VStack(alignment: .leading, spacing: DS.Spacing.xs + 2) {
            HStack(alignment: .top, spacing: DS.Spacing.sm + 2) {
                if let mate {
                    MateFaceView(mate: mate, size: DS.ControlSize.regular)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(offer.mateName)
                        .font(DS.Fonts.caption.weight(.semibold))
                        .foregroundColor(DS.Colors.warningText)
                        .lineLimit(1)
                    Text(offer.question)
                        .font(DS.Fonts.control)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: DS.Spacing.xs) {
                Spacer(minLength: 0)
                Button("Not now", action: onDismiss)
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                    .accessibilityLabel("Not now, dismiss \(offer.mateName)'s offer")
                Button("Yes", action: onAccept)
                    .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.small)
                    .accessibilityLabel("Yes, \(offer.mateName): \(offer.question)")
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .accessibilityElement(children: .contain)
    }
}

/// Every offer waiting for an answer. Draws nothing when there are none.
struct MateWakeOffers: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        let offers = MateWakeMatcher.current(companionManager.mateWakeOffers, now: Date())
        if !offers.isEmpty {
            VStack(spacing: DS.Spacing.xs) {
                ForEach(offers) { offer in
                    MateWakeOfferCard(
                        offer: offer,
                        mate: companionManager.mates.first { $0.id == offer.mateID },
                        onAccept: { companionManager.acceptMateWakeOffer(id: offer.id) },
                        onDismiss: { companionManager.dismissMateWakeOffer(id: offer.id) }
                    )
                }
            }
        }
    }
}
