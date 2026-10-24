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
    private static let contentSize = CGSize(width: 640, height: 680)

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
            .padding(.horizontal, 36)

            footer
                .padding(.bottom, 26)
        }
        .frame(width: 640, height: 680)
        .background {
            LinearGradient(
                colors: [Color(hex: "#131820"), Color(hex: "#101112"), DS.Colors.background],
                startPoint: .top, endPoint: .bottom
            )
        }
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
            }
            .buttonStyle(.plain)
            .font(DS.Fonts.caption)
            .foregroundColor(DS.Colors.textSecondary)
            .opacity(tour.canGoBack ? 1 : 0)
            .disabled(!tour.canGoBack)
            .focusEffectDisabled()
            .pointerCursor()
            .frame(width: 80, alignment: .leading)

            Spacer()
            progressDots
            Spacer()

            Button("Skip tour") { tour.skip() }
                .buttonStyle(.plain)
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
                .opacity(tour.step == .reveal ? 0 : 1)
                .disabled(tour.step == .reveal)
                .pointerCursor()
                .help("You can replay the tour from Settings › General")
                .focusEffectDisabled()
                .frame(width: 80, alignment: .trailing)
        }
        // Clear of the traffic lights.
        .padding(.leading, 56)
    }

    private var progressDots: some View {
        HStack(spacing: 5) {
            ForEach(Array(OnboardingStep.allCases.enumerated()), id: \.element) { offset, _ in
                let isCurrent = offset == tour.stepIndex
                Group {
                    if offset <= tour.stepIndex {
                        DSGlassSurface(cornerRadius: 3)
                    } else {
                        Capsule(style: .continuous).fill(DS.Colors.surface3)
                    }
                }
                .frame(width: isCurrent ? 18 : 6, height: 6)
            }
        }
        .animation(accessibilityReduceMotion ? nil : DS.Animation.controlSpring, value: tour.stepIndex)
        .accessibilityElement()
        .accessibilityLabel("Step \(tour.stepIndex + 1) of \(tour.stepCount)")
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        switch tour.step {
        case .permissions:
            // The walkthrough has its own buttons.
            EmptyView()
        case .reveal:
            Button("Start using HeyMate") { tour.finish(openingHome: true) }
                .dsCapsuleButtonStyle(.primary)
                .keyboardShortcut(.defaultAction)
        default:
            Button(tour.step == .hello ? "Let's go" : "Continue") { tour.next() }
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
        case .hello:
            OnboardingHelloStep()
        case .voice:
            OnboardingVoiceStep(tour: tour)
        case .permissions:
            OnboardingStepFrame(title: "A few permissions", subtitle: "One at a time. Each one says what it's for.") {
                PermissionWalkthrough(onFinish: { tour.permissionsFinished() })
                    .frame(maxWidth: 440)
            }
        case .ai:
            if MateEngine.selected() == .hermes {
                OnboardingHermesSetupStep(tour: tour)
            } else {
                OnboardingStepFrame(
                    title: "Pick your AI",
                    subtitle: "HeyMate thinks with the plan you already pay for. No API keys."
                ) {
                    NotchSubscriptionChoiceSection(
                        companionManager: tour.companionManager,
                        signIn: tour.companionManager.subscriptionSignIn
                    )
                    .frame(maxWidth: 440)
                }
            }
        case .mic:
            OnboardingMicStep(tour: tour, micCheck: tour.micCheck)
        case .talk:
            OnboardingStepFrame(
                title: "This is how you talk to me",
                subtitle: "Hold the keys, say your name, then let go. I listen the whole time you hold them."
            ) {
                OnboardingShortcutPrompt(keys: tour.talkKeys, verb: "Hold", phrase: "My name is …")
                OnboardingStatusLine(text: tour.status ?? "waiting for you…", isDone: tour.isStepDone)
            }
        case .interview:
            OnboardingInterviewStep(tour: tour)
        case .point:
            OnboardingStepFrame(
                title: "I can see your screen",
                subtitle: "Only when you ask. Hold the keys and ask about anything you're looking at."
            ) {
                OnboardingShortcutPrompt(keys: tour.talkKeys, verb: "Hold", phrase: "What's interesting on my screen?")
                OnboardingAnswerLine(tour: tour)
            }
        case .circle:
            OnboardingStepFrame(
                title: "Circle it, then ask",
                subtitle: "Hold the circle keys and draw around something. Then hold the talk keys and ask about it."
            ) {
                VStack(spacing: 14) {
                    OnboardingShortcutPrompt(keys: tour.circleKeys, verb: "Hold", phrase: "and draw around it")
                    OnboardingShortcutPrompt(keys: tour.talkKeys, verb: "Then hold", phrase: "What is this?")
                }
                OnboardingAnswerLine(tour: tour)
            }
        case .type:
            OnboardingStepFrame(
                title: "Not in the mood to talk? Type",
                subtitle: "Tap the key twice, quickly, and a box opens in the notch. Same HeyMate, just quieter."
            ) {
                OnboardingShortcutPrompt(keys: tour.typeKeys, verb: "Tap", phrase: "twice, quickly")
                OnboardingStatusLine(text: tour.status ?? "waiting for you…", isDone: tour.isStepDone)
            }
        case .firstTask:
            OnboardingFirstTaskStep(tour: tour, manager: tour.companionManager)
        case .reveal:
            OnboardingRevealStep(tour: tour)
        }
    }
}

// MARK: - Pieces

private struct OnboardingHermesSetupStep: View {
    @ObservedObject var tour: OnboardingTour
    @AppStorage(HermesEngineConfiguration.executablePathKey) private var executablePath = ""
    @AppStorage(HermesEngineConfiguration.profilePathKey) private var profilePath = HermesEngineConfiguration.defaultProfilePath
    @AppStorage(HermesEngineConfiguration.runtimePathKey) private var runtimePath = ""
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text("Connect Hermes")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Use a private Hermes profile. Sign in with ChatGPT for its Codex provider, or connect an OpenAI or Anthropic API key. API keys have separate usage billing.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HermesSetupPane(executablePath: $executablePath, profilePath: $profilePath,
                    runtimePath: $runtimePath, isWorking: $isWorking,
                    onReady: { tour.hermesReadinessChanged($0) })
                OnboardingStatusLine(text: tour.status ?? "Connect Hermes to continue, or skip setup.", isDone: tour.isStepDone)
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
        VStack(spacing: 22) {
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
        }
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
                .overlay(Capsule(style: .continuous).stroke(DS.Colors.accent.opacity(0.4), lineWidth: 1))
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
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface3))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 0, y: 2)
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

/// What HeyMate said on the point and circle steps, or the live status.
struct OnboardingAnswerLine: View {
    @ObservedObject var tour: OnboardingTour

    var body: some View {
        if let answer = tour.lastAnswer {
            OnboardingBubble(text: answer, speaker: .heyMate)
                .frame(maxWidth: 440)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            OnboardingStatusLine(text: tour.status ?? "waiting for you…", isDone: tour.isStepDone)
        }
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

/// HeyMate's face for the tour.
struct OnboardingFace: View {
    var size: CGFloat = 76
    var isThinking = false

    var body: some View {
        Image(MateFace.legacyAssetNames[0])
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(isThinking ? DS.Colors.warning : DS.Colors.accent.opacity(0.6), lineWidth: 1.5))
            .shadow(color: DS.Colors.accentGlow.opacity(0.35), radius: 18)
            .accessibilityHidden(true)
    }
}

// MARK: - Hello

struct OnboardingHelloStep: View {
    @ObservedObject private var analytics = HeyMateAnalytics.shared
    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            HeyMateHelloTrace(lineWidth: 4, duration: 2.0)
                .frame(width: 210, height: 150)
                .cueMotion(.boot)
            Text("I'm HeyMate.")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("I live in your notch. Ask me about anything on your screen, and I'll point at the answer.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("I only look at your screen when you ask. Screenshots are never stored.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textTertiary)
            if analytics.isAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Share usage analytics", isOn: Binding(
                        get: { analytics.isOptedIn }, set: { analytics.setOptedIn($0) }
                    ))
                    Text(UsageAnalytics.disclosure)
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 420)
                .padding(.top, 12)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Mic

struct OnboardingMicStep: View {
    @ObservedObject var tour: OnboardingTour
    @ObservedObject var micCheck: OnboardingMicCheck

    var body: some View {
        OnboardingStepFrame(
            title: "Can I hear you?",
            subtitle: "Say anything out loud. If the bars move, your mic works. Built-in and wired mics work best."
        ) {
            OnboardingLevelBars(level: micCheck.level)
                .frame(height: 64)
            if let error = micCheck.errorMessage {
                Text(error).font(DS.Fonts.caption).foregroundColor(DS.Colors.warningText)
            } else {
                OnboardingStatusLine(text: tour.isStepDone ? "Sounds good." : "say “testing, one, two”", isDone: tour.isStepDone)
            }
            Picker("Microphone", selection: $micCheck.selectedDeviceUID) {
                Text("System default").tag(AudioInputDeviceCatalog.systemDefaultDeviceID)
                ForEach(micCheck.devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
        }
    }
}

/// A row of bars that rise from the middle with the mic level.
struct OnboardingLevelBars: View {
    let level: CGFloat
    private let count = 17

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { index in
                let distance = abs(CGFloat(index) - CGFloat(count - 1) / 2) / (CGFloat(count) / 2)
                let height = max(0.12, min(1, level * 1.6 * (1 - distance * 0.85)))
                Capsule(style: .continuous)
                    .fill(height > 0.2 ? DS.Colors.accent : DS.Colors.surface4)
                    .frame(width: 7, height: 64 * height)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityLabel("Microphone level")
    }
}

// MARK: - Interview

struct OnboardingInterviewStep: View {
    @ObservedObject var tour: OnboardingTour

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("I'm curious about you")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Three quick questions, so I'm useful from day one.")
                    .font(DS.Fonts.body)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.top, 22)

            HStack(alignment: .bottom, spacing: 14) {
                OnboardingFace(size: 70, isThinking: tour.isInterviewThinking)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(tour.interviewLines) { line in
                                OnboardingBubble(text: line.text, speaker: line.speaker)
                                    .id(line.id)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                            if tour.isInterviewThinking {
                                OnboardingBubble(text: "…", speaker: .heyMate)
                                    .id("thinking")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onChange(of: tour.interviewLines.count) { _, _ in
                        withAnimation { proxy.scrollTo(tour.interviewLines.last?.id, anchor: .bottom) }
                    }
                }
                .frame(height: 280)
            }

            if !tour.isStepDone {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill").font(DS.Glyph.small)
                        Text("Hold \(PushToTalkShortcut.talk.displayText) to answer")
                    }
                    .font(DS.Fonts.caption.weight(.medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    TextField("or type here", text: $tour.typedAnswer)
                        .textFieldStyle(.plain)
                        .font(DS.Fonts.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule(style: .continuous).fill(DS.Colors.surface2))
                        .overlay(Capsule(style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 0.5))
                        .onSubmit { tour.submitTypedAnswer() }
                        .disabled(tour.isInterviewThinking)
                }
                OnboardingStatusLine(text: tour.status ?? " ", isDone: false)
            }
        }
    }
}

// MARK: - Reveal

struct OnboardingRevealStep: View {
    @ObservedObject var tour: OnboardingTour

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 16)
            OnboardingFace(size: 72)
            Text(tour.heardName.map { "You're all set, \($0)." } ?? "You're all set.")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Hold \(PushToTalkShortcut.talk.displayText) any time and tell me what you need. I'm up in the notch.")
                .font(DS.Fonts.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            OnboardingRevealVoicePicker(tour: tour)
            if !tour.createdMateNames.isEmpty {
                VStack(spacing: 8) {
                    Text("New mates, made from what you told me")
                        .font(DS.Fonts.caption)
                        .foregroundColor(DS.Colors.textTertiary)
                    HStack(spacing: 8) {
                        ForEach(tour.createdMateNames, id: \.self) { name in
                            Text(name)
                                .font(DS.Fonts.body.weight(.medium))
                                .foregroundColor(DS.Colors.textPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule(style: .continuous).fill(DS.Colors.surface3))
                        }
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Voice

/// Local voice downloads at launch; the tour can continue while it prepares.
struct OnboardingVoiceStep: View {
    @ObservedObject var tour: OnboardingTour
    @ObservedObject private var store = OnDeviceVoiceModelStore.shared

    var body: some View {
        OnboardingStepFrame(
            title: "How should I sound?",
            subtitle: store.speakState.isInstalled
                ? "My local voice is ready. Tap a voice to hear it."
                : "My local voice downloads automatically. Keep going while it gets ready."
        ) {
            OnDeviceVoiceGrid()
                .frame(maxWidth: 560)
            OnDeviceVoiceDownloadRow(companionManager: tour.companionManager, isCompact: true)
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
}

/// While the on-device voice downloads, a thin line under the header on
/// every step, so it's clear it keeps going.
struct OnboardingVoiceDownloadLine: View {
    let isOnVoiceStep: Bool
    @ObservedObject private var store = OnDeviceVoiceModelStore.shared

    var body: some View {
        Group {
            if store.isDownloading {
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

/// On the last page: pick a voice once the download has landed.
struct OnboardingRevealVoicePicker: View {
    @ObservedObject var tour: OnboardingTour
    @ObservedObject private var store = OnDeviceVoiceModelStore.shared

    var body: some View {
        if store.speakState.isInstalled && !tour.prefersTyping {
            OnDeviceVoiceGrid()
                .frame(maxWidth: 560)
                .padding(.top, 4)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
