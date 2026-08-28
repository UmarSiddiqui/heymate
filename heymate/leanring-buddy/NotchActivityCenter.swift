//
//  NotchActivityCenter.swift
//  leanring-buddy
//
//  Owns the micro-apps that turn the notch from "an AI button" into an
//  ambient surface, and arbitrates which one gets the pill's trailing slot
//  at any moment.
//
//  Every micro-app is independently switchable and every one of them is
//  OFF until enabled, so a user who wants only the assistant pays no CPU,
//  no permission prompts, and no polling for features they never turn on.
//  That opt-in default is the difference between a super app and bloat.
//

import AppKit
import Combine
import Foundation

/// Which micro-apps the user has turned on. Persisted as a set of raw
/// strings so adding a new one never invalidates the stored value.
enum NotchMicroApp: String, CaseIterable, Identifiable, Sendable {
    case shelf
    case media
    case timer
    case battery
    case calendar
    case clipboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shelf: return "File Shelf"
        case .media: return "Now Playing"
        case .timer: return "Timers"
        case .battery: return "Battery"
        case .calendar: return "Next Event"
        case .clipboard: return "Clipboard"
        }
    }

    var explanation: String {
        switch self {
        case .shelf: return "Drag files onto the notch to park them."
        case .media: return "Track and controls while music plays."
        case .timer: return "Countdowns and focus sessions."
        case .battery: return "Plug-in and low-battery moments."
        case .calendar: return "Your next meeting, with a join button."
        case .clipboard: return "Recent copies, in memory only."
        }
    }

    var symbolName: String {
        switch self {
        case .shelf: return "tray.full"
        case .media: return "waveform"
        case .timer: return "timer"
        case .battery: return "bolt.fill"
        case .calendar: return "calendar"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    /// Micro-apps that ask the OS for something. Surfaced in the UI so a
    /// toggle never produces a surprise permission dialog.
    var requiredPermissionDescription: String? {
        switch self {
        case .calendar: return "Calendar access"
        case .media: return "Automation access when you use the controls"
        case .shelf, .timer, .battery, .clipboard: return nil
        }
    }

    /// Defaults chosen so a fresh install feels alive without asking for
    /// anything: shelf and timer are pure local state, battery is a free
    /// IOKit callback.
    static let defaultEnabled: Set<NotchMicroApp> = [.shelf, .timer, .battery]
}

@MainActor
final class NotchActivityCenter: ObservableObject {

    nonisolated static let enabledMicroAppsPreferenceKey = "notchEnabledMicroApps"

    @Published private(set) var enabledMicroApps: Set<NotchMicroApp>

    /// The single activity the collapsed pill should render right now.
    @Published private(set) var frontmostActivity: NotchActivity?

    // Producers. Public so the expanded card can drive them directly.
    let shelfStore = NotchShelfStore()
    let timerStore = NotchTimerStore()
    let nowPlayingMonitor = NowPlayingMonitor()
    let batteryMonitor = BatteryActivityMonitor()
    let calendarMonitor = CalendarPeekMonitor()
    let clipboardStore = ClipboardHistoryStore()

    private var cancellables: Set<AnyCancellable> = []

    /// Activity produced by the agent runtime rather than a micro-app.
    /// Set by `CompanionManager` when a headless job is running.
    @Published var agentActivity: NotchActivity? {
        didSet { recomputeFrontmostActivity() }
    }

    init(userDefaults: UserDefaults = .standard) {
        if let storedRawValues = userDefaults.array(forKey: Self.enabledMicroAppsPreferenceKey) as? [String] {
            enabledMicroApps = Set(storedRawValues.compactMap(NotchMicroApp.init(rawValue:)))
        } else {
            enabledMicroApps = NotchMicroApp.defaultEnabled
        }
        observeProducers()
    }

    func start() {
        for microApp in enabledMicroApps {
            startProducer(for: microApp)
        }
        recomputeFrontmostActivity()
    }

    func stop() {
        for microApp in NotchMicroApp.allCases {
            stopProducer(for: microApp)
        }
        frontmostActivity = nil
    }

    // MARK: Enablement

    func isEnabled(_ microApp: NotchMicroApp) -> Bool {
        enabledMicroApps.contains(microApp)
    }

    func setEnabled(_ isEnabled: Bool, for microApp: NotchMicroApp) {
        if isEnabled {
            enabledMicroApps.insert(microApp)
            startProducer(for: microApp)
        } else {
            enabledMicroApps.remove(microApp)
            stopProducer(for: microApp)
        }
        UserDefaults.standard.set(
            enabledMicroApps.map(\.rawValue),
            forKey: Self.enabledMicroAppsPreferenceKey
        )
        recomputeFrontmostActivity()
    }

    private func startProducer(for microApp: NotchMicroApp) {
        switch microApp {
        case .media: nowPlayingMonitor.start()
        case .battery: batteryMonitor.start()
        case .clipboard: clipboardStore.setEnabled(true)
        case .calendar: Task { await calendarMonitor.start() }
        case .shelf: shelfStore.pruneExpiredItems()
        case .timer: break   // purely user-initiated; nothing to spin up
        }
    }

    private func stopProducer(for microApp: NotchMicroApp) {
        switch microApp {
        case .media: nowPlayingMonitor.stop()
        case .battery: batteryMonitor.stop()
        case .clipboard: clipboardStore.setEnabled(false)
        case .calendar: calendarMonitor.stop()
        case .shelf: shelfStore.removeAll()
        case .timer: timerStore.cancel()
        }
    }

    // MARK: Arbitration

    private func observeProducers() {
        // Each producer publishes its own optional activity; the center
        // just re-runs the priority rule whenever any of them changes.
        let activityChangeSignals: [AnyPublisher<Void, Never>] = [
            shelfStore.$items.map { _ in () }.eraseToAnyPublisher(),
            timerStore.$activity.map { _ in () }.eraseToAnyPublisher(),
            nowPlayingMonitor.$activity.map { _ in () }.eraseToAnyPublisher(),
            batteryMonitor.$activity.map { _ in () }.eraseToAnyPublisher(),
            calendarMonitor.$activity.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(activityChangeSignals)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeFrontmostActivity()
            }
            .store(in: &cancellables)
    }

    private func recomputeFrontmostActivity() {
        var candidates: [NotchActivity] = []
        if let agentActivity { candidates.append(agentActivity) }
        if isEnabled(.shelf), let shelfActivity = shelfStore.activity { candidates.append(shelfActivity) }
        if isEnabled(.timer), let timerActivity = timerStore.activity { candidates.append(timerActivity) }
        if isEnabled(.media), let mediaActivity = nowPlayingMonitor.activity { candidates.append(mediaActivity) }
        if isEnabled(.battery), let batteryActivity = batteryMonitor.activity { candidates.append(batteryActivity) }
        if isEnabled(.calendar), let calendarActivity = calendarMonitor.activity { candidates.append(calendarActivity) }

        let winner = NotchActivityArbiter.frontmostActivity(among: candidates)
        guard winner != frontmostActivity else { return }
        frontmostActivity = winner
    }
}
