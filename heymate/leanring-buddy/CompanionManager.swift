//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {

    /// UserDefaults key backing `isUISoundEnabled` (shared with UISoundPlayer).
    nonisolated static let uiSoundPreferenceKey = "isUISoundEnabled"

    /// UserDefaults key backing the onboarding theme color (hex without #).
    nonisolated static let themeColorPreferenceKey = "selectedThemeColorHex"

    /// UserDefaults key backing the notch outline animation. Default on.
    nonisolated static let notchOutlinePreferenceKey = "isNotchOutlineEnabled"

    /// UserDefaults key backing `selectedListenProvider`.
    nonisolated static let listenPreferenceKey = "selectedVoiceListenProvider"

    /// UserDefaults key backing `selectedSpeakProvider`.
    nonisolated static let speakPreferenceKey = "selectedVoiceSpeakProvider"

    nonisolated static let codexModelPreferenceKey = "selectedCodexModel"
    nonisolated static let codexReasoningEffortPreferenceKey = "selectedCodexReasoningEffort"

    /// Local cooldown timestamps keyed by Standing Order filename stem.
    nonisolated static let standingOrderLastTriggeredPreferenceKey = "standingOrderLastTriggeredAt"

    /// Injectable so tests can point memory at a temp file instead of the
    /// real Application Support store.
    let memoryRepository: FileMemoryRepository

    /// Injectable so tests can point chats at a temp file.
    let chatHistoryStore: FileChatHistoryStore

    /// Injectable so tests never touch the real agent-runs.json.
    let agentRunStore: FileAgentRunStore

    /// Spawns headless OpenCode / Claude Code processes. Callbacks are bound
    /// at the end of init so they can capture self.
    let agentLauncher: HeadlessAgentLauncher

    /// User-owned Markdown automation rules and recoverable agent snapshots.
    let standingOrderRepository: FileStandingOrderRepository
    let agentUndoLedger: FileAgentUndoLedger

    /// Owns durable activation choices and precedence for skills discovered
    /// across HeyMate and Claude Code folders.
    let skillActivationStore = SkillActivationStore()
    let skillRegistryInstallationStore = SkillRegistryInstallationStore()

    /// Default-arg construction happens inside the actor body (the
    /// FileMemoryRepository initializer is MainActor-isolated).
    init(
        memoryRepository: FileMemoryRepository? = nil,
        chatHistoryStore: FileChatHistoryStore? = nil,
        agentRunStore: FileAgentRunStore? = nil,
        standingOrderRepository: FileStandingOrderRepository? = nil,
        agentUndoLedger: FileAgentUndoLedger? = nil
    ) {
        let repository = memoryRepository
            ?? FileMemoryRepository(fileURL: FileMemoryRepository.appSupportFileURL())
        self.memoryRepository = repository
        self.memoryItems = repository.loadAll()

        let chats = chatHistoryStore
            ?? FileChatHistoryStore(fileURL: FileChatHistoryStore.appSupportFileURL())
        self.chatHistoryStore = chats
        self.savedChats = chats.loadAll()
        self.currentChat = ChatSession.empty()

        let store = agentRunStore
            ?? FileAgentRunStore(fileURL: FileAgentRunStore.appSupportFileURL())
        store.reconcileInterruptedRuns()
        self.agentRunStore = store
        self.agentRuns = store.loadAll()
        let undoLedger = agentUndoLedger
            ?? FileAgentUndoLedger(rootDirectoryURL: FileAgentUndoLedger.appSupportDirectoryURL())
        self.agentUndoLedger = undoLedger
        self.agentLauncher = HeadlessAgentLauncher(store: store, undoLedger: undoLedger)

        let standingOrders = standingOrderRepository
            ?? FileStandingOrderRepository(directoryURL: FileStandingOrderRepository.appSupportDirectoryURL())
        self.standingOrderRepository = standingOrders
        self.loadedStandingOrders = standingOrders.loadAll()
        self.latestAgentUndoEntry = undoLedger.latestReadyEntry()

        let speakProvider = VoiceSpeakProvider.fromUserDefaults()
        self.voiceSynthesisClient = Self.makeVoiceSynthesisClient(
            for: speakProvider,
            workerBaseURL: Self.workerBaseURL
        )
        print("🔊 Speak: using \(speakProvider.displayName)")
        AppTheme.currentHex = themeColorHex

        bindAgentLauncher()
        if let executor = selectedBrain.executor {
            defaultHeadlessExecutor = executor
        }
    }
    /// Canonical interaction state. Every change goes through dispatch(_:)
    /// so illegal transitions are rejected instead of corrupting the pipeline.
    @Published private(set) var state: CompanionState = .idle

    /// Legacy 4-state view of `state`, kept as a computed property so the
    /// overlay and panel UI keep working unchanged.
    var voiceState: CompanionVoiceState {
        switch state {
        case .idle, .error:
            return .idle
        case .listening:
            return .listening
        case .finalizingTranscript, .capturingContext, .thinking:
            return .processing
        // While the buddy flies to point, show the triangle (idle visuals) —
        // this matches the previous early-idle behavior before TTS starts.
        case .guiding:
            return .idle
        case .speaking:
            return .responding
        // Running work stays ambient; filament carries it. Waiting for a
        // decision is only agent state allowed to occupy notch slots.
        case .agentRunning:
            return .idle
        case .waitingForApproval:
            return .responding
        }
    }

    /// Why a typed message cannot be answered right now, in the words the
    /// composer should show. Nil when it can be sent.
    ///
    /// The Talk pipeline used to drop a typed message whenever `voiceState`
    /// was not idle and say nothing at all — and a plan waiting for approval
    /// is exactly such a state, so everything typed while reading a plan
    /// disappeared on Enter.
    var typedMessageBusyReason: String? {
        switch state {
        case .listening, .finalizingTranscript:
            return "Finish the voice request first."
        case .waitingForApproval:
            return "A plan is waiting on you. Approve or dismiss it, then ask."
        default:
            return nil
        }
    }

    /// True while a capture shortcut is held — typed send must not steal that.
    var canAcceptTypedAgentTask: Bool {
        switch state {
        case .listening, .finalizingTranscript:
            return false
        default:
            return true
        }
    }

    /// Only a decision gets foreground notch treatment. Running work is
    /// represented by filaments instead.
    var isForegroundAgentActive: Bool {
        switch state {
        case .waitingForApproval:
            return true
        default:
            return false
        }
    }

    /// Applies an event to the canonical state machine. Illegal transitions
    /// are logged and ignored — e.g. a stale dictation-flag callback firing
    /// while the response pipeline owns the state.
    private func dispatch(_ event: CompanionEvent) {
        guard let nextState = CompanionStateMachine.transition(from: state, on: event) else {
            print("🚫 CompanionState: ignoring illegal transition — \(state) + \(event)")
            return
        }
        if nextState != state {
            print("🎛️ CompanionState: \(state) → \(nextState)")
        }

        playUISoundForTransition(event)

        state = nextState
    }

    /// Interaction sounds at the two moments users benefit from an audio cue:
    /// the mic opening for a talk request, and the spoken answer arriving.
    /// Dictation/spatial flows stay silent — sound there would be noise.
    private func playUISoundForTransition(_ event: CompanionEvent) {
        switch event {
        case .startListening(.talk):
            UISoundPlayer.shared.play(.listenStart)
        case .beginSpeaking:
            UISoundPlayer.shared.play(.responseReady)
        default:
            break
        }
    }

    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Structured Drawing Annotations

    /// Resolved drawing annotations currently on screen (from the model's
    /// visualActions JSON). Each overlay renders only those matching its
    /// display frame; entries self-expire via their TTL.
    @Published private(set) var activeAnnotations: [ResolvedAnnotation] = []
    private var annotationExpiryTask: Task<Void, Never>?
    // lazy so the closure can capture self (stored-property initializers cannot).
    private lazy var annotationClearKeyMonitor = AnnotationClearKeyMonitor { [weak self] in
        self?.cancelSpatialContextAndAnnotations()
    }

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the welcome animation.
    /// Result line for the last typed command — "no such command", the
    /// /help listing, or a confirmation. Nil when there is nothing to say.
    @Published var commandBarFeedback: String?

    /// True while `/memory clear` is waiting for a yes. Memory deletion is
    /// not undoable, so a typed command must not perform it directly.
    @Published var pendingMemoryClearConfirmation = false

    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor(
        optionProvider: { BuddyPushToTalkShortcut.currentShortcutOption }
    )
    /// Second, independent shortcut channel for contextual dictation.
    private lazy var dictateShortcutMonitor = GlobalPushToTalkShortcutMonitor(
        optionProvider: { BuddyPushToTalkShortcut.currentDictateOption }
    )
    /// Third channel: hold + freehand drag to mark a screen region.
    private lazy var spatialShortcutMonitor = GlobalPushToTalkShortcutMonitor(
        optionProvider: { BuddyPushToTalkShortcut.currentSpatialOption }
    )
    /// Fourth channel: press ctrl+command (default) to summon compact notch chat.
    private lazy var chatShortcutMonitor = GlobalPushToTalkShortcutMonitor(
        optionProvider: { BuddyPushToTalkShortcut.currentChatOption }
    )
    /// Fifth channel: tap ctrl twice to summon the typed ask box. Separate tap
    /// because double-tap is a different state machine from hold-to-talk.
    private lazy var textDoubleTapMonitor = ModifierDoubleTapMonitor(
        shortcutProvider: { ModifierDoubleTapPreferences.textShortcut },
        isEnabledProvider: { ModifierDoubleTapPreferences.isTextShortcutEnabled }
    )
    /// Sixth channel: tap fn+ctrl twice to start a turn that ends when you
    /// stop talking rather than when you let go of a key.
    private lazy var handsFreeDoubleTapMonitor = ModifierDoubleTapMonitor(
        shortcutProvider: { ModifierDoubleTapPreferences.handsFreeShortcut },
        isEnabledProvider: { ModifierDoubleTapPreferences.isHandsFreeShortcutEnabled }
    )

    private var textDoubleTapCancellable: AnyCancellable?
    private var handsFreeDoubleTapCancellable: AnyCancellable?

    /// Watches the mic level during a hands-free turn so it can stop on
    /// silence. Nil whenever no hands-free turn is running.
    private var handsFreeSilenceCancellable: AnyCancellable?
    private var handsFreeTurnStartedAt: Date?
    private var handsFreeHasHeardSpeech = false
    private var handsFreeSilenceStartedAt: Date?

    /// HeyClicky-style ambient pill anchored over the MacBook notch.
    private lazy var notchCompanionController = NotchCompanionController()

    @Published var showNotchCompanion: Bool = NotchCompanionController.isEnabled {
        didSet {
            NotchCompanionController.isEnabled = showNotchCompanion
            notchCompanionController.setHidden(!showNotchCompanion)
        }
    }

    /// Subtle interaction sounds (mic-open blip, response-ready chime).
    /// Persisted so the choice survives app restarts.
    @Published var isUISoundEnabled: Bool = UserDefaults.standard.object(forKey: CompanionManager.uiSoundPreferenceKey) == nil
        ? true
        : UserDefaults.standard.bool(forKey: CompanionManager.uiSoundPreferenceKey) {
        didSet {
            UserDefaults.standard.set(isUISoundEnabled, forKey: CompanionManager.uiSoundPreferenceKey)
        }
    }

    /// Color picked on onboarding (and later in Models). One accent for the
    /// notch rim, cursor, and buttons.
    @Published var themeColorHex: String = AppTheme.resolvedHex(
        storedRawValue: UserDefaults.standard.string(forKey: CompanionManager.themeColorPreferenceKey)
    )

    /// Chasing rim around the hardware camera housing. Independent of color;
    /// default on, can be switched off.
    @Published var isNotchOutlineEnabled: Bool = AppTheme.outlineEnabled(
        storedObject: UserDefaults.standard.object(forKey: CompanionManager.notchOutlinePreferenceKey)
    ) {
        didSet {
            UserDefaults.standard.set(isNotchOutlineEnabled, forKey: Self.notchOutlinePreferenceKey)
        }
    }

    var themeColor: Color { Color(hex: themeColorHex) }

    /// Gate between a model-requested action and the Mac actually doing
    /// it. Off until the user turns it on; destructive actions always ask.
    let computerUseCoordinator = ComputerUseCoordinator()

    /// Same gate, for a connector tool call the Talk model asks to make.
    /// Each connector's own `ConnectorApprovalPolicy` decides whether a
    /// given call needs it; this coordinator only owns the suspend/resume.
    let connectorToolCoordinator = ConnectorToolCoordinator()

    /// Run every `[ACT:…]` directive found in a finished reply, in order,
    /// and return what happened so it can be shown or spoken. Returns nil
    /// when the reply contained no directives, which is the common case.
    @discardableResult
    func performComputerUseDirectives(in responseText: String) async -> String? {
        guard computerUseCoordinator.isEnabled else { return nil }
        let parsedActions = ComputerUseTagParser.parseActions(in: responseText)
        guard !parsedActions.isEmpty else { return nil }

        var outcomeLines: [String] = []
        for parsed in parsedActions {
            let outcome = await computerUseCoordinator.perform(
                parsed.action,
                statedReason: ComputerUseTagParser.strippingActionTags(from: responseText)
            )
            outcomeLines.append(outcome)
        }
        return outcomeLines.joined(separator: "\n")
    }

    /// Which outside services HeyMate may reach, and how each one
    /// authenticates. The store is persisted state; the runtime holds the
    /// live MCP sessions and performs the connect/disconnect handshakes.
    let connectorStore = ConnectorStore()
    lazy var connectorRuntime = ConnectorRuntime(store: connectorStore)
    let composioConnections = ComposioConnectionsRuntime()
    let composioToolkitDirectory = ComposioToolkitDirectory()
    let contextualConnectorSuggestionMonitor = ContextualConnectorSuggestionMonitor()

    /// The full desktop window. Built lazily — a user who never opens it
    /// never pays for it, and the app stays menu-bar-only until they do.
    private lazy var desktopWindowController = HeyMateDesktopWindowController(companionManager: self)

    /// Open (or focus) the HeyMate desktop window at a given section.
    /// Called from the notch card and from the `heymate://open` deep link.
    func openDesktopWindow(section: DesktopSection = .chat) {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        desktopWindowController.show(initialSection: section)
    }

    var isDesktopWindowVisible: Bool { desktopWindowController.isVisible }

    /// Handle a `heymate://` URL. Composio browser sign-in is confirmed by
    /// polling, so deep links only need to route to desktop sections.
    @discardableResult
    func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "heymate" else { return false }
        guard url.host?.lowercased() == "open" else { return false }
        let requestedSection = url.pathComponents
            .dropFirst()
            .first
            .flatMap(DesktopSection.init(rawValue:)) ?? .chat
        openDesktopWindow(section: requestedSection)
        return true
    }

    /// Micro-apps that share the notch with the assistant: file shelf,
    /// timers, now playing, battery, next event, clipboard. Every one is
    /// opt-in and each publishes at most one ambient activity; the center
    /// arbitrates which activity the collapsed pill shows.
    let notchActivityCenter = NotchActivityCenter()

    /// Whatever the notch should be showing when the companion itself is
    /// idle. Mirrors `notchActivityCenter.frontmostActivity` so the notch
    /// controller has a single publisher to observe.
    @Published private(set) var activeNotchActivity: NotchActivity?

    /// Point the companion cursor at whatever computer use is about to
    /// click. The executor pauses ~280 ms after this fires, which is what
    /// makes a synthesized click something the user watches rather than
    /// something that merely happens to them.
    private func startComputerUseCursorBridge() {
        computerUseCoordinator.onWillSynthesizeInput = { [weak self] targetPoint in
            guard let self else { return }
            self.detectedElementScreenLocation = targetPoint
        }
    }

    /// Bridges the activity center's arbitration result onto this manager
    /// and keeps the agent's own activity in sync with pipeline state.
    private func startNotchActivityCenter() {
        notchActivityCenter.start()
        notchActivityCenter.$frontmostActivity
            .receive(on: DispatchQueue.main)
            .sink { [weak self] activity in
                self?.activeNotchActivity = activity
            }
            .store(in: &notchActivityCancellables)

        notchActivityCenter.timerStore.onTimerCompleted = { [weak self] label in
            self?.handleTimerCompleted(label: label)
        }
    }

    private func handleTimerCompleted(label: String) {
        UISoundPlayer.shared.play(.responseReady)
        notchActivityCenter.agentActivity = NotchActivity(
            kind: .timer,
            trailingText: "done",
            tintHex: "34D399",
            expiresAt: Date().addingTimeInterval(6)
        )
        // A reminder set through Talk exists to be heard, not just seen in
        // the notch — the whole point of "remind me to leave in 15" is a
        // spoken nudge, not a silent pill most people are not looking at.
        Task { [weak self] in
            try? await self?.voiceSynthesisClient.speakText(label)
        }
    }

    // MARK: - Standing Orders

    /// Event-driven signals plus coarse duration recheck. Screen-text rules
    /// read bounded AX text only when explicitly enabled; never screenshots.
    private func startStandingOrders() {
        reloadStandingOrders()

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { notification in
                (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName
            }
            .sink { [weak self] applicationName in
                self?.considerStandingOrderSignal(
                    StandingOrderSignal(kind: .frontmostApp, value: applicationName, observedAt: Date())
                )
            }
            .store(in: &standingOrderCancellables)

        notchActivityCenter.clipboardStore.$entries
            .compactMap(\.first)
            .removeDuplicates(by: { $0.id == $1.id })
            .sink { [weak self] clipboardEntry in
                self?.considerStandingOrderSignal(
                    StandingOrderSignal(kind: .clipboard, value: clipboardEntry.text, observedAt: clipboardEntry.copiedAt)
                )
            }
            .store(in: &standingOrderCancellables)

        notchActivityCenter.calendarMonitor.$nextEvent
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] event in
                self?.considerStandingOrderSignal(
                    StandingOrderSignal(kind: .calendar, value: event.title, observedAt: Date())
                )
            }
            .store(in: &standingOrderCancellables)

        // Duration rules need another evaluation while context remains
        // unchanged. This never captures screen or starts work.
        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] now in
                guard let self else { return }
                for signal in Array(self.latestStandingOrderSignals.values) {
                    self.considerStandingOrderSignal(
                        StandingOrderSignal(kind: signal.kind, value: signal.value, observedAt: now)
                    )
                }
                self.collectStandingOrderScreenTextIfNeeded(observedAt: now)
            }
            .store(in: &standingOrderCancellables)
    }

    func reloadStandingOrders() {
        loadedStandingOrders = standingOrderRepository.loadAll()
    }

    /// Existing screen-reading flows may call this with text they already
    /// obtained. Standing Orders never initiate capture or OCR themselves.
    func considerStandingOrders(forScreenText screenText: String) {
        considerStandingOrderSignal(
            StandingOrderSignal(kind: .screenText, value: screenText, observedAt: Date())
        )
    }

    private func collectStandingOrderScreenTextIfNeeded(observedAt: Date) {
        guard loadedStandingOrders.contains(where: {
            $0.enabled && $0.signalKind == .screenText
        }), let application = NSWorkspace.shared.frontmostApplication,
        application.bundleIdentifier != Bundle.main.bundleIdentifier,
        !ExcludedApps.isCurrentlyExcluded(bundleId: application.bundleIdentifier) else { return }

        let screenText = AccessibilityElementFinder.visibleText(
            inApplicationWithProcessIdentifier: application.processIdentifier
        )
        guard !screenText.isEmpty else { return }
        considerStandingOrderSignal(
            StandingOrderSignal(kind: .screenText, value: screenText, observedAt: observedAt)
        )
    }

    private func considerStandingOrderSignal(_ signal: StandingOrderSignal) {
        latestStandingOrderSignals[signal.kind] = signal
        guard standingOrderProposal == nil else { return }
        let lastTriggeredAt = standingOrderLastTriggeredAt()
        guard let standingOrder = standingOrderEvaluator.firstReadyMatch(
            for: signal,
            in: loadedStandingOrders,
            lastTriggeredAt: lastTriggeredAt,
            now: signal.observedAt
        ) else { return }

        recordStandingOrderTrigger(standingOrder.id, at: signal.observedAt)
        if standingOrder.preplanEnabled {
            startSandboxAgent(prompt: standingOrder.task)
            return
        }

        standingOrderProposal = StandingOrderProposal(
            id: UUID(),
            standingOrderID: standingOrder.id,
            title: standingOrder.name,
            reason: "Matched \(standingOrder.signalKind.rawValue) context",
            task: standingOrder.task,
            preplanEnabled: false,
            createdAt: Date()
        )
        shouldRevealAgentsTab = true
        notchActivityCenter.agentActivity = NotchActivity(
            kind: .agent,
            trailingText: "offer",
            tintHex: "F59E0B"
        )
    }

    func approveStandingOrderProposal() {
        guard let proposal = standingOrderProposal else { return }
        standingOrderProposal = nil
        notchActivityCenter.agentActivity = nil
        startSandboxAgent(prompt: proposal.task)
    }

    func dismissStandingOrderProposal() {
        standingOrderProposal = nil
        notchActivityCenter.agentActivity = nil
    }

    @discardableResult
    func createStandingOrder(
        name: String,
        signalKind: StandingOrderSignalKind,
        contains: String,
        task: String
    ) -> Bool {
        do {
            _ = try standingOrderRepository.create(
                name: name,
                signalKind: signalKind,
                contains: contains,
                task: task
            )
            reloadStandingOrders()
            return true
        } catch {
            agentRevealErrorText = error.localizedDescription
            return false
        }
    }

    func revealStandingOrdersFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([standingOrderRepository.directory()])
    }

    func revealBehaviorContractFile() {
        NSWorkspace.shared.activateFileViewerSelecting([BehaviorContract.fileURL()])
    }

    private func standingOrderLastTriggeredAt() -> [String: Date] {
        let storedValues = UserDefaults.standard.dictionary(
            forKey: Self.standingOrderLastTriggeredPreferenceKey
        ) as? [String: Double] ?? [:]
        return storedValues.mapValues(Date.init(timeIntervalSince1970:))
    }

    private func recordStandingOrderTrigger(_ standingOrderID: String, at date: Date) {
        var storedValues = UserDefaults.standard.dictionary(
            forKey: Self.standingOrderLastTriggeredPreferenceKey
        ) as? [String: Double] ?? [:]
        storedValues[standingOrderID] = date.timeIntervalSince1970
        UserDefaults.standard.set(storedValues, forKey: Self.standingOrderLastTriggeredPreferenceKey)
    }

    func setThemeColorHex(_ hex: String) {
        let resolved = AppTheme.resolvedHex(storedRawValue: hex)
        themeColorHex = resolved
        AppTheme.currentHex = resolved
        UserDefaults.standard.set(resolved, forKey: Self.themeColorPreferenceKey)
    }

    func setNotchOutlineEnabled(_ enabled: Bool) {
        isNotchOutlineEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.notchOutlinePreferenceKey)
    }
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary. Configured via
    /// the WorkerBaseURL key in the app bundle's Info.plist.
    private static let workerBaseURL = AppBundleConfiguration
        .stringValue(forKey: "WorkerBaseURL")
        ?? "https://your-worker-name.your-subdomain.workers.dev"

    /// Read-only exposure for the settings screen, which shows which proxy
    /// the Cloud engine routes through.
    var workerBaseURLForDisplay: String { Self.workerBaseURL }

    /// Answers screen questions for every brain that is not OpenCode.
    ///
    /// Rebuilt rather than cached, because the user can change the endpoint,
    /// the model, or the key from Settings and the next question should use
    /// them.
    private var customAPIClient: any VisionConversationClient {
        ClaudeAPI(
            proxyURL: CustomAPIConfiguration.baseURL,
            model: CustomAPIConfiguration.model,
            apiKey: CustomAPIConfiguration.apiKey()
        )
    }

    /// Routes the sentences `VoiceRouter` cannot settle for free. Uses the
    /// same custom endpoint as Talk — not a CLI, because this has to answer
    /// in under two seconds.
    private lazy var voiceIntentClassifier = VoiceIntentClassifier(
        proxyURL: CustomAPIConfiguration.baseURL,
        apiKey: CustomAPIConfiguration.apiKey()
    )

    private var voiceSynthesisClient: any TTSClient = MacOSSpeechSynthesizerClient()

    /// Last-resort speaker when the selected TTS client throws. Retained so
    /// the utterance is not deallocated mid-sentence.
    private let emergencySpeechSynthesizer = NSSpeechSynthesizer()

    /// Speech-to-text backend for Talk / Dictate. Persisted independently of the brain.
    @Published var selectedListenProvider: VoiceListenProvider = VoiceListenProvider.fromUserDefaults()

    /// Text-to-speech backend for spoken replies. Persisted independently of the brain.
    @Published var selectedSpeakProvider: VoiceSpeakProvider = VoiceSpeakProvider.fromUserDefaults()

    // MARK: - Brain

    /// The one choice of what runs HeyMate. Drives which CLI takes agent jobs
    /// and which endpoint answers screen questions.
    @Published var selectedBrain: AgentBrain = AgentBrain.fromUserDefaults() {
        didSet {
            UserDefaults.standard.set(selectedBrain.rawValue, forKey: "selectedAgentBrain")
            if let executor = selectedBrain.executor {
                defaultHeadlessExecutor = executor
            }
        }
    }

    @Published var selectedClaudeModel: ClaudeModelChoice = ClaudeModelChoice.fromUserDefaults() {
        didSet {
            UserDefaults.standard.set(selectedClaudeModel.rawValue, forKey: ClaudeModelChoice.persistenceKey)
        }
    }

    @Published var selectedCodexModelID: String =
        UserDefaults.standard.string(forKey: CompanionManager.codexModelPreferenceKey) ?? "" {
        didSet {
            UserDefaults.standard.set(selectedCodexModelID, forKey: Self.codexModelPreferenceKey)
        }
    }

    @Published var selectedCodexReasoningEffort: String =
        UserDefaults.standard.string(forKey: CompanionManager.codexReasoningEffortPreferenceKey) ?? "" {
        didSet {
            UserDefaults.standard.set(
                selectedCodexReasoningEffort,
                forKey: Self.codexReasoningEffortPreferenceKey
            )
        }
    }

    /// Live catalog returned by this machine's signed-in Codex CLI. Both
    /// model availability and effort choices can change without an app update.
    @Published private(set) var codexModels: [CodexModelOption] = []
    @Published private(set) var isCodexModelRefreshInFlight = false
    @Published private(set) var codexModelCatalogErrorText: String?

    /// Base URL of the locally running `opencode serve` HTTP server.
    /// Persisted and applied by rebuilding the client.
    @Published var openCodeServerURLString: String =
        UserDefaults.standard.string(forKey: "openCodeServerURLString") ?? "http://127.0.0.1:4096" {
        didSet {
            UserDefaults.standard.set(openCodeServerURLString, forKey: "openCodeServerURLString")
            rebuildOpenCodeClient()
        }
    }

    /// Optional basic auth matching OPENCODE_SERVER_USERNAME /
    /// OPENCODE_SERVER_PASSWORD on the server. Empty password = no auth header.
    @Published var openCodeBasicAuthUsername: String =
        UserDefaults.standard.string(forKey: "openCodeBasicAuthUsername") ?? "" {
        didSet {
            UserDefaults.standard.set(openCodeBasicAuthUsername, forKey: "openCodeBasicAuthUsername")
            rebuildOpenCodeClient()
        }
    }
    @Published var openCodeBasicAuthPassword: String =
        UserDefaults.standard.string(forKey: "openCodeBasicAuthPassword") ?? "" {
        didSet {
            UserDefaults.standard.set(openCodeBasicAuthPassword, forKey: "openCodeBasicAuthPassword")
            rebuildOpenCodeClient()
        }
    }

    /// Currently selected OpenCode model as provider/model pair. Persisted
    /// separately from the Cloud-engine model choice so switching engines
    /// never loses either selection.
    @Published var openCodeProviderID: String =
        UserDefaults.standard.string(forKey: "selectedOpenCodeProviderID") ?? "" {
        didSet {
            UserDefaults.standard.set(openCodeProviderID, forKey: "selectedOpenCodeProviderID")
            rebuildOpenCodeClient()
        }
    }
    @Published var openCodeModelID: String =
        UserDefaults.standard.string(forKey: "selectedOpenCodeModelID") ?? "" {
        didSet {
            UserDefaults.standard.set(openCodeModelID, forKey: "selectedOpenCodeModelID")
            rebuildOpenCodeClient()
        }
    }

    /// Live snapshot of what the configured OpenCode server exposes. Filled by
    /// refreshOpenCodeServerStatus(); drives the model browser in Settings.
    @Published private(set) var openCodeModels: [OpenCodeModelOption] = []
    @Published private(set) var isOpenCodeServerReachable: Bool?
    @Published private(set) var openCodeServerVersion: String?
    @Published private(set) var openCodeConnectionErrorText: String?

    /// True while a health/models refresh against the OpenCode server runs,
    /// so the UI can show a spinner instead of flickering stale state.
    @Published private(set) var isOpenCodeRefreshInFlight = false

    private(set) var openCodeClient = OpenCodeClient(
        serverBaseURL: URL(string: "http://127.0.0.1:4096")!,
        providerID: nil,
        modelID: ""
    )

    /// The brain used for every conversation-style request this turn.
    var activeConversationClient: any VisionConversationClient {
        switch selectedBrain {
        case .openCode:
            return openCodeClient
        case .customAPI:
            return customAPIClient
        case .claudeCode:
            if CustomAPIConfiguration.isUsableForTalk {
                return customAPIClient
            }
            return SubscriptionCLIVisionClient(
                backend: .claude,
                model: selectedClaudeModel.cliIdentifier
            )
        case .codex:
            if CustomAPIConfiguration.isUsableForTalk {
                return customAPIClient
            }
            return SubscriptionCLIVisionClient(
                backend: .codex,
                model: selectedCodexModelID,
                reasoningEffort: selectedCodexReasoningEffort,
                textOnlyModel: SubscriptionCLIVisionClient.codexFastTalkModelIdentifier
            )
        }
    }

    /// Codex text-only Talk prefers subscription Spark even when user also
    /// configured vision endpoint. Visual turns keep existing endpoint/model.
    private func conversationClient(hasScreenContext: Bool) -> any VisionConversationClient {
        guard selectedBrain == .codex, !hasScreenContext else {
            return activeConversationClient
        }
        return SubscriptionCLIVisionClient(
            backend: .codex,
            model: SubscriptionCLIVisionClient.codexFastTalkModelIdentifier,
            textOnlyModel: SubscriptionCLIVisionClient.codexFastTalkModelIdentifier
        )
    }

    /// Trims user-edited server URLs (trailing slashes/spaces) and falls back
    /// to the standard port so a typo can't produce an invalid URL crash.
    private func normalizedOpenCodeServerURL() -> URL {
        var trimmed = openCodeServerURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed) ?? URL(string: "http://127.0.0.1:4096")!
    }

    private func rebuildOpenCodeClient() {
        openCodeClient = OpenCodeClient(
            serverBaseURL: normalizedOpenCodeServerURL(),
            providerID: openCodeProviderID.isEmpty ? nil : openCodeProviderID,
            modelID: openCodeModelID,
            basicAuthUsername: openCodeBasicAuthUsername.isEmpty ? nil : openCodeBasicAuthUsername,
            basicAuthPassword: openCodeBasicAuthPassword.isEmpty ? nil : openCodeBasicAuthPassword
        )
    }

    func setSelectedBrain(_ brain: AgentBrain) {
        selectedBrain = brain
        rebuildOpenCodeClient()
    }

    func setSelectedClaudeModel(_ choice: ClaudeModelChoice) {
        selectedClaudeModel = choice
    }

    func setSelectedCodexModel(_ option: CodexModelOption) {
        selectedCodexModelID = option.model
        let effortIsSupported = option.supportedReasoningEfforts.contains {
            $0.reasoningEffort == selectedCodexReasoningEffort
        }
        if !effortIsSupported {
            selectedCodexReasoningEffort = option.defaultReasoningEffort
        }
    }

    func setSelectedCodexReasoningEffort(_ effort: String) {
        guard selectedCodexModel?.supportedReasoningEfforts.contains(where: {
            $0.reasoningEffort == effort
        }) == true else { return }
        selectedCodexReasoningEffort = effort
    }

    func setSelectedListenProvider(_ provider: VoiceListenProvider) {
        selectedListenProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.listenPreferenceKey)
        buddyDictationManager.useTranscriptionProvider(
            BuddyTranscriptionProviderFactory.makeProvider(preferred: provider)
        )
    }

    func setSelectedSpeakProvider(_ provider: VoiceSpeakProvider) {
        selectedSpeakProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.speakPreferenceKey)
        voiceSynthesisClient.stopPlayback()
        voiceSynthesisClient = Self.makeVoiceSynthesisClient(
            for: provider,
            workerBaseURL: Self.workerBaseURL
        )
    }

    private static func makeVoiceSynthesisClient(
        for provider: VoiceSpeakProvider,
        workerBaseURL: String
    ) -> any TTSClient {
        switch provider {
        case .macOS:
            return MacOSSpeechSynthesizerClient()
        case .elevenLabs:
            return ElevenLabsTTSClient(proxyURL: "\(workerBaseURL)/tts")
        }
    }

    /// Applies a model picked in the panel or Settings. Both fields go through
    /// their persisted didSets, which rebuild the OpenCode client in one step.
    func selectOpenCodeModel(_ option: OpenCodeModelOption) {
        openCodeProviderID = option.providerID
        openCodeModelID = option.modelID
    }

    func openCodeProviderGroups(
        matching query: String = ""
    ) -> [OpenCodeModelCatalog.ProviderGroup] {
        OpenCodeModelCatalog.grouped(openCodeModels, matching: query)
    }

    /// Pings the OpenCode server for health and its full model catalog.
    /// Called from Settings ("Test Connection" / refresh) and once at startup
    /// when the OpenCode engine is active. Auto-selects the first available
    /// model when nothing valid is picked yet, so a fresh install works after
    /// just starting `opencode serve`.
    func refreshOpenCodeServerStatus() async {
        guard !isOpenCodeRefreshInFlight else { return }
        isOpenCodeRefreshInFlight = true
        defer { isOpenCodeRefreshInFlight = false }

        // Capture settings up front so a mid-flight edit doesn't mix two configs.
        let serverURL = normalizedOpenCodeServerURL()
        let authUsername = openCodeBasicAuthUsername.isEmpty ? nil : openCodeBasicAuthUsername
        let authPassword = openCodeBasicAuthPassword.isEmpty ? nil : openCodeBasicAuthPassword

        do {
            let serverVersion = try await OpenCodeClient.fetchServerVersion(
                baseURL: serverURL,
                basicAuthUsername: authUsername,
                basicAuthPassword: authPassword
            )
            let availableModels = try await OpenCodeClient.fetchAvailableModels(
                baseURL: serverURL,
                basicAuthUsername: authUsername,
                basicAuthPassword: authPassword
            )

            isOpenCodeServerReachable = true
            openCodeServerVersion = serverVersion
            openCodeConnectionErrorText = nil
            openCodeModels = availableModels.sorted {
                "\($0.providerID)\($0.modelID)".localizedStandardCompare("\($1.providerID)\($1.modelID)") == .orderedAscending
            }

            let currentSelectionIsValid = availableModels.contains {
                $0.providerID == openCodeProviderID && $0.modelID == openCodeModelID
            }
            if !currentSelectionIsValid, let firstAvailableModel = availableModels.first {
                selectOpenCodeModel(firstAvailableModel)
                print("🤖 OpenCode: auto-selected \(firstAvailableModel.id)")
            }
        } catch {
            isOpenCodeServerReachable = false
            openCodeConnectionErrorText = error.localizedDescription
        }
    }

    var selectedCodexModel: CodexModelOption? {
        codexModels.first { $0.model == selectedCodexModelID }
    }

    /// Fetches Codex's current account-aware picker catalog. Invalid stored
    /// values fall back to Codex's advertised default, never a HeyMate list.
    func refreshCodexModelCatalog() async {
        guard !isCodexModelRefreshInFlight else { return }
        isCodexModelRefreshInFlight = true
        defer { isCodexModelRefreshInFlight = false }

        do {
            let availableModels = try await CodexModelCatalogLoader.fetchAvailableModels()
            codexModels = availableModels
            codexModelCatalogErrorText = nil

            let currentModel = availableModels.first { $0.model == selectedCodexModelID }
            guard let resolvedModel = currentModel
                ?? availableModels.first(where: \.isDefault)
                ?? availableModels.first else {
                throw CodexModelCatalogError.invalidResponse
            }
            if currentModel == nil {
                selectedCodexModelID = resolvedModel.model
            }

            let effortIsSupported = resolvedModel.supportedReasoningEfforts.contains {
                $0.reasoningEffort == selectedCodexReasoningEffort
            }
            if !effortIsSupported {
                selectedCodexReasoningEffort = resolvedModel.defaultReasoningEffort
            }
        } catch {
            codexModelCatalogErrorText = error.localizedDescription
        }
    }

    /// Display name of the active brain for compact UI rows (panel footer,
    /// status lines). Falls back to the raw model id when unknown.
    var activeEngineDisplayName: String {
        switch selectedBrain {
        case .claudeCode: return selectedClaudeModel.displayName
        case .codex: return selectedCodexModel?.displayName ?? selectedCodexModelID
        case .customAPI: return CustomAPIConfiguration.model
        case .openCode:
            return openCodeModelID.isEmpty ? "OpenCode (no model)" : "\(openCodeProviderID)/\(openCodeModelID)"
        }
    }

    /// Live chat shown in the notch Chat tab. Past sessions live in `savedChats`.
    @Published private(set) var currentChat: ChatSession = .empty()

    /// Persisted chats, newest first. Empty when "Remember conversations" is off.
    @Published private(set) var savedChats: [ChatSession] = []

    /// Assistant text currently streaming into the Chat tab (and cursor overlay).
    @Published private(set) var streamingAssistantText: String = ""

    /// Completed user/assistant turns from the open chat, for the vision API.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] {
        currentChat.apiHistoryPairs(limit: 10)
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    /// Guards stale Talk completions after a newer turn cancelled the task.
    private var currentResponseCompletion: HeyMateRequestCompletionState?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var dictateTransitionCancellable: AnyCancellable?
    private var spatialTransitionCancellable: AnyCancellable?
    private var chatTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?

    /// Subscriptions owned by the notch micro-app layer. Separate from the
    /// single-purpose cancellables above so the activity center can be torn
    /// down independently of the voice pipeline.
    private var notchActivityCancellables: Set<AnyCancellable> = []
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Pending start task for the dictation channel — cancelled if the user
    /// releases the dictate shortcut before recording could begin.
    private var pendingDictateStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when Accessibility, Screen Recording, and Microphone are granted.
    /// Screen Content is requested automatically after Screen Recording — it
    /// is not a fourth setup gate.
    var allPermissionsGranted: Bool {
        WindowPositionManager.requiredPermissionsAreGranted(
            hasAccessibility: hasAccessibilityPermission,
            hasScreenRecording: hasScreenRecordingPermission,
            hasMicrophone: hasMicrophonePermission
        )
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// Newest-first snapshot of agent jobs for the Agents tab.
    @Published private(set) var agentRuns: [AgentRun] = []

    /// Exactly one proactive nudge at a time. Matching a rule only populates
    /// this value; approval starts normal read-only planning.
    @Published private(set) var loadedStandingOrders: [StandingOrder] = []
    @Published private(set) var standingOrderProposal: StandingOrderProposal?
    @Published private(set) var latestAgentUndoEntry: AgentUndoEntry?
    @Published private(set) var agentUndoErrorText = ""
    private var standingOrderCancellables: Set<AnyCancellable> = []
    private var standingOrderEvaluator = StandingOrderEvaluator()
    private var latestStandingOrderSignals: [StandingOrderSignalKind: StandingOrderSignal] = [:]

    /// CLI used for new agent jobs. Follows the Brain picker; kept as its own
    /// value so "Run in folder…" can still override one launch.
    @Published var defaultHeadlessExecutor: HeadlessExecutor = HeadlessExecutor.fromUserDefaults() {
        didSet {
            UserDefaults.standard.set(defaultHeadlessExecutor.rawValue, forKey: "defaultHeadlessExecutor")
        }
    }

    /// Flipped true when a job starts so the expanded card can switch to Agents.
    @Published var shouldRevealAgentsTab = false

    @Published private(set) var isOpenCodeCLIAvailable: Bool?
    @Published private(set) var isClaudeCLIAvailable: Bool?

    /// Sign-in state per executor, refreshed off the main actor. The launcher
    /// reads this cache instead of probing on the spawn path, because a probe
    /// spawns a process and the spawn path must never block on one.
    @Published fileprivate(set) var headlessExecutorReadiness: [HeadlessExecutor: HeadlessExecutorReadiness] = [:]

    func readiness(for executor: HeadlessExecutor) -> HeadlessExecutorReadiness {
        headlessExecutorReadiness[executor] ?? .indeterminate()
    }

    /// Soft error when Open folder points at a deleted workspace.
    @Published var agentRevealErrorText: String = ""

    /// The Claude model used for voice responses. Persisted to UserDefaults.

    /// The active Talk (push-to-talk) shortcut. Persisted via
    /// BuddyPushToTalkShortcut; takes effect immediately because the CGEvent
    /// tap consults the current option on every event.
    @Published var talkShortcutOption: BuddyPushToTalkShortcut.ShortcutOption = BuddyPushToTalkShortcut.currentShortcutOption {
        didSet {
            BuddyPushToTalkShortcut.currentShortcutOption = talkShortcutOption
        }
    }

    /// The active contextual-dictation shortcut. Separate channel from Talk:
    /// dictation inserts into the focused field instead of asking the
    /// screen-aware assistant.
    @Published var dictateShortcutOption: BuddyPushToTalkShortcut.ShortcutOption = BuddyPushToTalkShortcut.currentDictateOption {
        didSet {
            BuddyPushToTalkShortcut.currentDictateOption = dictateShortcutOption
        }
    }

    /// The spatial-selection shortcut: hold, drag a freehand region, and
    /// that region becomes priority context for the next Talk/dictate send.
    @Published var spatialSelectShortcutOption: BuddyPushToTalkShortcut.ShortcutOption = BuddyPushToTalkShortcut.currentSpatialOption {
        didSet {
            BuddyPushToTalkShortcut.currentSpatialOption = spatialSelectShortcutOption
        }
    }

    /// Press (not hold) to open the compact notch chat. Defaults to ctrl+command.
    @Published var chatShortcutOption: BuddyPushToTalkShortcut.ShortcutOption = BuddyPushToTalkShortcut.currentChatOption {
        didSet {
            BuddyPushToTalkShortcut.currentChatOption = chatShortcutOption
        }
    }

    // MARK: - Spatial Selection State

    /// Live freehand drag points in overlay-local coordinates (y-down) while
    /// a spatial capture is in progress; empty otherwise.
    @Published private(set) var spatialDraftPoints: [CGPoint] = []

    /// Last completed region selection. Consumed (then cleared) by the next
    /// Talk or Smart-dictation request; Escape also clears it.
    @Published private(set) var activeSpatialSelection: SpatialGeometry.NormalizedSelection?

    /// Display frame the current/last selection was drawn on.
    @Published private(set) var spatialSelectionScreenFrame: CGRect?

    /// Smart dictation rewrites the transcript using screen + focused-field
    /// context; Literal inserts the cleaned transcript as-is.
    @Published var dictationUsesSmartMode: Bool =
        UserDefaults.standard.object(forKey: "dictationUsesSmartMode") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "dictationUsesSmartMode") {
        didSet {
            UserDefaults.standard.set(dictationUsesSmartMode, forKey: "dictationUsesSmartMode")
        }
    }

    /// When on, Talk captures only the frontmost window instead of every
    /// display — a sharper, cheaper image when the question is about the app
    /// in front of the user. Falls back to all-screens capture whenever no
    /// frontmost window qualifies. Default off: full-screen context is the
    /// shipped behavior, and questions spanning windows/monitors need it.
    @Published var talkUsesFocusedWindowContext: Bool =
        UserDefaults.standard.bool(forKey: "talkUsesFocusedWindowContext") {
        didSet {
            UserDefaults.standard.set(talkUsesFocusedWindowContext, forKey: "talkUsesFocusedWindowContext")
        }
    }

    /// Input mode of the session currently being started — set before the
    /// mic pipeline flips its recording flags so the shared state binding
    /// publishes listening(.talk) vs listening(.dictate) correctly.
    private var inputModeOfActiveSession: CompanionInputMode = .talk

    // MARK: - Memory & Skills

    @Published private(set) var memoryItems: [MemoryItem] = []

    /// When off, nothing is written to durable memory (in-session context
    /// still works — that's just conversation history, not storage).
    @Published var rememberConversationsEnabled: Bool =
        UserDefaults.standard.object(forKey: "rememberConversations") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "rememberConversations") {
        didSet {
            UserDefaults.standard.set(rememberConversationsEnabled, forKey: "rememberConversations")
            if rememberConversationsEnabled {
                persistCurrentChatIfNeeded()
            }
        }
    }

    /// Every valid skill found across HeyMate and Claude Code local folders.
    @Published private(set) var discoveredSkills: [DiscoveredSkill] = []

    /// Active skill files in user-selected priority order.
    @Published private(set) var loadedSkills: [SkillFile] = []

    /// Re-scans the skills folder (seeding any still-missing bundled
    /// defaults first) so newly added or edited skill files apply without
    /// an app restart. Called at startup and whenever the Skills page opens.
    func reloadSkills() {
        let skillsDirectoryURL = SkillMarkdownParser.defaultDirectory()
        SkillMarkdownParser.seedDefaultsIfNeeded(intoDirectory: skillsDirectoryURL)
        discoveredSkills = SkillDirectoryScanner.scanAllLocalSources(
            heyMateSkillsDirectoryURL: skillsDirectoryURL,
            claudeCodeUserSkillsDirectoryURL: SkillDirectoryScanner.defaultClaudeCodeUserSkillsDirectory(),
            claudeCodeProjectRootPaths: SkillDirectoryScanner.uniqueProjectRootPaths(from: agentRuns)
        ) + skillRegistryInstallationStore.discoveredSkills()
        refreshActiveSkills()
    }

    func installRemoteSkill(_ descriptor: RemoteSkillDescriptor) throws {
        try skillRegistryInstallationStore.install(descriptor)
        reloadSkills()
    }

    func removeRemoteSkill(_ descriptor: RemoteSkillDescriptor) throws {
        if let discoveredSkill = discoveredSkills.first(where: { $0.remoteMetadata?.id == descriptor.id }) {
            skillActivationStore.setActive(false, for: discoveredSkill)
        }
        try skillRegistryInstallationStore.remove(id: descriptor.id)
        reloadSkills()
    }

    func isSkillActive(_ discoveredSkill: DiscoveredSkill) -> Bool {
        skillActivationStore.isActive(discoveredSkill)
    }

    func setSkillActive(_ shouldBeActive: Bool, for discoveredSkill: DiscoveredSkill) {
        skillActivationStore.setActive(shouldBeActive, for: discoveredSkill)
        refreshActiveSkills()
    }

    func moveActiveSkill(_ discoveredSkill: DiscoveredSkill, by offset: Int) {
        var orderedActiveSkills = skillActivationStore.activeSkillsInPriorityOrder(from: discoveredSkills)
        guard let currentIndex = orderedActiveSkills.firstIndex(where: { $0.id == discoveredSkill.id }) else {
            return
        }
        let destinationIndex = currentIndex + offset
        guard orderedActiveSkills.indices.contains(destinationIndex) else { return }
        orderedActiveSkills.swapAt(currentIndex, destinationIndex)
        skillActivationStore.setPriorityOrder(orderedActiveSkills.map(\.identifier))
        refreshActiveSkills()
    }

    func activeSkillPriority(for discoveredSkill: DiscoveredSkill) -> Int? {
        skillActivationStore.activeSkillsInPriorityOrder(from: discoveredSkills)
            .firstIndex(where: { $0.id == discoveredSkill.id })
            .map { $0 + 1 }
    }

    func resetSkillActivationChoices() {
        skillActivationStore.resetAllActivationChoices()
        refreshActiveSkills()
    }

    private func refreshActiveSkills() {
        loadedSkills = skillActivationStore
            .activeSkillsInPriorityOrder(from: discoveredSkills)
            .map(\.skill)
    }

    private var rollingSummaryItemId: UUID?

    func deleteMemory(id: UUID) {
        memoryRepository.delete(id: id)
        if id == rollingSummaryItemId { rollingSummaryItemId = nil }
        memoryItems = memoryRepository.loadAll()
    }

    func clearAllMemory() {
        memoryRepository.deleteAll()
        rollingSummaryItemId = nil
        memoryItems = []
        print("🧹 All durable memory cleared")
    }

    /// Compact label for the notch dock model chip.
    var notchDockModelLabel: String {
        switch selectedBrain {
        case .claudeCode:
            return selectedClaudeModel.displayName
        case .codex:
            return selectedCodexModel?.displayName ?? (selectedCodexModelID.isEmpty ? "Model" : selectedCodexModelID)
        case .customAPI:
            return CustomAPIConfiguration.model
        case .openCode:
            if let selected = openCodeModels.first(where: {
                $0.providerID == openCodeProviderID && $0.modelID == openCodeModelID
            }) {
                return selected.shortLabel
            }
            return openCodeModelID.isEmpty ? "Model" : openCodeModelID
        }
    }

    func startNewChat() {
        persistCurrentChatIfNeeded()
        currentChat = ChatSession.empty()
        streamingAssistantText = ""
        savedChats = rememberConversationsEnabled ? chatHistoryStore.loadAll() : []
    }

    func openChat(id: UUID) {
        persistCurrentChatIfNeeded()
        guard let session = chatHistoryStore.session(id: id) ?? savedChats.first(where: { $0.id == id }) else {
            return
        }
        currentChat = session
        streamingAssistantText = ""
    }

    func deleteChat(id: UUID) {
        chatHistoryStore.delete(id: id)
        savedChats = chatHistoryStore.loadAll()
        if currentChat.id == id {
            currentChat = ChatSession.empty()
            streamingAssistantText = ""
        }
    }

    func clearAllChats() {
        chatHistoryStore.deleteAll()
        savedChats = []
        currentChat = ChatSession.empty()
        streamingAssistantText = ""
    }

    private func persistCurrentChatIfNeeded() {
        guard rememberConversationsEnabled else { return }
        guard !currentChat.messages.isEmpty else { return }
        chatHistoryStore.upsert(currentChat)
        savedChats = chatHistoryStore.loadAll()
    }

    private func appendUserMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if currentChat.messages.last?.role == .user,
           currentChat.messages.last?.text == trimmed {
            return
        }
        var session = currentChat
        session.messages.append(ChatMessage(
            id: UUID(),
            role: .user,
            text: trimmed,
            createdAt: Date()
        ))
        session.updatedAt = Date()
        if session.title == ChatSession.defaultTitle {
            session.title = ChatSession.title(from: trimmed)
        }
        currentChat = session
        persistCurrentChatIfNeeded()
    }

    private func appendAssistantMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            streamingAssistantText = ""
            return
        }
        var session = currentChat
        session.messages.append(ChatMessage(
            id: UUID(),
            role: .assistant,
            text: trimmed,
            createdAt: Date()
        ))
        session.updatedAt = Date()
        currentChat = session
        streamingAssistantText = ""
        persistCurrentChatIfNeeded()
    }

    /// Replaces the single rolling session-summary item with a fresh digest
    /// of recent exchanges. One item instead of one-per-turn keeps the list
    /// inspectable rather than spammy.
    private func updateRollingSessionSummary() {
        guard rememberConversationsEnabled else { return }

        let recentExchanges = conversationHistory.suffix(6)
        guard !recentExchanges.isEmpty else { return }

        let digest = recentExchanges.map { exchange in
            "user: \(exchange.userTranscript)\nheymate: \(exchange.assistantResponse)"
        }
        .joined(separator: "\n---\n")
        let truncated = String(digest.prefix(800))

        if let existingId = rollingSummaryItemId {
            memoryRepository.delete(id: existingId)
            rollingSummaryItemId = nil
        }

        let summary = MemoryItem(
            id: UUID(),
            kind: .sessionSummary,
            text: truncated,
            createdAt: Date()
        )
        memoryRepository.append(summary)
        rollingSummaryItemId = summary.id
        memoryItems = memoryRepository.loadAll()
    }

    /// Pure prompt-block builders so prompt composition stays testable.
    nonisolated static func memoryPromptBlock(items: [MemoryItem], limit: Int = 8) -> String? {
        guard !items.isEmpty else { return nil }
        let lines = items.suffix(limit).reversed().map { item in
            "- [\(item.kind.rawValue)] \(item.text.replacingOccurrences(of: "\n", with: " "))"
        }
        return """
        things you remember from earlier (user-approved, deletable in settings):
        \(lines.joined(separator: "\n"))
        """
    }

    /// Anchors a vague follow-up ("okay", "what now", "next") to the most
    /// recent exchange instead of letting the model resolve it against an
    /// older, unrelated topic sitting earlier in the history window.
    nonisolated static func topicAnchorPromptFragment(
        mostRecentExchange: (userPlaceholder: String, assistantResponse: String)?
    ) -> String? {
        guard let mostRecentExchange else { return nil }
        let priorReply = mostRecentExchange.assistantResponse.prefix(160)
        return """
        the message below continues the immediately preceding exchange, where you last said: "\(priorReply)". if the message is short or ambiguous (e.g. "okay", "what now", "next"), keep answering that same topic — do not jump back to an earlier, unrelated exchange from further back in the conversation history.
        """
    }

    nonisolated static func skillsPromptBlock(skills: [SkillFile]) -> String? {
        guard !skills.isEmpty else { return nil }
        let blocks = skills.map { skill in
            """
            skill '\(skill.name)' (trigger: \(skill.trigger)):
            \(skill.instructions)
            """
        }
        return """
        relevant user skills for this request — follow their instructions:
        \(blocks.joined(separator: "\n\n"))
        """
    }

    /// Lists what `talkTools` actually contains, so the model knows a
    /// reminder or a connected Gmail account exists before it needs one.
    /// Returns nil when there is nothing to call, which is what keeps
    /// `BehaviorContract.toolUseSection` out of the prompt on a turn where
    /// the active brain has no tool-calling support at all.
    nonisolated static func connectorsPromptBlock(talkTools: [TalkTool]) -> String? {
        guard !talkTools.isEmpty else { return nil }
        let lines = talkTools.map { talkTool -> String in
            switch talkTool.origin {
            case .local:
                return "- \(talkTool.toolDefinition.name): \(talkTool.toolDefinition.description)"
            case .connector(_, let connectorDisplayName, _):
                return "- \(talkTool.toolDefinition.name) (\(connectorDisplayName))"
            }
        }
        return """
        connected tools:
        \(lines.joined(separator: "\n"))
        """
    }

    // MARK: - Privacy

    /// Apps whose screens are NEVER captured (password managers, System
    /// Settings, plus user additions). Published so the panel privacy
    /// section stays live.
    @Published private(set) var excludedAppBundleIds: [String] = ExcludedApps.currentList()

    func addUserAppExclusion(_ bundleId: String) {
        ExcludedApps.addUserExclusion(bundleId)
        excludedAppBundleIds = ExcludedApps.currentList()
        print("🛡️ Screen context excluded for: \(bundleId)")
    }

    func removeUserAppExclusion(_ bundleId: String) {
        ExcludedApps.removeUserExclusion(bundleId)
        excludedAppBundleIds = ExcludedApps.currentList()
    }

    /// True when the frontmost app's screen must not be captured — the
    /// pipelines degrade to voice-only / literal-dictation in that case.
    private var isFrontmostAppScreenExcluded: Bool {
        let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return ExcludedApps.isCurrentlyExcluded(bundleId: bundleId)
    }

    /// User preference for persistent cursor deployment. Off keeps the buddy
    /// docked until an interaction launches it transiently. Persisted so the
    /// launch-bay choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    /// Visual deployment phase for the notch footer launch bay. Preference and phase
    /// differ during launch/return because the overlay finishes its flight
    /// before the window is considered settled.
    @Published private(set) var cursorDockPhase: CursorDockPhase = CursorDockStateMachine.initialPhase(
        isEnabled: UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")
    )

    /// Live AppKit screen coordinate for the rocket glyph in the expanded
    /// notch footer. Not published: overlay reads it when a transition begins.
    private(set) var cursorDockAnchorScreenPoint: CGPoint?

    func updateCursorDockAnchorScreenPoint(_ point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        cursorDockAnchorScreenPoint = point
    }

    func setClickyCursorEnabled(_ enabled: Bool) {
        guard cursorDockPhase.acceptsDeploymentToggle else { return }

        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        // Turning persistent deployment off mid-conversation changes the
        // preference now, but recall waits for normal interaction completion.
        // Hiding a listening waveform or spoken reply would look like failure.
        if !enabled && voiceState != .idle {
            cursorDockPhase = .deployed
            return
        }

        cursorDockPhase = CursorDockStateMachine.phaseWhenRequesting(
            enabled: enabled,
            overlayIsVisible: isOverlayVisible
        )

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else if cursorDockPhase == .docked {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    func toggleCursorDeployment() {
        switch cursorDockPhase {
        case .docked:
            setClickyCursorEnabled(true)
        case .deployed:
            setClickyCursorEnabled(false)
        case .launching, .returning:
            break
        }
    }

    func completeCursorLaunchAnimation() {
        guard cursorDockPhase == .launching else { return }
        cursorDockPhase = CursorDockStateMachine.completedPhase(after: cursorDockPhase)
    }

    func completeCursorReturnAnimation() {
        guard cursorDockPhase == .returning else { return }
        cursorDockPhase = CursorDockStateMachine.completedPhase(after: cursorDockPhase)
        overlayWindowManager.hideOverlay()
        isOverlayVisible = false
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 HeyMate start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindDictateShortcutTransitions()
        bindSpatialShortcutTransitions()
        bindChatShortcutTransitions()
        bindDoubleTapShortcuts()
        startNotchActivityCenter()
        startStandingOrders()
        startComputerUseCursorBridge()
        contextualConnectorSuggestionMonitor.start()
        Task { await connectorRuntime.restoreEnabledConnectors() }
        Task { await composioConnections.revalidate() }
        // Escape clears any on-screen drawing annotations (master spec).
        annotationClearKeyMonitor.start()
        // Load skill files + refresh the published memory snapshot. Bundled
        // defaults are seeded first so a fresh install starts with skills.
        reloadSkills()
        BehaviorContract.seedIfNeeded()
        memoryItems = memoryRepository.loadAll()
        savedChats = rememberConversationsEnabled ? chatHistoryStore.loadAll() : []
        notchCompanionController.start(companionManager: self)
        // The notch card is the only control surface now — force it on even
        // if the old "Show in notch" toggle had been turned off. Assign AFTER
        // start() so the controller already holds `self` when it places panels.
        showNotchCompanion = true
        if !hasCompletedOnboarding || !allPermissionsGranted {
            notchCompanionController.expandPinned()
        }
        // OpenCode gets an immediate health + model-catalog fetch (which
        // also auto-selects a model if needed). Custom API warms TLS.
        rebuildOpenCodeClient()
        switch selectedBrain {
        case .openCode:
            Task { await refreshOpenCodeServerStatus() }
        case .claudeCode, .codex, .customAPI:
            _ = customAPIClient
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // notch card will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
        startExternalControlBridgeIfNeeded()
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro prompt play.
    func triggerOnboarding() {
        // Post notification so the notch card collapses and the overlay is visible
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding prompt
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and prompt.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        stopExternalControlBridge()
        globalPushToTalkShortcutMonitor.stop()
        dictateShortcutMonitor.stop()
        spatialShortcutMonitor.stop()
        chatShortcutMonitor.stop()
        textDoubleTapMonitor.stop()
        handsFreeDoubleTapMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        contextualConnectorSuggestionMonitor.stop()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        annotationClearKeyMonitor.stop()
        notchCompanionController.stop()
        annotationExpiryTask?.cancel()
        pendingDictateStartTask?.cancel()
        pendingDictateStartTask = nil
        dictateTransitionCancellable?.cancel()
        spatialTransitionCancellable?.cancel()
        chatTransitionCancellable?.cancel()
        textDoubleTapCancellable?.cancel()
        handsFreeDoubleTapCancellable?.cancel()
        endHandsFreeSilenceWatch()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        if hasAccessibilityPermission != currentlyHasAccessibility {
            hasAccessibilityPermission = currentlyHasAccessibility
        }

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
            dictateShortcutMonitor.start()
            spatialShortcutMonitor.start()
            chatShortcutMonitor.start()
            textDoubleTapMonitor.start()
            handsFreeDoubleTapMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
            dictateShortcutMonitor.stop()
            spatialShortcutMonitor.stop()
            chatShortcutMonitor.stop()
            textDoubleTapMonitor.stop()
            handsFreeDoubleTapMonitor.stop()
        }

        let currentlyHasScreenRecording = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch()
        if hasScreenRecordingPermission != currentlyHasScreenRecording {
            hasScreenRecordingPermission = currentlyHasScreenRecording
        }

        let currentlyHasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if hasMicrophonePermission != currentlyHasMicrophone {
            hasMicrophonePermission = currentlyHasMicrophone
        }

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if hasScreenRecordingPermission && !hasScreenContentPermission && !hasAttemptedScreenContentAutoRequest {
            hasAttemptedScreenContentAutoRequest = true
            requestScreenContentPermission()
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false
    private var hasAttemptedScreenContentAutoRequest = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, _ in
                guard let self else { return }
                // The reducer rejects transitions that would stomp
                // pipeline-owned states (capturing/thinking/guiding/speaking),
                // so stale dictation-flag callbacks are harmless here.
                if isFinalizing {
                    self.dispatch(.finishListening)
                } else if isRecording {
                    self.dispatch(.startListening(self.inputModeOfActiveSession))
                } else if !self.state.isIdle && self.currentResponseTask == nil {
                    // Recording stopped without producing a response — e.g.
                    // the user pressed and released without saying anything.
                    // Return to idle and schedule the transient hide so the
                    // overlay doesn't get stuck on screen.
                    self.dispatch(.interactionFinished)
                    self.scheduleTransientHideIfNeeded()
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func bindDictateShortcutTransitions() {
        // Separate cancellable so Talk and Dictate channels stay independent.
        dictateTransitionCancellable = dictateShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleDictateTransition(transition)
            }
    }

    private func bindSpatialShortcutTransitions() {
        spatialTransitionCancellable = spatialShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleSpatialTransition(transition)
            }
    }

    private func bindChatShortcutTransitions() {
        chatTransitionCancellable = chatShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleChatShortcutTransition(transition)
            }
    }

    private func bindDoubleTapShortcuts() {
        textDoubleTapCancellable = textDoubleTapMonitor
            .doubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleTextDoubleTap()
            }

        handsFreeDoubleTapCancellable = handsFreeDoubleTapMonitor
            .doubleTapPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleHandsFreeDoubleTap()
            }
    }

    /// Text mode: the typed ask box, summoned from anywhere. Reuses the same
    /// compact chat surface the chat hold-shortcut opens, so there is one
    /// composer rather than two that can disagree.
    private func handleTextDoubleTap() {
        guard !buddyDictationManager.isDictationInProgress else { return }
        notchCompanionController.toggleCompactChat()
    }

    /// Hands-free: same talk turn as push-to-talk, but nothing is being held,
    /// so the turn has to end itself. A second double tap ends it early.
    private func handleHandsFreeDoubleTap() {
        if handsFreeSilenceCancellable != nil {
            finishHandsFreeTurn()
            return
        }

        guard !buddyDictationManager.isDictationInProgress else { return }
        handleShortcutTransition(.pressed)
        beginHandsFreeSilenceWatch()
    }

    /// How quiet counts as quiet, and for how long. The threshold is on the
    /// same normalized 0...1 scale the waveform uses.
    private static let handsFreeSilencePowerThreshold: CGFloat = 0.06
    private static let handsFreeSilenceDuration: TimeInterval = 1.6
    /// Backstop for a turn where the mic never picks anything up, so a stray
    /// double tap cannot leave the mic open indefinitely.
    private static let handsFreeMaximumTurnDuration: TimeInterval = 45

    private func beginHandsFreeSilenceWatch() {
        handsFreeTurnStartedAt = Date()
        handsFreeHasHeardSpeech = false
        handsFreeSilenceStartedAt = nil

        handsFreeSilenceCancellable = buddyDictationManager
            .$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] audioPowerLevel in
                self?.evaluateHandsFreeSilence(audioPowerLevel: audioPowerLevel)
            }
    }

    private func evaluateHandsFreeSilence(audioPowerLevel: CGFloat) {
        guard handsFreeSilenceCancellable != nil else { return }

        let now = Date()

        if let handsFreeTurnStartedAt,
           now.timeIntervalSince(handsFreeTurnStartedAt) >= Self.handsFreeMaximumTurnDuration {
            finishHandsFreeTurn()
            return
        }

        if audioPowerLevel > Self.handsFreeSilencePowerThreshold {
            handsFreeHasHeardSpeech = true
            handsFreeSilenceStartedAt = nil
            return
        }

        // Silence before the user has said anything is just the gap between
        // the double tap and them starting to speak — not the end of a turn.
        guard handsFreeHasHeardSpeech else { return }

        guard let handsFreeSilenceStartedAt else {
            self.handsFreeSilenceStartedAt = now
            return
        }

        if now.timeIntervalSince(handsFreeSilenceStartedAt) >= Self.handsFreeSilenceDuration {
            finishHandsFreeTurn()
        }
    }

    private func finishHandsFreeTurn() {
        endHandsFreeSilenceWatch()
        handleShortcutTransition(.released)
    }

    /// Explicit notch-card equivalent of releasing Talk. A listening turn
    /// finalizes normally so spoken input is not discarded.
    func finishVoiceInputFromNotch() {
        guard voiceState == .listening else { return }
        if handsFreeSilenceCancellable != nil {
            finishHandsFreeTurn()
        } else {
            handleShortcutTransition(.released)
        }
    }

    private func endHandsFreeSilenceWatch() {
        handsFreeSilenceCancellable?.cancel()
        handsFreeSilenceCancellable = nil
        handsFreeTurnStartedAt = nil
        handsFreeHasHeardSpeech = false
        handsFreeSilenceStartedAt = nil
    }

    /// Press opens compact notch chat; a second press collapses it. Release
    /// is ignored — chat is not a hold-to-show mode.
    private func handleChatShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            notchCompanionController.toggleCompactChat()
        case .released, .none:
            break
        }
    }

    /// Spatial channel: press starts freehand capture on the cursor's screen
    /// (the overlay temporarily accepts mouse events); release finalizes the
    /// polygon and returns the overlay to click-through.
    private func handleSpatialTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard case .idle = state else { return }

            // A fresh gesture replaces any previous selection.
            clearSpatialSelection()
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            dispatch(.startListening(.spatial))

            // When persistent deployment is off, the cursor is docked and no
            // overlay window exists yet — beginSpatialCapture would find no
            // target window and silently no-op. Deploy the overlay for the
            // gesture, then undock it again afterward if it wasn't already up.
            let overlayWasAlreadyVisible = isOverlayVisible
            if !overlayWasAlreadyVisible {
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            overlayWindowManager.beginSpatialCapture { [weak self] draftPoints in
                self?.spatialDraftPoints = draftPoints
            } completion: { [weak self] screenFrame, normalizedSelection in
                guard let self else { return }
                if let screenFrame, let normalizedSelection {
                    self.spatialSelectionScreenFrame = screenFrame
                    self.activeSpatialSelection = normalizedSelection
                    print("🔲 Spatial selection captured on \(screenFrame): \(normalizedSelection.bounds)")
                }
                self.spatialDraftPoints = []
                self.overlayWindowManager.endSpatialCapture()
                if !overlayWasAlreadyVisible && !self.isClickyCursorEnabled {
                    self.overlayWindowManager.hideOverlay()
                    self.isOverlayVisible = false
                }
                self.dispatch(.interactionFinished)
            }
        case .released:
            overlayWindowManager.finishSpatialCapture()
        case .none:
            break
        }
    }

    /// Escape path: wipes annotations AND any in-progress/completed spatial
    /// selection together — one gesture, one semantic.
    func cancelSpatialContextAndAnnotations() {
        if overlayWindowManager.isSpatialCaptureActive {
            overlayWindowManager.endSpatialCapture()
            spatialDraftPoints = []
            dispatch(.interactionFinished)
        }
        activeSpatialSelection = nil
        spatialSelectionScreenFrame = nil
        clearAnnotations()
    }

    func clearSpatialSelection() {
        activeSpatialSelection = nil
        spatialSelectionScreenFrame = nil
        spatialDraftPoints = []
    }

    /// Prompt fragment describing the selected region with higher priority
    /// than the rest of the screenshot. Returns nil when nothing selected.
    private func spatialSelectionPromptFragment() -> String? {
        guard let selection = activeSpatialSelection,
              let screenFrame = spatialSelectionScreenFrame else { return nil }

        let polygonText = selection.polygon
            .map { String(format: "[%.3f,%.3f]", $0[0], $0[1]) }
            .joined(separator: ",")
        let b = selection.bounds

        return """
        PRIORITY REGION: the user circled an area on the display whose frame is \(screenFrame). Treat this region as the subject of their question above everything else visible:
        bounds(normalized x,y,w,h)=[\(String(format: "%.3f,%.3f,%.3f,%.3f", b[0], b[1], b[2], b[3]))]
        polygon(normalized)=[\(polygonText)]
        """
    }

    /// Dictate channel: hold to stream speech; on release the transcript is
    /// (Literal) cleaned or (Smart) rewritten with screen/focused-field
    /// context, then inserted into whatever field has keyboard focus.
    private func handleDictateTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            guard hasMicrophonePermission else { return }

            // Cancel any in-flight response/TTS — one interaction at a time.
            currentResponseTask?.cancel()
            voiceSynthesisClient.stopPlayback()
            clearDetectedElementLocation()
            clearAnnotations()

            inputModeOfActiveSession = .dictate
            dispatch(.startListening(.dictate))
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            pendingDictateStartTask?.cancel()
            pendingDictateStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.processDictationTranscript(finalTranscript)
                    }
                )
            }
        case .released:
            pendingDictateStartTask?.cancel()
            pendingDictateStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Contextual Dictation Pipeline

    /// Routes a finalized dictation transcript through Literal cleanup or the
    /// Smart screen-aware rewrite, then inserts into the focused text field.
    private func processDictationTranscript(_ finalTranscript: String) {
        let trimmedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            // Nothing spoken — return to idle without touching any field.
            dispatch(.interactionFinished)
            scheduleTransientHideIfNeeded()
            return
        }

        // Occupy the shared response-task slot synchronously so the voiceState
        // binding doesn't stampede to idle while the pipeline is still working.
        currentResponseTask?.cancel()

        let usesSmartMode = dictationUsesSmartMode

        currentResponseTask = Task {
            var textToInsert = trimmedTranscript
            var insertionContextSummary = "literal"

            do {
                // Privacy gate: excluded apps never get screenshotted even in
                // Smart mode — degrade to Literal insertion instead.
                let smartModePermitted = usesSmartMode && !isFrontmostAppScreenExcluded
                if usesSmartMode && !smartModePermitted {
                    print("🛡️ Dictation: frontmost app excluded — falling back to literal insert")
                }

                if smartModePermitted {
                    // Screenshot capture begins (spinner visuals).
                    dispatch(.beginContextCapture)
                    CaptureAudit.shared.recordCaptureAttempt(context: CaptureAudit.Context.dictateResponsePipeline)
                    let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    guard !Task.isCancelled else { return }
                    dispatch(.contextCaptured)

                    let focusedField = DictationInserter.focusedFieldMetadata()
                    let dimensionInfo = screenCaptures.map { capture in
                        "\(capture.label) (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    }

                    let labeledImages = zip(screenCaptures, dimensionInfo).map { capture, label in
                        (data: capture.imageData, label: label)
                    }

                    let userPrompt = Self.dictationRewriteUserPrompt(
                        transcript: trimmedTranscript,
                        focusedField: focusedField,
                        spatialFragment: spatialSelectionPromptFragment()
                    )
                    activeSpatialSelection = nil   // consumed
                    spatialSelectionScreenFrame = nil

                    let (rewritten, _) = try await activeConversationClient.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: Self.dictationRewriteSystemPrompt,
                        conversationHistory: [],
                        userPrompt: userPrompt,
                        onTextChunk: { _ in }
                    )

                    guard !Task.isCancelled else { return }

                    textToInsert = Self.cleanRewrittenDictation(rewritten)
                    insertionContextSummary = focusedField.map { "\($0.appName ?? "unknown app")" } ?? "smart/no-focus"
                } else {
                    // Literal mode still needs a legal state path for the UI;
                    // skip straight to guidance-free completion below.
                    dispatch(.beginContextCapture)
                    dispatch(.contextCaptured)
                }

                guard !Task.isCancelled else { return }

                if !textToInsert.isEmpty {
                    let outcome = await DictationInserter.insert(textToInsert)
                    print("✍️ Dictation insert (\(insertionContextSummary)): \(outcome)")
                }

                dispatch(.interactionFinished)
                scheduleTransientHideIfNeeded()
            } catch is CancellationError {
                // User started another interaction mid-rewrite.
            } catch {
                dispatch(.fail(error.localizedDescription))
                print("⚠️ Dictation pipeline error: \(error)")
                dispatch(.interactionFinished)
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// Strips code fences/quotes models sometimes wrap around rewrite output.
    static func cleanRewrittenDictation(_ rewritten: String) -> String {
        var text = rewritten.trimmingCharacters(in: .whitespacesAndNewlines)

        // Drop wrapping triple-backtick fences if present.
        if text.hasPrefix("```") {
            var body = text.dropFirst(3)
            if body.hasPrefix("\n") { body = body.dropFirst() }
            if let fenceRange = body.range(of: "```", options: .backwards) {
                body = body[..<fenceRange.lowerBound]
            }
            text = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Strip symmetric surrounding quotes ("..." or “...”).
        for pair in [("\"", "\""), ("\u{201C}", "\u{201D}")] {
            if text.count > 1, text.hasPrefix(pair.0), text.hasSuffix(pair.1) {
                text = String(text.dropFirst().dropLast())
                break
            }
        }

        return text
    }

    private static func dictationRewriteUserPrompt(
        transcript: String,
        focusedField: FocusedFieldInfo?,
        spatialFragment: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("the user just dictated this draft out loud:")
        lines.append("\"\(transcript)\"")
        lines.append("")
        if let spatialFragment {
            lines.append(spatialFragment)
            lines.append("")
        }
        if let field = focusedField {
            lines.append("the focused field they want it inserted into:")
            lines.append("- app: \(field.appName ?? "unknown") (\(field.bundleIdentifier ?? "unknown bundle"))")
            if let role = field.role { lines.append("- element role: \(role)") }
            if let subrole = field.subrole, !subrole.isEmpty { lines.append("- subrole: \(subrole)") }
            if let placeholder = field.placeholder, !placeholder.isEmpty {
                lines.append("- placeholder: \(placeholder)")
            }
            if let preview = field.currentValuePreview, !preview.isEmpty {
                lines.append("- current field content (truncated): \(preview)")
            }
        } else {
            lines.append("no focused-field metadata was readable; infer intent from the visible screen only.")
        }
        lines.append("")
        lines.append("rewrite the draft appropriately and reply with only the text to insert.")
        return lines.joined(separator: "\n")
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            // A new interaction wins over a recall already in flight. Overlay
            // view sees deployed phase and resumes normal pointer following.
            if cursorDockPhase == .returning {
                cursorDockPhase = .deployed
            }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                cursorDockPhase = .launching
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the notch card so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            voiceSynthesisClient.stopPlayback()
            clearDetectedElementLocation()

            // Interrupting whatever was happening (speaking/thinking/guiding)
            // and start listening again — Talk always interrupts.
            inputModeOfActiveSession = .talk
            dispatch(.startListening(.talk))

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.handleTalkTranscript(finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're heymate, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    structured drawing:
    when one point isn't enough — arrows, circles, boxes, freehand paths, or highlights explain it better — you may instead end your response with ONE json code block describing visual actions. coordinates are NORMALIZED 0…1 relative to that screen's width and height, origin at the top-left. use "screenId":"screenN" matching the image labels (screen1 = first labeled screen); omit screenId for the cursor's screen.

    format: {"visualActions": [ ... ]}
    action types: point, arrow, circle, roundedRect, polygon, polyline, highlight, caption, clear.
    - point/caption: {"type","x","y"} (caption also has "label")
    - arrow: {"points":[[x1,y1],[x2,y2]]} (start → end)
    - circle: {"center":[x,y],"radius":[rx,ry]}
    - roundedRect/highlight: {"rect":[x,y,w,h]}
    - polygon: 3+ points; polyline: 2+ points
    - clear removes everything currently drawn
    each action may include a short "label" (shown near the shape) and "ttlMs".

    rules for json drawing: never mix the json block and a [POINT:] tag in one response; never mention the json, keys, or coordinates aloud — they are silent visuals only; prefer a single clear shape over many overlapping ones.

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    // MARK: - AI Response Pipeline

    /// Voice and typed Ask-anything. Local open/volume is a sub-100ms
    /// fast-path. Coding jobs (`agent, …` / `build a …`) mint a sandbox.
    /// Everything else is screen-aware Talk with TTS.
    /// Returns false when the message was not accepted, so the composer can
    /// keep the text on screen instead of clearing a message nobody answered.
    @discardableResult
    func sendTypedMessage(_ typedMessageText: String) -> Bool {
        let trimmedTypedMessageText = typedMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTypedMessageText.isEmpty else { return false }

        if let typedMessageBusyReason {
            commandBarFeedback = typedMessageBusyReason
            return false
        }

        // "/" and "@" are handled before anything reaches the model, so a
        // command never gets answered as if it were a question.
        switch CommandBarParser.parse(trimmedTypedMessageText) {
        case .slashCommand(let command, _):
            runSlashCommand(command)
            return true

        case .unknownSlashCommand(let commandName):
            commandBarFeedback = commandName.isEmpty
                ? "Type a command after the slash. /help lists them."
                : "No command called /\(commandName). /help lists them."
            return false

        case .message(let messageText, let contextTokens):
            // A message that was nothing but tokens has no question in it.
            guard !messageText.isEmpty else {
                commandBarFeedback = "Add a question to go with that context."
                return false
            }

            commandBarFeedback = nil
            let messageWithContext = messageText.appending(contextPreamble(for: contextTokens))
            lastTranscript = messageText
            ClickyAnalytics.trackUserMessageSent(transcript: messageText)
            // Not `requiresIdle`: a busy Talk pipeline is something a second
            // question deliberately interrupts, and the states where typing
            // genuinely cannot be served were refused above by name.
            routeUserTranscript(messageWithContext, requiresIdle: false)
            return true
        }
    }

    /// Everything a slash command can do is something a click already does.
    /// Clearing memory is the one destructive command, so it asks first
    /// rather than acting on the keystroke.
    private func runSlashCommand(_ command: SlashCommand) {
        commandBarFeedback = nil

        if let desktopSection = command.desktopSection {
            openDesktopWindow(section: desktopSection)
            return
        }

        switch command {
        case .help:
            commandBarFeedback = CommandBarParser.helpText()

        case .clearMemory:
            pendingMemoryClearConfirmation = true

        case .checkForUpdates:
            AppUpdateController.shared.checkForUpdates()

        case .chat, .agents, .connectors, .skills, .memory, .privacy, .settings, .notch:
            // Handled by the desktopSection branch above.
            break
        }
    }

    /// Confirms the `/memory clear` prompt. Separate from `clearAllMemory()`
    /// so the confirmation state is always cleared with it.
    func confirmPendingMemoryClear() {
        pendingMemoryClearConfirmation = false
        clearAllMemory()
        commandBarFeedback = "Memory cleared."
    }

    func cancelPendingMemoryClear() {
        pendingMemoryClearConfirmation = false
    }

    /// Builds the text appended to a message for each `@token`. Returns an
    /// empty string when there are no tokens, so the ordinary path is
    /// byte-for-byte what it was before the command bar existed.
    private func contextPreamble(for contextTokens: [ContextToken]) -> String {
        guard !contextTokens.isEmpty else { return "" }

        var sections: [String] = []

        for token in contextTokens {
            switch token {
            case .skills:
                guard !loadedSkills.isEmpty else {
                    sections.append("Loaded skills: none.")
                    continue
                }
                let skillLines = loadedSkills.map { skill in
                    "- \(skill.name): \(skill.trigger)"
                }
                sections.append("Loaded skills:\n" + skillLines.joined(separator: "\n"))

            case .memory:
                guard !memoryItems.isEmpty else {
                    sections.append("Remembered notes: none.")
                    continue
                }
                let memoryLines = memoryItems.map { "- \($0.text)" }
                sections.append("Remembered notes:\n" + memoryLines.joined(separator: "\n"))

            case .clipboard:
                let clipboardText = NSPasteboard.general.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !clipboardText.isEmpty else {
                    sections.append("Clipboard: empty.")
                    continue
                }
                sections.append("Clipboard contents:\n\(clipboardText)")
            }
        }

        return "\n\n" + sections.joined(separator: "\n\n")
    }

    /// Shared front door for push-to-talk. Already inside the Talk pipeline,
    /// so it must not idle-gate — that would drop the transcript.
    private func handleTalkTranscript(_ transcript: String) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }
        routeUserTranscript(trimmedTranscript, requiresIdle: false)
    }

    /// Fast-path first (open app / volume). AgentInvocation remains the
    /// coding-agent authority. Hybrid and destructive confirmation stay Talk
    /// — they are not a 13-guard classifier.
    private func routeUserTranscript(_ transcript: String, requiresIdle: Bool) {
        if let instruction = StandingOrderVoiceInstruction.parse(transcript) {
            let created = createStandingOrder(
                name: instruction.name,
                signalKind: instruction.signalKind,
                contains: instruction.contains,
                task: instruction.task
            )
            speakLine(created
                ? "standing order saved. i'll offer, never start it."
                : "i couldn't save that standing order.")
            return
        }
        switch VoiceRouter.decide(transcript) {
        case .local(let action):
            performLocalVoiceAction(action)
        case .agent:
            startSandboxAgentFromTranscript(transcript)
        case .hybrid, .confirmDestructive, .talk:
            sendToTalk(transcript, requiresIdle: requiresIdle)
        case .needsClassification:
            classifyThenRoute(transcript, requiresIdle: requiresIdle)
        }
    }

    /// The free tier could not decide, so one small-model call does.
    ///
    /// The wait is real, which is why `VoiceRouter` answers everything it can
    /// first — a screen question never reaches here. If the call fails or is
    /// slow, the old prefix-and-word-list behaviour is the floor: worst case
    /// the app routes exactly as well as it did before, never worse.
    private func classifyThenRoute(_ transcript: String, requiresIdle: Bool) {
        Task { [weak self] in
            guard let self else { return }
            self.voiceIntentClassifier.configure(
                proxyURL: CustomAPIConfiguration.baseURL,
                apiKey: CustomAPIConfiguration.apiKey()
            )
            let decision = await self.voiceIntentClassifier.classify(transcript)

            guard let decision else {
                self.applyFallbackRoute(transcript, requiresIdle: requiresIdle)
                return
            }

            switch decision.route {
            case .agent:
                self.startSandboxAgent(prompt: decision.task)
            case .local:
                // The classifier can spot a shortcut the local parser missed,
                // but it does not get to invent one — if the phrase still does
                // not parse into a real action, it is a question.
                if let action = LocalVoiceAction.parse(transcript) {
                    self.performLocalVoiceAction(action)
                } else {
                    self.sendToTalk(transcript, requiresIdle: requiresIdle)
                }
            case .talk:
                self.sendToTalk(transcript, requiresIdle: requiresIdle)
            }
        }
    }

    private func applyFallbackRoute(_ transcript: String, requiresIdle: Bool) {
        if case .agent = VoiceRouter.fallbackDecision(transcript) {
            startSandboxAgentFromTranscript(transcript)
        } else {
            sendToTalk(transcript, requiresIdle: requiresIdle)
        }
    }

    private func sendToTalk(_ transcript: String, requiresIdle: Bool) {
        if requiresIdle, voiceState != .idle { return }
        sendTranscriptToClaudeWithScreenshot(
            transcript: transcript,
            shouldCaptureScreen: TalkContextPolicy.shouldCaptureScreen(
                for: transcript,
                hasSpatialSelection: activeSpatialSelection != nil
            )
        )
    }

    private func performLocalVoiceAction(_ action: LocalVoiceAction) {
        let succeeded = action.perform()
        let utterance = succeeded ? action.spokenAcknowledgement : "i couldn't do that."
        Task { [weak self] in
            try? await self?.voiceSynthesisClient.speakText(utterance)
        }
    }

    /// Captures a screenshot, sends it along with the transcript to the
    /// active engine, and plays the response aloud via the selected TTS
    /// (Mac system voice by default). The cursor stays in the spinner until
    /// audio begins. A [POINT:] tag or visualActions JSON can fly the buddy.
    private func sendTranscriptToClaudeWithScreenshot(
        transcript: String,
        shouldCaptureScreen: Bool
    ) {
        currentResponseCompletion?.didComplete = true
        currentResponseTask?.cancel()
        voiceSynthesisClient.stopPlayback()

        let completion = HeyMateRequestCompletionState()
        currentResponseCompletion = completion
        currentResponseTask = Task {
            appendUserMessage(transcript)
            streamingAssistantText = ""

            dispatch(.beginContextCapture)

            do {
                let screenCaptures: [CompanionScreenCapture]
                var contextUnavailableNote = ""
                if !shouldCaptureScreen {
                    print("⚡️ Talk: text-only fast path")
                    screenCaptures = []
                } else if isFrontmostAppScreenExcluded {
                    print("🛡️ Talk: frontmost app excluded — voice-only response")
                    contextUnavailableNote = "(the user's screen context is unavailable right now; answer from the words alone and never claim to see anything on screen)"
                    screenCaptures = []
                } else {
                    CaptureAudit.shared.recordCaptureAttempt(context: CaptureAudit.Context.talkResponsePipeline)
                    if talkUsesFocusedWindowContext {
                        // Focused-window capture falls back to all screens
                        // itself when no frontmost window qualifies.
                        screenCaptures = try await CompanionScreenCaptureUtility.captureFocusedWindowAsJPEG()
                    } else {
                        screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    }
                }

                guard !Task.isCancelled, !completion.didComplete else { return }

                dispatch(.contextCaptured)

                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let spatialFragment = spatialSelectionPromptFragment()
                activeSpatialSelection = nil
                spatialSelectionScreenFrame = nil

                var promptParts: [String] = []
                if !contextUnavailableNote.isEmpty {
                    promptParts.append(contextUnavailableNote)
                }
                if let spatialFragment {
                    promptParts.append(spatialFragment)
                }
                if let memoryBlock = Self.memoryPromptBlock(items: memoryItems) {
                    promptParts.append(memoryBlock)
                }
                if let topicAnchor = Self.topicAnchorPromptFragment(mostRecentExchange: historyForAPI.last) {
                    promptParts.append(topicAnchor)
                }
                promptParts.append(transcript)

                let matchedSkills = SkillRetrieval.relevant(
                    skills: loadedSkills,
                    transcript: transcript
                )

                let talkClient = conversationClient(hasScreenContext: !labeledImages.isEmpty)
                // Only a client that can actually run a tool-use loop gets
                // handed tools — advertising `start_timer` to a backend that
                // has no way to call it would just teach the model to lie
                // about having done something.
                let toolCallingTalkClient = talkClient as? ToolCallingConversationClient
                let availableTalkTools = toolCallingTalkClient != nil
                    ? TalkToolCatalog.availableTools(connectorRuntime: connectorRuntime)
                    : []

                let effectiveSystemPrompt = BehaviorContract.combinedSystemPrompt(
                    voicePersonaPrompt: Self.companionVoiceResponseSystemPrompt,
                    matchedSkillsBlock: Self.skillsPromptBlock(skills: matchedSkills),
                    isComputerControlEnabled: computerUseCoordinator.isEnabled,
                    connectedToolsBlock: Self.connectorsPromptBlock(talkTools: availableTalkTools)
                )

                let fullResponseText: String
                if let toolCallingTalkClient, !availableTalkTools.isEmpty {
                    (fullResponseText, _) = try await toolCallingTalkClient.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: effectiveSystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: promptParts.joined(separator: "\n\n"),
                        availableTools: availableTalkTools.map(\.toolDefinition),
                        onTextChunk: { [weak self] chunk in
                            self?.streamingAssistantText = PointingTagParser.stripTrailingFragment(
                                VisualActionParser.extract(from: chunk).spokenText
                            )
                        },
                        onToolCallRequested: { [weak self] toolCall in
                            guard let self else { return ("HeyMate is no longer available.", true) }
                            return await self.executeTalkTool(toolCall, availableTalkTools: availableTalkTools)
                        }
                    )
                } else {
                    (fullResponseText, _) = try await talkClient.analyzeImageStreaming(
                        images: labeledImages,
                        systemPrompt: effectiveSystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: promptParts.joined(separator: "\n\n"),
                        onTextChunk: { [weak self] chunk in
                            self?.streamingAssistantText = PointingTagParser.stripTrailingFragment(
                                VisualActionParser.extract(from: chunk).spokenText
                            )
                        }
                    )
                }

                guard !Task.isCancelled, !completion.didComplete else { return }

                let extracted = VisualActionParser.extract(from: fullResponseText)
                if !extracted.actions.isEmpty {
                    applyVisualActions(extracted.actions, screenCaptures: screenCaptures)
                }

                let parseResult = PointingTagParser.parse(extracted.spokenText)
                applyPointingParseResult(parseResult, screenCaptures: screenCaptures)
                // Strip any [ACT:…] directives before the text is spoken —
                // the user should hear "I'll click Send", not the markup.
                let spokenText = ComputerUseTagParser.strippingActionTags(
                    from: parseResult.spokenText
                )

                appendAssistantMessage(spokenText)
                print("🧠 Conversation history: \(conversationHistory.count) exchanges")
                updateRollingSessionSummary()

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                if AgentEscalation.shouldEscalate(responseText: spokenText, transcript: transcript) {
                    completion.didComplete = true
                    startSandboxAgent(prompt: AgentEscalation.agentInstruction(from: transcript))
                    return
                }

                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await voiceSynthesisClient.speakText(spokenText)
                        dispatch(.beginSpeaking)
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ Voice synthesis error: \(error)")
                        speakPipelineFailure(error)
                    }
                }

                // Act last, after the user has heard what is about to
                // happen. Each directive above read-only opens an approval
                // card and waits for an answer.
                if let actionOutcome = await performComputerUseDirectives(in: extracted.spokenText) {
                    appendAssistantMessage(actionOutcome)
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                dispatch(.fail(error.localizedDescription))
                print("⚠️ Companion response error: \(error)")
                speakPipelineFailure(error)
            }

            guard !completion.didComplete else { return }
            completion.didComplete = true
            if !Task.isCancelled {
                dispatch(.interactionFinished)
                restoreAgentForegroundIfNeeded()
                scheduleTransientHideIfNeeded()
            }
        }
    }

    // MARK: - Talk tool calls

    /// Runs one tool call the model asked for mid-turn and returns the
    /// result text (plus whether it was an error) for `ClaudeAPI` to feed
    /// back as a `tool_result`. Never throws — a missing tool, a bad
    /// argument, a denied connector call, and a connector failure are all
    /// just different result texts the model can react to in its next
    /// sentence.
    private func executeTalkTool(
        _ toolCall: AssistantToolCall,
        availableTalkTools: [TalkTool]
    ) async -> (text: String, isError: Bool) {
        guard let matchedTool = TalkToolCatalog.tool(named: toolCall.toolName, in: availableTalkTools) else {
            return ("No tool named \(toolCall.toolName).", true)
        }

        let arguments = TalkToolCatalog.arguments(fromInputArgumentsJSON: toolCall.inputArgumentsJSON)

        switch matchedTool.origin {
        case .local:
            return executeLocalTalkTool(named: toolCall.toolName, arguments: arguments)
        case .connector(let connectorIdentifier, let connectorDisplayName, let maximumRisk):
            return await executeConnectorTalkTool(
                namespacedToolID: toolCall.toolName,
                connectorIdentifier: connectorIdentifier,
                connectorDisplayName: connectorDisplayName,
                maximumRisk: maximumRisk,
                arguments: arguments
            )
        }
    }

    /// Local actions run immediately, no approval — the same trust level
    /// "open Safari" already has when spoken directly and matched by
    /// `LocalVoiceAction` outside a tool call entirely.
    private func executeLocalTalkTool(named toolName: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
        switch toolName {
        case TalkToolCatalog.startTimerToolName, TalkToolCatalog.setReminderToolName:
            let seconds = (arguments["seconds"] as? NSNumber)?.doubleValue
                ?? (arguments["seconds"] as? Double)
                ?? Double(arguments["seconds"] as? Int ?? 0)
            let label = (arguments["label"] as? String) ?? (arguments["reminder"] as? String) ?? "Timer"
            guard seconds > 0 else {
                return ("Give the timer a duration greater than zero seconds.", true)
            }
            notchActivityCenter.timerStore.start(duration: seconds, label: label)
            return ("Set for \(NotchTimerStore.formatted(remainingSeconds: seconds)) from now: \(label).", false)

        case TalkToolCatalog.openApplicationToolName:
            guard let applicationName = arguments["name"] as? String, !applicationName.isEmpty else {
                return ("Missing the application name.", true)
            }
            let action = LocalVoiceAction.openApp(name: applicationName)
            let succeeded = action.perform()
            return succeeded ? (action.spokenAcknowledgement, false) : ("Couldn't open \(applicationName).", true)

        case TalkToolCatalog.setSystemVolumeToolName:
            guard let requestedPercent = arguments["percent"] as? Int else {
                return ("Missing the volume percent.", true)
            }
            let clampedPercent = max(0, min(100, requestedPercent))
            let action = LocalVoiceAction.setVolume(percent: clampedPercent)
            let succeeded = action.perform()
            return succeeded ? (action.spokenAcknowledgement, false) : ("Couldn't change the volume.", true)

        default:
            return ("Unknown local tool \(toolName).", true)
        }
    }

    /// Connector calls detour through the exact approval policy Settings →
    /// Integrations already lets the user set per connector
    /// (`ConnectorApprovalPolicy.requiresApproval`) before reaching
    /// `ConnectorRuntime.callTool`. Reads run freely under the default
    /// policy; anything that writes, sends, or is destructive stops for a
    /// yes first.
    private func executeConnectorTalkTool(
        namespacedToolID: String,
        connectorIdentifier: String,
        connectorDisplayName: String,
        maximumRisk: ConnectorToolRisk,
        arguments: [String: Any]
    ) async -> (text: String, isError: Bool) {
        let approvalPolicy = connectorStore.record(for: connectorIdentifier).approvalPolicy
        if approvalPolicy.requiresApproval(forRisk: maximumRisk) {
            let wasApproved = await connectorToolCoordinator.requestApproval(
                for: ConnectorToolApprovalRequest(
                    connectorDisplayName: connectorDisplayName,
                    toolName: namespacedToolID,
                    argumentsSummary: TalkToolCatalog.argumentsSummary(arguments),
                    risk: maximumRisk
                )
            )
            guard wasApproved else {
                return ("The user did not approve this action.", true)
            }
        }

        do {
            let result = try await connectorRuntime.callTool(namespacedID: namespacedToolID, arguments: arguments)
            return (result.textContent, result.isError)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    /// Speaks a classified failure. Credits only when the *model* is out of
    /// quota — never because Mac listen/speak were selected.
    private func speakPipelineFailure(_ error: Error) {
        speak(SpokenFailure.classify(error))
    }

    private func speak(_ failure: SpokenFailure) {
        guard let utterance = failure.spokenUtterance else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.voiceSynthesisClient.speakText(utterance)
            } catch is CancellationError {
                return
            } catch {
                self.emergencySpeechSynthesizer.startSpeaking(utterance)
            }
        }
    }

    /// If the cursor is in transient mode, waits for speech and pointing to
    /// finish, then recalls the buddy into the notch after a one-second pause.
    /// Cancelled automatically if the user starts another interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            while voiceSynthesisClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }

            // Returning through the launch bay gives transient interactions
            // the same physical ending as a manual recall.
            if isOverlayVisible {
                cursorDockPhase = .returning
            } else {
                cursorDockPhase = .docked
            }
        }
    }

    // MARK: - Structured Drawing Annotations

    /// Resolves the model's visual actions against the captured displays and
    /// publishes them for rendering. A "clear" action removes everything
    /// drawn before it in the same list.
    func applyVisualActions(_ actions: [VisualAction], screenCaptures: [CompanionScreenCapture]) {
        let screens = screenCaptures.enumerated().map { index, capture in
            VisualActionResolver.ScreenGeometryInfo(
                id: "screen\(index + 1)",
                frame: capture.displayFrame,
                isCursorScreen: capture.isCursorScreen
            )
        }

        activeAnnotations = VisualActionResolver.apply(actions, to: activeAnnotations, screens: screens)
        scheduleAnnotationExpiryCleanup()
    }

    /// Escape (or a model "clear" action) wipes all annotations immediately.
    func clearAnnotations() {
        guard !activeAnnotations.isEmpty else { return }
        activeAnnotations = []
        annotationExpiryTask?.cancel()
        annotationExpiryTask = nil
    }

    /// Purges expired annotations on a light loop instead of one timer per
    /// shape; stops as soon as nothing is left on screen.
    private func scheduleAnnotationExpiryCleanup() {
        annotationExpiryTask?.cancel()
        guard !activeAnnotations.isEmpty else { return }

        annotationExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                let now = Date()
                self.activeAnnotations = self.activeAnnotations.filter { $0.expiresAt > now }
                if self.activeAnnotations.isEmpty {
                    return
                }
            }
        }
    }

    /// Clean-room Smart-dictation contract (master spec 06): rewrite the
    /// spoken draft for the exact field being edited. Never invent facts;
    /// visible context resolves references and sets register only.
    private static let dictationRewriteSystemPrompt = """
    you are the dictation rewriter for heymate, a mac companion app. the user dictated a rough draft out loud; you rewrite it so it can be inserted into the text field they currently have focused.

    rules:
    - preserve their meaning exactly. never invent facts, names, numbers, or commitments.
    - use the focused-field metadata and the screenshot ONLY to resolve references ("this", "that email"), match the surrounding register (email reply vs code prompt vs form field), and fix obvious transcription artifacts.
    - match how a person would naturally write in that specific field — short for chat and forms, structured for prompts.
    - keep it as close to the user's own words as the register allows. do not pad.
    - reply with ONLY the final text to insert: no quotes around it, no code fences, no explanations, no alternatives.

    if the draft is already clean and appropriate, return it essentially unchanged.
    """

    // MARK: - Point Tag Parsing

    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        PointingTagParser.parse(responseText)
    }

    private func applyPointingParseResult(
        _ parseResult: PointingParseResult,
        screenCaptures: [CompanionScreenCapture]
    ) {
        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber = parseResult.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen })
        }()

        if let targetScreenCapture, parseResult.visualGuidance != nil {
            let actions = PointingTagParser.visualActions(
                from: parseResult,
                screenshotPixelWidth: targetScreenCapture.screenshotWidthInPixels,
                screenshotPixelHeight: targetScreenCapture.screenshotHeightInPixels
            )
            if !actions.isEmpty {
                applyVisualActions(actions, screenCaptures: screenCaptures)
            }
        }

        if parseResult.coordinate != nil {
            dispatch(.beginGuidance)
        }

        if let pointCoordinate = parseResult.coordinate,
           let targetScreenCapture {
            let geometry = DisplayGeometry(
                screenshotPixelWidth: targetScreenCapture.screenshotWidthInPixels,
                screenshotPixelHeight: targetScreenCapture.screenshotHeightInPixels,
                displayWidthInPoints: targetScreenCapture.displayWidthInPoints,
                displayHeightInPoints: targetScreenCapture.displayHeightInPoints,
                displayFrame: targetScreenCapture.displayFrame
            )
            let globalLocation = ScreenCoordinateMath.globalAppKitPoint(
                fromScreenshotPixelPoint: pointCoordinate,
                geometry: geometry
            )

            detectedElementScreenLocation = globalLocation
            detectedElementDisplayFrame = targetScreenCapture.displayFrame
            ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
            print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
        } else {
            print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
        }
    }

    // MARK: - Onboarding Intro

    /// Runs the onboarding intro without any remote video dependency:
    /// lets the local welcome animation play, triggers the live pointing
    /// demo (the "it sees my screen" moment), then streams in the prompt
    /// to try talking. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        // Give the welcome animation a moment to land before the demo fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self.performOnboardingDemoInteraction()
        }

        // Stream the try-talking prompt after the demo has had time to play.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { [weak self] in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.startOnboardingPromptStream()
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're heymate, a small cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            // Privacy gate: never demo pointing by screenshotting an
            // excluded app's screen.
            guard !isFrontmostAppScreenExcluded else {
                print("🛡️ Onboarding demo: frontmost app excluded — skipping capture")
                return
            }

            do {
                CaptureAudit.shared.recordCaptureAttempt(context: CaptureAudit.Context.onboardingDemoInteraction)
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await activeConversationClient.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    conversationHistory: [],
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let geometry = DisplayGeometry(
                    screenshotPixelWidth: cursorScreenCapture.screenshotWidthInPixels,
                    screenshotPixelHeight: cursorScreenCapture.screenshotHeightInPixels,
                    displayWidthInPoints: cursorScreenCapture.displayWidthInPoints,
                    displayHeightInPoints: cursorScreenCapture.displayHeightInPoints,
                    displayFrame: cursorScreenCapture.displayFrame
                )
                let globalLocation = ScreenCoordinateMath.globalAppKitPoint(
                    fromScreenshotPixelPoint: pointCoordinate,
                    geometry: geometry
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = cursorScreenCapture.displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }

    // MARK: - Headless agents

    private func bindAgentLauncher() {
        agentLauncher.onRunsChanged = { [weak self] in
            guard let self else { return }
            self.agentRuns = self.agentRunStore.loadAll()
        }
        agentLauncher.onEvent = { [weak self] runID, event in
            self?.handleAgentEvent(runID: runID, event: event)
        }
        agentLauncher.onUndoLedgerChanged = { [weak self] in
            self?.latestAgentUndoEntry = self?.agentLauncher.latestUndoEntry()
        }
        agentLauncher.readinessForExecutor = { [weak self] executor in
            self?.readiness(for: executor) ?? .indeterminate()
        }
        agentLauncher.openCodeModelIdentifier = { [weak self] in
            self?.selectedOpenCodeModelIdentifier
        }
        agentLauncher.claudeModelIdentifier = { [weak self] in
            self?.selectedClaudeModel.cliIdentifier
        }
        agentLauncher.codexModelIdentifier = { [weak self] in
            guard let modelIdentifier = self?.selectedCodexModelID,
                  !modelIdentifier.isEmpty else { return nil }
            return modelIdentifier
        }
        agentLauncher.codexReasoningEffort = { [weak self] in
            guard let reasoningEffort = self?.selectedCodexReasoningEffort,
                  !reasoningEffort.isEmpty else { return nil }
            return reasoningEffort
        }
        agentLauncher.mcpConfigurationJSON = {
            HeyMateMCPServer.claudeCodeConfigurationJSON(
                additionalServers: ComposioAgentAttachment.mcpServerConfiguration()
            )
        }
        agentLauncher.openCodeMCPConfigurationJSON = {
            HeyMateMCPServer.openCodeConfigurationJSON()
        }
        agentLauncher.codexMCPConfigurationArguments = {
            HeyMateMCPServer.codexConfigurationArguments()
        }
        agentLauncher.mcpChildEnvironment = {
            // Composio's key is merged in here, not into `childEnvironment()`
            // itself, so the Codex adapter's `env_vars` list keeps naming only
            // the bridge values the HeyMate server actually reads.
            HeyMateMCPServer.childEnvironment()
                .merging(ComposioAgentAttachment.childEnvironment()) { existing, _ in existing }
        }
        refreshHeadlessExecutorReadiness()
    }

    /// `provider/model` for the model picked in Settings, which is the form
    /// `opencode run --model` expects. Nil when either half is unset, so the
    /// adapter omits the flag rather than passing a malformed identifier.
    private var selectedOpenCodeModelIdentifier: String? {
        let providerID = openCodeProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelID = openCodeModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerID.isEmpty, !modelID.isEmpty else { return nil }
        return "\(providerID)/\(modelID)"
    }

    /// Voice/typed `agent, …` (and construction phrases) mint a sandbox.
    func startSandboxAgentFromTranscript(_ transcript: String) {
        guard let task = AgentInvocation.parse(transcript) else { return }
        startSandboxAgent(prompt: task)
    }

    func startSandboxAgent(prompt: String, executor: HeadlessExecutor? = nil) {
        leaveTalkPipelineForAgent()
        let explicitlyRequestedExecutor = HeadlessExecutor.explicitlyRequested(in: prompt)
        if selectedBrain.executor == nil, executor == nil, explicitlyRequestedExecutor == nil {
            agentRevealErrorText = selectedBrain.unavailableReason ?? "Pick Claude, Codex, or OpenCode as the brain first."
            speakLine("that brain doesn't run agents. pick claude, codex, or opencode.")
            shouldRevealAgentsTab = true
            return
        }
        let resolvedExecutor = executor
            ?? explicitlyRequestedExecutor
            ?? selectedBrain.executor
            ?? defaultHeadlessExecutor
        print("🤖 Agent: starting sandbox (\(resolvedExecutor.displayName)): \(prompt)")
        _ = agentLauncher.startSandbox(
            prompt: prompt,
            executor: resolvedExecutor,
            screenContext: currentAgentScreenContext()
        )
        shouldRevealAgentsTab = true
        speakAgentStartedAck()
        scheduleTransientHideIfNeeded()
    }

    /// One-line ack so Talk doesn't feel dead while the CLI boots. Does not
    /// enter `.speaking` — that would fight the agent-running state.
    private func speakAgentStartedAck() {
        speakLine("on it. i'll plan it first and show you before i touch anything.")
    }

    /// Says one plain sentence. `speak(_:)` is for `SpokenFailure` only, and
    /// an agent milestone is not a failure.
    private func speakLine(_ utterance: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.voiceSynthesisClient.speakText(utterance)
            } catch {
                print("⚠️ Agent TTS failed: \(error.localizedDescription)")
            }
        }
    }

    func startAttachedAgent(prompt: String, workspaceURL: URL, executor: HeadlessExecutor? = nil) {
        leaveTalkPipelineForAgent()
        let explicitlyRequestedExecutor = HeadlessExecutor.explicitlyRequested(in: prompt)
        if selectedBrain.executor == nil, executor == nil, explicitlyRequestedExecutor == nil {
            agentRevealErrorText = selectedBrain.unavailableReason ?? "Pick Claude, Codex, or OpenCode as the brain first."
            speakLine("that brain doesn't run agents. pick claude, codex, or opencode.")
            shouldRevealAgentsTab = true
            return
        }
        let resolvedExecutor = executor
            ?? explicitlyRequestedExecutor
            ?? selectedBrain.executor
            ?? defaultHeadlessExecutor
        _ = agentLauncher.startAttached(
            prompt: prompt,
            executor: resolvedExecutor,
            workspaceURL: workspaceURL,
            screenContext: currentAgentScreenContext()
        )
        shouldRevealAgentsTab = true
    }

    func cancelAgent(runID: UUID) {
        agentLauncher.cancel(runID: runID)
    }

    /// Stop driving a job and hand its CLI session to the user in Terminal.
    /// The queued-follow-up path is the only other way to talk to a live
    /// agent, and it waits for the current leg; this is the escape hatch for
    /// when the agent is going the wrong way *right now*.
    func takeOverAgentInTerminal(runID: UUID) {
        agentRevealErrorText = ""
        switch agentLauncher.beginTerminalTakeover(runID: runID) {
        case .success(let command):
            if !AgentTerminalTakeover.openInTerminal(command: command) {
                agentRevealErrorText = "Couldn't open Terminal. Allow HeyMate to control Terminal in System Settings › Privacy & Security › Automation."
            }
        case .failure(let unavailability):
            agentRevealErrorText = unavailability.explanation
        }
    }

    /// Per-tool approval inside a running attached job.
    func approveAgent(runID: UUID) {
        agentLauncher.resolveApproval(runID: runID, approve: true)
    }

    func denyAgent(runID: UUID) {
        agentLauncher.resolveApproval(runID: runID, approve: false)
    }

    /// The plan gate. Nothing an agent does reaches disk without passing here.
    func approveAgentPlan(runID: UUID) {
        agentLauncher.approvePlan(runID: runID)
    }

    /// Send the plan back with an objection. Same session, so the agent knows
    /// what it got wrong.
    func requestAgentReplan(runID: UUID, feedback: String) {
        agentLauncher.requestReplan(runID: runID, feedback: feedback)
    }

    /// Throw the job away. Nothing was written, so there is nothing to undo.
    func dismissAgentPlan(runID: UUID) {
        agentLauncher.dismissPlan(runID: runID)
    }

    /// More work on a finished job, in the session that already knows what it
    /// built. Still gated: the follow-up produces a plan to approve.
    @discardableResult
    func sendAgentFollowUp(runID: UUID, instruction: String) -> Bool {
        let didContinue = agentLauncher.sendFollowUp(runID: runID, instruction: instruction)
        if didContinue {
            shouldRevealAgentsTab = true
        } else {
            agentRevealErrorText = "That job can't be continued — start a new one."
        }
        return didContinue
    }

    func canSendAgentFollowUp(runID: UUID) -> Bool {
        agentLauncher.canSendFollowUp(runID: runID)
    }

    func undoLastAgentWork() {
        agentUndoErrorText = ""
        do {
            _ = try agentLauncher.undoLastAgentWork()
            latestAgentUndoEntry = agentLauncher.latestUndoEntry()
        } catch {
            agentUndoErrorText = error.localizedDescription
        }
    }

    func revealAgentFolder(runID: UUID) {
        agentRevealErrorText = ""
        guard let run = agentRunStore.run(id: runID) else { return }
        guard agentLauncher.revealWorkspace(runID: runID) else {
            agentRevealErrorText = "Folder missing"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([run.workspaceURL])
    }

    func pickExistingAgentFolder() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = "Use Folder"
        openPanel.message = "Pick a project folder for this agent. Writes need your approval."
        guard openPanel.runModal() == .OK else { return nil }
        return openPanel.url
    }

    func refreshHeadlessCLIStatus() {
        isOpenCodeCLIAvailable = LoginShellExecutableResolver.isExecutableAvailable(named: HeadlessExecutor.openCode.executableName)
        isClaudeCLIAvailable = LoginShellExecutableResolver.isExecutableAvailable(named: HeadlessExecutor.claudeCode.executableName)
        refreshHeadlessExecutorReadiness()
    }

    /// Asks each CLI whether it is actually signed in. Each probe spawns a
    /// short-lived process (`claude auth status`, `opencode auth list`), so
    /// the work happens off the main actor and the results are published back.
    /// Opens the CLI's own login in Terminal, then watches for it to take.
    ///
    /// The sign-in happens in the browser and can take a minute, so this polls
    /// rather than asking the user to come back and press refresh. It stops as
    /// soon as the executor reports ready, and gives up after a few minutes so
    /// an abandoned sign-in does not leave a probe running all session.
    func beginExecutorSignIn(_ executor: HeadlessExecutor) {
        guard HeadlessExecutorSignIn.beginSignIn(for: executor) else { return }

        Task { [weak self] in
            for _ in 0..<36 {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                guard let self else { return }
                let probed = await Task.detached(priority: .utility) {
                    HeadlessExecutorReadinessProbe.probe(executor)
                }.value
                await MainActor.run {
                    self.headlessExecutorReadiness[executor] = probed
                }
                if probed.state == .ready { return }
            }
        }
    }

    func refreshHeadlessExecutorReadiness() {
        Task { [weak self] in
            let probedReadiness = await Task.detached(priority: .utility) { () -> [HeadlessExecutor: HeadlessExecutorReadiness] in
                var results: [HeadlessExecutor: HeadlessExecutorReadiness] = [:]
                for executor in HeadlessExecutor.allCases {
                    results[executor] = HeadlessExecutorReadinessProbe.probe(executor)
                }
                return results
            }.value
            await MainActor.run {
                self?.headlessExecutorReadiness = probedReadiness
            }
        }
    }

    func sandboxParentPathForDisplay() -> String {
        AgentFolderNaming.sandboxParentURL().path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    func revealSandboxParentInFinder() {
        let parentURL = AgentFolderNaming.sandboxParentURL()
        try? FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([parentURL])
    }

    private func leaveTalkPipelineForAgent() {
        currentResponseCompletion?.didComplete = true
        currentResponseTask?.cancel()
        voiceSynthesisClient.stopPlayback()
        if !state.isIdle {
            switch state {
            case .agentRunning, .waitingForApproval:
                break
            default:
                dispatch(.interactionFinished)
            }
        }
    }

    /// Put a run that still needs a decision back in the foreground after a
    /// Talk turn has taken the state machine through `.idle`. Nothing else
    /// re-raises it: `.approvalRequested` is only legal from that run's own
    /// `.agentRunning`, so the interrupt would otherwise be lost for good.
    private func restoreAgentForegroundIfNeeded() {
        guard state.isIdle,
              let runNeedingUser = agentRunStore.runningRuns().first(where: { $0.status.needsUser })
        else { return }
        dispatch(.agentStarted(runNeedingUser.id))
        dispatch(.approvalRequested(runNeedingUser.id))
    }

    private func currentAgentScreenContext() -> AgentScreenContext {
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        return AgentScreenContext(
            activeAppName: frontmostApplication?.localizedName ?? "unknown",
            windowTitle: "unknown"
        )
    }

    private func handleAgentEvent(runID: UUID, event: AgentEvent) {
        switch event {
        case .started:
            dispatch(.agentStarted(runID))
        case .tool, .text, .sessionIdentified:
            break
        case .planReady:
            // A plan the user has not read is the one agent state allowed to
            // interrupt: nothing moves until they answer. With several agents
            // in flight the foreground may belong to a different run, and
            // `.approvalRequested` only transitions from that run's own
            // `.agentRunning` — so claim the foreground first.
            shouldRevealAgentsTab = true
            dispatch(.agentStarted(runID))
            dispatch(.approvalRequested(runID))
            speakLine("i've got a plan. take a look before i start.")
        case .approvalRequested:
            // `.approvalRequested` is only legal from this run's own
            // `.agentRunning`, and any Talk turn taken while the agent worked
            // has since returned the machine to `.idle`. Without claiming the
            // foreground first the dispatch is dropped as illegal, the notch
            // never interrupts, and the agent sits blocked on an answer that
            // cannot be given until the runtime timeout kills it.
            shouldRevealAgentsTab = true
            dispatch(.agentStarted(runID))
            dispatch(.approvalRequested(runID))
        case .finished:
            handleForegroundAgentEnded(runID: runID)
        case .failed(let message):
            speak(SpokenFailure.classify(message: message))
            handleForegroundAgentEnded(runID: runID)
        }
    }

    private func handleForegroundAgentEnded(runID: UUID) {
        switch state {
        case .agentRunning(runID), .waitingForApproval(runID):
            if let nextRun = agentRunStore.runningRuns().first {
                dispatch(.interactionFinished)
                dispatch(.agentStarted(nextRun.id))
                if nextRun.status.needsUser {
                    dispatch(.approvalRequested(nextRun.id))
                }
            } else {
                dispatch(.interactionFinished)
            }
        default:
            break
        }
    }
}
