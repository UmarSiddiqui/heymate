//
//  OnboardingWindow.swift
//  HeyMate
//
//  The welcome tour's window: centered, dark, one step at a time, with
//  Back, progress dots and Skip along the top. The steps themselves live
//  in OnboardingTour; this file is the window and how each step looks.
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    /// Sized for the tallest steps (voice grid, interview); the short steps
    /// fill the rest with HeyMate itself rather than empty space.
    static let contentSize = CGSize(width: 620, height: 600)

    private weak var companionManager: CompanionManager?
    private var window: NSWindow?
    private var tour: OnboardingTour?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(restart: Bool) {
        guard let companionManager else { return }
        if restart || window == nil {
            window?.delegate = nil
            window?.close()
            let tour = OnboardingTour(companionManager: companionManager, restart: restart)
            tour.onFinish = { [weak self] in self?.closeAfterFinish() }
            self.tour = tour
            window = makeWindow(tour: tour)
            tour.begin()
        } else if let tour, window?.isVisible == false {
            tour.begin()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func closeAfterFinish() {
        window?.delegate = nil
        window?.close()
        window = nil
        tour = nil
    }

    private func makeWindow(tour: OnboardingTour) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to HeyMate"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(DS.Colors.background)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingRootView(tour: tour))
        window.center()
        return window
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closed partway: keep the place for next time, stop listening now.
        tour?.suspend()
        window = nil
        tour = nil
    }
}

// MARK: - Root

struct OnboardingRootView: View {
    @ObservedObject var tour: OnboardingTour
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 14)
                .padding(.horizontal, 20)
            OnboardingVoiceDownloadLine(isOnVoiceStep: tour.step == .voice)
                .padding(.top, 6)

            ZStack {
                stepView(tour.step)
                    .id(tour.step)
                    .transition(transition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A step taller than the window is cut here, never by pushing
            // the header and Continue out of the window.
            .clipped()
            .padding(.horizontal, 36)

            footer
                .padding(.bottom, 26)
        }
        .frame(width: OnboardingWindowController.contentSize.width,
               height: OnboardingWindowController.contentSize.height)
        .background(DS.Colors.background)
        .preferredColorScheme(.dark)
    }

    private var transition: AnyTransition {
        if accessibilityReduceMotion { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 30).combined(with: .opacity),
            removal: .offset(x: -30).combined(with: .opacity)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button {
                tour.back()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .dsIconHitArea()
            }
            .buttonStyle(.plain)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textSecondary)
            .opacity(tour.canGoBack ? 1 : 0)
            .disabled(!tour.canGoBack)
            .focusEffectDisabled()
            .pointerCursor()
            .frame(width: 116, alignment: .leading)

            Spacer()
            progressDots
            Spacer()

            HStack(spacing: DS.Spacing.sm) {
                OnboardingMusicToggle(music: tour.music)
                Button { tour.skip() } label: {
                    Text("Skip tour").dsIconHitArea()
                }
                    .buttonStyle(.plain)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .opacity(tour.step == .reveal ? 0 : 1)
                    .disabled(tour.step == .reveal)
                    .pointerCursor()
                    .help("You can replay the tour from Settings › General")
                    .focusEffectDisabled()
            }
            .frame(width: 116, alignment: .trailing)
        }
        // Clear of the traffic lights.
        .padding(.leading, 56)
    }

    /// Thirteen dots said "long" and nothing else. Three named chapters
    /// say where you are and what's left.
    private var progressDots: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(OnboardingChapter.allCases) { chapter in
                let fill = chapter.progress(at: tour.step)
                let isCurrent = chapter.contains(tour.step)
                VStack(spacing: 5) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous).fill(DS.Colors.surface3)
                            Capsule(style: .continuous)
                                .fill(DS.Colors.textPrimary.opacity(isCurrent ? 0.92 : 0.55))
                                .frame(width: max(fill > 0 ? 4 : 0, proxy.size.width * fill))
                        }
                    }
                    .frame(width: 72, height: 4)
                    Text(chapter.title)
                        .font(DS.Fonts.micro)
                        .foregroundColor(isCurrent ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                }
            }
        }
        .animation(accessibilityReduceMotion ? nil : DS.Animation.controlSpring, value: tour.stepIndex)
        .accessibilityElement()
        .accessibilityLabel("\(OnboardingChapter.of(tour.step).title), step \(tour.stepIndex + 1) of \(tour.stepCount)")
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch tour.step {
        case .permissions:
            // The walkthrough has its own buttons.
            EmptyView()
        case .interview where !tour.isStepDone:
            // Answer chips, the composer and "Skip questions" are the
            // actions here; a dead Continue under them is only noise.
            Button("Continue") {}
                .dsCapsuleButtonStyle(.primary)
                .hidden()
                .accessibilityHidden(true)
        case .reveal:
            Button("Start using HeyMate") { tour.finish(openingHome: true) }
                .dsCapsuleButtonStyle(.primary)
                .keyboardShortcut(.defaultAction)
        default:
            Button(tour.stepIndex == 0 ? "Let's go" : "Continue") { tour.next() }
                .dsCapsuleButtonStyle(.primary)
                .disabled(!tour.isStepDone)
                .keyboardShortcut(.defaultAction)
                .help(tour.isStepDone ? "" : "Do the step above, or Skip tour")
        }
    }

    // MARK: Steps

    @ViewBuilder
    private func stepView(_ step: OnboardingStep) -> some View {
        switch step {
        case .voice:
            OnboardingVoiceFirstStep(tour: tour)
        case .hello:
            OnboardingHelloStep(name: tour.heardName, tour: tour)
        case .permissions:
            OnboardingStepFrame(title: "A few permissions", subtitle: "One at a time. Each one says what it's for.") {
                PermissionWalkthrough(onFinish: { tour.permissionsFinished() })
                    .frame(maxWidth: 440)
            }
        case .ai:

                OnboardingMateAgentSetupStep(tour: tour)

        case .talk:
            OnboardingStageFrame(
                tour: tour,
                title: "This is how you talk to me",
                subtitle: "Hold the keys, say your name, then let go. I listen the whole time you hold them."
            ) {
                OnboardingShortcutPrompt(keys: tour.talkKeys, verb: "Hold", phrase: "My name is …")
                OnboardingStatusLine(text: tour.status ?? "waiting for you…", isDone: tour.isStepDone)
                // The mic check used to be its own step; hearing your name
                // is the check. If nothing comes through, switch mics here.
                if !tour.isStepDone { OnboardingMicPicker() }
            }
        case .interview:
            OnboardingInterviewStep(tour: tour)
        case .showMe:
            OnboardingStageFrame(
                tour: tour,
                title: "Here's how I'd help you",
                subtitle: "I'll draw right on your screen, then show what that looks like in your week."
            ) {
                OnboardingShortcutPrompt(keys: tour.talkKeys, verb: "Hold", phrase: "Show me how you'd help me")
                OnboardingStatusLine(text: tour.status ?? "waiting for you…", isDone: tour.isStepDone)
            }
        case .point:
            OnboardingStageFrame(
                tour: tour,
                title: "Ask about your screen",
                subtitle: "Only when you ask. Hold the keys and ask about anything you're looking at. Circle part of it while you hold them to ask about just that."
            ) {
                OnboardingShortcutPrompt(keys: tour.talkKeys, verb: "Hold", phrase: "What's interesting here?")
                Text("Tip: circle something with the pointer while you hold the keys.")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                OnboardingStatusLine(text: tour.status ?? (tour.isStepDone ? "Ask another, or continue." : "waiting for you…"),
                                     isDone: tour.isStepDone)
            }
        case .kickoff:
            if tour.createdMates.isEmpty {
                OnboardingFirstTaskStep(tour: tour, manager: tour.companionManager)
            } else {
                OnboardingKickoffStep(tour: tour)
            }
        case .reveal:
            OnboardingRevealStep(tour: tour)
        }
    }
}

// MARK: - Pieces

private struct OnboardingMateAgentSetupStep: View {
    @ObservedObject var tour: OnboardingTour
    @AppStorage(MateAgentEngineConfiguration.executablePathKey) private var executablePath = ""
    @AppStorage(MateAgentEngineConfiguration.profilePathKey) private var profilePath = MateAgentEngineConfiguration.defaultProfilePath
    @AppStorage(MateAgentEngineConfiguration.runtimePathKey) private var runtimePath = ""
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("Connect HeyMate Agent")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Use a private HeyMate agent profile. Sign in with ChatGPT for its Codex provider, or connect an OpenAI or Anthropic API key. API keys have separate usage billing.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                MateAgentSetupPane(executablePath: $executablePath, profilePath: $profilePath,
                    runtimePath: $runtimePath, isWorking: $isWorking,
                    onReady: { tour.mateAgentReadinessChanged($0) })
                OnboardingStatusLine(text: tour.status ?? "Connect HeyMate Agent to continue, or skip setup.", isDone: tour.isStepDone)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.vertical, 20)
        }
    }
}

/// Title, subtitle, then the step's own content in the middle.
struct OnboardingStepFrame<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        // Centered top to bottom, a little high, so short steps don't
        // hang off the top of an empty window.
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            .padding(.top, 26)
            content
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
    }
}

/// A short, do-one-thing step: a headline at the top, the keys in the
/// middle, and HeyMate itself at the bottom telling you what to do. The
/// face and its words fill the window with something alive instead of
/// empty space, and the instruction is said once, by HeyMate, not
/// printed twice. Anyone who chose typing still reads it in the bubble.
struct OnboardingStageFrame<Content: View>: View {
    @ObservedObject var tour: OnboardingTour
    let title: String
    /// What the bubble says until HeyMate speaks this step's line.
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, 22)
            Spacer(minLength: 8)
            content
            Spacer(minLength: 8)
            OnboardingStage(tour: tour, manager: tour.companionManager, fallback: subtitle)
                .padding(.bottom, 8)
        }
    }
}

/// HeyMate's face with a speech bubble beside it: its answer when there
/// is one, otherwise the line it just said for this step.
struct OnboardingStage: View {
    @ObservedObject var tour: OnboardingTour
    @ObservedObject var manager: CompanionManager
    var fallback: String?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var line: String? { tour.lastAnswer ?? tour.speech ?? fallback }

    private var expression: MateFaceExpression {
        if !manager.state.isIdle { return .live(manager.state) }
        return tour.isStepDone ? .success : .idle
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            OnboardingFace(manager: manager, size: 76, expression: expression)
            if let line {
                OnboardingSpeechBubble(text: line)
                    .id(line)
                    .transition(accessibilityReduceMotion ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.92, anchor: .bottomLeading)))
            }
        }
        .frame(maxWidth: 500, alignment: line == nil ? .center : .leading)
        .animation(accessibilityReduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.85), value: line)
    }
}

/// A speech bubble whose lower-left corner points back at the face.
struct OnboardingSpeechBubble: View {
    let text: String

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 16, bottomLeadingRadius: 4, bottomTrailingRadius: 16, topTrailingRadius: 16,
            style: .continuous
        )
        Text(text)
            .font(DS.Fonts.bodyLarge)
            .foregroundColor(DS.Colors.textPrimary)
            .lineLimit(7)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(shape.fill(DS.Colors.surface2))
            .overlay(shape.strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
            .padding(.bottom, 30)
            .accessibilityLabel("HeyMate says: \(text)")
    }
}

/// "Hold [ctrl] [option] and say …" with big keys and the phrase in a chip.
struct OnboardingShortcutPrompt: View {
    let keys: [String]
    let verb: String
    let phrase: String

    var body: some View {
        HStack(spacing: 12) {
            Text(verb)
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    OnboardingKeyCap(label: key)
                }
            }
            Text(phrase)
                .font(DS.Fonts.body.weight(.medium))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule(style: .continuous).fill(DS.Colors.accent.opacity(0.16)))
                .overlay(Capsule(style: .circular).strokeBorder(DS.Colors.accent.opacity(0.4), lineWidth: 1))
        }
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingKeyCap: View {
    let label: String

    var body: some View {
        if label == "×2" {
            Text("×2")
                .font(DS.Fonts.caption.weight(.semibold))
                .foregroundColor(DS.Colors.textTertiary)
        } else {
            VStack(spacing: 2) {
                Text(KeyCapSymbols.symbol(for: label))
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .foregroundColor(DS.Colors.textPrimary)
            .frame(width: 58, height: 58)
            // The key's drop edge belongs to the key, not its letters.
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface3)
                .shadow(color: .black.opacity(0.35), radius: 0, y: 2))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
        }
    }
}

struct OnboardingStatusLine: View {
    let text: String
    let isDone: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isDone {
                Image(systemName: "checkmark.circle.fill").foregroundColor(DS.Colors.success)
            }
            Text(text)
                .foregroundColor(isDone ? DS.Colors.textPrimary : DS.Colors.textTertiary)
        }
        .font(DS.Fonts.caption)
        .animation(.easeOut(duration: DS.Animation.normal), value: text)
    }
}

struct OnboardingBubble: View {
    let text: String
    let speaker: OnboardingInterviewLine.Speaker

    var body: some View {
        Text(text)
            .font(DS.Fonts.body)
            .foregroundColor(speaker == .heyMate ? DS.Colors.textPrimary : DS.Colors.textOnAccent)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(speaker == .heyMate ? DS.Colors.surface3 : DS.Colors.accent)
            )
            .frame(maxWidth: .infinity, alignment: speaker == .heyMate ? .leading : .trailing)
    }
}

/// HeyMate's face for the tour: the person's own HeyMate mate, so the
/// face they meet here is the one in the notch and the sidebar.
struct OnboardingFace: View {
    @ObservedObject var manager: CompanionManager
    var size: CGFloat = 76
    var expression: MateFaceExpression = .idle

    /// Before the mate list loads, a stand-in with the default Blobatar.
    private static let standIn: Mate = {
        var mate = Mate(id: UUID(uuidString: "6E6D8F1A-2C3B-4A5D-9E0F-1A2B3C4D5E6F")!, name: Mate.defaultName,
                        job: Mate.defaultJob, pinned: false, archived: false, unreadCount: 0,
                        createdAt: .distantPast, updatedAt: .distantPast, memoryNote: "", folderPath: nil)
        mate.faceAssetName = BlobatarCharacter.faces[0].assetName
        return mate
    }()

    private var mate: Mate {
        manager.mates.first { $0.id == manager.mateDirectory.defaultMateID } ?? Self.standIn
    }

    var body: some View {
        MateFaceView(mate: mate, size: size, expression: expression)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A mate the interview made: face, name and the job it was given.
struct OnboardingMateCard: View {
    let mate: Mate

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            MateFaceView(mate: mate, size: 36, expression: .idle)
            VStack(alignment: .leading, spacing: 2) {
                Text(mate.name)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(mate.job)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
            .strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hello

struct OnboardingHelloStep: View {
    var name: String?
    var tour: OnboardingTour? = nil
    @ObservedObject private var analytics = HeyMateAnalytics.shared
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    /// The words arrive after the hello trace, one beat at a time.
    @State private var revealed = 0

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 8)
            HeyMateHelloTrace(lineWidth: 4, duration: 2.6)
                .frame(width: 180, height: 120)
                .cueMotion(.boot)
            Text(name.map { "Hey \($0)! I'm your AI Mate." } ?? "Hey! I'm your AI Mate.")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .opacity(revealed >= 1 ? 1 : 0)
                .offset(y: revealed >= 1 ? 0 : 8)
            Text("This is the start of a great friendship. I live in your notch, ask me about anything on your screen, and I'll point at the answer.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .opacity(revealed >= 2 ? 1 : 0)
                .offset(y: revealed >= 2 ? 0 : 8)
            Text("I only look at your screen when you ask. Screenshots are never stored.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .opacity(revealed >= 3 ? 1 : 0)
            if let tour {
                OnboardingTypingChoice(tour: tour)
                    .opacity(revealed >= 3 ? 1 : 0)
            }
            if analytics.isAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Share product diagnostics", isOn: Binding(
                        get: { analytics.isOptedIn }, set: { analytics.setOptedIn($0) }
                    ))
                    Text(UsageAnalytics.disclosure)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 420)
                .padding(.top, 12)
                .opacity(revealed >= 3 ? 1 : 0)
            }
            Spacer(minLength: 0)
        }
        .task {
            guard !accessibilityReduceMotion else {
                revealed = 3
                return
            }
            for step in 1...3 {
                try? await Task.sleep(for: .seconds(step == 1 ? 1.8 : 0.9))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 1.1)) { revealed = step }
            }
        }
    }
}

/// Mutes or brings back the tour's background music.
struct OnboardingMusicToggle: View {
    @ObservedObject var music: OnboardingMusic

    var body: some View {
        Button(action: music.toggleMuted) {
            Image(systemName: music.isMuted ? "speaker.slash" : "speaker.wave.2")
                .font(DS.Glyph.small)
        }
        .dsToolbarIconButtonStyle()
        .focusEffectDisabled()
        .help(music.isMuted ? "Play music" : "Mute music")
        .accessibilityLabel(music.isMuted ? "Play background music" : "Mute background music")
    }
}

// MARK: - Interview

struct OnboardingInterviewStep: View {
    @ObservedObject var tour: OnboardingTour
    @ObservedObject var manager: CompanionManager
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @FocusState private var isTyping: Bool

    init(tour: OnboardingTour) {
        self.tour = tour
        self.manager = tour.companionManager
    }

    private var faceExpression: MateFaceExpression {
        if tour.isInterviewThinking { return .thinking }
        if !manager.state.isIdle { return .live(manager.state) }
        return tour.isStepDone ? .success : .idle
    }

    private var answered: Int { min(tour.interviewAnswerCount, OnboardingInterview.answerCount) }

    var body: some View {
        VStack(spacing: 14) {
            header
            conversation
            if tour.isStepDone {
                result
            } else {
                answerArea
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: 500)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            OnboardingFace(manager: manager, size: 64, expression: faceExpression)
            Text("I'm curious about you")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            HStack(spacing: 8) {
                Text(tour.isStepDone ? "Thanks. That's all I needed." : "Three quick questions, so I'm useful from day one.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                if !tour.isStepDone {
                    questionMeter
                }
            }
        }
        .padding(.top, 10)
    }

    private var questionMeter: some View {
        HStack(spacing: 3) {
            ForEach(0..<OnboardingInterview.answerCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index < answered ? DS.Colors.textPrimary : DS.Colors.surface4)
                    .frame(width: 12, height: 3)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(answered) of \(OnboardingInterview.answerCount) answered")
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(tour.interviewLines) { line in
                        OnboardingBubble(text: line.text, speaker: line.speaker)
                            .id(line.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if tour.isInterviewThinking {
                        OnboardingTypingBubble()
                            .id("thinking")
                            .transition(.opacity)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: tour.interviewLines.count) { _, _ in
                withAnimation(accessibilityReduceMotion ? nil : .easeOut(duration: DS.Animation.normal)) {
                    proxy.scrollTo(tour.interviewLines.last?.id, anchor: .bottom)
                }
            }
            .onChange(of: tour.isInterviewThinking) { _, thinking in
                guard thinking else { return }
                withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
        .mask(
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                   .init(color: .black, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: Answering

    private var answerArea: some View {
        VStack(spacing: 10) {
            if !tour.interviewSuggestions.isEmpty {
                OnboardingWrapLayout(spacing: 8) {
                    ForEach(tour.interviewSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { tour.chooseSuggestion(suggestion) }
                            .dsCapsuleButtonStyle(.secondary)
                            .disabled(tour.isInterviewThinking)
                            .help("Answer with this")
                    }
                }
                .transition(.opacity)
            }

            HStack(spacing: 8) {
                TextField("Type your answer", text: $tour.typedAnswer)
                    .textFieldStyle(.plain)
                    .font(DS.Fonts.bodyLarge)
                    .focused($isTyping)
                    .focusEffectDisabled()
                    .onSubmit { tour.submitTypedAnswer() }
                    .disabled(tour.isInterviewThinking)
                Button {
                    tour.submitTypedAnswer()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(DS.Glyph.small)
                        .foregroundColor(canSend ? DS.Colors.textOnAccent : DS.Colors.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(canSend ? DS.Colors.accent : DS.Colors.surface3))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .pointerCursor(isEnabled: canSend)
                .accessibilityLabel("Send answer")
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background {
                // A stroked continuous capsule this short draws stray
                // flat edges past its curve; the circular one doesn't.
                Capsule(style: .circular)
                    .fill(DS.Colors.surface1)
                    .strokeBorder(isTyping ? DS.Colors.borderStrong : DS.Colors.borderSubtle, lineWidth: 1)
            }

            HStack(spacing: 6) {
                Text("or hold")
                ForEach(Array(tour.talkKeys.enumerated()), id: \.offset) { _, key in
                    Text(KeyCapSymbols.symbol(for: key) + " " + key)
                        .font(DS.Fonts.keycap)
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.Colors.surface2))
                }
                Text("and say it")
                if let status = tour.status, !status.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("· \(status)").foregroundColor(DS.Colors.textSecondary)
                }
                Spacer(minLength: 0)
                Button("Skip questions") { tour.skipInterview() }
                    .dsCapsuleButtonStyle(.quiet)
                    .help("Move on. No mates are made from a skipped interview.")
            }
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textTertiary)
        }
        .animation(accessibilityReduceMotion ? nil : .easeOut(duration: DS.Animation.normal), value: tour.interviewSuggestions)
    }

    private var canSend: Bool {
        !tour.isInterviewThinking && !tour.typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Result

    @ViewBuilder
    private var result: some View {
        let mates = tour.createdMates
        if mates.isEmpty {
            OnboardingStatusLine(text: tour.status ?? "Got it. On to the fun part.", isDone: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // The conversation already says it; a tour resumed from
                // before transcripts were kept needs the line here.
                if tour.interviewLines.isEmpty {
                    Text("I made you \(mates.count == 1 ? "a mate" : "\(mates.count) mates"). They're in your sidebar.")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                ForEach(mates) { mate in
                    OnboardingMateCard(mate: mate)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// HeyMate is writing back: three dots that breathe.
struct OnboardingTypingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        TimelineView(.animation(paused: accessibilityReduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(DS.Colors.textSecondary)
                        .frame(width: 6, height: 6)
                        .opacity(accessibilityReduceMotion ? 0.7 : 0.35 + 0.65 * max(0, sin(time * 5 - Double(index) * 0.7)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.Colors.surface3))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("HeyMate is thinking")
    }
}

/// Lays chips out in rows, centered, wrapping when a row is full.
struct OnboardingWrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if added > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Reveal

struct OnboardingRevealStep: View {
    @ObservedObject var tour: OnboardingTour

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 16)
            OnboardingFace(manager: tour.companionManager, size: 72, expression: .success)
            Text(tour.heardName.map { "You're all set, \($0)." } ?? "You're all set.")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Hold \(PushToTalkShortcut.talk.displayText) any time and tell me what you need. I'm up in the notch.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if tour.isTypeShortcutOn {
                HStack(spacing: 6) {
                    Text("Rather type? Double-tap")
                    // The labels spell the double tap out (the key twice);
                    // one cap plus "double-tap" says it once.
                    if let key = tour.typeKeys.first(where: { $0 != "×2" }) {
                        Text(KeyCapSymbols.symbol(for: key) + " " + key)
                            .font(DS.Fonts.keycap)
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.Colors.surface2))
                    }
                    Text("and a box opens in the notch.")
                }
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
            }
            if !tour.prefersTyping { OnboardingVoiceRow() }
            let mates = tour.createdMates
            if !mates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your new mates, made from what you told me")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                    ForEach(mates) { mate in
                        OnboardingMateCard(mate: mate)
                    }
                }
                .frame(maxWidth: 440)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Voice

/// "I'd rather type" on the first page: the tour goes quiet and HeyMate
/// starts in silent mode. It used to sit on the voice step.
struct OnboardingTypingChoice: View {
    @ObservedObject var tour: OnboardingTour

    var body: some View {
        Button {
            tour.setPrefersTyping(!tour.prefersTyping)
        } label: {
            Label("I'd rather type. No voice.", systemImage: tour.prefersTyping ? "checkmark.square.fill" : "square")
                .foregroundColor(DS.Colors.textSecondary)
                .font(DS.Fonts.body)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("HeyMate stays quiet and you type. Change this in Settings › Voice › Advanced.")
    }
}

/// Which microphone HeyMate listens with, for when the talk step hears
/// nothing. Same setting as Settings › Voice.
struct OnboardingMicPicker: View {
    @State private var devices: [AudioInputDevice] = []
    @State private var selected = AudioInputDeviceCatalog.selectedDeviceUID

    var body: some View {
        HStack(spacing: 6) {
            Text("Not hearing you? Mic:")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
            Picker("Microphone", selection: $selected) {
                Text("System default").tag(AudioInputDeviceCatalog.systemDefaultDeviceID)
                ForEach(devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .onAppear { devices = AudioInputDeviceCatalog.availableInputDevices() }
        .onChange(of: selected) { _, uid in AudioInputDeviceCatalog.selectedDeviceUID = uid }
    }
}

/// The new mates each offer one first job; the person says yes or no.
/// Yes hands the job to that mate, which works in its own chat while the
/// tour finishes, so the tour ends with mates already working.
struct OnboardingKickoffStep: View {
    @ObservedObject var tour: OnboardingTour

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                Text("Your mates have ideas")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Say yes to anything you want started. It runs in that mate's chat, and asks before anything risky.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            .padding(.top, 22)
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                ForEach(tour.offeredJobs, id: \.mate.id) { offer in
                    OnboardingJobOfferCard(mate: offer.mate, job: offer.job,
                                           decision: tour.kickoffDecisions[offer.mate.name],
                                           onYes: { tour.startFirstJob(for: offer.mate) },
                                           onNo: { tour.declineFirstJob(for: offer.mate) })
                }
            }
            .frame(maxWidth: 500)
            Spacer(minLength: 0)
            OnboardingStatusLine(text: tour.status ?? " ", isDone: tour.isStepDone)
                .padding(.bottom, 14)
        }
    }
}

struct OnboardingJobOfferCard: View {
    let mate: Mate
    let job: String
    let decision: Bool?
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                MateFaceView(mate: mate, size: 32, expression: decision == true ? .thinking : .idle)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mate.name)
                        .font(DS.Fonts.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(job)
                        .font(DS.Fonts.bodyLarge)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                switch decision {
                case .some(true):
                    Label("On it", systemImage: "checkmark.circle.fill")
                        .font(DS.Fonts.caption.weight(.medium))
                        .foregroundColor(DS.Colors.success)
                case .some(false):
                    Text("Not now")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                case .none:
                    Button("No", action: onNo)
                        .dsCapsuleButtonStyle(.quiet)
                    Button("Yes, do it", action: onYes)
                        .dsCapsuleButtonStyle(.primary)
                }
            }
        }
        .padding(DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
            .strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
        .opacity(decision == false ? 0.6 : 1)
        .animation(.easeOut(duration: DS.Animation.normal), value: decision)
    }
}

/// While the on-device voice downloads, a thin line under the header on
/// every step, so it's clear it keeps going.
struct OnboardingVoiceDownloadLine: View {
    let isOnVoiceStep: Bool
    @ObservedObject private var store = OnDeviceVoiceModelStore.shared

    var body: some View {
        Group {
            if isOnVoiceStep {
                // The voice step shows the download in full.
                EmptyView()
            } else if store.isDownloading {
                HStack(spacing: 8) {
                    Text(isOnVoiceStep ? "Downloading my voice. Keep going, it finishes in the background." : "Downloading my voice…")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                    if let progress = store.combinedProgress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 120)
                        Text("\(Int(progress * 100))%")
                            .font(DS.Fonts.caption.monospacedDigit())
                            .foregroundColor(DS.Colors.textTertiary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            } else if let failure = store.lastFailureMessage {
                Text("Voice download stopped: \(failure)")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
                    .lineLimit(1)
            }
        }
        .frame(height: 18)
    }
}

/// The tour's first step: pick HeyMate's voice, and see plainly what the
/// on-device download is doing. Hearing (speech recognition) and the voice
/// download separately at launch; each has its own row, so a slow or failed
/// download is never a mystery. Nothing here uses the Mac system voice.
struct OnboardingVoiceFirstStep: View {
    @ObservedObject var tour: OnboardingTour
    @ObservedObject private var store = OnDeviceVoiceModelStore.shared
    @State private var selectedID = SpeechStylePreferences.onDeviceVoice
    @State private var previewClient: PhononTTSClient?
    @State private var previewingID: String?
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text(store.isEverythingInstalled || !store.isSupportedOnThisMac ? "Pick my voice" : "Getting me ready")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("I listen and talk right on this Mac, so it works offline and nothing you say leaves it. It downloads once.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            .padding(.top, 18)

            downloadCard

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(OnDeviceVoiceOption.all) { option in
                    tile(option)
                }
            }
            .disabled(!store.speakState.isInstalled || tour.prefersTyping)
            .opacity(store.speakState.isInstalled && !tour.prefersTyping ? 1 : 0.4)
            .overlay {
                if !store.speakState.isInstalled && !store.speakState.isUnsupported {
                    Text("Voices unlock as soon as my voice is ready.")
                        .font(DS.Fonts.caption.weight(.medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule(style: .continuous).fill(DS.Colors.surface3))
                }
            }

            OnboardingTypingChoice(tour: tour)
            Spacer(minLength: 0)
            if !tour.isStepDone {
                HStack(spacing: 8) {
                    OnboardingStatusLine(text: tour.status ?? "Getting ready…", isDone: false)
                    Button("Start without waiting") { tour.startWithoutWaiting() }
                        .dsCapsuleButtonStyle(.quiet)
                        .help("Talking to me won't work until hearing is ready. It keeps downloading in the background.")
                }
            } else if let status = tour.status {
                OnboardingStatusLine(text: status, isDone: true)
            }
        }
        .frame(maxWidth: 520)
        .onAppear { store.refreshInstalledState() }
        .onDisappear { previewClient?.stopPlayback() }
    }

    // MARK: Download

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(icon: "ear", title: "Hearing you", detail: "Turns your voice into text", state: store.listenState)
            Divider().overlay(DS.Colors.borderSubtle)
            row(icon: "waveform", title: "My voice", detail: "How I talk back · comes with the app", state: store.speakState)
            if let footnote {
                Text(footnote)
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.md)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous).fill(DS.Colors.surface1))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
            .strokeBorder(DS.Colors.borderSubtle, lineWidth: 0.5))
    }

    private var footnote: String? {
        if store.isEverythingInstalled { return "Ready. Stored on this Mac and works offline." }
        if !store.isSupportedOnThisMac {
            return "This Mac can't run on-device voice. I'll show my words as text; add an ElevenLabs key in Settings › Voice if you'd like me to talk."
        }
        let size = "One-time download, \(OnDeviceVoiceModelStore.approximateDownloadSizeDescription)."
        if store.isDownloading {
            return size + " The tour starts as soon as it's done."
        }
        if store.lastFailureMessage != nil {
            return size + " Check your connection and retry, or start anyway."
        }
        return size + " The tour starts as soon as it's ready."
    }

    private func row(icon: String, title: String, detail: String, state: OnDeviceVoiceModelState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(DS.Glyph.regular)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DS.Fonts.headline).foregroundColor(DS.Colors.textPrimary)
                Text(detail).font(DS.Fonts.caption).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 8)
            status(for: state)
        }
    }

    @ViewBuilder
    private func status(for state: OnDeviceVoiceModelState) -> some View {
        switch state {
        case .installed:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(DS.Fonts.caption.weight(.medium))
                .foregroundColor(DS.Colors.success)
        case .downloading(let fraction):
            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 120)
                    Text("\(Int(fraction * 100))%")
                        .font(DS.Fonts.numeric)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 34, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Preparing…").font(DS.Fonts.caption).foregroundColor(DS.Colors.textSecondary)
                }
            }
        case .notInstalled:
            if store.isDownloading {
                Text("Waiting its turn").font(DS.Fonts.caption).foregroundColor(DS.Colors.textTertiary)
            } else {
                Button("Set up now") { tour.downloadOnDeviceVoice() }
                    .dsCapsuleButtonStyle(.secondary)
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text("Stopped: \(message)")
                    .font(DS.Fonts.caption)
                    .foregroundColor(DS.Colors.warningText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 170, alignment: .trailing)
                    .help(message)
                Button("Retry") { tour.downloadOnDeviceVoice() }
                    .dsCapsuleButtonStyle(.secondary)
            }
        case .unsupported:
            Text("Not on this Mac").font(DS.Fonts.caption).foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: Voices

    private func tile(_ option: OnDeviceVoiceOption) -> some View {
        let selected = option.id == selectedID
        let speaking = option.id == previewingID
        let shape = RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
        return Button {
            selectedID = option.id
            SpeechStylePreferences.onDeviceVoice = option.id
            preview(option)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: speaking ? "waveform" : option.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(option.tint)
                    .symbolEffect(.variableColor.iterative, isActive: speaking && !accessibilityReduceMotion)
                    .shadow(color: option.tint.opacity(selected ? 0.7 : 0.35), radius: selected ? 8 : 4)
                    .frame(height: 22)
                Text(option.name)
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundColor(selected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                shape.fill(DS.Colors.surface1)
                shape.fill(option.tint.opacity(selected ? 0.16 : 0.05))
            }
            .overlay(shape.strokeBorder(selected ? option.tint.opacity(0.9) : DS.Colors.borderSubtle,
                                        lineWidth: selected ? 1.5 : 0.5))
            // The chosen voice glows in its own colour.
            .shadow(color: option.tint.opacity(selected ? 0.45 : 0), radius: 12)
            .scaleEffect(selected && !accessibilityReduceMotion ? 1.03 : 1)
            .animation(accessibilityReduceMotion ? nil : DS.Animation.controlSpring, value: selected)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel("\(option.name) voice")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func preview(_ option: OnDeviceVoiceOption) {
        previewClient?.stopPlayback()
        guard PhononEngine.unsupportedReason == nil, store.speakState.isInstalled else { return }
        let client = previewClient ?? PhononTTSClient()
        previewClient = client
        previewingID = option.id
        Task {
            try? await client.speakText("Hi, I'm \(option.name). This is how I'll sound.")
            try? await Task.sleep(for: .seconds(2.2))
            if previewingID == option.id { previewingID = nil }
        }
    }
}

/// One line to pick HeyMate's voice: a menu of the on-device voices, and a
/// short preview each time the choice changes. Same setting and preview as
/// Settings › Voice. Shown only once the voice has downloaded.
struct OnboardingVoiceRow: View {
    @ObservedObject private var store = OnDeviceVoiceModelStore.shared
    @State private var selectedID = SpeechStylePreferences.onDeviceVoice
    @State private var previewClient: PhononTTSClient?

    var body: some View {
        if store.speakState.isInstalled {
            HStack(spacing: 8) {
                Text("My voice")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                Picker("Voice", selection: $selectedID) {
                    ForEach(OnDeviceVoiceOption.all) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    preview(selectedID)
                } label: {
                    Image(systemName: "play.fill").font(DS.Glyph.small)
                }
                .dsToolbarIconButtonStyle()
                .help("Hear this voice")
                .accessibilityLabel("Hear this voice")
            }
            .onChange(of: selectedID) { _, id in
                SpeechStylePreferences.onDeviceVoice = id
                preview(id)
            }
            .onDisappear { previewClient?.stopPlayback() }
        }
    }

    private func preview(_ id: String) {
        previewClient?.stopPlayback()
        guard PhononEngine.unsupportedReason == nil,
              let option = OnDeviceVoiceOption.all.first(where: { $0.id == id }) else { return }
        let client = previewClient ?? PhononTTSClient()
        previewClient = client
        Task { try? await client.speakText("Hi, I'm \(option.name). This is how I'll sound.") }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
