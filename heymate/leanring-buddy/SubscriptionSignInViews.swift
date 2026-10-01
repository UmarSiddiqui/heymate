//
//  SubscriptionSignInViews.swift
//  leanring-buddy
//
//  The notch faces of `SubscriptionSignInCoordinator`: the onboarding
//  question, the status line under it, and the banner a failed question
//  leaves behind. Each observes the coordinator directly — it is a nested
//  object on CompanionManager, so a view observing only the manager would
//  never see the phase change.
//

import AppKit
import SwiftUI

// MARK: - Status

/// Progress, a green check with the account, or what went wrong and the
/// way out. Renders nothing until a run for `executor` has started.
struct SubscriptionSignInStatusView: View {
    @ObservedObject var signIn: SubscriptionSignInCoordinator
    let executor: HeadlessExecutor

    var body: some View {
        if signIn.executor == executor, signIn.phase != .idle {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    statusGlyph
                    Text(signIn.statusLine)
                        .font(DS.Fonts.caption)
                        .foregroundColor(statusColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actionRow
            }
            .animation(.easeOut(duration: DS.Animation.fast), value: signIn.phase)
        }
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch signIn.phase {
        case .checking, .installing, .waitingForBrowser:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(DS.Glyph.small)
                .foregroundColor(DS.Colors.success)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(DS.Glyph.small)
                .foregroundColor(DS.Colors.warningText)
        case .idle:
            EmptyView()
        }
    }

    private var statusColor: Color {
        switch signIn.phase {
        case .ready: return DS.Colors.textPrimary
        case .failed: return DS.Colors.warningText
        default: return DS.Colors.textSecondary
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch signIn.phase {
        case .waitingForBrowser:
            HStack(spacing: 6) {
                if let signInPageURL = signIn.signInPageURL {
                    Button("Open sign-in page") { NSWorkspace.shared.open(signInPageURL) }
                        .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                }
                if signIn.isUsingTerminalFallback {
                    Text("Running in Terminal")
                        .font(DS.Fonts.micro)
                        .foregroundColor(DS.Colors.textTertiary)
                } else {
                    Button("Browser didn't open?") { signIn.continueInTerminal() }
                        .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                        .help("Opens Terminal with the sign-in already running. You only approve it in the browser.")
                }
            }
        case .failed:
            HStack(spacing: 6) {
                Button("Try again") { signIn.begin(executor) }
                    .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                if let manualInstallURL = signIn.manualInstallURL {
                    Button("Download \(SubscriptionSignInCopy.productName(for: executor))") {
                        NSWorkspace.shared.open(manualInstallURL)
                    }
                    .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                } else {
                    Button("Use Terminal") { signIn.continueInTerminal() }
                        .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
                        .help("Opens Terminal with the sign-in already running. You only approve it in the browser.")
                }
            }
        case .idle, .checking, .installing, .ready:
            EmptyView()
        }
    }
}

// MARK: - Onboarding

/// "Which AI do you already pay for?" — between permissions and saying hi.
/// Skippable: Start works whether or not anything was picked.
struct NotchSubscriptionChoiceSection: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var signIn: SubscriptionSignInCoordinator

    @State private var choice: OnboardingAIChoice?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DSSectionLabel(title: "Your AI")

            Text("Which AI do you already pay for?")
                .font(DS.Fonts.headline)
                .foregroundColor(DS.Colors.textPrimary)

            HStack(spacing: 6) {
                ForEach(OnboardingAIChoice.allCases) { option in
                    Button(option.title) { select(option) }
                        .dsCapsuleButtonStyle(choice == option ? .primary : .secondary)
                        .accessibilityAddTraits(choice == option ? .isSelected : [])
                }
            }

            if choice == .neither {
                Text(SubscriptionSignInCopy.neitherExplanation)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let executor = choice?.executor {
                SubscriptionSignInStatusView(signIn: signIn, executor: executor)
            } else {
                Text("HeyMate runs on the plan you already have. No API keys, nothing extra to pay.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            // Returning to this step mid-run shows that run, not a blank pick.
            if choice == nil, let executor = signIn.executor {
                choice = OnboardingAIChoice(executor: executor)
            }
            guard choice == nil else { return }
            // Already signed in? Preselect it so this is one click.
            let found = await companionManager.findSignedInSubscription()
            if choice == nil, let found {
                choice = found
                companionManager.setSelectedBrain(found.brain)
            }
        }
    }

    private func select(_ option: OnboardingAIChoice) {
        choice = option
        companionManager.chooseOnboardingAI(option)
    }
}

/// Start, or Continue once an AI is signed in. Observes the coordinator so
/// the label follows the sign-in.
struct NotchOnboardingStartButton: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var signIn: SubscriptionSignInCoordinator

    var body: some View {
        Button(signIn.phase.isReady ? "Continue" : "Start") {
            companionManager.triggerOnboarding()
        }
        .buttonStyle(DSPrimaryButtonStyle(isFullWidth: true))
    }
}

// MARK: - After a failed question

/// Shown on the notch Home tab when a question failed because the selected
/// AI is signed out or not installed: the fix, one click away, instead of
/// an error to decode.
struct NotchSubscriptionSignInBanner: View {
    @ObservedObject var signIn: SubscriptionSignInCoordinator

    var body: some View {
        if let executor = signIn.attentionExecutor {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: isReady(executor) ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                        .font(DS.Glyph.small)
                        .foregroundColor(isReady(executor) ? DS.Colors.success : DS.Colors.warningText)
                    Text(headline(for: executor))
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        signIn.dismissAttention()
                    } label: {
                        Image(systemName: "xmark")
                            .font(DS.Glyph.micro)
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                }

                if signIn.executor == executor, signIn.phase != .idle, !isReady(executor) {
                    SubscriptionSignInStatusView(signIn: signIn, executor: executor)
                } else if !isReady(executor) {
                    Button(SubscriptionSignInCopy.signInActionTitle(for: executor)) {
                        signIn.begin(executor)
                    }
                    .dsCapsuleButtonStyle(.primary, height: DS.ControlSize.small)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface2.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
    }

    private func isReady(_ executor: HeadlessExecutor) -> Bool {
        signIn.executor == executor && signIn.phase.isReady
    }

    private func headline(for executor: HeadlessExecutor) -> String {
        let product = SubscriptionSignInCopy.productName(for: executor)
        if isReady(executor) {
            return "\(product) is signed in. Ask again."
        }
        return "\(product) isn't signed in on this Mac."
    }
}
