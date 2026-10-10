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
import OSLog
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

    private static let screenPointingLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.heymate.app",
        category: "ScreenPointing"
    )
    private static let pipelineErrorLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.heymate.app",
        category: "PipelineErrors"
    )

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
    nonisolated static let claudeEffortPreferenceKey = "selectedClaudeEffort"
    nonisolated static let chatConnectorExclusionsPreferenceKey = "chatConnectorExclusions"

    nonisolated static let openCodeBasicAuthPasswordKeychainIdentifier =
        "heymate.opencode.basicAuthPassword"
    nonisolated static let legacyOpenCodeBasicAuthPasswordPreferenceKey =
        "openCodeBasicAuthPassword"

    /// Local cooldown timestamps keyed by Standing Order filename stem.
    nonisolated static let standingOrderLastTriggeredPreferenceKey = "standingOrderLastTriggeredAt"

    /// Injectable so tests can point memory at a temp file instead of the
    /// real Application Support store.
    let memoryRepository: FileMemoryRepository

    /// Injectable so tests can point chats at a temp file.
    let chatHistoryStore: FileChatHistoryStore

    /// Mates and their routines. Chats stay in `chatHistoryStore`.
    let mateDirectory: MateDirectory
    let mateRoutineScheduler: MateRoutineScheduler

    @Published var mates: [Mate] = []
    @Published var routines: [MateRoutine] = []
    @Published var activeMateID: UUID?

    /// Set while a routine is answering into a mate who is not on screen.
    var backgroundRoutineSession: ChatSession?
    var activeRoutineTurn: ActiveRoutineTurn?

    /// Injectable so tests never touch the real agent-runs.json.
    let agentRunStore: FileAgentRunStore

    /// Spawns headless OpenCode / Claude Code processes. Callbacks are bound
    /// at the end of init so they can capture self.
    let agentLauncher: HeadlessAgentLauncher
    private let agentUserNotifier = AgentUserNotifier()

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
        agentUndoLedger: FileAgentUndoLedger? = nil,
        mateStore: FileMateStore? = nil,
        routineStore: FileMateRoutineStore? = nil
    ) {
        let repository = memoryRepository
            ?? FileMemoryRepository(fileURL: FileMemoryRepository.appSupportFileURL())
        self.memoryRepository = repository
        self.memoryItems = repository.loadAll()

        let chats = chatHistoryStore
            ?? FileChatHistoryStore(fileURL: FileChatHistoryStore.appSupportFileURL())
        self.chatHistoryStore = chats
        let mateFileStore = mateStore ?? FileMateStore(fileURL: FileMateStore.appSupportFileURL())
        let routineFileStore = routineStore
            ?? FileMateRoutineStore(fileURL: FileMateRoutineStore.appSupportFileURL())
        self.mateDirectory = MateDirectory(
            mateStore: mateFileStore,
            routineStore: routineFileStore,
            chatHistoryStore: chats
        )
        self.mateRoutineScheduler = MateRoutineScheduler()

        let store = agentRunStore
            ?? FileAgentRunStore(fileURL: FileAgentRunStore.appSupportFileURL())
        self.agentRunStore = store
        self.agentRuns = store.loadAll()
        let undoLedger = agentUndoLedger
            ?? FileAgentUndoLedger(
                rootDirectoryURL: FileAgentUndoLedger.appSupportDirectoryURL(),
                recoverPreparedEntriesOnInit: false
            )
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
        HeyMateLog.log("🔊 Speak: using \(speakProvider.displayName)")
        bindOnDeviceVoiceModels()
        AppTheme.currentHex = themeColorHex

        bindAgentLauncher()
        agentLauncher.recoverPersistedRuns()
        self.agentRuns = store.loadAll()
        self.latestAgentUndoEntry = undoLedger.latestReadyEntry()
        if let executor = selectedBrain.executor {
            defaultHeadlessExecutor = executor
        }
        finishMateLaunch()
        mateRoutineScheduler.owner = self
        isRecordingMeeting = meetingNotes.isRecording
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
    func dispatch(_ event: CompanionEvent) {
        guard let nextState = CompanionStateMachine.transition(from: state, on: event) else {
            HeyMateLog.log("🚫 CompanionState: ignoring illegal transition — \(state) + \(event)")
            return
        }
        if nextState != state {
            HeyMateLog.log("🎛️ CompanionState: \(state) → \(nextState)")
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
    @Published var activeAnnotations: [ResolvedAnnotation] = []
    private var annotationExpiryTask: Task<Void, Never>?
    // lazy so the closure can capture self (stored-property initializers cannot).
    private lazy var annotationClearKeyMonitor = AnnotationClearKeyMonitor { [weak self] in
        self?.cancelGuidance()
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

    /// Updates Claude, Codex, and OpenCode when HeyMate opens. On until the
    /// user turns it off, because those CLIs are where the model lists come from.
    @Published var keepsSubscriptionCLIsUpdated: Bool = SubscriptionCLIUpdatePreference.isEnabled() {
        didSet {
            SubscriptionCLIUpdatePreference.setEnabled(keepsSubscriptionCLIsUpdated)
        }
    }

    @Published private(set) var isSubscriptionCLIUpdateInFlight = false
    @Published private(set) var subscriptionCLIUpdateStatusText: String?

    /// Subtle interaction sounds (mic-open blip, response-ready chime).
    /// Persisted so the choice survives app restarts.
    @Published var isUISoundEnabled: Bool = UserDefaults.standard.object(forKey: CompanionManager.uiSoundPreferenceKey) == nil
        ? true
        : UserDefaults.standard.bool(forKey: CompanionManager.uiSoundPreferenceKey) {
        didSet {
            UserDefaults.standard.set(isUISoundEnabled, forKey: CompanionManager.uiSoundPreferenceKey)
        }
    }

    /// The one-time "go silent?" offer after an answer played through the
    /// Mac's own speakers. Shown under the chat composer.
    @Published var isSilentModeSuggestionVisible = false
    private var hasOfferedSilentModeThisSession = false

    func acceptSilentModeSuggestion() {
        isSilentModeSuggestionVisible = false
        isSilentModeEnabled = true
    }

    func dismissSilentModeSuggestion() {
        isSilentModeSuggestionVisible = false
        SilentModePreferences.isSuggestionDismissed = true
    }

    /// The one-time "star HeyMate on GitHub" ask, shown under the chat
    /// composer after enough answered questions. See StarNudge.swift.
    @Published var isStarNudgeVisible = false

    func acceptStarNudge() {
        isStarNudgeVisible = false
        StarNudgePreferences.isResolved = true
        if let url = URL(string: SupportLinks.repositoryURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    func dismissStarNudge() {
        isStarNudgeVisible = false
        StarNudgePreferences.isResolved = true
    }

    /// Counts an answer to a question the user asked (not a routine or a
    /// mate handoff) and shows the ask once the count is reached.
    private func recordAnsweredQuestionForStarNudge() {
        guard !StarNudgePreferences.isResolved else { return }
        StarNudgePreferences.answeredQuestionCount += 1
        if StarNudgePreferences.shouldOffer(
            answeredQuestionCount: StarNudgePreferences.answeredQuestionCount,
            isResolved: StarNudgePreferences.isResolved
        ) {
            isStarNudgeVisible = true
        }
    }

    /// Called just before an answer is spoken. The answer still plays — the
    /// user asked out loud and expects to hear it — but the next time they
    /// look at the chat, the offer is waiting.
    private func offerSilentModeIfAnsweringThroughSpeakers() {
        guard SilentModePreferences.shouldOfferSilentMode(
            isSilentModeEnabled: isSilentModeEnabled,
            isSuggestionDismissed: SilentModePreferences.isSuggestionDismissed,
            hasOfferedThisSession: hasOfferedSilentModeThisSession,
            isPlayingThroughBuiltInSpeakers: HeyMateSystemOutputVolume.isDefaultOutputBuiltInSpeaker()
        ) else { return }
        hasOfferedSilentModeThisSession = true
        isSilentModeSuggestionVisible = true
    }

    /// No mic, no speaker: the Talk shortcut opens the typed composer and
    /// replies are read instead of heard. See SilentMode.swift.
    @Published var isSilentModeEnabled: Bool = SilentModePreferences.isEnabled {
        didSet {
            guard isSilentModeEnabled != oldValue else { return }
            SilentModePreferences.isEnabled = isSilentModeEnabled
            if isSilentModeEnabled {
                isSilentModeSuggestionVisible = false
                // Going quiet mid-answer should be quiet now, not after
                // the current sentence finishes.
                voiceSynthesisClient.stopPlayback()
                if handsFreeSilenceCancellable != nil {
                    finishHandsFreeTurn()
                }
            }
        }
    }

    /// Color picked on onboarding (and later in Models). One accent for the
    /// cursor and buttons.
    @Published var themeColorHex: String = AppTheme.resolvedHex(
        storedRawValue: UserDefaults.standard.string(forKey: CompanionManager.themeColorPreferenceKey)
    )

    /// Compatibility state for old preferences. Product chrome is always
    /// black now, so stale saved rim settings cannot revive an outline.
    @Published private(set) var isNotchOutlineEnabled = false

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

    /// Connected apps excluded from chat tool context. Empty means every
    /// connected app is available, matching existing behavior.
    @Published private(set) var chatConnectorExclusions: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: CompanionManager.chatConnectorExclusionsPreferenceKey) ?? []
    )

    nonisolated static func chatConnectorSelectionID(forConnectorID connectorID: String) -> String {
        "connector:\(connectorID)"
    }

    nonisolated static func chatConnectorSelectionID(forComposioSlug slug: String) -> String {
        "composio:\(slug.lowercased())"
    }

    func isChatConnectorEnabled(_ selectionID: String) -> Bool {
        !chatConnectorExclusions.contains(selectionID)
    }

    func setChatConnectorEnabled(_ enabled: Bool, selectionID: String) {
        if enabled {
            chatConnectorExclusions.remove(selectionID)
        } else {
            chatConnectorExclusions.insert(selectionID)
        }
        UserDefaults.standard.set(
            chatConnectorExclusions.sorted(),
            forKey: Self.chatConnectorExclusionsPreferenceKey
        )
        persistConnectorExclusionsOnActiveMate()
    }

    /// Replaces the chat connector exclusion set. Used when a mate becomes active.
    func replaceChatConnectorExclusions(_ ids: Set<String>) {
        if chatConnectorExclusions != ids {
            chatConnectorExclusions = ids
            UserDefaults.standard.set(
                chatConnectorExclusions.sorted(),
                forKey: Self.chatConnectorExclusionsPreferenceKey
            )
        }
        persistConnectorExclusionsOnActiveMate()
    }

    /// Exclusions for the turn in flight. A routine firing in the background
    /// speaks as its own mate, so it carries that mate's connector choices
    /// rather than those of whichever chat happens to be open. The open chat
    /// keeps `chatConnectorExclusions`, which is already the active mate's.
    private var turnConnectorExclusions: Set<String> {
        guard backgroundRoutineSession != nil,
              let ids = speakingMateForTurn()?.connectorExclusionIDs else {
            return chatConnectorExclusions
        }
        return Set(ids)
    }

    private func isConnectorSelectionEnabledForTurn(_ selectionID: String) -> Bool {
        !turnConnectorExclusions.contains(selectionID)
    }

    private var enabledChatComposioSlugs: Set<String> {
        Set(composioConnections.connectedSlugs.filter {
            isConnectorSelectionEnabledForTurn(Self.chatConnectorSelectionID(forComposioSlug: $0))
        })
    }

    func isConnectorEnabledForChat(_ connectorID: String) -> Bool {
        if connectorID == ComposioSessionStore.connectorID {
            return !enabledChatComposioSlugs.isEmpty
        }
        return isConnectorSelectionEnabledForTurn(Self.chatConnectorSelectionID(forConnectorID: connectorID))
    }

    /// The full desktop window. Built lazily — a user who never opens it
    /// never pays for it, and the app stays menu-bar-only until they do.
    private lazy var desktopWindowController = HeyMateDesktopWindowController(companionManager: self)

    /// Open (or focus) the HeyMate desktop window at a given section.
    /// Called from the notch card and from the `heymate://open` deep link.
    func openDesktopWindow(section: DesktopSection = .chat) {
        activateConnectorsIfNeeded()
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        desktopWindowController.show(initialSection: section)
    }

    var isDesktopWindowVisible: Bool { desktopWindowController.isVisible }

    /// Planning and launch races still make Cmd-Q unsafe. A write-enabled job
    /// may outlive HeyMate only after its detached runner's complete process
    /// identity has been verified against live state.
    var activeProcessBackedAgentRunCount: Int {
        agentLauncher.terminationBlockingRunCount
    }

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

    func setNotchOutlineEnabled(_: Bool) {
        isNotchOutlineEnabled = false
        UserDefaults.standard.removeObject(forKey: Self.notchOutlinePreferenceKey)
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

    var voiceSynthesisClient: any TTSClient = MacOSSpeechSynthesizerClient()

    /// Last-resort speaker when the selected TTS client throws. Retained so
    /// the utterance is not deallocated mid-sentence.
    private let emergencySpeechSynthesizer = NSSpeechSynthesizer()

    /// Speech-to-text backend for Talk / Dictate. Persisted independently of the brain.
    @Published var selectedListenProvider: VoiceListenProvider = VoiceListenProvider.fromUserDefaults()

    /// Text-to-speech backend for spoken replies. Persisted independently of the brain.
    @Published var selectedSpeakProvider: VoiceSpeakProvider = VoiceSpeakProvider.fromUserDefaults()

    // MARK: - Brain

    /// Installs and signs in the Claude / ChatGPT CLIs from one click.
    /// See SubscriptionSignIn.swift and CompanionManager+SignIn.swift.
    let subscriptionSignIn = SubscriptionSignInCoordinator()

    /// The one choice of what runs HeyMate. Drives which CLI takes agent jobs
    /// and which endpoint answers screen questions.
    @Published var selectedBrain: AgentBrain = AgentBrain.fromUserDefaults() {
        didSet {
            UserDefaults.standard.set(selectedBrain.rawValue, forKey: "selectedAgentBrain")
            if let executor = selectedBrain.executor {
                defaultHeadlessExecutor = executor
            }
            persistBrainOnActiveMate()
        }
    }

    /// Alias (`opus`) or exact id (`claude-opus-4-8`). Whatever the installed
    /// Claude CLI listed last time the catalog was read.
    @Published var selectedClaudeModelID: String =
        UserDefaults.standard.string(forKey: ClaudeModelChoice.persistenceKey) ?? ClaudeModelChoice.sonnet.rawValue {
        didSet {
            UserDefaults.standard.set(selectedClaudeModelID, forKey: ClaudeModelChoice.persistenceKey)
        }
    }

    @Published private(set) var claudeModels: [ClaudeModelOption] = ClaudeModelCatalogParser.fallbackOptions

    /// `claude --effort` level. Empty leaves the CLI's own default in charge.
    @Published var selectedClaudeEffort: String =
        UserDefaults.standard.string(forKey: CompanionManager.claudeEffortPreferenceKey) ?? "" {
        didSet {
            UserDefaults.standard.set(selectedClaudeEffort, forKey: Self.claudeEffortPreferenceKey)
        }
    }

    /// Levels the installed Claude CLI lists for `--effort`. Empty when the
    /// CLI is too old to have the flag, which hides the effort control.
    @Published private(set) var claudeEfforts: [ClaudeEffortOption] = ClaudeEffortCatalog.fallbackOptions
    @Published private(set) var isClaudeModelRefreshInFlight = false
    @Published private(set) var claudeModelCatalogErrorText: String?

    var selectedClaudeModel: ClaudeModelChoice {
        ClaudeModelChoice(rawValue: selectedClaudeModelID) ?? .sonnet
    }

    var selectedClaudeModelLabel: String {
        claudeModels.first { $0.id == selectedClaudeModelID }?.displayName
            ?? selectedClaudeModel.displayName
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
        CompanionManager.loadOpenCodeBasicAuthPassword() {
        didSet {
            CompanionManager.persistOpenCodeBasicAuthPassword(openCodeBasicAuthPassword)
            rebuildOpenCodeClient()
        }
    }

    private static func loadOpenCodeBasicAuthPassword(
        userDefaults: UserDefaults = .standard
    ) -> String {
        if let stored = ConnectorSecretStore.secret(
            forConnectorID: openCodeBasicAuthPasswordKeychainIdentifier
        ) {
            userDefaults.removeObject(forKey: legacyOpenCodeBasicAuthPasswordPreferenceKey)
            return stored
        }

        guard let legacy = userDefaults.string(
            forKey: legacyOpenCodeBasicAuthPasswordPreferenceKey
        ), !legacy.isEmpty else { return "" }

        let migrated = ConnectorSecretStore.setSecret(
            legacy,
            forConnectorID: openCodeBasicAuthPasswordKeychainIdentifier
        )
        if migrated {
            // Remove plaintext only after Keychain confirms the replacement.
            userDefaults.removeObject(forKey: legacyOpenCodeBasicAuthPasswordPreferenceKey)
        }
        return legacy
    }

    private static func persistOpenCodeBasicAuthPassword(_ password: String) {
        let persisted: Bool
        if password.isEmpty {
            persisted = ConnectorSecretStore.deleteSecret(
                forConnectorID: openCodeBasicAuthPasswordKeychainIdentifier
            )
        } else {
            persisted = ConnectorSecretStore.setSecret(
                password,
                forConnectorID: openCodeBasicAuthPasswordKeychainIdentifier
            )
        }
        if persisted {
            UserDefaults.standard.removeObject(
                forKey: legacyOpenCodeBasicAuthPasswordPreferenceKey
            )
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
                model: selectedClaudeModelID,
                reasoningEffort: selectedClaudeEffortIfSupported ?? "",
                connectedAppsReachable: connectedAppsReachableFromChildCLI
            )
        case .codex:
            if CustomAPIConfiguration.isUsableForTalk {
                return customAPIClient
            }
            let trimmedModel = selectedCodexModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            return SubscriptionCLIVisionClient(
                backend: .codex,
                model: trimmedModel.isEmpty
                    ? SubscriptionCLIVisionClient.codexFastTalkModelIdentifier
                    : trimmedModel,
                reasoningEffort: selectedCodexReasoningEffort,
                connectedAppsReachable: connectedAppsReachableFromChildCLI
            )
        case .onDevice:
            return onDeviceLanguageClient
        }
    }

    /// Whether a subscription CLI child would find anything behind HeyMate's
    /// loopback server this turn: Composio, or any other connector with a
    /// live session that this chat has left on.
    private var connectedAppsReachableFromChildCLI: Bool {
        ComposioAgentAttachment.isAttachable()
            || connectorRuntime.availableMCPTools.contains { namespaced in
                namespaced.connectorID != ComposioSessionStore.connectorID
                    && isConnectorEnabledForChat(namespaced.connectorID)
                    && !Self.isWithheldFromTalk(namespaced.tool.name)
            }
    }

    /// The model the user picked is the model that answers, with or without
    /// a screenshot. Spark is only the stand-in before Codex has a selection.
    /// Talk's client. A subscription CLI brain is bound to the open chat so
    /// follow-ups continue one CLI session instead of starting cold; other
    /// callers of `activeConversationClient` (dictation rewrite, onboarding)
    /// stay one-off and never touch that session.
    private func conversationClient(hasScreenContext: Bool) -> any VisionConversationClient {
        _ = hasScreenContext
        let client = activeConversationClient
        guard let subscriptionClient = client as? SubscriptionCLIVisionClient,
              backgroundRoutineSession == nil else { return client }
        return subscriptionClient.boundToConversation(
            key: currentChat.id.uuidString,
            position: currentChat.messages.count
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
        WarmTalkPool.shared.drain()
    }

    /// Starts the Claude child the next Talk question will use, if Claude
    /// answers Talk. A warm child whose model or tools no longer match is
    /// replaced, so a stale one is never handed a turn.
    func prewarmTalkEngine() {
        (activeConversationClient as? SubscriptionCLIVisionClient)?.prewarm()
    }

    func setSelectedClaudeModel(_ choice: ClaudeModelChoice) {
        selectedClaudeModelID = choice.rawValue
    }

    func setSelectedClaudeModel(_ option: ClaudeModelOption) {
        selectedClaudeModelID = option.id
    }

    /// Empty string returns effort to the Claude CLI's default.
    func setSelectedClaudeEffort(_ effort: String) {
        guard effort.isEmpty || claudeEfforts.contains(where: { $0.effort == effort }) else { return }
        selectedClaudeEffort = effort
    }

    /// The saved level, dropped when this CLI no longer lists it.
    var selectedClaudeEffortIfSupported: String? {
        guard !selectedClaudeEffort.isEmpty,
              claudeEfforts.contains(where: { $0.effort == selectedClaudeEffort }) else { return nil }
        return selectedClaudeEffort
    }

    /// Updates Claude, Codex, and OpenCode now, then reloads their model lists.
    func updateSubscriptionCLIsNow() async {
        await runSubscriptionCLIUpdate(automatic: false)
    }

    private func refreshSubscriptionCLICatalogs(updatingWhenDue: Bool) async {
        await refreshClaudeModelCatalog()
        await refreshCodexModelCatalog()
        await refreshOpenCodeServerStatus()
        if updatingWhenDue && SubscriptionCLIUpdatePreference.shouldUpdateAutomatically() {
            await runSubscriptionCLIUpdate(automatic: true)
        }
    }

    private func runSubscriptionCLIUpdate(automatic: Bool) async {
        guard !isSubscriptionCLIUpdateInFlight else { return }
        isSubscriptionCLIUpdateInFlight = true
        subscriptionCLIUpdateStatusText = "Updating Claude, Codex, and OpenCode…"
        let outcomes = await Task.detached(priority: .utility) {
            SubscriptionCLIUpdater.updateInstalledCLIs()
        }.value
        subscriptionCLIUpdateStatusText = SubscriptionCLIUpdater.summary(of: outcomes)
        isSubscriptionCLIUpdateInFlight = false
        if automatic {
            SubscriptionCLIUpdatePreference.markAutomaticUpdateFinished()
        }
        await waitForSubscriptionCLICatalogRefreshToFinish()
        await refreshClaudeModelCatalog()
        await refreshCodexModelCatalog()
        await refreshOpenCodeServerStatus()
    }

    private func waitForSubscriptionCLICatalogRefreshToFinish() async {
        for _ in 0..<60 {
            if !isClaudeModelRefreshInFlight && !isCodexModelRefreshInFlight && !isOpenCodeRefreshInFlight {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Reads the model ids embedded in the Claude CLI on this Mac.
    func refreshClaudeModelCatalog() async {
        guard !isClaudeModelRefreshInFlight else { return }
        isClaudeModelRefreshInFlight = true
        defer { isClaudeModelRefreshInFlight = false }
        do {
            let available = try await ClaudeModelCatalogLoader.fetchAvailableModels()
            claudeModels = available
            claudeModelCatalogErrorText = nil
        } catch {
            if claudeModels.isEmpty {
                claudeModels = ClaudeModelCatalogParser.fallbackOptions
            }
            claudeModelCatalogErrorText = error.localizedDescription
        }
        claudeEfforts = await ClaudeEffortCatalog.fetchAvailableEfforts()
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
        if provider == .onDevice { Self.warmKokoro() }
    }

    /// A finished on-device download switches Listen or Speak over to it —
    /// the user downloaded it to use it. Also warms Parakeet and Kokoro when
    /// they are already the choice, so the first press after launch is quick.
    private func bindOnDeviceVoiceModels() {
        OnDeviceVoiceModelStore.shared.onModelInstalled = { [weak self] kind in
            guard let self, self.voiceState == .idle else { return }
            switch kind {
            case .listen:
                self.setSelectedListenProvider(.onDevice)
            case .speak:
                self.setSelectedSpeakProvider(.onDevice)
            }
        }

        if selectedListenProvider == .onDevice, ParakeetEngine.modelsAreInstalled() {
            Task.detached(priority: .utility) {
                _ = try? await ParakeetEngine.shared.loadIfNeeded()
            }
        }
        if selectedSpeakProvider == .onDevice {
            Self.warmKokoro()
        }
    }

    /// Loading Kokoro and compiling it for the Neural Engine took 13 s on
    /// the first reply after launch. One throwaway synthesis moves that
    /// cost to launch, off the user's first question.
    private static func warmKokoro() {
        guard KokoroEngine.modelsAreInstalled() else { return }
        Task.detached(priority: .utility) {
            let startedAt = ContinuousClock.now
            guard (try? await KokoroEngine.shared.synthesize("Hi.")) != nil else { return }
            HeyMateLog.log("🔊 Kokoro: warmed in \(HeyMateLog.milliseconds(since: startedAt))ms", category: "KokoroTTSClient")
        }
    }

    private static func makeVoiceSynthesisClient(
        for provider: VoiceSpeakProvider,
        workerBaseURL: String
    ) -> any TTSClient {
        SilentModeAwareTTSClient(wrapping: makeSpeakingClient(for: provider, workerBaseURL: workerBaseURL))
    }

    /// The client for a Speak choice. ElevenLabs and on-device fall back to
    /// the Mac voice when they fail, so a reply is never lost.
    static func makeSpeakingClient(
        for provider: VoiceSpeakProvider,
        workerBaseURL: String
    ) -> any TTSClient {
        switch provider {
        case .macOS:
            return MacOSSpeechSynthesizerClient()
        case .elevenLabs:
            return FallbackTTSClient(
                primary: ElevenLabsTTSClient(proxyURL: "\(workerBaseURL)/tts"),
                fallback: MacOSSpeechSynthesizerClient()
            )
        case .onDevice:
            return FallbackTTSClient(
                primary: KokoroTTSClient(),
                fallback: MacOSSpeechSynthesizerClient()
            )
        }
    }

    /// Applies a model picked in the panel or Settings. Both fields go through
    /// their persisted didSets, which rebuild the OpenCode client in one step.
    func selectOpenCodeModel(_ option: OpenCodeModelOption) {
        openCodeProviderID = option.providerID
        openCodeModelID = option.modelID
        if openCodeTrainingNotice?.modelKey != OpenCodeTrainingPolicy.modelKey(
            providerID: option.providerID,
            modelID: option.modelID
        ) {
            cancelOpenCodeTrainingSend()
        }
    }

    func confirmOpenCodeTrainingSend() {
        guard let pending = pendingOpenCodeTrainingSend else { return }
        OpenCodeTrainingConsent.acknowledge(pending.modelKey)
        let images = pendingOpenCodeTrainingImages
        let handoff = pending.handoff
        let text = pending.text
        pendingOpenCodeTrainingSend = nil
        pendingOpenCodeTrainingImages = []
        openCodeTrainingNotice = nil
        commandBarFeedback = nil
        if let handoff {
            beginHandoff(handoff)
            return
        }
        _ = sendTypedMessage(text, imageAttachments: images)
    }

    func cancelOpenCodeTrainingSend() {
        pendingOpenCodeTrainingSend = nil
        pendingOpenCodeTrainingImages = []
        openCodeTrainingNotice = nil
    }

    /// True when the send was held back. The composer keeps the text.
    func holdForOpenCodeTrainingConsent(
        _ text: String,
        imageAttachments: [ChatImageAttachment],
        handoff: MateHandoff? = nil
    ) -> Bool {
        guard selectedBrain == .openCode else { return false }
        let modelKey = OpenCodeTrainingPolicy.modelKey(
            providerID: openCodeProviderID,
            modelID: openCodeModelID
        )
        guard !OpenCodeTrainingConsent.isAcknowledged(modelKey) else { return false }
        let modelName = openCodeModels.first {
            $0.providerID == openCodeProviderID && $0.modelID == openCodeModelID
        }?.modelName ?? openCodeModelID
        guard case .mayTrain(let detail) = OpenCodeTrainingPolicy.dataUse(
            providerID: openCodeProviderID,
            modelID: openCodeModelID,
            modelName: modelName
        ) else { return false }
        openCodeTrainingNotice = OpenCodeTrainingNotice(
            modelKey: modelKey,
            modelLabel: modelName.isEmpty ? modelKey : modelName,
            detail: detail
        )
        pendingOpenCodeTrainingSend = PendingOpenCodeSend(
            modelKey: modelKey,
            text: text,
            imageAttachmentCount: imageAttachments.count,
            handoff: handoff
        )
        pendingOpenCodeTrainingImages = imageAttachments
        commandBarFeedback = detail
        return true
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
                HeyMateLog.log("🤖 OpenCode: auto-selected \(firstAvailableModel.id)")
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
        case .claudeCode: return selectedClaudeModelLabel
        case .codex: return selectedCodexModel?.displayName ?? selectedCodexModelID
        case .customAPI: return CustomAPIConfiguration.model
        case .openCode:
            return openCodeModelID.isEmpty ? "OpenCode (no model)" : "\(openCodeProviderID)/\(openCodeModelID)"
        case .onDevice: return "Apple Intelligence"
        }
    }

    /// Live chat shown in the notch Chat tab. Past sessions live in `savedChats`.
    @Published var currentChat: ChatSession = .empty()

    /// Listen, the ChatGPT or Claude plan answers, this Mac speaks, then listen again.
    @Published var isSubscriptionVoiceChatActive = false

    /// Set when the selected OpenCode model may train on the next send.
    @Published var openCodeTrainingNotice: OpenCodeTrainingNotice?

    /// Non-nil while Apple's Image Playground sheet should be up.
    @Published var imagePlaygroundConcept: String?

    @Published var isRecordingMeeting = false

    private var pendingOpenCodeTrainingSend: PendingOpenCodeSend?
    private var pendingOpenCodeTrainingImages: [ChatImageAttachment] = []
    var pendingHandoffs: [MateHandoff] = []
    /// Agent run -> the mate whose chat asked for it, so results land back there.
    var mateRunOwners: [UUID: UUID] = [:]
    var activeHandoffMateID: UUID?
    var activeHandoffHops = 0
    let meetingNotes = MeetingNotes(fileURL: MeetingNotes.appSupportFileURL())
    private let onDeviceLanguageClient = OnDeviceLanguageClient()

    /// Persisted chats, newest first. Empty when "Remember conversations" is off.
    @Published var savedChats: [ChatSession] = []

    /// Assistant text currently streaming into the Chat tab (and cursor overlay).
    @Published var streamingAssistantText: String = "" {
        didSet { mirrorStreamingTextIntoCursorCaption() }
    }

    /// Reply caption beside the buddy cursor. Follows the streamed text, then
    /// lingers after the reply finishes until it has been spoken and read.
    @Published var cursorCaptionText: String = ""
    var cursorCaptionTask: Task<Void, Never>?
    /// Small "2 of 4" / "step 2 of 5" line above the caption during guidance.
    @Published var cursorCaptionProgress: String?

    /// True while a guided reply is pointing and speaking step by step; the
    /// overlay keeps the buddy at its target until this clears.
    @Published var isGuidancePointerHeld = false

    /// The multi-turn plan being walked through, if any.
    @Published var activeWalkthrough: GuidedWalkthrough?
    var walkthroughClickMonitor: Any?
    var isCursorCaptionSpeechPlaying: Bool {
        voiceSynthesisClient.isPlaying || state == .speaking
    }

    /// Completed user/assistant turns from the open chat, for the vision API.
    private func speakingMateForTurn() -> Mate? {
        let session = backgroundRoutineSession ?? currentChat
        let id = session.mateID ?? mateDirectory.defaultMateID
        return mateDirectory.mates.first { $0.id == id }
    }

    private func mateIdentityBlock(for mate: Mate?) -> String? {
        guard let mate else { return nil }
        if mate.conductsOthers {
            let brief = FirstMateBrief.promptBlock(
                mate: mate,
                others: mateDirectory.mates,
                memoryExcerpts: SubscriptionMemoryIndex.excerpts(
                    root: FileManager.default.homeDirectoryForCurrentUser
                ),
                meetingNotesAreOn: isRecordingMeeting
            )
            return [brief, MateAgentBrief.promptBlock(mate: mate, runsCanOperateApps: runsCanOperateApps)].joined(separator: "\n")
        }
        let blocks = [
            MateSoul.promptBlock(name: mate.name, job: mate.job, soul: mate.soul),
            MateMessagingBrief.promptBlock(sender: mate, mates: mateDirectory.mates),
            MateAgentBrief.promptBlock(mate: mate, runsCanOperateApps: runsCanOperateApps)
        ].compactMap { $0 }
        return blocks.joined(separator: "\n")
    }

    /// Whether an approved run will get Cua's background app control: the
    /// same two conditions the launcher checks before attaching it.
    private var runsCanOperateApps: Bool {
        computerUseCoordinator.isEnabled && CuaDriverSetup.shared.isReady
    }

    func toggleSubscriptionVoiceChat() {
        if isSubscriptionVoiceChatActive {
            isSubscriptionVoiceChatActive = false
            if voiceState == .listening {
                finishVoiceInputFromNotch()
            }
            return
        }
        guard selectedBrain.offersSubscriptionVoiceChat else {
            commandBarFeedback = "Voice chat runs on a ChatGPT or Claude plan. Pick Codex or Claude."
            return
        }
        isSubscriptionVoiceChatActive = true
        commandBarFeedback = nil
        if handsFreeSilenceCancellable == nil, !buddyDictationManager.isDictationInProgress {
            handleHandsFreeDoubleTap()
        }
    }

    private func continueSubscriptionVoiceChat() {
        guard isSubscriptionVoiceChatActive, selectedBrain.offersSubscriptionVoiceChat else {
            isSubscriptionVoiceChatActive = false
            return
        }
        guard handsFreeSilenceCancellable == nil, !buddyDictationManager.isDictationInProgress else { return }
        handleHandsFreeDoubleTap()
    }

    func scheduleNextHandoffIfNeeded() {
        guard activeHandoffMateID == nil, activeRoutineTurn == nil, !pendingHandoffs.isEmpty else { return }
        let next = pendingHandoffs.removeFirst()
        Task { @MainActor in
            self.beginHandoff(next)
        }
    }

    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] {
        let session = backgroundRoutineSession ?? currentChat
        return session.apiHistoryPairs(limit: 10).map { pair in
            (
                userTranscript: TalkContextPolicy.withoutPriorScreenshots(pair.userTranscript),
                assistantResponse: TalkContextPolicy.withoutPriorScreenshots(pair.assistantResponse)
            )
        }
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?
    /// Guards stale Talk completions after a newer turn cancelled the task.
    private var currentResponseCompletion: HeyMateRequestCompletionState?

    /// Whether a reply is still being produced. `currentResponseTask` keeps
    /// pointing at a finished turn, so it alone cannot answer this: after the
    /// first reply it is never nil again, and a press that ended with no
    /// transcript (released too fast, nothing heard, speech permission
    /// missing) then left HeyMate showing Listening forever.
    var isResponseInFlight: Bool {
        guard currentResponseTask != nil, let completion = currentResponseCompletion else { return false }
        return !completion.didComplete
    }

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
    @Published var agentRuns: [AgentRun] = []

    /// Exactly one proactive nudge at a time. Matching a rule only populates
    /// this value; approval starts normal read-only planning.
    @Published private(set) var loadedStandingOrders: [StandingOrder] = []
    @Published private(set) var standingOrderProposal: StandingOrderProposal?
    @Published var latestAgentUndoEntry: AgentUndoEntry?
    @Published var agentUndoErrorText = ""
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

    /// Flipped when a file drag reaches the notch so the Apps shelf appears
    /// before the pointer drops the files.
    @Published var shouldRevealAppsTab = false

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

    @Published internal(set) var memoryItems: [MemoryItem] = []

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
        HeyMateLog.log("🧹 All durable memory cleared")
    }

    /// Compact label for the notch dock model chip.
    var notchDockModelLabel: String {
        switch selectedBrain {
        case .claudeCode:
            return "Claude · \(selectedClaudeModelLabel)"
        case .codex:
            let modelName = selectedCodexModel?.displayName
                ?? (selectedCodexModelID.isEmpty ? "Spark" : selectedCodexModelID)
            return "Codex · \(modelName)"
        case .customAPI:
            return "API · \(CustomAPIConfiguration.model)"
        case .onDevice:
            return "On this Mac · Apple Intelligence"
        case .openCode:
            if let selected = openCodeModels.first(where: {
                $0.providerID == openCodeProviderID && $0.modelID == openCodeModelID
            }) {
                return "OpenCode · \(selected.shortLabel)"
            }
            if openCodeModelID.isEmpty {
                return isOpenCodeServerReachable == false ? "OpenCode · offline" : "OpenCode · pick a model"
            }
            return "OpenCode · \(openCodeModelID)"
        }
    }

    func startNewChat() {
        persistCurrentChatIfNeeded()
        var session = ChatSession.empty()
        session.mateID = activeMateID ?? mateDirectory.defaultMateID
        currentChat = session
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
        let mateID = session.mateID ?? mateDirectory.defaultMateID
        mateDirectory.activeMateID = mateID
        mateDirectory.markRead(id: mateID)
        syncMatePublications()
    }

    func deleteChat(id: UUID) {
        chatHistoryStore.delete(id: id)
        savedChats = chatHistoryStore.loadAll()
        if currentChat.id == id {
            var session = ChatSession.empty()
            session.mateID = activeMateID ?? mateDirectory.defaultMateID
            currentChat = session
            streamingAssistantText = ""
        }
    }

    func clearAllChats() {
        chatHistoryStore.deleteAll()
        savedChats = []
        var session = ChatSession.empty()
        session.mateID = activeMateID ?? mateDirectory.defaultMateID
        currentChat = session
        streamingAssistantText = ""
    }

    func persistCurrentChatIfNeeded() {
        guard rememberConversationsEnabled else { return }
        let draft = currentChat.draftText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !currentChat.messages.isEmpty || !draft.isEmpty else { return }
        chatHistoryStore.upsert(currentChat)
        savedChats = chatHistoryStore.loadAll()
    }

    /// Send becomes Stop while a reply is streaming, queued, or being spoken.
    /// A finished task stays referenced, so Stop hides once that turn has completed.
    var isComposerStopVisible: Bool {
        if !streamingAssistantText.isEmpty { return true }
        switch state {
        case .thinking, .capturingContext, .speaking:
            return true
        default:
            break
        }
        guard currentResponseTask != nil else { return false }
        return currentResponseCompletion?.didComplete != true
    }

    /// Stops the open reply: the in-flight task, streamed text, and speech.
    /// Returns to idle so the composer cannot stay on thinking, capturing, or speaking.
    func cancelInFlightChatTurn() {
        let completion = currentResponseCompletion
        completion?.didComplete = true
        currentResponseTask?.cancel()
        currentResponseTask = nil
        streamingAssistantText = ""
        voiceSynthesisClient.stopPlayback()
        if activeRoutineTurn != nil {
            completeActiveRoutineTurn(.cancelled)
        }
        dispatch(.cancel)
        // The reply task calls beginContextCapture before it notices cancellation.
        // If that prefix runs after this return, idle those states again.
        Task { @MainActor in
            guard currentResponseTask == nil, currentResponseCompletion === completion else { return }
            streamingAssistantText = ""
            switch state {
            case .thinking, .capturingContext, .speaking:
                dispatch(.cancel)
            default:
                break
            }
        }
    }

    func appendUserMessage(_ text: String, attachmentNames: [String] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let names = attachmentNames.isEmpty ? nil : attachmentNames
        if backgroundRoutineSession != nil {
            appendUserMessageToBackground(trimmed, attachmentNames: names)
            return
        }
        if currentChat.messages.last?.role == .user,
           currentChat.messages.last?.text == trimmed,
           currentChat.messages.last?.attachmentNames == names {
            return
        }
        var session = currentChat
        session.messages.append(ChatMessage(
            id: UUID(),
            role: .user,
            text: trimmed,
            createdAt: Date(),
            attachmentNames: names
        ))
        session.updatedAt = Date()
        if session.title == ChatSession.defaultTitle {
            session.title = ChatSession.title(from: trimmed)
        }
        currentChat = session
        persistCurrentChatIfNeeded()
        if isRecordingMeeting, backgroundRoutineSession == nil {
            meetingNotes.append(speaker: "You", text: trimmed)
        }
    }

    private func appendUserMessageToBackground(_ trimmed: String, attachmentNames: [String]?) {
        guard var session = backgroundRoutineSession else { return }
        if session.messages.last?.role == .user,
           session.messages.last?.text == trimmed,
           session.messages.last?.attachmentNames == attachmentNames {
            return
        }
        session.messages.append(ChatMessage(
            id: UUID(),
            role: .user,
            text: trimmed,
            createdAt: Date(),
            attachmentNames: attachmentNames
        ))
        session.updatedAt = Date()
        if session.title == ChatSession.defaultTitle {
            session.title = ChatSession.title(from: trimmed)
        }
        backgroundRoutineSession = session
        if rememberConversationsEnabled {
            chatHistoryStore.upsert(session)
            savedChats = chatHistoryStore.loadAll()
        }
    }

    func appendAssistantMessage(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            streamingAssistantText = ""
            return
        }
        if let activeRoutineTurn {
            trimmed = MateRoutineMessage.format(task: activeRoutineTurn.task, outcome: trimmed)
        }
        if backgroundRoutineSession != nil {
            appendAssistantMessageToBackground(trimmed)
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
        let captionText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        streamingAssistantText = ""
        lingerCursorCaption(captionText)
        persistCurrentChatIfNeeded()
        if isRecordingMeeting, backgroundRoutineSession == nil {
            meetingNotes.append(speaker: "HeyMate", text: trimmed)
        }
    }

    private func appendAssistantMessageToBackground(_ trimmed: String) {
        guard var session = backgroundRoutineSession else { return }
        session.messages.append(ChatMessage(
            id: UUID(),
            role: .assistant,
            text: trimmed,
            createdAt: Date()
        ))
        session.updatedAt = Date()
        backgroundRoutineSession = session
        if rememberConversationsEnabled {
            chatHistoryStore.upsert(session)
            savedChats = chatHistoryStore.loadAll()
        }
        streamingAssistantText = ""
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

    /// Only a short, ambiguous follow-up ("okay", "what now") needs the anchor.
    /// A greeting or a fresh question must not be dragged back to whatever was
    /// said last, which could be hours old ("hi" -> "still on the textedit task").
    nonisolated static func shouldAnchorToPriorTopic(transcript: String) -> Bool {
        let words = transcript
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
        guard !words.isEmpty, words.count <= 3 else { return false }
        let greetings: Set<Substring> = ["hi", "hey", "hello", "yo", "sup", "heymate", "morning", "evening"]
        return !words.allSatisfy { greetings.contains($0) }
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
                // The description carries what the tool actually does. Naming
                // the connector alone reads as noise next to the local tools
                // and gives the model no reason to prefer a real lookup over
                // answering from memory.
                return "- \(talkTool.toolDefinition.name) (\(connectorDisplayName)): \(talkTool.toolDefinition.description)"
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
        HeyMateLog.log("🛡️ Screen context excluded for: \(bundleId)")
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

    private var frontmostIsHeyMate: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
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

    /// AppKit screen coordinate for the dock glyph in the expanded notch
    /// footer. Not published: the overlay reads it every flight frame. Asks
    /// the glyph's view directly when it is on screen, so a notch that is
    /// still settling or has moved does not leave the landing point stale.
    var cursorDockAnchorScreenPoint: CGPoint? {
        if let livePoint = cursorDockAnchorProvider?(),
           livePoint.x.isFinite, livePoint.y.isFinite {
            lastCursorDockAnchorScreenPoint = livePoint
            return livePoint
        }
        return lastCursorDockAnchorScreenPoint
    }

    private var lastCursorDockAnchorScreenPoint: CGPoint?
    private var cursorDockAnchorProvider: (() -> CGPoint?)?

    func updateCursorDockAnchorScreenPoint(_ point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        lastCursorDockAnchorScreenPoint = point
    }

    func setCursorDockAnchorProvider(_ provider: (() -> CGPoint?)?) {
        cursorDockAnchorProvider = provider
    }

    /// True while the user is typing and the pointer has not moved yet.
    @Published private(set) var hidesCursorForTyping = false
    private var typingHideAnchor: CGPoint = .zero

    func hideCursorForTyping(anchor: CGPoint) {
        guard !cursorDockPhase.isTransitioning else { return }
        guard anchor.x.isFinite, anchor.y.isFinite else { return }
        guard !hidesCursorForTyping else { return }
        typingHideAnchor = anchor
        hidesCursorForTyping = true
    }

    func revealCursorIfPointerMoved(to point: CGPoint) {
        guard hidesCursorForTyping else { return }
        guard BuddyCursorTypingPolicy.shouldReveal(from: typingHideAnchor, to: point) else { return }
        hidesCursorForTyping = false
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

    // MARK: Deferred connector activation

    private var hasActivatedConnectors = false
    private var connectorActivationTask: Task<Void, Never>?

    /// Reconnect everything the user had enabled — but not at launch.
    ///
    /// Restoring reads the Keychain, and macOS answers a Keychain read with
    /// a password panel of its own. Doing that during `start()` puts a
    /// dialog on screen before the user has clicked anything, which is the
    /// bug this exists to prevent. Instead the work runs the first time the
    /// user actually reaches for HeyMate — hovering the notch, opening the
    /// window, or speaking — by which point a panel reads as a response.
    ///
    /// The two passes run in one task rather than two, so a Keychain panel
    /// and a permission panel can never stack on top of each other.
    func activateConnectorsIfNeeded() {
        guard !hasActivatedConnectors else { return }
        hasActivatedConnectors = true
        connectorActivationTask = Task {
            await connectorRuntime.restoreEnabledConnectors()
            await composioConnections.revalidate()
        }
    }

    /// First Talk turn must wait for deferred MCP discovery. Starting the
    /// model alongside that work gives it an empty tool list, so it reports a
    /// connected account as missing even though the server appears seconds
    /// later.
    func awaitConnectorActivation() async {
        activateConnectorsIfNeeded()
        await connectorActivationTask?.value
    }

    func start() {
        refreshAllPermissions()
        HeyMateLog.log("🔑 HeyMate start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
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
        mateRoutineScheduler.start()
        startComputerUseCursorBridge()
        contextualConnectorSuggestionMonitor.start()
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
        // Catalogs load immediately. When an update is due, they reload after
        // Claude, Codex, and OpenCode finish so the new models show.
        rebuildOpenCodeClient()
        _ = customAPIClient
        Task { await refreshSubscriptionCLICatalogs(updatingWhenDue: true) }

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
            HeyMateLog.log("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
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
                HeyMateLog.log("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
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
                HeyMateLog.log("⚠️ Screen content permission request failed: \(error)")
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
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // The reducer rejects transitions that would stomp
                // pipeline-owned states (capturing/thinking/guiding/speaking),
                // so stale dictation-flag callbacks are harmless here.
                if isFinalizing {
                    self.dispatch(.finishListening)
                } else if isRecording {
                    self.dispatch(.startListening(self.inputModeOfActiveSession))
                    // The seconds spent speaking cover the CLI's boot.
                    self.prewarmTalkEngine()
                } else if isPreparing {
                    // The microphone is still starting. Keep showing
                    // Listening instead of flickering to idle and back.
                } else if !self.state.isIdle && !self.isResponseInFlight {
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

    /// Silent mode: the voice shortcuts still summon HeyMate, but into the
    /// typed composer. Any answer still being spoken is cut off, the same way
    /// pressing Talk interrupts one.
    private func openTypedComposerForSilentMode() {
        guard !buddyDictationManager.isDictationInProgress else { return }
        voiceSynthesisClient.stopPlayback()
        notchCompanionController.toggleCompactChat()
    }

    /// Hands-free: same talk turn as push-to-talk, but nothing is being held,
    /// so the turn has to end itself. A second double tap ends it early.
    private func handleHandsFreeDoubleTap() {
        if handsFreeSilenceCancellable != nil {
            finishHandsFreeTurn()
            return
        }

        if isSilentModeEnabled {
            openTypedComposerForSilentMode()
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
                    HeyMateLog.log("🔲 Spatial selection captured on \(screenFrame): \(normalizedSelection.bounds)")
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
            // Silent mode means no mic at all; dictation has no typed
            // equivalent here, so the shortcut does nothing.
            guard !isSilentModeEnabled else { return }
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
            // Nothing was started on press. A dictation already recording when
            // silent mode was switched on still finishes normally.
            if isSilentModeEnabled && !buddyDictationManager.isDictationInProgress
                && pendingDictateStartTask == nil {
                return
            }
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
        currentResponseCompletion?.didComplete = true
        let dictationCompletion = HeyMateRequestCompletionState()
        currentResponseCompletion = dictationCompletion

        let usesSmartMode = dictationUsesSmartMode

        currentResponseTask = Task {
            defer { dictationCompletion.didComplete = true }
            var textToInsert = trimmedTranscript
            var insertionContextSummary = "literal"

            do {
                // Privacy gate: excluded apps never get screenshotted even in
                // Smart mode — degrade to Literal insertion instead.
                let smartModePermitted = usesSmartMode
                    && !isFrontmostAppScreenExcluded
                    && !frontmostIsHeyMate
                if usesSmartMode && !smartModePermitted {
                    HeyMateLog.log("🛡️ Dictation: frontmost app excluded or HeyMate is in front — literal insert")
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
                    HeyMateLog.log("✍️ Dictation insert (\(insertionContextSummary)): \(outcome)")
                }

                dispatch(.interactionFinished)
                scheduleTransientHideIfNeeded()
            } catch is CancellationError {
                // User started another interaction mid-rewrite.
            } catch {
                dispatch(.fail(error.localizedDescription))
                HeyMateLog.log("⚠️ Dictation pipeline error: \(error)")
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
            if isSilentModeEnabled {
                openTypedComposerForSilentMode()
                return
            }
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
                        HeyMateLog.log("🗣️ Companion received transcript (\(finalTranscript.count) characters)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.handleTalkTranscript(finalTranscript)
                    }
                )
            }
        case .released:
            // Silent mode opened the composer on press; there is no recording
            // to stop. A turn already recording when silent mode was switched
            // on still finishes normally.
            if isSilentModeEnabled && !buddyDictationManager.isDictationInProgress
                && pendingKeyboardShortcutStartTask == nil {
                return
            }
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

    private static let companionVoiceStyleBlock = """
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
    """

    /// Silent mode's counterpart to the voice style: the reply is read in the
    /// chat, so it can use formatting and show code instead of describing it.
    private static let companionReadingStyleBlock = """
    you're heymate, a friendly always-on companion that lives in the user's menu bar. the user is in silent mode — they can't talk or listen right now, so they typed to you and will read your reply on screen. it is never spoken aloud. you can see their screen(s). this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to a short, direct answer: a sentence or a few. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - casual and warm, with normal capitalization. no emojis.
    - write for the eye: short paragraphs. use numbered steps for a sequence and dashes for a list when it makes the answer easier to scan. use **bold** sparingly for the one thing that matters most, and `backticks` for commands, file names, keyboard shortcuts, and code. no headings or tables.
    - when the answer is code, show the code itself in a fenced code block instead of describing it.
    - symbols, numbers, and abbreviations are fine — this is read, not heard.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't end with simple yes/no questions like "want me to explain more?" — those are dead ends. when it fits naturally, end by pointing at a next step worth taking instead.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.
    """

    /// Pointing and drawing work the same whether the reply is heard or read.
    private static let companionScreenToolsBlock = """
    element pointing:
    you have a small blue shaftless cursor arrowhead that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, put a coordinate tag right AFTER the sentence it belongs to. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    pointing at several things: you may use several [POINT:] tags in one reply, each right after its own sentence, in the order the user should look. the cursor flies to each one while that sentence is spoken and shows it as a caption, one at a time. use this when everything you mention is visible on screen right now, for example "the play button is here [POINT:..:play] and the volume slider is next to it [POINT:..:volume]". keep it to five points or fewer.

    if pointing wouldn't help, append [POINT:none].

    walkthroughs:
    when the user wants to be shown how to do a multi-step task in an app ("how do i…", "show me how", "walk me through", "teach me") and later steps will only appear after earlier ones are done (a menu that opens, a dialog, a new page), plan it instead of guessing coordinates you cannot see yet. write [PLAN:first step|second step|third step] with short imperative steps (no more than ten), then guide ONLY the first step: say it in one or two sentences, point at it, and write [STEP:1]. heymate remembers the plan, waits for the user to click what you pointed at (or say "next"), takes a fresh screenshot, and asks you for the next step. never write a plan for a single-step answer. the plan and step tags are silent, never mention them aloud.

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

    per-step drawing: inside a pointed sequence you may use [RECT:x,y,w,h:label] (screenshot pixels) in place of a [POINT:] tag to box an area for that step instead of pointing at one spot. it stays drawn while that step is spoken.

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    - user asks what the controls in their video player do: "that's play and pause [POINT:640,980:play button] and the slider beside it scrubs through the video [POINT:900,980:timeline] and the gear on the right sets quality [POINT:1500,980:settings]"
    - user asks how to export a video in final cut: "[PLAN:open the file menu|choose share|pick export file|choose a format and save] first, click the file menu up in the top left. [POINT:80,11:file menu] [STEP:1]"
    """

    static func companionResponseSystemPrompt(isSilentModeEnabled: Bool) -> String {
        let styleBlock = isSilentModeEnabled ? companionReadingStyleBlock : companionVoiceStyleBlock
        return styleBlock + "\n\n" + companionScreenToolsBlock
    }

    // MARK: - AI Response Pipeline

    /// Voice and typed Ask-anything. Local open/volume is a sub-100ms
    /// fast-path. Coding jobs (`agent, …` / `build a …`) mint a sandbox.
    /// Everything else is screen-aware Talk with TTS.
    /// Returns false when the message was not accepted, so the composer can
    /// keep the text on screen instead of clearing a message nobody answered.
    @discardableResult
    func sendTypedMessage(
        _ typedMessageText: String,
        imageAttachments: [ChatImageAttachment] = []
    ) -> Bool {
        let trimmedTypedMessageText = typedMessageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTypedMessageText.isEmpty || !imageAttachments.isEmpty else { return false }
        // Backstop for the hover trigger: a first turn driven by a shortcut
        // still needs connector tools to come online.
        activateConnectorsIfNeeded()

        if let typedMessageBusyReason {
            commandBarFeedback = typedMessageBusyReason
            return false
        }

        // "/" and "@" are handled before anything reaches the model, so a
        // command never gets answered as if it were a question.
        let effectiveInput = trimmedTypedMessageText.isEmpty
            ? "Describe what is in the attached image."
            : trimmedTypedMessageText
        switch CommandBarParser.parse(effectiveInput) {
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
            if acceptLocalMateCommand(messageText) { return true }
            if holdForOpenCodeTrainingConsent(messageText, imageAttachments: imageAttachments) {
                return false
            }

            commandBarFeedback = nil
            let messageWithContext = messageText.appending(contextPreamble(for: contextTokens))
            lastTranscript = messageText
            ClickyAnalytics.trackUserMessageSent(transcript: messageText)
            // Not `requiresIdle`: a busy Talk pipeline is something a second
            // question deliberately interrupts, and the states where typing
            // genuinely cannot be served were refused above by name.
            if imageAttachments.isEmpty {
                routeUserTranscript(messageWithContext, requiresIdle: false, typedInsideHeyMate: true)
            } else {
                sendToTalk(
                    messageWithContext,
                    requiresIdle: false,
                    imageAttachments: imageAttachments,
                    typedInsideHeyMate: true
                )
            }
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

        case .silent:
            isSilentModeEnabled.toggle()
            commandBarFeedback = isSilentModeEnabled
                ? "Silent mode on. Your Talk shortcut opens this box, and replies stay on screen."
                : "Silent mode off. Talk listens and answers out loud again."

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
        if acceptLocalMateCommand(trimmedTranscript) { return }
        if holdForOpenCodeTrainingConsent(trimmedTranscript, imageAttachments: []) {
            speakLine("That OpenCode model may use this for training. Confirm it in the chat and I'll send it.")
            return
        }
        routeUserTranscript(trimmedTranscript, requiresIdle: false)
    }

    /// Fast-path first (open app / volume). AgentInvocation remains the
    /// coding-agent authority. Hybrid and destructive confirmation stay Talk
    /// — they are not a 13-guard classifier.
    private func routeUserTranscript(
        _ transcript: String,
        requiresIdle: Bool,
        typedInsideHeyMate: Bool = false,
        alreadyRoutedToMate: Bool = false
    ) {
        if !alreadyRoutedToMate,
           let address = MateAddressParser.parse(transcript),
           let mate = MateAddressParser.match(address.mateName, mates: mates) {
            openMate(id: mate.id)
            routeUserTranscript(
                address.message,
                requiresIdle: requiresIdle,
                typedInsideHeyMate: typedInsideHeyMate,
                alreadyRoutedToMate: true
            )
            return
        }
        if acceptLocalMateCommand(transcript) { return }
        if let instruction = StandingOrderVoiceInstruction.parse(transcript) {
            let created = createStandingOrder(
                name: instruction.name,
                signalKind: instruction.signalKind,
                contains: instruction.contains,
                task: instruction.task
            )
            speakLine(created
                ? "suggestion saved. i'll offer it, never start it."
                : "i couldn't save that suggestion.")
            return
        }
        switch VoiceRouter.decide(transcript) {
        case .local(let action):
            performLocalVoiceAction(action)
        case .agent:
            startSandboxAgentFromTranscript(transcript)
        case .hybrid, .confirmDestructive, .talk:
            sendToTalk(transcript, requiresIdle: requiresIdle, typedInsideHeyMate: typedInsideHeyMate)
        case .needsClassification:
            classifyThenRoute(
                transcript,
                requiresIdle: requiresIdle,
                typedInsideHeyMate: typedInsideHeyMate
            )
        }
    }

    /// The free tier could not decide, so one small-model call does.
    ///
    /// The wait is real, which is why `VoiceRouter` answers everything it can
    /// first — a screen question never reaches here. If the call fails or is
    /// slow, the old prefix-and-word-list behaviour is the floor: worst case
    /// the app routes exactly as well as it did before, never worse.
    private func classifyThenRoute(
        _ transcript: String,
        requiresIdle: Bool,
        typedInsideHeyMate: Bool = false
    ) {
        Task { [weak self] in
            guard let self else { return }
            self.voiceIntentClassifier.configure(
                proxyURL: CustomAPIConfiguration.baseURL,
                apiKey: CustomAPIConfiguration.apiKey()
            )
            let decision = await self.voiceIntentClassifier.classify(transcript)

            guard let decision else {
                self.applyFallbackRoute(
                    transcript,
                    requiresIdle: requiresIdle,
                    typedInsideHeyMate: typedInsideHeyMate
                )
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
                    self.sendToTalk(
                        transcript,
                        requiresIdle: requiresIdle,
                        typedInsideHeyMate: typedInsideHeyMate
                    )
                }
            case .talk:
                self.sendToTalk(
                    transcript,
                    requiresIdle: requiresIdle,
                    typedInsideHeyMate: typedInsideHeyMate
                )
            }
        }
    }

    private func applyFallbackRoute(
        _ transcript: String,
        requiresIdle: Bool,
        typedInsideHeyMate: Bool = false
    ) {
        if case .agent = VoiceRouter.fallbackDecision(transcript) {
            startSandboxAgentFromTranscript(transcript)
        } else {
            sendToTalk(transcript, requiresIdle: requiresIdle, typedInsideHeyMate: typedInsideHeyMate)
        }
    }

    private func sendToTalk(
        _ transcript: String,
        requiresIdle: Bool,
        imageAttachments: [ChatImageAttachment] = [],
        typedInsideHeyMate: Bool = false
    ) {
        if requiresIdle, voiceState != .idle { return }
        activateConnectorsIfNeeded()
        // A walkthrough always needs a fresh look: "next" names nothing on
        // screen, but the next step can only be found there.
        let wantsScreen = activeWalkthrough != nil || TalkContextPolicy.shouldCaptureScreen(
            for: transcript,
            hasSpatialSelection: activeSpatialSelection != nil
        )
        sendTranscriptToClaudeWithScreenshot(
            transcript: transcript,
            shouldCaptureScreen: TalkContextPolicy.allowCapture(
                wantsScreen: wantsScreen,
                typedInsideHeyMate: typedInsideHeyMate,
                frontmostIsHeyMate: frontmostIsHeyMate,
                hasSpatialSelection: activeSpatialSelection != nil
            ),
            imageAttachments: imageAttachments
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
    func sendTranscriptToClaudeWithScreenshot(
        transcript: String,
        shouldCaptureScreen: Bool,
        imageAttachments: [ChatImageAttachment] = []
    ) {
        currentResponseCompletion?.didComplete = true
        currentResponseTask?.cancel()
        voiceSynthesisClient.stopPlayback()

        let completion = HeyMateRequestCompletionState()
        currentResponseCompletion = completion
        currentResponseTask = Task {
            // Every exit, early returns included, ends the turn. Runs after
            // the closing `guard !completion.didComplete` below, so the
            // normal ending still dispatches `interactionFinished` first.
            defer { completion.didComplete = true }
            appendUserMessage(
                transcript,
                attachmentNames: imageAttachments.map(\.fileName)
            )
            streamingAssistantText = ""

            dispatch(.beginContextCapture)

            do {
                await awaitConnectorActivation()
                guard !Task.isCancelled, !completion.didComplete else { return }

                let screenCaptures: [CompanionScreenCapture]
                var contextUnavailableNote = ""
                if !shouldCaptureScreen {
                    HeyMateLog.log("⚡️ Talk: text-only fast path")
                    screenCaptures = []
                } else if isFrontmostAppScreenExcluded {
                    HeyMateLog.log("🛡️ Talk: frontmost app excluded — voice-only response")
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

                let screenImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }
                let attachedImages = imageAttachments.map {
                    (data: $0.data, label: $0.modelLabel)
                }
                let labeledImages = screenImages + attachedImages

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
                if !screenCaptures.isEmpty, let walkthroughBlock = walkthroughPromptBlock() {
                    promptParts.append(walkthroughBlock)
                }
                if Self.shouldAnchorToPriorTopic(transcript: transcript),
                   let topicAnchor = Self.topicAnchorPromptFragment(mostRecentExchange: historyForAPI.last) {
                    promptParts.append(topicAnchor)
                }
                promptParts.append(contentsOf: await macAccountContextBlocks(for: transcript))
                if !imageAttachments.isEmpty {
                    promptParts.append(
                        "The user explicitly attached \(imageAttachments.count) image(s). Analyze those attachments as primary context. They are not live screens, so never emit pointer coordinates for them."
                    )
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
                    ? TalkToolCatalog.availableTools(connectorRuntime: connectorRuntime).filter { talkTool in
                        guard case .connector(let identifier, _, _) = talkTool.origin else { return true }
                        return isConnectorEnabledForChat(identifier)
                    }
                    : []

                // A CLI-backed brain loads Composio inside its own child, so
                // its tools never appear in `availableTalkTools`. Both cases
                // have to be checked or the prompt tells the wrong half of
                // the turns that connected apps are out of reach.
                let composioIsReachableThisTurn = availableTalkTools.contains { talkTool in
                    guard case .connector(let identifier, _, _) = talkTool.origin else { return false }
                    return identifier == ComposioSessionStore.connectorID
                } || (talkClient as? SubscriptionCLIVisionClient)?.carriesComposioTools == true
                let composioBlock = composioIsReachableThisTurn
                    ? ComposioAgentAttachment.talkPromptBlock(
                        enabledToolkitSlugs: enabledChatComposioSlugs
                    )
                    : ComposioAgentAttachment.unreachablePromptBlock()

                let speakingMate = speakingMateForTurn()
                let effectiveSystemPrompt = BehaviorContract.combinedSystemPrompt(
                    voicePersonaPrompt: Self.companionResponseSystemPrompt(isSilentModeEnabled: isSilentModeEnabled),
                    matchedSkillsBlock: Self.skillsPromptBlock(skills: matchedSkills),
                    isComputerControlEnabled: computerUseCoordinator.isEnabled,
                    connectedToolsBlock: Self.connectorsPromptBlock(talkTools: availableTalkTools),
                    connectedAppsBlock: composioBlock,
                    mateIdentityBlock: mateIdentityBlock(for: speakingMate)
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
                            self?.publishStreamingAssistantText(GuidedReplyParser.streamingDisplayText(
                                VisualActionParser.extract(from: chunk).spokenText
                            ))
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
                            self?.publishStreamingAssistantText(GuidedReplyParser.streamingDisplayText(
                                VisualActionParser.extract(from: chunk).spokenText
                            ))
                        }
                    )
                }

                guard !Task.isCancelled, !completion.didComplete else { return }

                let extracted = VisualActionParser.extract(from: fullResponseText)
                if !extracted.actions.isEmpty {
                    applyVisualActions(extracted.actions, screenCaptures: screenCaptures)
                }

                // Every [POINT:] tag becomes its own step, so a reply can walk
                // the user through several things in order.
                let guidedReply = GuidedReplyParser.parse(extracted.spokenText)
                let isGuidedPlayback = activeRoutineTurn == nil && backgroundRoutineSession == nil
                if isGuidedPlayback {
                    applyWalkthroughDirectives(guidedReply.walkthroughDirectives, goal: transcript)
                    endWalkthroughIfFinished(by: guidedReply)
                } else if let firstPointing = guidedReply.firstPointing {
                    applyPointingParseResult(firstPointing, screenCaptures: screenCaptures)
                }
                // Strip any [ACT:…] directives before the text is spoken —
                // the user should hear "I'll click Send", not the markup.
                let withoutActions = ComputerUseTagParser.strippingActionTags(
                    from: guidedReply.spokenText
                )
                let handoff = MateHandoffParser.extract(
                    from: withoutActions,
                    mates: mateDirectory.mates,
                    sender: speakingMateForTurn(),
                    senderHops: activeHandoffMateID == nil ? 0 : activeHandoffHops
                )
                if !handoff.handoffs.isEmpty {
                    pendingHandoffs.append(contentsOf: handoff.handoffs)
                }
                let work = MateWorkParser.extract(from: handoff.spokenText)
                let spokenText = work.spokenText
                startMateWork(work.tasks, mate: speakingMateForTurn())

                appendAssistantMessage(spokenText)
                HeyMateLog.log("🧠 Conversation history: \(conversationHistory.count) exchanges")
                updateRollingSessionSummary()

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                if AgentEscalation.shouldEscalate(responseText: spokenText, transcript: transcript) {
                    completion.didComplete = true
                    // A mate that answered "can't" instead of writing [WORK: ...]
                    // still gets its run, in its own folder.
                    if work.tasks.isEmpty {
                        startMateWork(
                            [AgentEscalation.agentInstruction(from: transcript)],
                            mate: speakingMateForTurn()
                        )
                    }
                    if activeRoutineTurn != nil {
                        completeActiveRoutineTurn(.success(spokenText))
                    }
                    return
                }

                if activeRoutineTurn != nil {
                    completeActiveRoutineTurn(.success(spokenText))
                } else if activeHandoffMateID != nil {
                    let shouldSpeak = backgroundRoutineSession == nil
                    completeActiveHandoff(succeeded: true)
                    if shouldSpeak, !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        offerSilentModeIfAnsweringThroughSpeakers()
                        do {
                            try await playGuidedTurn(guidedReply, screenCaptures: screenCaptures)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            Self.recordPipelineError(error, category: .textToSpeech)
                            speakPipelineFailure(error)
                        }
                    }
                } else if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || guidedReply.pointingStepCount > 0 {
                    offerSilentModeIfAnsweringThroughSpeakers()
                    recordAnsweredQuestionForStarNudge()
                    do {
                        try await playGuidedTurn(guidedReply, screenCaptures: screenCaptures)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Self.recordPipelineError(error, category: .textToSpeech)
                        speakPipelineFailure(error)
                        isSubscriptionVoiceChatActive = false
                    }
                }

                // A routine or background turn is not played step by step,
                // so its directives still run here, after the reply.
                if !isGuidedPlayback,
                   let actionOutcome = await performComputerUseDirectives(in: extracted.spokenText) {
                    appendAssistantMessage(actionOutcome)
                }
            } catch is CancellationError {
                if activeRoutineTurn != nil {
                    completeActiveRoutineTurn(.cancelled)
                } else if activeHandoffMateID != nil {
                    completeActiveHandoff(succeeded: false)
                }
            } catch {
                Self.recordPipelineError(error, category: .responsePipeline)
                dispatch(.fail(error.localizedDescription))
                if activeRoutineTurn != nil {
                    completeActiveRoutineTurn(.failure(error.localizedDescription))
                } else if activeHandoffMateID != nil {
                    completeActiveHandoff(succeeded: false)
                } else {
                    // A turn typed in the window is read, not heard, so an
                    // expired login has to say what to do in the chat too.
                    // The notch then offers "Sign in to Claude" instead of
                    // leaving the user with an error.
                    let failure = SpokenFailure.classify(error)
                    if failure == .signedOut {
                        appendAssistantMessage(subscriptionSignInNeededMessage())
                        if noteSubscriptionSignInNeeded() != nil {
                            notchCompanionController.expandPinned()
                        }
                    }
                    speak(failure, isAlreadyShownInChat: failure == .signedOut)
                    isSubscriptionVoiceChatActive = false
                }
            }

            guard !completion.didComplete else { return }
            completion.didComplete = true
            if !Task.isCancelled {
                dispatch(.interactionFinished)
                restoreAgentForegroundIfNeeded()
                if isSubscriptionVoiceChatActive {
                    continueSubscriptionVoiceChat()
                } else {
                    scheduleTransientHideIfNeeded()
                }
                scheduleNextHandoffIfNeeded()
            }
        }
    }

    private static func recordPipelineError(
        _ error: Error,
        category: AnalyticsErrorCategory
    ) {
        let summary = AnalyticsErrorSummary(category: category, error: error)
        ClickyAnalytics.trackError(summary)
        pipelineErrorLogger.error(
            "Pipeline failure category=\(summary.category.rawValue, privacy: .public) domain=\(summary.domain, privacy: .public) code=\(summary.code, privacy: .public)"
        )
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
    /// Internal rather than private: the loopback bridge routes a child
    /// CLI's connector call through this same gate, so a tool called from a
    /// Talk turn and one called from a spawned `claude`/`codex` obey one
    /// approval policy instead of two.
    func executeConnectorTalkTool(
        namespacedToolID: String,
        connectorIdentifier: String,
        connectorDisplayName: String,
        maximumRisk: ConnectorToolRisk,
        arguments: [String: Any]
    ) async -> (text: String, isError: Bool) {
        guard isConnectorEnabledForChat(connectorIdentifier) else {
            return ("That connector is disabled for this chat.", true)
        }
        if connectorIdentifier == ComposioSessionStore.connectorID,
           let disabledApp = disabledComposioAppRequested(
                byToolNamed: namespacedToolID,
                arguments: arguments
           ) {
            return ("\(disabledApp) is disabled for this chat.", true)
        }

        // Judged per tool, capped by what the connector can do at worst. The
        // ceiling alone would put a destructive-red card in front of a tool
        // search, and a turn that has to wait on a click to discover anything
        // runs out of time before it answers.
        let risk = ConnectorToolRisk.inferred(
            forToolNamed: namespacedToolID,
            arguments: arguments,
            ceiling: maximumRisk
        )
        let approvalPolicy = connectorStore.record(for: connectorIdentifier).approvalPolicy
        if approvalPolicy.requiresApproval(forRisk: risk) {
            let wasApproved = await connectorToolCoordinator.requestApproval(
                for: ConnectorToolApprovalRequest(
                    connectorDisplayName: connectorDisplayName,
                    toolName: namespacedToolID,
                    argumentsSummary: TalkToolCatalog.argumentsSummary(arguments),
                    risk: risk
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

    /// Composio exposes one meta execute tool for every connected app. Chat
    /// scope therefore must inspect inner tool slugs, not only connector id.
    private func disabledComposioAppRequested(
        byToolNamed toolName: String,
        arguments: [String: Any]
    ) -> String? {
        guard toolName.uppercased().contains("COMPOSIO_MULTI_EXECUTE_TOOL"),
              let tools = arguments["tools"] as? [[String: Any]] else { return nil }
        let connectedSlugs = composioConnections.connectedSlugs
        for tool in tools {
            guard let innerName = (tool["tool_slug"] as? String)
                ?? (tool["tool_name"] as? String)
                ?? (tool["slug"] as? String) else { continue }
            let uppercaseInnerName = innerName.uppercased()
            guard let matchedSlug = connectedSlugs.first(where: {
                uppercaseInnerName.hasPrefix($0.uppercased().replacingOccurrences(of: "-", with: "_") + "_")
            }) else { continue }
            let selectionID = Self.chatConnectorSelectionID(forComposioSlug: matchedSlug)
            if !isConnectorSelectionEnabledForTurn(selectionID) {
                return composioConnections.records[matchedSlug]?.displayName ?? matchedSlug
            }
        }
        return nil
    }

    /// Speaks a classified failure. Credits only when the *model* is out of
    /// quota — never because Mac listen/speak were selected.
    private func speakPipelineFailure(_ error: Error) {
        speak(SpokenFailure.classify(error))
    }

    private func speak(_ failure: SpokenFailure, isAlreadyShownInChat: Bool = false) {
        guard let utterance = failure.spokenUtterance else { return }
        // Silent mode never speaks, so a failure has to be read instead of
        // vanishing — the user is looking at the chat, not listening.
        if isSilentModeEnabled {
            if !isAlreadyShownInChat {
                appendAssistantMessage(utterance)
            }
            return
        }
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

            while !cursorCaptionText.isEmpty {
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

    func applyPointingParseResult(
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

        if parseResult.coordinate != nil, state == .thinking {
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
            let telemetry = ScreenPointingTelemetrySummary(
                coordinate: pointCoordinate,
                elementLabel: parseResult.elementLabel
            )
            ClickyAnalytics.trackElementPointed(telemetry)
            Self.screenPointingLogger.info(
                "Element pointing x=\(telemetry.x, privacy: .public) y=\(telemetry.y, privacy: .public) labelCharacters=\(telemetry.labelCharacterCount, privacy: .public)"
            )
        } else {
            let telemetry = ScreenPointingTelemetrySummary(
                coordinate: nil,
                elementLabel: parseResult.elementLabel
            )
            Self.screenPointingLogger.info(
                "Element pointing x=\(telemetry.x, privacy: .public) y=\(telemetry.y, privacy: .public) labelCharacters=\(telemetry.labelCharacterCount, privacy: .public)"
            )
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
                HeyMateLog.log("🛡️ Onboarding demo: frontmost app excluded — skipping capture")
                return
            }

            do {
                CaptureAudit.shared.recordCaptureAttempt(context: CaptureAudit.Context.onboardingDemoInteraction)
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    HeyMateLog.log("🎯 Onboarding demo: no cursor screen found")
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
                    HeyMateLog.log("🎯 Onboarding demo: no element to point at")
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
                let telemetry = ScreenPointingTelemetrySummary(
                    coordinate: pointCoordinate,
                    elementLabel: parseResult.elementLabel,
                    commentary: parseResult.spokenText
                )
                Self.screenPointingLogger.info(
                    "Onboarding pointing x=\(telemetry.x, privacy: .public) y=\(telemetry.y, privacy: .public) labelCharacters=\(telemetry.labelCharacterCount, privacy: .public) commentaryCharacters=\(telemetry.commentaryCharacterCount, privacy: .public)"
                )
            } catch {
                HeyMateLog.log("⚠️ Onboarding demo error: \(error)")
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
            self?.selectedClaudeModelID
        }
        agentLauncher.claudeEffort = { [weak self] in
            self?.selectedClaudeEffortIfSupported
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
        // Authorising a new app has to re-mint the router session: the old
        // one was scoped without it, so every search would keep answering as
        // though the app were never connected.
        composioConnections.onConnectedToolkitsChanged = { [weak self] in
            await self?.connectorRuntime.refreshComposioForChangedToolkits()
        }
        agentLauncher.openCodeMCPConfigurationJSON = {
            HeyMateMCPServer.openCodeConfigurationJSON()
        }
        // Cua's driver rides only on approved legs (the launcher never asks
        // for a config on a read-only leg) and only while computer control
        // is switched on.
        agentLauncher.claudeMCPConfigurationJSON = { [weak self] in
            HeyMateMCPServer.claudeCodeConfigurationJSON(
                additionalServers: CuaDriverSetup.shared.claudeServers(
                    computerControlEnabled: self?.computerUseCoordinator.isEnabled == true
                )
            )
        }
        agentLauncher.claudeMCPAllowedToolNames = { [weak self] in
            HeyMateMCPServer.claudeCodeToolNames() + CuaDriverSetup.shared.claudeAllowedToolNames(
                computerControlEnabled: self?.computerUseCoordinator.isEnabled == true
            )
        }
        // No allow-list: connector tools are discovered from the user's live
        // sessions at `tools/list` time, so naming only the overlay tools here
        // would filter out every connected app a mate's job needs.
        agentLauncher.codexMCPConfigurationArguments = { [weak self] in
            HeyMateMCPServer.codexConfigurationArguments(enabledTools: nil)
                + CuaDriverSetup.shared.codexArguments(
                    computerControlEnabled: self?.computerUseCoordinator.isEnabled == true
                )
        }
        Task { await CuaDriverSetup.shared.refresh() }
        agentLauncher.mcpChildEnvironment = { executor in
            _ = executor
            return HeyMateMCPServer.childEnvironment()
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

    @discardableResult
    func startSandboxAgent(prompt: String, executor: HeadlessExecutor? = nil) -> UUID? {
        leaveTalkPipelineForAgent()
        let explicitlyRequestedExecutor = HeadlessExecutor.explicitlyRequested(in: prompt)
        if selectedBrain.executor == nil, executor == nil, explicitlyRequestedExecutor == nil {
            agentRevealErrorText = selectedBrain.unavailableReason ?? "Pick Claude, Codex, or OpenCode as the brain first."
            speakLine("that brain doesn't run agents. pick claude, codex, or opencode.")
            shouldRevealAgentsTab = true
            return nil
        }
        let resolvedExecutor = executor
            ?? explicitlyRequestedExecutor
            ?? selectedBrain.executor
            ?? defaultHeadlessExecutor
        HeyMateLog.log("🤖 Agent: starting sandbox (\(resolvedExecutor.displayName))")
        let runID = agentLauncher.startSandbox(
            prompt: prompt,
            executor: resolvedExecutor,
            screenContext: currentAgentScreenContext()
        )
        shouldRevealAgentsTab = true
        speakAgentStartedAck()
        scheduleTransientHideIfNeeded()
        return runID
    }

    /// One-line ack so Talk doesn't feel dead while the CLI boots. Does not
    /// enter `.speaking` — that would fight the agent-running state.
    private func speakAgentStartedAck() {
        speakLine("on it. i'll plan it first and show you before i touch anything.")
    }

    /// Says one plain sentence. `speak(_:)` is for `SpokenFailure` only, and
    /// an agent milestone is not a failure.
    private func speakLine(_ utterance: String) {
        guard activeRoutineTurn == nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.voiceSynthesisClient.speakText(utterance)
            } catch {
                HeyMateLog.log("⚠️ Agent TTS failed: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func startAttachedAgent(prompt: String, workspaceURL: URL, executor: HeadlessExecutor? = nil) -> UUID? {
        leaveTalkPipelineForAgent()
        let explicitlyRequestedExecutor = HeadlessExecutor.explicitlyRequested(in: prompt)
        if selectedBrain.executor == nil, executor == nil, explicitlyRequestedExecutor == nil {
            agentRevealErrorText = selectedBrain.unavailableReason ?? "Pick Claude, Codex, or OpenCode as the brain first."
            speakLine("that brain doesn't run agents. pick claude, codex, or opencode.")
            shouldRevealAgentsTab = true
            return nil
        }
        let resolvedExecutor = executor
            ?? explicitlyRequestedExecutor
            ?? selectedBrain.executor
            ?? defaultHeadlessExecutor
        let runID = agentLauncher.startAttached(
            prompt: prompt,
            executor: resolvedExecutor,
            workspaceURL: workspaceURL,
            screenContext: currentAgentScreenContext()
        )
        shouldRevealAgentsTab = true
        return runID
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
        Task { [weak self] in
            guard let self else { return }
            switch await self.agentLauncher.beginTerminalTakeover(runID: runID) {
            case .success(let command):
                if !AgentTerminalTakeover.openInTerminal(command: command) {
                    self.agentRevealErrorText = "Couldn't open Terminal. Allow HeyMate to control Terminal in System Settings › Privacy & Security › Automation. Resume command: \(command)"
                }
            case .failure(let unavailability):
                self.agentRevealErrorText = unavailability.explanation
            }
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
        if let run = agentRunStore.run(id: runID) {
            agentUserNotifier.handle(run: run, event: event)
        }

        postMateRunUpdate(runID: runID, event: event)

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
