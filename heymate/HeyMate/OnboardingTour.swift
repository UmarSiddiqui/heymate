//
//  OnboardingTour.swift
//  HeyMate
//
//  The welcome tour a new person walks through in its own window. Every
//  step is something they actually do, not a slide: grant a permission,
//  pick their AI, say their name, answer a few questions, ask about their
//  screen, and say yes to their new mates' first jobs. HeyMate narrates
//  each step out loud. Kept short on purpose: nine steps, a few minutes.
//
//      voice → hello → permissions → your AI → talk (your name) → interview
//            → show me → ask about your screen → first jobs → reveal
//
//  Voice comes first because the tour talks the whole way through; that
//  step also shows the on-device model download plainly. The mic check is
//  the talk step itself, circling is part of asking about the screen, and
//  the typing shortcut is a tip at the end.
//
//  Progress is saved per step, so quitting partway resumes there next
//  launch. Skip ends the tour from anywhere; nothing here blocks HeyMate.
//

import AppKit
import AVFoundation
import Combine
import SwiftUI

enum OnboardingStep: String, CaseIterable, Identifiable {
    /// Pick HeyMate's voice and see the on-device download.
    case voice
    case hello
    case permissions
    case ai
    case talk
    case interview
    case showMe
    /// Ask about the screen, circling part of it if you like.
    case point
    /// The new mates each offer a first job: yes or no.
    case kickoff
    case reveal

    var id: String { rawValue }

    /// A saved step, including ones from the longer tour, so someone
    /// halfway through an older build resumes at the nearest step.
    static func restored(_ raw: String) -> OnboardingStep? {
        if let step = OnboardingStep(rawValue: raw) { return step }
        switch raw {
        case "mic": return .talk
        case "circle": return .point
        case "type", "firstTask": return .kickoff
        default: return nil
        }
    }
}

/// The tour's three parts, shown as the progress bar along the top.
enum OnboardingChapter: CaseIterable, Identifiable {
    case setUp
    case meet
    case tryIt

    var id: Self { self }

    var title: String {
        switch self {
        case .setUp: return "Set up"
        case .meet: return "Meet"
        case .tryIt: return "Try it"
        }
    }

    var steps: [OnboardingStep] {
        switch self {
        case .setUp: return [.voice, .hello, .permissions, .ai]
        case .meet: return [.talk, .interview]
        case .tryIt: return [.showMe, .point, .kickoff]
        }
    }

    func contains(_ step: OnboardingStep) -> Bool { steps.contains(step) }

    /// The chapter a step belongs to; the closing page counts as the last.
    static func of(_ step: OnboardingStep) -> OnboardingChapter {
        allCases.first { $0.contains(step) } ?? .tryIt
    }

    /// 0…1: how much of this chapter is behind the person at `step`.
    func progress(at step: OnboardingStep) -> CGFloat {
        let all = OnboardingStep.allCases
        guard let current = all.firstIndex(of: step),
              let first = steps.first.flatMap(all.firstIndex(of:)),
              let last = steps.last.flatMap(all.firstIndex(of:)) else { return 0 }
        if current > last { return 1 }
        if current < first { return 0 }
        return CGFloat(current - first + 1) / CGFloat(steps.count)
    }
}

@MainActor
final class OnboardingTour: ObservableObject {
    @Published private(set) var step: OnboardingStep = OnboardingStep.allCases[0]
    /// The step's own task is done, so Continue lights up.
    @Published private(set) var isStepDone = false
    /// A short live note under the step: "listening…", "thinking…".
    @Published private(set) var status: String?
    @Published private(set) var heardName: String? = OnboardingTour.storedName
    @Published private(set) var interviewLines: [OnboardingInterviewLine] =
        OnboardingInterview.decode(UserDefaults.standard.data(forKey: OnboardingTour.interviewKey))
    @Published private(set) var isInterviewThinking = false
    /// One-tap answers for the question on screen.
    @Published private(set) var interviewSuggestions: [String] = []
    @Published private(set) var createdMateNames: [String] = UserDefaults.standard.stringArray(forKey: OnboardingTour.createdMatesKey) ?? []
    /// First jobs the interview's mates offered, by mate name.
    @Published private(set) var firstJobs: [String: String] =
        UserDefaults.standard.dictionary(forKey: OnboardingTour.firstJobsKey) as? [String: String] ?? [:]
    /// Yes (started) or no for each first job, by mate name.
    @Published private(set) var kickoffDecisions: [String: Bool] = [:]
    /// What HeyMate said when asked about the screen.
    @Published private(set) var lastAnswer: String?
    /// HeyMate's latest line on this step, shown in its speech bubble.
    /// Set even when the tour is silent, so typing-only people read it.
    @Published private(set) var speech: String?
    @Published private(set) var hasMarkedRegion = false
    @Published var typedAnswer = ""
    /// Chose "just type" on the first page: the tour stops talking, and
    /// silent mode comes on when it ends.
    @Published private(set) var prefersTyping = UserDefaults.standard.bool(forKey: OnboardingTour.prefersTypingKey)

    let music = OnboardingMusic()
    let companionManager: CompanionManager
    private let voiceClips = OnboardingVoiceClips()

    /// Called when the tour ends, by Skip or by its last step.
    var onFinish: (() -> Void)?

    static let progressKey = "heymate.onboarding.tourStep"
    static let nameKey = "heymate.onboarding.preferredName"
    static let prefersTypingKey = "heymate.onboarding.prefersTyping"
    /// Mates the interview already made, so a resumed or replayed tour
    /// doesn't make another set.
    static let createdMatesKey = "heymate.onboarding.createdMates"
    /// The interview so far, so Back, a relaunch or the "show me" step
    /// never lose what the person said.
    static let interviewKey = "heymate.onboarding.interview"
    static let firstJobsKey = "heymate.onboarding.firstJobs"


    private var stepTask: Task<Void, Never>?
    private var watchers: Set<AnyCancellable> = []
    private var interviewAnswers = 0
    /// The AI step asked for a sign-in that hasn't happened yet.
    private var isAwaitingSignIn = false
    /// A point or circle answer is being worked out; further presses wait.
    private var isAnswering = false

    init(companionManager: CompanionManager, restart: Bool) {
        self.companionManager = companionManager
        if !restart, let saved = UserDefaults.standard.string(forKey: Self.progressKey),
           let resumed = OnboardingStep.restored(saved) {
            step = resumed
        }
    }

    /// What the buddy cursor says the first time it fades in.
    static let cursorGreeting = "Hey! I am your AI Mate ^-^"

    static var storedName: String? {
        UserDefaults.standard.string(forKey: nameKey)
    }

    /// Mates the interview made, as they are now: renamed or deleted
    /// mates follow what the person did after.
    var createdMates: [Mate] {
        createdMateNames.compactMap { name in
            companionManager.mates.first { $0.name == name && !$0.archived }
        }
    }

    var interviewAnswerCount: Int { interviewLines.filter { $0.speaker == .user }.count }

    var stepIndex: Int { OnboardingStep.allCases.firstIndex(of: step) ?? 0 }
    var stepCount: Int { OnboardingStep.allCases.count }
    var canGoBack: Bool { stepIndex > 0 && step != .reveal }

    var talkKeys: [String] { PushToTalkShortcut.talk.keyCapsuleLabels }
    var typeKeys: [String] { ModifierDoubleTapPreferences.textShortcut.keyCapsuleLabels }
    var isTypeShortcutOn: Bool { ModifierDoubleTapPreferences.isTextShortcutEnabled }

    // MARK: - Moving

    func begin() {
        // A tour starting from the top boots HeyMate up; a resumed one
        // picks up quietly where it left off.
        if step == OnboardingStep.allCases[0] {
            HeyMateCue.shared.fire(.boot)
            companionManager.greetWithCursor(Self.cursorGreeting)
        }
        music.start()
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
        UserDefaults.standard.removeObject(forKey: Self.interviewKey)
        UserDefaults.standard.removeObject(forKey: Self.firstJobsKey)
        companionManager.finishWelcomeTour(openingHome: openingHome)
        if prefersTyping { companionManager.isSilentModeEnabled = true }
        if openingHome && !prefersTyping {
            if let heardName {
                speak("You're all set, \(heardName). I'm up in the notch whenever you need me.")
            } else {
                speak("You're all set. I'm up in the notch whenever you need me.")
            }
        }
        music.stop()
        onFinish?()
    }

    /// The window closed without finishing: stop listening, keep the place.
    func suspend() {
        leaveStep()
        music.stop(fade: 0.5)
    }

    private func enter(_ newStep: OnboardingStep) {
        leaveStep()
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86)) {
            step = newStep
            isStepDone = false
            status = nil
            lastAnswer = nil
            speech = nil
        }
        UserDefaults.standard.set(newStep.rawValue, forKey: Self.progressKey)
        HeyMateAnalytics.track(.onboardingStepViewed(step: newStep.rawValue))
        music.setListening(Self.listens(newStep))
        stepTask = Task { [weak self] in await self?.run(newStep) }
    }

    private func leaveStep() {
        isAnswering = false
        isAwaitingSignIn = false
        stepTask?.cancel()
        stepTask = nil
        watchers.removeAll()
        companionManager.onboardingTranscriptSink = nil
        companionManager.stopSpeaking()
        voiceClips.stop()
        music.setDucked(false)
    }

    /// Steps that hear the person. The music steps aside for them.
    private static func listens(_ step: OnboardingStep) -> Bool {
        switch step {
        case .talk, .interview, .showMe, .point: return true
        default: return false
        }
    }

    private func markDone(_ note: String? = nil) {
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: DS.Animation.normal)) {
            isStepDone = true
            if let note { status = note }
        }
    }

    /// Fire-and-forget line; silent when the person chose typing.
    private func speak(_ line: String) {
        speech = line
        guard speaksAloud else { return }
        if usesVoiceClips, voiceClips.start(line) { return }
        companionManager.speakLine(line)
    }

    private func say(_ line: String) async {
        speech = line
        guard speaksAloud else { return }
        music.setDucked(true)
        defer { music.setDucked(false) }
        if usesVoiceClips, await voiceClips.play(line) { return }
        await companionManager.speakAndWait(line)
    }

    private var speaksAloud: Bool {
        !prefersTyping && !companionManager.isSilentModeEnabled
    }

    /// Scripted lines play pre-rendered in HeyMate's own voice, so the
    /// first words are instant and never wait on the speaking model.
    private var usesVoiceClips: Bool {
        OnboardingVoiceClips.isPreferred(for: companionManager.selectedSpeakProvider)
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
            await say("Hey! I'm your AI mate. This is the start of a great friendship. I live up in your notch, and I'm here for whatever's on your screen. Let me show you around.")

        case .voice:
            // The tour waits here until hearing and voice are ready, so every
            // later step works the first time. Start-anyway is on the page.
            let store = OnDeviceVoiceModelStore.shared
            store.refreshInstalledState()
            if !store.isDownloading, !store.isEverythingInstalled, store.isSupportedOnThisMac {
                Task { await store.downloadAll() }
            }
            let readyAtStart = Self.modelsSettled(store)
            if readyAtStart { markDone() } else { status = "Getting ready…" }
            store.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self, self.step == .voice, !self.isStepDone, Self.modelsSettled(store) else { return }
                    if store.lastFailureMessage != nil {
                        self.markDone("Download stopped. Retry above, or start anyway.")
                    } else {
                        self.markDone("All set.")
                        self.speak("All set. Let's go!")
                    }
                }
                .store(in: &watchers)
            // Let the buddy's greeting land first.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            if !store.isSupportedOnThisMac {
                await say("Hi! This Mac can't run my voice, so I'll show my words as text.")
            } else if readyAtStart || store.speakState.isInstalled {
                await say("Hi! First, pick how I should sound. Tap a voice to hear it.")
            } else {
                await say("Hi! I'm getting my ears and voice ready on your Mac. It takes a minute, then we'll start.")
            }

        case .permissions:
            // The walkthrough moves on by itself through `permissionsFinished`.
            if companionManager.allPermissionsGranted { markDone("Everything's already on.") }
            await say("First, a few permissions so I can hear you and see your screen. One at a time.")

        case .ai:
            // The setup pane reports readiness as soon as it appears, so an
            // already-connected AI has usually marked the step done by now.
            if isStepDone {
                await say("You're already connected. Let's keep going.")
            } else {
                status = "Connect ChatGPT or Claude to continue, or skip setup."
                isAwaitingSignIn = true
                await say("Next, connect your AI. Sign in with ChatGPT or Claude, and I'll work on your plan.")
            }

        case .talk:
            watchListening(prompt: "listening…")
            listen { [weak self] transcript in self?.heardIntroduction(transcript) }
            await say("This is how you talk to me. Hold the keys, tell me your name, then let go.")

        case .interview:
            await startInterview()

        case .showMe:
            watchListening(prompt: "listening…")
            listen { [weak self] transcript in self?.showMe(transcript) }
            await say("Now let me show you what I can do. Hold the keys and say: show me how you'd help me.")

        case .point:
            watchListening(prompt: "listening…")
            companionManager.$activeSpatialSelection
                .receive(on: RunLoop.main)
                .sink { [weak self] selection in
                    guard let self, selection != nil, !self.isStepDone else { return }
                    self.hasMarkedRegion = true
                    self.status = "Keep holding the talk keys and ask about it."
                }
                .store(in: &watchers)
            listen { [weak self] transcript in
                guard let self else { return }
                self.answer(transcript, aboutSelection: self.hasMarkedRegion || self.companionManager.activeSpatialSelection != nil)
            }
            await say("I can see your screen when you ask. Hold the keys and ask what's interesting. Circle something while you hold them to ask about just that.")

        case .kickoff:
            if createdMates.isEmpty {
                await say("Try one small real task. Type it here, review any approval, then see the result. You can skip this step.")
            } else if offeredJobs.allSatisfy({ kickoffDecisions[$0.mate.name] != nil }) {
                markDone()
            } else {
                await say("Your new mates already have ideas. Say yes to the ones you want started, and they'll get going while we finish.")
            }

        case .reveal:
            markDone()
            let mates = createdMateNames
            if mates.isEmpty {
                await say("That's the tour. I'm ready when you are.")
            } else {
                let working = kickoffDecisions.values.filter { $0 }.count
                await say(working > 0
                    ? "That's the tour. Your mates are working, and they'll report back in their chats."
                    : "That's the tour. Your \(mates.count) mates are waiting in the sidebar.")
            }
        }
    }

    /// Hearing and voice are both usable, or can't be: installed, failed
    /// (retry is on the page), or not supported on this Mac.
    private static func modelsSettled(_ store: OnDeviceVoiceModelStore) -> Bool {
        if store.isEverythingInstalled || !store.isSupportedOnThisMac { return true }
        let states = [store.listenState, store.speakState]
        return states.allSatisfy { state in
            switch state {
            case .installed, .unsupported, .failed: return true
            case .notInstalled, .downloading: return false
            }
        }
    }

    /// Leaves the first step before the models finish; they keep going.
    func startWithoutWaiting() {
        guard step == .voice else { return }
        next()
    }

    func firstTaskFinished() {
        guard step == .kickoff else { return }
        markDone("Your result stays in chat.")
    }

    func skipFirstTask() {
        guard step == .kickoff else { return }
        markDone("Continue whenever you are ready. Work already sent stays in chat.")
    }

    // MARK: First jobs

    /// The interview's mates that offered a first job, in the order made.
    var offeredJobs: [(mate: Mate, job: String)] {
        createdMates.compactMap { mate in
            guard let job = firstJobs[mate.name], !job.isEmpty else { return nil }
            return (mate, job)
        }
    }

    /// Yes: the job goes to that mate as a handoff, the same way any chat
    /// hands a mate work. It runs in the mate's own chat under its usual
    /// approvals; nothing here skips a plan or an approval card.
    func startFirstJob(for mate: Mate) {
        guard step == .kickoff, kickoffDecisions[mate.name] == nil, let job = firstJobs[mate.name] else { return }
        companionManager.enqueueHandoff(
            MateHandoff(mateID: mate.id, mateName: mate.name, instruction: "Yes, do it: \(job)"),
            source: "welcome tour"
        )
        decide(mate, started: true)
        speak("On it.")
    }

    func declineFirstJob(for mate: Mate) {
        guard step == .kickoff, kickoffDecisions[mate.name] == nil else { return }
        decide(mate, started: false)
    }

    private func decide(_ mate: Mate, started: Bool) {
        withAnimation(.easeOut(duration: DS.Animation.normal)) {
            kickoffDecisions[mate.name] = started
        }
        let started = kickoffDecisions.values.filter { $0 }.count
        if offeredJobs.allSatisfy({ kickoffDecisions[$0.mate.name] != nil }) {
            markDone(started == 0 ? "No jobs yet. Ask any mate from the sidebar." : "Working. Results land in each mate's chat.")
        } else if started > 0 {
            markDone()
        }
    }

    // MARK: Voice

    /// Starts the download and lets the tour go on; it keeps running in the
    /// background and switches HeyMate to the new voice when it lands.
    func downloadOnDeviceVoice() {
        setPrefersTyping(false)
        let store = OnDeviceVoiceModelStore.shared
        guard !store.isDownloading else { return }
        Task { await store.downloadAll() }
    }

    func setPrefersTyping(_ typing: Bool) {
        prefersTyping = typing
        UserDefaults.standard.set(typing, forKey: Self.prefersTypingKey)
        if typing {
                voiceClips.stop()
            companionManager.stopSpeaking()
        }
    }

    /// MateAgent readiness cannot be replaced by an unrelated native CLI login.
    func mateAgentReadinessChanged(_ ready: Bool) {
        guard step == .ai else { return }
        if ready {
            // Only a sign-in that happens on this step gets a spoken "Connected".
            let justConnected = !isStepDone && isAwaitingSignIn
            isAwaitingSignIn = false
            markDone("HeyMate Agent is connected.")
            if justConnected { speak("Connected. Nice.") }
        } else {
            isStepDone = false
            status = "Connect HeyMate Agent to continue, or skip setup."
        }
    }

    /// The permission walkthrough's last page.
    func permissionsFinished() {
        markDone()
        next()
        // The first capture is when macOS asks to let HeyMate skip its
        // window picker. Ask now, next to the other permissions, rather
        // than in the middle of the "I can see your screen" demo.
        if companionManager.hasScreenRecordingPermission {
            Task { _ = try? await ScreenCapture.allScreens() }
        }
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
        if let name {
            speak("Nice to meet you, \(name)!")
        } else {
            speak("Got it, I can hear you!")
        }
    }

    // MARK: Show me

    /// ReferenceRenderer's drawn "here's how I'd help you" step: one real drawing turn on their screen, built from the
    /// interview. A second press while it draws stays in the tour.
    private func showMe(_ request: String) {
        guard !isAnswering else {
            status = "still drawing…"
            return
        }
        isAnswering = true
        status = "drawing…"
        let interview = interviewLines
        let name = heardName
        Task { [weak self] in
            guard let self else { return }
            let drew = await self.companionManager.runDrawnTourStep(request, interview: interview, name: name)
            self.isAnswering = false
            guard !Task.isCancelled else { return }
            self.status = drew ? nil : "I couldn't draw just now. You can ask me anything from the notch later."
            self.markDone(drew ? "That's what I'm here for." : nil)
        }
    }

    // MARK: Point and circle

    /// The step keeps listening throughout, so a second press while this
    /// is still looking stays in the tour instead of starting a real turn.
    private func answer(_ request: String, aboutSelection: Bool) {
        guard !isAnswering else {
            status = "still looking…"
            return
        }
        isAnswering = true
        status = "looking…"
        Task { [weak self] in
            guard let self else { return }
            // A real talk turn; it captures any circled region itself.
            let spoken = await self.companionManager.runScreenTourStep(request)
            self.isAnswering = false
            guard !Task.isCancelled else { return }
            if aboutSelection { self.hasMarkedRegion = false }
            guard let spoken else {
                // Not done: a failed try is not a demo. They can ask again.
                self.status = "That didn't go through. Hold the keys and ask again."
                return
            }
            self.lastAnswer = spoken.isEmpty ? nil : spoken
            self.markDone()
            self.status = nil
        }
    }

    // MARK: Interview

    private func startInterview() async {
        // Already done, in this run or an earlier one: show what came of
        // it and let them move on. Nothing is asked twice.
        if !createdMateNames.isEmpty || interviewAnswerCount >= OnboardingInterview.answerCount {
            interviewSuggestions = []
            markDone()
            return
        }
        if interviewLines.isEmpty {
            let hello = heardName.map { "So, \($0). I'm curious about you." } ?? "I'm curious about you."
            setInterviewLines([
                OnboardingInterviewLine(speaker: .heyMate, text: hello),
                OnboardingInterviewLine(speaker: .heyMate, text: OnboardingInterview.openingQuestion),
            ])
            interviewSuggestions = OnboardingInterview.openingSuggestions
        } else if interviewSuggestions.isEmpty {
            interviewSuggestions = fallbackSuggestions(afterAnswers: interviewAnswerCount)
        }
        interviewAnswers = interviewAnswerCount
        listen { [weak self] transcript in self?.interviewAnswer(transcript) }
        watchListening(prompt: "listening…")
        // Picking up partway: only the question still waiting is said again.
        let waiting = interviewAnswers == 0
            ? interviewLines.suffix(2).map(\.text).joined(separator: " ")
            : interviewLines.last(where: { $0.speaker == .heyMate })?.text ?? ""
        await say(waiting)
    }

    private func fallbackSuggestions(afterAnswers answered: Int) -> [String] {
        if answered == 0 { return OnboardingInterview.openingSuggestions }
        let index = min(answered - 1, OnboardingInterview.fallbackSuggestions.count - 1)
        return OnboardingInterview.fallbackSuggestions[index]
    }

    private func setInterviewLines(_ lines: [OnboardingInterviewLine]) {
        interviewLines = lines
        UserDefaults.standard.set(OnboardingInterview.encode(lines), forKey: Self.interviewKey)
    }

    /// A one-tap answer counts the same as saying or typing it.
    func chooseSuggestion(_ suggestion: String) {
        guard step == .interview, !isInterviewThinking, !isStepDone else { return }
        interviewAnswer(suggestion)
    }

    /// Moves on without finishing the questions; no mates are made.
    func skipInterview() {
        guard step == .interview, !isStepDone else { return }
        companionManager.onboardingTranscriptSink = nil
        companionManager.stopSpeaking()
        voiceClips.stop()
        interviewSuggestions = []
        isInterviewThinking = false
        markDone("Skipped. You can make mates any time from the sidebar.")
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
            setInterviewLines(interviewLines + [OnboardingInterviewLine(speaker: .user, text: answer)])
            interviewSuggestions = []
            isInterviewThinking = true
            status = nil
        }
        interviewAnswers += 1
        let lines = interviewLines
        let answered = interviewAnswers
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.askInterviewer(lines)
            guard !Task.isCancelled, self.step == .interview, !self.isStepDone else { return }
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
        case .next(let reaction, let question, let suggestions) where !isLast:
            interviewSuggestions = suggestions.isEmpty ? fallbackSuggestions(afterAnswers: answered) : suggestions
            await add([reaction, question])
        case .wrapUp(let reaction, let summary, let mates):
            createMates(mates)
            markDone()
            let made = createdMateNames.isEmpty ? [] : ["I made you \(createdMateNames.count) mates for that. They're waiting in your sidebar."]
            await add([reaction, summary] + made)
        case .next(let reaction, _, _):
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
                interviewSuggestions = fallbackSuggestions(afterAnswers: answered)
                await add([reaction, question])
            }
        }
    }

    /// Adds HeyMate's lines as bubbles, then says them.
    private func add(_ lines: [String]) async {
        let lines = lines.filter { !$0.isEmpty }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
            setInterviewLines(interviewLines + lines.map { OnboardingInterviewLine(speaker: .heyMate, text: $0) })
        }
        await say(lines.joined(separator: " "))
    }

    #if DEBUG
    /// Design snapshots only: puts the tour on a step with a given
    /// interview, without running the step or saving anything.
    func stageForSnapshot(step: OnboardingStep, lines: [OnboardingInterviewLine] = [], suggestions: [String] = [],
                          thinking: Bool = false, done: Bool = false, mateNames: [String] = [], name: String? = nil,
                          speech: String? = nil, answer: String? = nil, status: String? = nil,
                          jobs: [String: String] = [:], decisions: [String: Bool] = [:]) {
        self.step = step
        firstJobs = jobs
        kickoffDecisions = decisions
        self.speech = speech
        lastAnswer = answer
        self.status = status
        interviewLines = lines
        interviewSuggestions = suggestions
        isInterviewThinking = thinking
        isStepDone = done
        createdMateNames = mateNames
        heardName = name
    }
    #endif

    private func createMates(_ suggestions: [OnboardingMateSuggestion]) {
        var made: [String] = []
        var jobs: [String: String] = [:]
        for suggestion in suggestions {
            if let mate = companionManager.createMate(
                name: suggestion.name, job: suggestion.job, opensChat: false
            ) {
                made.append(mate.name)
                if let first = suggestion.firstJob, !first.isEmpty { jobs[mate.name] = first }
            }
        }
        createdMateNames = made
        firstJobs = jobs
        UserDefaults.standard.set(made, forKey: Self.createdMatesKey)
        UserDefaults.standard.set(jobs, forKey: Self.firstJobsKey)
        HeyMateLog.log("🎉 Welcome tour made \(made.count) mate(s)")
    }
}
