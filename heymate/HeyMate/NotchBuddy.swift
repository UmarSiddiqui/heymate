//
//  NotchBuddy.swift
//  HeyMate
//
//  The little character that lives beside the camera in the collapsed
//  notch. This file is the logic only: which mate is shown, which pose it
//  is in, how fast it walks and which frame to draw. The art is drawn in
//  code in `NotchBuddyView.swift`; HeyMate ships no sprite sheets.
//
//  Every decision is a pure function of a value snapshot and a date, so
//  the view can ask "what is on screen at time t" without timers, and the
//  tests can ask the same thing without a window.
//

import Combine
import Foundation

// MARK: - Poses

/// How fast a working mate moves its feet.
nonisolated enum NotchBuddyGait: Equatable, CaseIterable {
    case walk
    case run
    case sprint

    /// Token-equivalents per second at which the mate breaks into a run.
    static let runThreshold: Double = 8
    /// Token-equivalents per second at which it sprints.
    static let sprintThreshold: Double = 28

    static func forRate(_ rate: Double) -> Self {
        guard rate.isFinite else { return .walk }
        if rate >= sprintThreshold { return .sprint }
        if rate >= runThreshold { return .run }
        return .walk
    }
}

/// What a working mate is holding while it walks.
nonisolated enum NotchBuddyWork: Equatable, CaseIterable {
    /// Nothing recognisable in the progress line: just keep walking.
    case none
    case reasoning
    case reading
    case writing
    case tooling
    case browsing

    /// Reads a run's latest progress line with the same rules the mate
    /// faces use, so the notch and the cards never disagree.
    static func forProgress(_ text: String) -> Self {
        switch MateWorkActivity.match(for: text) {
        case .thinking: return .reasoning
        case .reading: return .reading
        case .writing: return .writing
        case .tooling: return .tooling
        case .browsing: return .browsing
        default: return .none
        }
    }
}

nonisolated enum NotchBuddyPose: Equatable {
    case doze
    case waking
    case idle
    case listening
    case thinking
    case speaking
    case guiding
    /// A job or the voice pipeline needs the user: the mate waves.
    case attention
    case celebrate
    case failed
    case working(NotchBuddyWork, NotchBuddyGait)

    /// Base frames per second and whether the pose loops. Once-poses hold
    /// their last frame. Rates follow the behaviour study (6 to 18 FPS).
    var playback: (fps: Double, loops: Bool) {
        switch self {
        case .doze: return (6, true)
        case .waking: return (14, false)
        case .idle, .listening, .thinking, .speaking: return (8, true)
        case .guiding, .attention: return (14, true)
        case .celebrate, .failed: return (14, false)
        case .working(_, let gait):
            switch gait {
            case .walk: return (14, true)
            case .run: return (16, true)
            case .sprint: return (18, true)
            }
        }
    }

    /// Resting poses obey the "idle animations" preference.
    var isIdle: Bool { self == .idle || self == .doze }
}

// MARK: - Frame clock

/// The frame is a function of time since the pose started, never a
/// counter, so a pose always starts from frame 0 and a missed redraw
/// never makes the character drift.
nonisolated enum NotchBuddyFrameClock {
    static let framesPerPose = 16
    /// Redraw ceiling. Reduce Motion draws one still frame instead.
    static let maximumFPS: Double = 24
    /// The frame Reduce Motion (and a paused idle) always shows.
    static let stillFrame = 0

    /// Whole frames elapsed since the pose started.
    static func tick(for pose: NotchBuddyPose, elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        let fps = max(1, pose.playback.fps)
        return Int((elapsed * fps).rounded(.down))
    }

    static func frame(for pose: NotchBuddyPose, elapsed: TimeInterval, still: Bool) -> Int {
        guard !still else { return stillFrame }
        let tick = tick(for: pose, elapsed: elapsed)
        return pose.playback.loops ? tick % framesPerPose : min(tick, framesPerPose - 1)
    }

    /// Which pass through the loop this is. Lets the idle pose blink or
    /// glance only on some loops instead of every two seconds.
    static func loop(for pose: NotchBuddyPose, elapsed: TimeInterval, still: Bool) -> Int {
        guard !still, pose.playback.loops else { return 0 }
        return tick(for: pose, elapsed: elapsed) / framesPerPose
    }

    /// Seconds between redraws for a pose, capped at `maximumFPS`.
    static func redrawInterval(for pose: NotchBuddyPose) -> TimeInterval {
        1 / min(maximumFPS, max(1, pose.playback.fps))
    }

    /// How long a once-pose takes to reach its last frame.
    static func onceDuration(for pose: NotchBuddyPose) -> TimeInterval {
        Double(framesPerPose) / max(1, pose.playback.fps)
    }
}

// MARK: - Pace

/// Smoothed work rate for one run.
///
/// HeyMate's agent runtime reports no token counts, so pace comes from
/// how often a run's activity entries (progress lines, agent messages,
/// status changes) arrive. Each new entry counts as
/// `tokensPerActivityEntry` token-equivalents, which lets the reference
/// thresholds (walk under 8/s, run 8–28/s, sprint 28/s and up) and the
/// 0.65 · previous + 0.35 · sample smoothing apply unchanged. With 24
/// tokens per entry, one entry every 3 s or slower walks, one every
/// 0.86–3 s runs, and faster than that sprints. A run that goes quiet for
/// `staleAfter` drops back to a walk without needing a timer to decay it.
nonisolated struct NotchBuddyPace: Equatable {
    static let tokensPerActivityEntry: Double = 24
    static let minimumSampleInterval: TimeInterval = 0.25
    static let previousWeight: Double = 0.65
    static let sampleWeight: Double = 0.35
    static let staleAfter: TimeInterval = 12

    /// Nil until the second observation: the first one only sets the clock.
    private(set) var smoothedRate: Double?
    private(set) var lastSampleAt: Date?
    private(set) var lastProgressAt: Date?

    /// Records `units` token-equivalents that arrived since the last sample.
    mutating func sample(units: Double, at now: Date) {
        defer { lastSampleAt = now }
        if units > 0 { lastProgressAt = now }
        guard let lastSampleAt else { return }
        let interval = max(Self.minimumSampleInterval, now.timeIntervalSince(lastSampleAt))
        let rate = max(0, units.isFinite ? units : 0) / interval
        if let smoothedRate {
            self.smoothedRate = Self.previousWeight * smoothedRate + Self.sampleWeight * rate
        } else {
            smoothedRate = rate
        }
    }

    mutating func sample(newEntries: Int, at now: Date) {
        sample(units: Double(max(0, newEntries)) * Self.tokensPerActivityEntry, at: now)
    }

    func gait(at now: Date) -> NotchBuddyGait {
        guard let smoothedRate else { return .walk }
        if let lastProgressAt, now.timeIntervalSince(lastProgressAt) > Self.staleAfter { return .walk }
        return NotchBuddyGait.forRate(smoothedRate)
    }
}

/// Paces for every live run, fed from each `agentRuns` publish.
nonisolated struct NotchBuddyPaceTracker: Equatable {
    private struct Entry: Equatable {
        var pace = NotchBuddyPace()
        var lastSeenEntryAt: Date
    }

    private var entries: [UUID: Entry] = [:]

    func pace(for runID: UUID) -> NotchBuddyPace? { entries[runID]?.pace }

    mutating func observe(_ runs: [AgentRun], at now: Date) {
        var next: [UUID: Entry] = [:]
        for run in runs where !run.status.isTerminal {
            let counted = run.activity.filter { $0.kind != .user }
            let newest = counted.map(\.createdAt).max() ?? run.createdAt
            if var entry = entries[run.id] {
                let fresh = counted.filter { $0.createdAt > entry.lastSeenEntryAt }.count
                entry.pace.sample(newEntries: fresh, at: now)
                entry.lastSeenEntryAt = max(entry.lastSeenEntryAt, newest)
                next[run.id] = entry
            } else {
                // First sighting sets the baseline: history is not speed.
                var entry = Entry(lastSeenEntryAt: newest)
                entry.pace.sample(newEntries: 0, at: now)
                next[run.id] = entry
            }
        }
        entries = next
    }
}

// MARK: - Snapshot

/// One live run, as much of it as the character needs.
nonisolated struct NotchBuddyRun: Equatable {
    let id: UUID
    let mateID: UUID
    let status: AgentRunStatus
    let latestAction: String
    let createdAt: Date
    var pace = NotchBuddyPace()
}

/// A job that just finished, played once on its mate.
nonisolated struct NotchBuddyOutcome: Equatable {
    let runID: UUID
    let mateID: UUID
    let succeeded: Bool
    let at: Date
}

/// Everything the director reads. A value, so a render can never see a
/// half-updated model.
nonisolated struct NotchBuddyContext: Equatable {
    var companionState: CompanionState = .idle
    var stateChangedAt: Date
    var activeMateID: UUID
    var runs: [NotchBuddyRun] = []
    var outcomes: [NotchBuddyOutcome] = []
    /// Last time anything happened: a state change, a job change, a hover.
    var idleSince: Date
    /// Set when activity arrives while the mate is dozing.
    var wakeStartedAt: Date?

    init(activeMateID: UUID, now: Date) {
        self.activeMateID = activeMateID
        stateChangedAt = now
        idleSince = now
    }
}

/// What the notch shows at one moment.
nonisolated struct NotchBuddyScene: Equatable {
    let mateID: UUID
    let pose: NotchBuddyPose
    /// When this pose started. The frame clock counts from here.
    let since: Date
    /// Mates with live jobs, for the trailing count.
    let liveMateCount: Int
}

// MARK: - Director

nonisolated enum NotchBuddyDirector {
    /// Idle this long and the mate dozes off.
    static let dozeAfter: TimeInterval = 120
    /// Seconds each mate gets in the notch when several are working.
    static let rotationInterval: TimeInterval = 4
    /// How long a finished job's celebrate or wobble stays up. A little
    /// longer than the animation so the last frame reads.
    static let outcomeDuration: TimeInterval = 1.8
    static var wakeDuration: TimeInterval { NotchBuddyFrameClock.onceDuration(for: .waking) }

    /// Voice and companion state, which always outrank background jobs.
    /// Nil means "nothing in the foreground": jobs or rest decide.
    static func pose(for state: CompanionState) -> NotchBuddyPose? {
        switch state {
        case .idle, .agentRunning: return nil
        case .listening, .finalizingTranscript: return .listening
        case .capturingContext, .thinking: return .thinking
        case .speaking: return .speaking
        case .guiding: return .guiding
        case .waitingForApproval: return .attention
        case .error: return .failed
        }
    }

    static func pose(for run: NotchBuddyRun, at now: Date) -> NotchBuddyPose {
        if run.status.needsUser { return .attention }
        switch run.status {
        case .queued: return .idle
        case .planning: return .working(.reasoning, run.pace.gait(at: now))
        case .running: return .working(NotchBuddyWork.forProgress(run.latestAction), run.pace.gait(at: now))
        case .succeeded: return .celebrate
        case .failed: return .failed
        case .cancelled, .awaitingPlanApproval, .waitingForApproval: return .idle
        }
    }

    /// Higher is more urgent. Waiting on the user beats working beats queued.
    static func urgency(of status: AgentRunStatus) -> Int {
        if status.needsUser { return 3 }
        switch status {
        case .planning, .running: return 2
        case .queued: return 1
        default: return 0
        }
    }

    /// The most urgent live run for each mate, most urgent mate first, then
    /// the mate whose job started earliest. This is the rotation order.
    static func rotation(_ runs: [NotchBuddyRun]) -> [NotchBuddyRun] {
        var best: [UUID: NotchBuddyRun] = [:]
        for run in runs where !run.status.isTerminal {
            guard let current = best[run.mateID] else { best[run.mateID] = run; continue }
            if precedes(run, current) { best[run.mateID] = run }
        }
        return best.values.sorted(by: precedes)
    }

    private static func precedes(_ left: NotchBuddyRun, _ right: NotchBuddyRun) -> Bool {
        let leftUrgency = urgency(of: left.status)
        let rightUrgency = urgency(of: right.status)
        if leftUrgency != rightUrgency { return leftUrgency > rightUrgency }
        if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
        return left.id.uuidString < right.id.uuidString
    }

    static func dozeStart(_ context: NotchBuddyContext) -> Date {
        context.idleSince.addingTimeInterval(dozeAfter)
    }

    /// The scene at `now`. `still` is Reduce Motion: no rotation and no
    /// wake-up stretch, just the most urgent mate in a held pose.
    static func scene(_ context: NotchBuddyContext, at now: Date, still: Bool) -> NotchBuddyScene {
        let rotation = rotation(context.runs)
        let liveCount = rotation.count

        func scene(_ mateID: UUID, _ pose: NotchBuddyPose, since: Date) -> NotchBuddyScene {
            NotchBuddyScene(mateID: mateID, pose: pose, since: since, liveMateCount: liveCount)
        }

        // 1. The foreground conversation, on the mate you are talking to.
        if let voice = pose(for: context.companionState) {
            return scene(context.activeMateID, voice, since: context.stateChangedAt)
        }

        // 2. A job that just ended plays its outcome once.
        if let outcome = context.outcomes
            .filter({ now >= $0.at && now.timeIntervalSince($0.at) < outcomeDuration })
            .max(by: { $0.at < $1.at }) {
            return scene(outcome.mateID, outcome.succeeded ? .celebrate : .failed, since: outcome.at)
        }

        // 3. A waking stretch, if activity just roused a dozing mate.
        let waking = !still && context.wakeStartedAt.map { now >= $0 && now.timeIntervalSince($0) < wakeDuration } == true

        // 4. Live jobs, rotating every few seconds.
        if !rotation.isEmpty {
            let index: Int
            let since: Date
            if still || rotation.count == 1 {
                index = 0
                since = context.stateChangedAt
            } else {
                let slot = (now.timeIntervalSinceReferenceDate / rotationInterval).rounded(.down)
                index = Int(slot.truncatingRemainder(dividingBy: Double(rotation.count)))
                since = Date(timeIntervalSinceReferenceDate: slot * rotationInterval)
            }
            let run = rotation[max(0, min(index, rotation.count - 1))]
            let pose = pose(for: run, at: now)
            if waking, pose != .attention, let wakeStartedAt = context.wakeStartedAt {
                return scene(run.mateID, .waking, since: wakeStartedAt)
            }
            return scene(run.mateID, pose, since: max(since, context.stateChangedAt))
        }

        if waking, let wakeStartedAt = context.wakeStartedAt {
            return scene(context.activeMateID, .waking, since: wakeStartedAt)
        }

        // 5. Rest: idle, then a doze after a long quiet spell.
        let dozeStart = dozeStart(context)
        if now >= dozeStart {
            return scene(context.activeMateID, .doze, since: dozeStart)
        }
        return scene(context.activeMateID, .idle, since: context.idleSince)
    }

    /// True when the scene at `now` would be a doze. The model uses this to
    /// decide whether new activity should play the wake-up stretch.
    static func isDozing(_ context: NotchBuddyContext, at now: Date) -> Bool {
        scene(context, at: now, still: true).pose == .doze
    }

    /// The next moment the picture changes when nothing animates: the doze
    /// onset, an outcome ending, a wake ending, or the next rotation slot.
    static func nextChange(after now: Date, in context: NotchBuddyContext, still: Bool) -> Date? {
        var candidates: [Date] = []
        if pose(for: context.companionState) == nil, context.runs.allSatisfy(\.status.isTerminal) {
            candidates.append(dozeStart(context))
        }
        for outcome in context.outcomes {
            candidates.append(outcome.at.addingTimeInterval(outcomeDuration))
        }
        if let wakeStartedAt = context.wakeStartedAt, !still {
            candidates.append(wakeStartedAt.addingTimeInterval(wakeDuration))
        }
        if !still, rotation(context.runs).count > 1 {
            let slot = (now.timeIntervalSinceReferenceDate / rotationInterval).rounded(.down) + 1
            candidates.append(Date(timeIntervalSinceReferenceDate: slot * rotationInterval))
        }
        for run in context.runs where !run.status.isTerminal {
            if let last = run.pace.lastProgressAt {
                candidates.append(last.addingTimeInterval(NotchBuddyPace.staleAfter + 0.01))
            }
        }
        return candidates.filter { $0 > now }.min()
    }
}

// MARK: - Motion

/// What the view is allowed to do right now.
nonisolated struct NotchBuddyMotion: Equatable {
    var policy: CompanionMotionPolicy

    /// Reduce Motion (system or container) shows one still frame.
    var isStill: Bool { policy.reduceMotion }

    func animates(_ pose: NotchBuddyPose) -> Bool {
        policy.allowsPlayback(isIdle: pose.isIdle)
    }

    /// When to draw next after `date`, or nil to stop. Hidden views never
    /// schedule anything. Low-frequency mode (a backgrounded or dimmed
    /// display) slows the walk to one frame a second.
    func nextRedraw(after date: Date, context: NotchBuddyContext, lowFrequency: Bool = false) -> Date? {
        guard policy.isVisible else { return nil }
        let scene = NotchBuddyDirector.scene(context, at: date, still: isStill)
        let change = NotchBuddyDirector.nextChange(after: date, in: context, still: isStill)
        guard animates(scene.pose) else { return change }
        // A once-pose that has reached its last frame holds; wait for the
        // next real change instead of redrawing the same picture.
        if !scene.pose.playback.loops,
           date.timeIntervalSince(scene.since) >= NotchBuddyFrameClock.onceDuration(for: scene.pose) {
            return change
        }
        let interval = lowFrequency ? 1 : NotchBuddyFrameClock.redrawInterval(for: scene.pose)
        let next = date.addingTimeInterval(interval)
        if let change, change < next { return change }
        return next
    }
}

// MARK: - Model

/// Owned by the notch controller, observed by the character view. Holds a
/// `NotchBuddyContext` value and updates it from coarse app signals only:
/// companion state, job list, mates and hover. Nothing here ticks.
@MainActor
final class NotchBuddyModel: ObservableObject {
    @Published private(set) var context: NotchBuddyContext
    /// Face asset per mate, for the character's colour.
    @Published private(set) var mateAssets: [UUID: String] = [:]

    private var defaultMateID: UUID
    private var paceTracker = NotchBuddyPaceTracker()
    private var knownStatuses: [UUID: AgentRunStatus] = [:]
    private let now: () -> Date

    #if DEBUG
    /// Snapshot renders pin the clock so every frame is reproducible.
    var snapshotDate: Date?
    #endif

    init(defaultMateID: UUID = UUID(), now: @escaping () -> Date = Date.init) {
        self.defaultMateID = defaultMateID
        self.now = now
        context = NotchBuddyContext(activeMateID: defaultMateID, now: now())
    }

    func assetName(for mateID: UUID) -> String {
        mateAssets[mateID] ?? MateFace.legacyAssetNames[0]
    }

    func setMates(_ mates: [Mate], activeMateID: UUID?, defaultMateID: UUID) {
        self.defaultMateID = defaultMateID
        let assets = Dictionary(mates.map { ($0.id, MateFace.assetName(for: $0)) },
                                uniquingKeysWith: { _, latest in latest })
        if assets != mateAssets { mateAssets = assets }
        let active = activeMateID ?? defaultMateID
        if context.activeMateID != active { context.activeMateID = active }
    }

    func setCompanionState(_ state: CompanionState) {
        guard state != context.companionState else { return }
        let date = now()
        var next = context
        if NotchBuddyDirector.pose(for: state) != nil { wakeIfDozing(&next, at: date) }
        next.companionState = state
        next.stateChangedAt = date
        next.idleSince = date
        context = next
    }

    func setRuns(_ runs: [AgentRun]) {
        let date = now()
        paceTracker.observe(runs, at: date)
        var next = context

        var outcomes = next.outcomes.filter { date.timeIntervalSince($0.at) < NotchBuddyDirector.outcomeDuration }
        for run in runs {
            guard let previous = knownStatuses[run.id], !previous.isTerminal,
                  run.status == .succeeded || run.status == .failed else { continue }
            outcomes.append(NotchBuddyOutcome(runID: run.id, mateID: mateID(for: run),
                                              succeeded: run.status == .succeeded, at: date))
        }
        knownStatuses = Dictionary(runs.map { ($0.id, $0.status) }, uniquingKeysWith: { _, latest in latest })
        next.outcomes = Array(outcomes.suffix(4))

        let live = runs.filter { !$0.status.isTerminal }.map { run in
            NotchBuddyRun(id: run.id, mateID: mateID(for: run), status: run.status,
                          latestAction: run.latestAction, createdAt: run.createdAt,
                          pace: paceTracker.pace(for: run.id) ?? NotchBuddyPace())
        }
        let liveChanged = live.map { [$0.id.uuidString, $0.status.rawValue] } != next.runs.map { [$0.id.uuidString, $0.status.rawValue] }
        if liveChanged || outcomes.count != context.outcomes.count {
            if !live.isEmpty || !outcomes.isEmpty { wakeIfDozing(&next, at: date) }
            next.idleSince = date
        }
        next.runs = live
        if next != context { context = next }
    }

    /// The pointer is on the notch: a dozing mate wakes up and the idle
    /// clock restarts.
    func noteUserPresence() {
        let date = now()
        var next = context
        wakeIfDozing(&next, at: date)
        next.idleSince = date
        context = next
    }

    private func wakeIfDozing(_ context: inout NotchBuddyContext, at date: Date) {
        if NotchBuddyDirector.isDozing(context, at: date) { context.wakeStartedAt = date }
    }

    private func mateID(for run: AgentRun) -> UUID {
        run.chatOwner?.mateID ?? defaultMateID
    }
}
