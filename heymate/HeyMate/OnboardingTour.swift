//
//  OnboardingTour.swift
//  HeyMate
//
//  The welcome tour a new person walks through in its own window. Every
//  step is something they actually do, not a slide: grant a permission,
//  pick their AI, talk into the mic, answer a few questions, ask about
//  their screen. HeyMate narrates each step out loud.
//
//      hello → permissions → your AI → mic check → talk (your name)
//            → interview → point → circle → type → reveal
//
//  Progress is saved per step, so quitting partway resumes there next
//  launch. Skip ends the tour from anywhere; nothing here blocks HeyMate.
//

import Combine
import SwiftUI

enum OnboardingStep: String, CaseIterable, Identifiable {
    case hello
    case permissions
    case ai
    case mic
    case talk
    case interview
    case point
    case circle
    case type
    case reveal

    var id: String { rawValue }
}

@MainActor
final class OnboardingTour: ObservableObject {
    @Published private(set) var step: OnboardingStep = .hello
    /// The step's own task is done, so Continue lights up.
    @Published private(set) var isStepDone = false
    /// A short live note under the step: "listening…", "thinking…".
    @Published private(set) var status: String?
    @Published private(set) var heardName: String? = OnboardingTour.storedName
    @Published private(set) var interviewLines: [OnboardingInterviewLine] = []
    @Published private(set) var isInterviewThinking = false
    @Published private(set) var createdMateNames: [String] = []
    /// What HeyMate said on the point and circle steps.
    @Published private(set) var lastAnswer: String?
    @Published private(set) var hasMarkedRegion = false
    @Published var typedAnswer = ""

    let micCheck = OnboardingMicCheck()
    let companionManager: CompanionManager

    /// Called when the tour ends, by Skip or by its last step.
    var onFinish: (() -> Void)?

    static let progressKey = "heymate.onboarding.tourStep"
    static let nameKey = "heymate.onboarding.preferredName"

    private var stepTask: Task<Void, Never>?
    private var watchers: Set<AnyCancellable> = []
    private var interviewAnswers = 0

    init(companionManager: CompanionManager, restart: Bool) {
        self.companionManager = companionManager
        if !restart, let saved = UserDefaults.standard.string(forKey: Self.progressKey),
           let resumed = OnboardingStep(rawValue: saved) {
            step = resumed
        }
    }

    static var storedName: String? {
        UserDefaults.standard.string(forKey: nameKey)
    }

    var stepIndex: Int { OnboardingStep.allCases.firstIndex(of: step) ?? 0 }
    var stepCount: Int { OnboardingStep.allCases.count }
    var canGoBack: Bool { stepIndex > 0 && step != .reveal }

    var talkKeys: [String] { PushToTalkShortcut.talk.keyCapsuleLabels }
    var circleKeys: [String] { PushToTalkShortcut.spatialSelect.keyCapsuleLabels }
    var typeKeys: [String] { ModifierDoubleTapPreferences.textShortcut.keyCapsuleLabels }
    var isTypeShortcutOn: Bool { ModifierDoubleTapPreferences.isTextShortcutEnabled }

    // MARK: - Moving

    func begin() {
        enter(step)
    }

    func next() {
        guard let index = OnboardingStep.allCases.firstIndex(of: step),
              index + 1 < OnboardingStep.allCases.count else {
            finish(openingHome: true)
            return
        }
        enter(OnboardingStep.allCases[index + 1])
    }

    func back() {
        guard canGoBack else { return }
        enter(OnboardingStep.allCases[stepIndex - 1])
    }

    /// Skip from anywhere: the tour is over, HeyMate is ready.
    func skip() {
        HeyMateAnalytics.track(.onboardingSkipped)
        finish(openingHome: false)
    }

    func finish(openingHome: Bool) {
        leaveStep()
        UserDefaults.standard.removeObject(forKey: Self.progressKey)
        companionManager.finishWelcomeTour(openingHome: openingHome)
        if openingHome {
            let greeting = heardName.map { "You're all set, \($0). I'm up in the notch whenever you need me." }
                ?? "You're all set. I'm up in the notch whenever you need me."
            companionManager.speakLine(greeting)
        }
        onFinish?()
    }

    /// The window closed without finishing: stop listening, keep the place.
    func suspend() {
        leaveStep()
    }

    private func enter(_ newStep: OnboardingStep) {
        leaveStep()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            step = newStep
            isStepDone = false
            status = nil
            lastAnswer = nil
        }
        UserDefaults.standard.set(newStep.rawValue, forKey: Self.progressKey)
        HeyMateAnalytics.track(.onboardingStepViewed(step: newStep.rawValue))
        stepTask = Task { [weak self] in await self?.run(newStep) }
    }

    private func leaveStep() {
        stepTask?.cancel()
        stepTask = nil
        watchers.removeAll()
        companionManager.onboardingTranscriptSink = nil
        companionManager.stopSpeaking()
        micCheck.stop()
    }

    private func markDone(_ note: String? = nil) {
        withAnimation(.easeOut(duration: DS.Animation.normal)) {
            isStepDone = true
            if let note { status = note }
        }
    }

    private func say(_ line: String) async {
        await companionManager.speakAndWait(line)
    }

    /// Talk transcripts come here for this step, through the main actor.
    private func listen(_ handler: @escaping (String) -> Void) {
        companionManager.onboardingTranscriptSink = { transcript in handler(transcript) }
    }

    // MARK: - Steps

    private func run(_ step: OnboardingStep) async {
        switch step {
        case .hello:
            markDone()
            await say("Hey, I'm HeyMate. I live up in your notch and help with whatever's on your screen. Let me show you around.")

        case .permissions:
            // The walkthrough moves on by itself through `permissionsFinished`.
            if companionManager.allPermissionsGranted { markDone("Everything's already on.") }
            await say("First, a few permissions so I can hear you and see your screen. One at a time.")

        case .ai:
            let signIn = companionManager.subscriptionSignIn
            if signIn.phase.isReady { markDone() }
            signIn.$phase
                .receive(on: RunLoop.main)
                .sink { [weak self] phase in if phase.isReady { self?.markDone() } }
                .store(in: &watchers)
            await say("I think with the AI you already pay for. Which one do you have?")

        case .mic:
            await say("Can I hear you? Say anything, and watch the bars.")
            guard !Task.isCancelled else { return }
            micCheck.start()
            micCheck.$hasHeardSound
                .receive(on: RunLoop.main)
                .sink { [weak self] heard in if heard { self?.markDone("Sounds good.") } }
                .store(in: &watchers)

        case .talk:
            watchListening(prompt: "listening…")
            listen { [weak self] transcript in self?.heardIntroduction(transcript) }
            await say("This is how you talk to me. Hold the keys, tell me your name, then let go.")

        case .interview:
            await startInterview()

        case .point:
            watchListening(prompt: "listening…")
            listen { [weak self] transcript in self?.answer(transcript, aboutSelection: false) }
            await say("I can see your screen when you ask. Hold the keys and ask me what's interesting on it.")

        case .circle:
            watchListening(prompt: "listening…")
            companionManager.$activeSpatialSelection
                .receive(on: RunLoop.main)
                .sink { [weak self] selection in
                    guard let self, selection != nil, !self.isStepDone else { return }
                    self.hasMarkedRegion = true
                    self.status = "Now hold \(PushToTalkShortcut.talk.displayText) and ask about it."
                }
                .store(in: &watchers)
            listen { [weak self] transcript in
                guard let self else { return }
                self.answer(transcript, aboutSelection: self.hasMarkedRegion)
            }
            await say("You can also circle something first. Hold the circle keys, draw around anything, then ask me about it.")

        case .type:
            guard isTypeShortcutOn else {
                markDone("Typing is switched off in Settings › Shortcuts.")
                return
            }
            let startCount = companionManager.typedComposerSummonCount
            companionManager.$typedComposerSummonCount
                .receive(on: RunLoop.main)
                .sink { [weak self] count in
                    guard let self, count > startCount, !self.isStepDone else { return }
                    self.markDone("That's the one.")
                    self.companionManager.speakLine("There it is. Type anything, any time.")
                }
                .store(in: &watchers)
            await say("Not in the mood to talk? Tap the key twice, quickly, and type instead.")

        case .reveal:
            markDone()
            let mates = createdMateNames
            if mates.isEmpty {
                await say("That's the tour. I'm ready when you are.")
            } else {
                await say("That's the tour. I made you \(mates.count) mates from what you told me. They're waiting in the sidebar.")
            }
        }
    }

    /// The permission walkthrough's last page.
    func permissionsFinished() {
        markDone()
        next()
    }

    /// Shows "listening…" while a talk turn records, "thinking…" after.
    private func watchListening(prompt: String) {
        companionManager.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self, !self.isStepDone else { return }
                switch state {
                case .listening: self.status = prompt
                case .finalizingTranscript: self.status = "got it…"
                default: break
                }
            }
            .store(in: &watchers)
    }

    // MARK: Talk

    private func heardIntroduction(_ transcript: String) {
        let name = OnboardingInterview.name(fromIntroduction: transcript)
        if let name {
            heardName = name
            UserDefaults.standard.set(name, forKey: Self.nameKey)
        }
        markDone(name.map { "Hi, \($0)." } ?? "Heard you.")
        companionManager.onboardingTranscriptSink = nil
        companionManager.speakLine(name.map { "Nice to meet you, \($0)!" } ?? "Got it, I can hear you!")
    }

    // MARK: Point and circle

    private func answer(_ request: String, aboutSelection: Bool) {
        status = "looking…"
        companionManager.onboardingTranscriptSink = nil
        Task { [weak self] in
            guard let self else { return }
            let spoken = await self.companionManager.answerTourQuestion(request, aboutSelection: aboutSelection)
            guard !Task.isCancelled else { return }
            self.lastAnswer = spoken
            self.markDone(spoken == nil ? "I couldn't answer that one. Try again later from the notch." : nil)
            if spoken == nil {
                self.status = "I couldn't answer that one. Try again later from the notch."
            } else {
                self.status = nil
            }
        }
    }

    // MARK: Interview

    private func startInterview() async {
        if interviewLines.isEmpty {
            let hello = heardName.map { "So, \($0). I'm curious about you." } ?? "I'm curious about you."
            interviewLines = [
                OnboardingInterviewLine(speaker: .heyMate, text: hello),
                OnboardingInterviewLine(speaker: .heyMate, text: OnboardingInterview.openingQuestion),
            ]
            interviewAnswers = 0
        }
        if interviewAnswers >= OnboardingInterview.answerCount {
            markDone()
            return
        }
        listen { [weak self] transcript in self?.interviewAnswer(transcript) }
        watchListening(prompt: "listening…")
        let spokenSoFar = interviewLines.suffix(2).map(\.text).joined(separator: " ")
        await say(spokenSoFar)
    }

    func submitTypedAnswer() {
        let text = typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, step == .interview, !isInterviewThinking else { return }
        typedAnswer = ""
        interviewAnswer(text)
    }

    private func interviewAnswer(_ answer: String) {
        guard !isInterviewThinking, !isStepDone else { return }
        companionManager.stopSpeaking()
        withAnimation(.easeOut(duration: DS.Animation.normal)) {
            interviewLines.append(OnboardingInterviewLine(speaker: .user, text: answer))
            isInterviewThinking = true
            status = nil
        }
        interviewAnswers += 1
        let lines = interviewLines
        let answered = interviewAnswers
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.askInterviewer(lines)
            guard !Task.isCancelled, self.step == .interview else { return }
            self.isInterviewThinking = false
            await self.handle(reply, answered: answered)
        }
    }

    private func askInterviewer(_ lines: [OnboardingInterviewLine]) async -> OnboardingInterviewReply? {
        do {
            let (text, _) = try await companionManager.activeConversationClient.analyzeImageStreaming(
                images: [],
                systemPrompt: OnboardingInterview.systemPrompt,
                conversationHistory: [],
                userPrompt: OnboardingInterview.transcript(lines),
                onTextChunk: { _ in }
            )
            return OnboardingInterview.parseReply(text)
        } catch {
            HeyMateLog.log("⚠️ Welcome tour interview couldn't reach the AI: \(error.localizedDescription)")
            return nil
        }
    }

    private func handle(_ reply: OnboardingInterviewReply?, answered: Int) async {
        let isLast = answered >= OnboardingInterview.answerCount
        switch reply {
        case .next(let reaction, let question) where !isLast:
            await add([reaction, question])
        case .wrapUp(let reaction, let summary, let mates):
            await add([reaction, summary, "I'll set up a few mates for you while we keep going."])
            createMates(mates)
            markDone()
        case .next(let reaction, _):
            // Asked again past the last answer: wrap up without mates.
            await add([reaction, "Thanks, that helps a lot."])
            markDone()
        case nil:
            let reaction = OnboardingInterview.fallbackReactions[(answered - 1) % OnboardingInterview.fallbackReactions.count]
            if isLast {
                await add([reaction, "Thanks, that helps a lot."])
                markDone()
            } else {
                let question = OnboardingInterview.fallbackQuestions[min(answered - 1, OnboardingInterview.fallbackQuestions.count - 1)]
                await add([reaction, question])
            }
        }
    }

    /// Adds HeyMate's lines as bubbles, then says them.
    private func add(_ lines: [String]) async {
        let lines = lines.filter { !$0.isEmpty }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            interviewLines.append(contentsOf: lines.map { OnboardingInterviewLine(speaker: .heyMate, text: $0) })
        }
        await say(lines.joined(separator: " "))
    }

    private func createMates(_ suggestions: [OnboardingMateSuggestion]) {
        let faces = MateFace.packs.flatMap(\.faces).map(\.assetName).shuffled()
        var made: [String] = []
        for (offset, suggestion) in suggestions.enumerated() {
            let face = faces.isEmpty ? nil : faces[offset % faces.count]
            if let mate = companionManager.createMate(
                name: suggestion.name, job: suggestion.job, opensChat: false, faceAssetName: face
            ) {
                made.append(mate.name)
            }
        }
        createdMateNames = made
        HeyMateLog.log("🎉 Welcome tour made \(made.count) mate(s)")
    }
}
