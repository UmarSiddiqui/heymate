//
//  DriveTakeOverController.swift
//  HeyMate
//
//  Owns a drive from offer to end: idle → offered(goal) → driving(goal,
//  step) → idle. One drive at a time.
//
//  An offer always shows the consent card, whoever asked (Talk, an agent,
//  or the local bridge), and nothing acts until the person presses Take
//  over. While driving, the frame is up, every step is logged, and the
//  person's own mouse, click, or key ends the drive at once. A step cap and
//  a deadline bound every drive.
//
//  Field names follow the takeover controller recovered from HeyClicky's
//  REA pack (phase, actuatingUntil, userPointerMoveStart, actionLog,
//  lastCallResults, driveTakenBackBy, …). The behavior is HeyMate's own.
//

import AppKit
import Combine
import Foundation

enum DriveTakeOverPhase: Equatable {
    case idle
    case offered(goal: String)
    case driving(goal: String, step: Int)

    var name: String {
        switch self {
        case .idle: return "idle"
        case .offered: return "offered"
        case .driving: return "driving"
        }
    }
}

struct DriveTakeOverOutcome: Equatable {
    enum Ending: String, Equatable {
        case completed, handedBack, takenBack, declined, failed, cancelled
    }

    let driveIdentifier: String
    let goal: String
    let status: DriveStatus
    let ending: Ending
    let steps: Int
    let actionLog: [String]

    /// What Talk says and an agent reads back.
    var report: String {
        var lines = [status.summary]
        if !actionLog.isEmpty {
            lines.append("Steps: " + actionLog.suffix(8).joined(separator: "; "))
        }
        return lines.joined(separator: "\n")
    }
}

/// Picks the next step. The live one is a HeyMate agent session of its own;
/// tests script it.
@MainActor
protocol DriveStepDeciding: AnyObject {
    func decide(systemPrompt: String, prompt: String, images: [(data: Data, label: String)]) async throws -> String
}

/// One private agent session per drive, so steps never land in a chat.
@MainActor
final class MateAgentDriveDecider: DriveStepDeciding {
    private let client = MateAgentServeConversationClient(chatID: UUID())

    func decide(systemPrompt: String, prompt: String, images: [(data: Data, label: String)]) async throws -> String {
        try await client.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: [],
            userPrompt: prompt,
            onTextChunk: { _ in }
        ).text
    }
}

@MainActor
final class DriveTakeOverController: ObservableObject {
    @Published private(set) var phase: DriveTakeOverPhase = .idle

    weak var host: CompanionManager?
    let overlay: DriveTakeOverOverlay
    var consentCard: DriveTakeOverOverlay { overlay }

    private(set) var targetBundleID: String?
    /// Until this moment pointer moves are HeyMate's doing, not the person's.
    private(set) var actuatingUntil = Date.distantPast
    var userPointerMoveStart: (CGPoint, Date)? {
        judge.userPointerMoveStart.map { ($0, judge.userPointerMoveStartedAt ?? Date()) }
    }
    private(set) var lastTakeOverEndedAt = Date.distantPast
    private(set) var driveIdentifier = ""
    private(set) var driveStartedAt = Date.distantPast
    /// Held for the life of one drive; a second offer finds it taken.
    private(set) var driveLeaseID: String?
    private(set) var agentDriveEnded: DriveTakeOverOutcome?
    private(set) var driveEnding: DriveTakeOverOutcome.Ending?
    /// The mate the drive was asked for, when one asked.
    var agentDriveMateName: String?
    private(set) var driveTakenBackBy: String?
    private(set) var actionLog: [String] = []
    private(set) var lastCallResults: [[String: Any]] = []
    /// The Talk turn that asked for this drive, if any.
    var currentTurnToken: String?
    var askingTurnTokens: [String] = []

    private let makeDriver: () -> any DriveAppDriving
    private let makeDecider: () -> any DriveStepDeciding
    private let pointerDriver: DrivePointerEvaluationDriver
    private let accessibilityTrusted: () -> Bool
    private let requestConsent: (DriveRequest, String) async -> Bool
    private let watchesInput: Bool
    private let captureScreen: () async -> ScreenSnapshot?
    private let settleDelay: Duration
    private var judge = DriveTakeBackJudge()
    private var driver: (any DriveAppDriving)?
    private var loopTask: Task<DriveTakeOverOutcome, Never>?
    private var outcomes: [String: DriveTakeOverOutcome] = [:]
    private var takeBackReason: ComputerUseTakeBackReason?

    /// Settle time after each action before the next snapshot.
    static let defaultSettleDelay: Duration = .milliseconds(450)
    /// `defaults write <bundle> heymate.drive.fastLaneDisabled -bool YES` turns plans and sums off, for A/B timing.
    static let fastLaneDisabledKey = "heymate.drive.fastLaneDisabled"
    /// Between queued presses the next key is already on screen.
    static let plannedSettleDelay: Duration = .milliseconds(120)
    /// The person's hand is still on the mouse after pressing Take over.
    static let startGrace: TimeInterval = 1.2

    init(
        overlay: DriveTakeOverOverlay? = nil,
        makeDriver: (() -> any DriveAppDriving)? = nil,
        makeDecider: (() -> any DriveStepDeciding)? = nil,
        pointerDriver: DrivePointerEvaluationDriver? = nil,
        accessibilityTrusted: @escaping () -> Bool = { AccessibilityElementFinder.isAccessibilityTrusted },
        captureScreen: @escaping () async -> ScreenSnapshot? = {
            let screens = (try? await ScreenCapture.allScreens()) ?? []
            return screens.first(where: \.isCursorScreen) ?? screens.first
        },
        settleDelay: Duration = DriveTakeOverController.defaultSettleDelay,
        requestConsent: ((DriveRequest, String) async -> Bool)? = nil,
        watchesInput: Bool = true
    ) {
        let overlay = overlay ?? DriveTakeOverOverlay()
        self.overlay = overlay
        self.requestConsent = requestConsent ?? { request, applicationName in
            await overlay.requestConsent(goal: request.goal, applicationName: applicationName, origin: request.origin)
        }
        self.watchesInput = watchesInput
        // Cua's driver when it is installed (what HeyClicky drives with);
        // HeyMate's own AX driver otherwise.
        self.makeDriver = makeDriver ?? {
            if let executable = CuaDriverClient.installedExecutable { return CuaDriveAppDriver(executable: executable) }
            return DriveAppDriver()
        }
        self.makeDecider = makeDecider ?? { MateAgentDriveDecider() }
        self.pointerDriver = pointerDriver ?? DrivePointerEvaluationDriver()
        self.accessibilityTrusted = accessibilityTrusted
        self.captureScreen = captureScreen
        self.settleDelay = settleDelay
    }

    var isBusy: Bool { driveLeaseID != nil }

    // MARK: Offering

    /// Starts a drive and returns its identifier at once, for callers that
    /// poll (`/drive/status`). Nil when another drive holds the lease.
    func offer(_ request: DriveRequest) -> String? {
        guard !isBusy else { return nil }
        let identifier = UUID().uuidString
        claimLease(identifier: identifier, request: request)
        loopTask = Task { [weak self] in
            guard let self else {
                return DriveTakeOverOutcome(driveIdentifier: identifier, goal: request.goal, status: .cancelled, ending: .cancelled, steps: 0, actionLog: [])
            }
            return await self.drive(request, identifier: identifier)
        }
        return identifier
    }

    /// Offers a drive and waits for it to end.
    func run(_ request: DriveRequest) async -> DriveTakeOverOutcome {
        guard offer(request) != nil, let task = loopTask else {
            return DriveTakeOverOutcome(driveIdentifier: "", goal: request.goal,
                status: .blocked(reason: "another drive is already running"), ending: .failed, steps: 0, actionLog: [])
        }
        return await task.value
    }

    func outcome(for identifier: String) -> DriveTakeOverOutcome? { outcomes[identifier] }

    /// Ends the drive in progress. Safe to call at any phase.
    func cancel(driveIdentifier identifier: String? = nil) {
        guard isBusy, identifier == nil || identifier == driveIdentifier else { return }
        overlay.dismissConsent(answer: false)
        loopTask?.cancel()
    }

    /// The person took the wheel.
    func takeBack(_ reason: ComputerUseTakeBackReason) {
        guard case .driving = phase, takeBackReason == nil else { return }
        takeBackReason = reason
        driveTakenBackBy = String(describing: reason)
        driver?.userTookOver = true
        HeyMateLog.log("🖐️ Drive: taken back (\(reason))")
        loopTask?.cancel()
    }

    // MARK: Status

    func status(for identifier: String? = nil) -> [String: Any] {
        if let identifier, identifier != driveIdentifier || !isBusy, let finished = outcomes[identifier] {
            return [
                "driveIdentifier": identifier,
                "phase": "ended",
                "finished": true,
                "status": finished.status.code,
                "succeeded": finished.status.succeeded,
                "summary": finished.status.summary,
                "report": finished.report,
                "ending": finished.ending.rawValue,
                "steps": finished.steps,
                "actionLog": finished.actionLog,
            ]
        }
        var fields: [String: Any] = [
            "driveIdentifier": driveIdentifier,
            "phase": phase.name,
            "finished": !isBusy,
            "userTookOver": driver?.userTookOver ?? false,
            "actuatingUntil": actuatingUntil.timeIntervalSince1970,
            "actionLogCount": actionLog.count,
            "actionLog": Array(actionLog.suffix(10)),
        ]
        if case .driving(let goal, let step) = phase {
            fields["goal"] = goal
            fields["step"] = step
        } else if case .offered(let goal) = phase {
            fields["goal"] = goal
        }
        return fields
    }

    // MARK: The drive

    private func claimLease(identifier: String, request: DriveRequest) {
        driveLeaseID = identifier
        driveIdentifier = identifier
        actionLog = []
        lastCallResults = []
        driveTakenBackBy = nil
        driveEnding = nil
        takeBackReason = nil
        judge = DriveTakeBackJudge()
        targetBundleID = request.targetBundleID
        phase = .offered(goal: request.goal)
    }

    private func drive(_ request: DriveRequest, identifier: String) async -> DriveTakeOverOutcome {
        var request = request
        request.maxSteps = max(1, min(request.maxSteps, DriveEngine.maximumAllowedSteps))
        var steps = 0
        let status: DriveStatus
        let driver = makeDriver()
        self.driver = driver
        driver.onWillAct = { [weak self] point in self?.overlay.showTarget(point) }

        defer { pointerDriver.stop() }
        do {
            guard accessibilityTrusted() else {
                return finish(identifier: identifier, goal: request.goal, steps: 0,
                    status: .blocked(reason: "HeyMate needs Accessibility permission to drive apps."))
            }
            let target = Self.resolveTarget(request)
            let applicationName = target?.localizedName ?? request.applicationName ?? "the app"
            HeyMateLog.log("🚗 Drive: offered \"\(request.goal)\" in \(applicationName) (\(request.origin))")

            guard await requestConsent(request, applicationName) else {
                return finish(identifier: identifier, goal: request.goal, steps: 0, status: .declined)
            }
            try Task.checkCancellation()

            driveStartedAt = Date()
            actuatingUntil = Date().addingTimeInterval(Self.startGrace)
            phase = .driving(goal: request.goal, step: 0)
            overlay.showDrive(goal: request.goal, applicationName: applicationName, maxSteps: request.maxSteps)
            startWatchingForTakeBack()
            guard pointerDriver.isRunning else {
                return finish(identifier: identifier, goal: request.goal, steps: 0,
                    status: .blocked(reason: "HeyMate can't watch the mouse and keyboard, so it won't drive blind. Check Accessibility permission."))
            }

            var processIdentifier: pid_t
            if let target {
                processIdentifier = target.processIdentifier
                Self.bringForward(target)
            } else if let name = request.applicationName {
                overlay.update(step: 0, status: "Opening \(name)")
                actuatingUntil = Date().addingTimeInterval(2)
                let opened = try await driver.perform(.openApplication(name), in: Self.emptySnapshot, request: request, screenshot: nil)
                log(.openApplication(name), snapshot: Self.emptySnapshot, outcome: opened)
                guard let launched = Self.runningApplication(named: name) else {
                    return finish(identifier: identifier, goal: request.goal, steps: 0, status: .blocked(reason: "couldn't open \(name)"))
                }
                processIdentifier = launched.processIdentifier
                Self.bringForward(launched)
            } else {
                return finish(identifier: identifier, goal: request.goal, steps: 0, status: .blocked(reason: "no app to drive"))
            }
            try await Task.sleep(for: .milliseconds(350))

            let decider = makeDecider()
            var consecutiveFailures = 0
            var lastStepFailed = false
            var plan: DrivePlan?
            let fastLaneEnabled = !UserDefaults.standard.bool(forKey: Self.fastLaneDisabledKey)
            var finalStatus: DriveStatus?

            while steps < request.maxSteps, finalStatus == nil {
                try Task.checkCancellation()
                guard let snapshot = await driver.snapshot(processIdentifier: processIdentifier) else {
                    finalStatus = .blocked(reason: "\(applicationName) isn't running any more")
                    break
                }
                if DriveEngine.successContainsMatched(request.successContains, in: snapshot) {
                    finalStatus = .successContainsMatched
                    break
                }
                if let expected = plan?.expectedResult, plan?.isEmpty == true {
                    if DriveFastLane.windowShows(expected, in: snapshot) {
                        finalStatus = .done(summary: "The window shows \(expected).")
                        break
                    }
                    plan = nil
                }
                let decision: DriveDecision
                var screenshot: ScreenSnapshot?
                var source = "model"
                let stepStarted = Date()
                if let queued = plan?.labels.first, let element = DriveFastLane.resolve(queued, in: snapshot) {
                    decision = .press(token: element.token)
                    source = plan?.source ?? "plan"
                    plan?.labels.removeFirst()
                } else {
                    if plan?.isEmpty == false { HeyMateLog.log("🚗 Drive: plan dropped, window diverged") }
                    plan = nil
                    if fastLaneEnabled, steps == 0, let sum = DriveFastLane.plan(forGoal: request.goal, in: snapshot) {
                        plan = sum
                    }
                    if let queued = plan?.labels.first, let element = DriveFastLane.resolve(queued, in: snapshot) {
                        decision = .press(token: element.token)
                        source = "sum"
                        plan?.labels.removeFirst()
                    } else {
                        plan = nil
                        screenshot = (snapshot.elements.count < 3 || lastStepFailed) ? await captureScreen() : nil
                        let prompt = DriveEngine.stepPrompt(
                            request: request, snapshot: snapshot, step: steps,
                            history: actionLog, hasScreenshot: screenshot != nil
                        )
                        overlay.update(step: steps + 1, status: "Looking")
                        let images = screenshot.map { [(data: $0.imageData, label: $0.label)] } ?? []
                        var reply = try await decider.decide(systemPrompt: DriveEngine.systemPrompt, prompt: prompt, images: images)
                        try Task.checkCancellation()
                        var parsed = DriveEngine.parseDecision(reply)
                        if parsed == nil {
                            reply = try await decider.decide(
                                systemPrompt: DriveEngine.systemPrompt,
                                prompt: prompt + "\nYour last reply was not one valid JSON action. Reply with exactly one JSON object.",
                                images: images
                            )
                            parsed = DriveEngine.parseDecision(reply)
                        }
                        guard let parsed else {
                            finalStatus = .untrustedAnswer("no valid action in the reply")
                            break
                        }
                        decision = parsed
                        let labels = DriveEngine.parsePlan(reply)
                        plan = (labels.isEmpty || !fastLaneEnabled) ? nil : DrivePlan(labels: labels, expectedResult: nil, source: "plan")
                    }
                }
                // Every step, whoever chose it, is vetted against the snapshot it will act on.
                if let end = DriveEngine.vet(decision, snapshot: snapshot, request: request, hasScreenshot: screenshot != nil) {
                    finalStatus = end
                    break
                }
                HeyMateLog.log("🚗 Drive: step \(steps + 1) via \(source) in \(Int(Date().timeIntervalSince(stepStarted) * 1000)) ms")
                steps += 1
                phase = .driving(goal: request.goal, step: steps)
                let line = DriveEngine.historyLine(for: decision, snapshot: snapshot)
                overlay.update(step: steps, status: line)
                // Held for the whole action: Cua's drag moves the real pointer
                // without HeyMate's event tag. Escape still stops it.
                actuatingUntil = .distantFuture
                do {
                    let outcome = try await driver.perform(decision, in: snapshot, request: request, screenshot: screenshot)
                    log(decision, snapshot: snapshot, outcome: outcome)
                    consecutiveFailures = 0
                    lastStepFailed = false
                    if case .openApplication(let name) = decision, let opened = Self.runningApplication(named: name) {
                        processIdentifier = opened.processIdentifier
                        Self.bringForward(opened)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    log(decision, snapshot: snapshot, outcome: "failed: \(error.localizedDescription)")
                    consecutiveFailures += 1
                    lastStepFailed = true
                    if consecutiveFailures >= 2 {
                        finalStatus = .actionFailed(error.localizedDescription)
                    }
                }
                actuatingUntil = Date().addingTimeInterval(0.4)
                let quick = plan?.isEmpty == false && !lastStepFailed
                try await Task.sleep(for: quick ? min(settleDelay, Self.plannedSettleDelay) : settleDelay)
            }
            status = finalStatus ?? .maxSteps
        } catch {
            if let takeBackReason {
                status = .handedBack(reason: takeBackReason.summary)
            } else if case .deadline? = deadlineHit {
                status = .deadline
            } else if error is CancellationError {
                status = .cancelled
            } else {
                status = .actionFailed(error.localizedDescription)
            }
        }
        return finish(identifier: identifier, goal: request.goal, steps: steps, status: status)
    }

    private var deadlineHit: DriveStatus?

    private func startWatchingForTakeBack() {
        deadlineHit = nil
        pointerDriver.onInput = { [weak self] input in
            guard let self else { return }
            if let reason = self.judge.observe(input, at: Date(), actuatingUntil: self.actuatingUntil) {
                HeyMateLog.log("🖐️ Drive: \(input.kind) from the person at \(Int(input.location.x)),\(Int(input.location.y))")
                self.takeBack(reason)
            }
        }
        pointerDriver.evaluation = { [weak self] in
            guard let self else { return }
            let start = self.judge.userPointerMoveStart
            let location = NSEvent.mouseLocation
            if let reason = self.judge.evaluate(currentLocation: location, now: Date(), actuatingUntil: self.actuatingUntil) {
                if let start {
                    HeyMateLog.log("🖐️ Drive: pointer moved \(Int(hypot(location.x - start.x, location.y - start.y)))pt")
                }
                self.takeBack(reason)
            }
        }
        pointerDriver.onDeadline = { [weak self] in
            guard let self else { return }
            HeyMateLog.log("⏱️ Drive: deadline")
            self.deadlineHit = .deadline
            self.loopTask?.cancel()
        }
        pointerDriver.start(deadlineSeconds: DriveEngine.defaultDeadline, watchInput: watchesInput)
    }

    private func log(_ decision: DriveDecision, snapshot: DriveSnapshot, outcome: String) {
        let line = DriveEngine.historyLine(for: decision, snapshot: snapshot)
        actionLog.append(outcome.isEmpty ? line : "\(line) → \(outcome)")
        lastCallResults.append(["action": line, "result": outcome, "at": Date().timeIntervalSince1970])
    }

    private func finish(identifier: String, goal: String, steps: Int, status: DriveStatus) -> DriveTakeOverOutcome {
        let ending: DriveTakeOverOutcome.Ending
        switch status {
        case .done, .successContainsMatched: ending = .completed
        case .declined: ending = .declined
        case .cancelled, .deadline: ending = .cancelled
        case .handedBack where takeBackReason != nil: ending = .takenBack
        case .blocked, .refusedControl, .needsText, .maxSteps, .handedBack: ending = .handedBack
        case .untrustedAnswer, .actionFailed: ending = .failed
        }
        let outcome = DriveTakeOverOutcome(driveIdentifier: identifier, goal: goal, status: status,
                                           ending: ending, steps: steps, actionLog: actionLog)
        pointerDriver.stop()
        overlay.hideDrive()
        overlay.dismissConsent(answer: false)
        outcomes[identifier] = outcome
        agentDriveEnded = outcome
        driveEnding = ending
        lastTakeOverEndedAt = Date()
        driveLeaseID = nil
        driver = nil
        phase = .idle
        HeyMateLog.log("🚗 Drive: ended \(status.code) after \(steps) step(s): \(status.summary)")
        DriveActionLogStore.append(outcome)
        return outcome
    }

    // MARK: Targets

    private static let emptySnapshot = DriveSnapshot(applicationName: "", processIdentifier: 0, windowTitle: nil, elements: [], visibleStrings: [])

    static func resolveTarget(_ request: DriveRequest) -> NSRunningApplication? {
        let ownBundleID = Bundle.main.bundleIdentifier
        if let bundleID = request.targetBundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        if let name = request.applicationName {
            return runningApplication(named: name)
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != ownBundleID else { return nil }
        return frontmost
    }

    /// Keys go to the frontmost app. The unit-test host leaves the desk alone.
    private static func bringForward(_ app: NSRunningApplication) {
        guard !HeyMateDataDirectory.isUnitTestHost else { return }
        app.activate()
    }

    static func runningApplication(named name: String) -> NSRunningApplication? {
        let wanted = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { $0.localizedName?.lowercased() == wanted }
            ?? apps.first { ($0.localizedName?.lowercased()).map { $0.contains(wanted) || wanted.contains($0) } ?? false }
    }
}

/// Append-only record of every drive, for audit. One JSON line per drive.
enum DriveActionLogStore {
    static var fileURL: URL {
        HeyMateDataDirectory.url.appendingPathComponent("drive-log.jsonl", isDirectory: false)
    }

    static func append(_ outcome: DriveTakeOverOutcome) {
        let record: [String: Any] = [
            "driveIdentifier": outcome.driveIdentifier,
            "goal": outcome.goal,
            "status": outcome.status.code,
            "summary": outcome.status.summary,
            "ending": outcome.ending.rawValue,
            "steps": outcome.steps,
            "actionLog": outcome.actionLog,
            "endedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }
}
