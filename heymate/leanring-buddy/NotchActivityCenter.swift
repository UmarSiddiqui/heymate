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
    case mirror
    case downloads
    case volumeHUD
    case brightnessHUD
    case bluetooth
    case reminders

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shelf: return "File Shelf"
        case .media: return "Now Playing"
        case .timer: return "Timers"
        case .battery: return "Battery"
        case .calendar: return "Next Event"
        case .clipboard: return "Clipboard"
        case .mirror: return "Camera Mirror"
        case .downloads: return "Downloads"
        case .volumeHUD: return "Volume HUD"
        case .brightnessHUD: return "Brightness HUD"
        case .bluetooth: return "Bluetooth"
        case .reminders: return "Reminders"
        }
    }

    /// Short label for 2-column notch launcher. Full name remains available
    /// to accessibility and Settings.
    var compactDisplayName: String {
        switch self {
        case .shelf: return "Shelf"
        case .media: return "Music"
        case .timer: return "Timer"
        case .battery: return "Battery"
        case .calendar: return "Event"
        case .clipboard: return "Clipboard"
        case .mirror: return "Mirror"
        case .downloads: return "Download"
        case .volumeHUD: return "Volume"
        case .brightnessHUD: return "Brightness"
        case .bluetooth: return "Bluetooth"
        case .reminders: return "Tasks"
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
        case .mirror: return "Check framing before joining a call."
        case .downloads: return "See browser downloads finish in the notch."
        case .volumeHUD: return "Replace macOS volume overlay with the notch."
        case .brightnessHUD: return "Replace the brightness and keyboard-light overlays with the notch."
        case .bluetooth: return "See headphones and devices connect and disconnect."
        case .reminders: return "See and complete your next due reminder."
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
        case .mirror: return "camera"
        case .downloads: return "arrow.down.circle"
        case .volumeHUD: return "speaker.wave.2"
        case .brightnessHUD: return "sun.max"
        case .bluetooth: return "headphones"
        case .reminders: return "checklist"
        }
    }

    /// Micro-apps that ask the OS for something. Surfaced in the UI so a
    /// toggle never produces a surprise permission dialog.
    var requiredPermissionDescription: String? {
        switch self {
        case .calendar: return "Calendar access"
        case .media: return "Automation access when you use the controls"
        case .mirror: return "Camera access"
        case .volumeHUD, .brightnessHUD: return "Accessibility access"
        case .bluetooth: return "Bluetooth access"
        case .reminders: return "Reminders access"
        case .shelf, .timer, .battery, .clipboard, .downloads: return nil
        }
    }

    /// Defaults chosen so a fresh install feels alive without asking for
    /// anything: shelf and timer are pure local state, battery is a free
    /// IOKit callback.
    static let defaultEnabled: Set<NotchMicroApp> = [.shelf, .timer, .battery, .downloads]
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
    let downloadsMonitor = DownloadsActivityMonitor()
    let volumeHUDInterceptor = VolumeHUDInterceptor()
    let brightnessHUDInterceptor = BrightnessHUDInterceptor()
    let bluetoothMonitor = BluetoothActivityMonitor()
    let reminderMonitor = ReminderPeekMonitor()

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

    /// Launch restore. Producers come back exactly as the user left them,
    /// but none of them may open a permission panel: the user has not
    /// touched anything yet, and a dialog on top of a just-launched app is
    /// a demand rather than an answer. A producer whose permission is still
    /// outstanding stays dark and reports `needsPermissionPrompt`, which the
    /// next tap on its tile resolves.
    func start() {
        for microApp in enabledMicroApps {
            startProducer(for: microApp, promptForPermission: false)
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
            startProducer(for: microApp, promptForPermission: true)
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

    private func startProducer(for microApp: NotchMicroApp, promptForPermission: Bool) {
        switch microApp {
        case .media: nowPlayingMonitor.start()
        case .battery: batteryMonitor.start()
        case .clipboard: clipboardStore.setEnabled(true)
        case .calendar: Task { await calendarMonitor.start(promptForAccess: promptForPermission) }
        case .shelf: shelfStore.pruneExpiredItems()
        case .timer: break   // purely user-initiated; nothing to spin up
        case .mirror: break  // session lives only while mirror UI is visible
        case .downloads: downloadsMonitor.start()
        case .volumeHUD: volumeHUDInterceptor.start()
        case .brightnessHUD: brightnessHUDInterceptor.start()
        case .bluetooth: bluetoothMonitor.start(promptForAccess: promptForPermission)
        case .reminders: Task { await reminderMonitor.start(promptForAccess: promptForPermission) }
        }
    }

    /// Whether this micro-app is on but still waiting for macOS to be
    /// asked — the state a launch restore deliberately leaves behind.
    func needsPermissionPrompt(for microApp: NotchMicroApp) -> Bool {
        guard isEnabled(microApp) else { return false }
        switch microApp {
        case .calendar: return calendarMonitor.needsPermissionPrompt
        case .reminders: return reminderMonitor.needsPermissionPrompt
        case .bluetooth: return bluetoothMonitor.needsPermissionPrompt
        default: return false
        }
    }

    /// Tapping an already-on tile that never got its permission asks now,
    /// rather than toggling the micro-app off. Without this the tile would
    /// need two taps — off, then on — to reach the panel.
    func grantPendingPermission(for microApp: NotchMicroApp) {
        guard needsPermissionPrompt(for: microApp) else { return }
        startProducer(for: microApp, promptForPermission: true)
    }

    private func stopProducer(for microApp: NotchMicroApp) {
        switch microApp {
        case .media: nowPlayingMonitor.stop()
        case .battery: batteryMonitor.stop()
        case .clipboard: clipboardStore.setEnabled(false)
        case .calendar: calendarMonitor.stop()
        case .shelf: shelfStore.removeAll()
        case .timer: timerStore.cancel()
        case .mirror: break
        case .downloads: downloadsMonitor.stop()
        case .volumeHUD: volumeHUDInterceptor.stop()
        case .brightnessHUD: brightnessHUDInterceptor.stop()
        case .bluetooth: bluetoothMonitor.stop()
        case .reminders: reminderMonitor.stop()
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
            calendarMonitor.$activity.map { _ in () }.eraseToAnyPublisher(),
            downloadsMonitor.$activity.map { _ in () }.eraseToAnyPublisher(),
            volumeHUDInterceptor.$activity.map { _ in () }.eraseToAnyPublisher(),
            brightnessHUDInterceptor.$activity.map { _ in () }.eraseToAnyPublisher(),
            bluetoothMonitor.$activity.map { _ in () }.eraseToAnyPublisher(),
            reminderMonitor.$activity.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(activityChangeSignals)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeFrontmostActivity()
            }
            .store(in: &cancellables)

        // Permission state lives on the monitors, but the tiles observe the
        // center, so forward the change or a tile would keep rendering as
        // "on" after its permission resolved.
        Publishers.MergeMany([
            calendarMonitor.$needsPermissionPrompt.map { _ in () }.eraseToAnyPublisher(),
            reminderMonitor.$needsPermissionPrompt.map { _ in () }.eraseToAnyPublisher(),
            bluetoothMonitor.$needsPermissionPrompt.map { _ in () }.eraseToAnyPublisher()
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.objectWillChange.send()
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
        if isEnabled(.downloads), let downloadActivity = downloadsMonitor.activity { candidates.append(downloadActivity) }
        if isEnabled(.volumeHUD), let volumeActivity = volumeHUDInterceptor.activity { candidates.append(volumeActivity) }
        if isEnabled(.brightnessHUD), let brightnessActivity = brightnessHUDInterceptor.activity { candidates.append(brightnessActivity) }
        if isEnabled(.bluetooth), let bluetoothActivity = bluetoothMonitor.activity { candidates.append(bluetoothActivity) }
        if isEnabled(.reminders), let reminderActivity = reminderMonitor.activity { candidates.append(reminderActivity) }

        let winner = NotchActivityArbiter.frontmostActivity(among: candidates)
        guard winner != frontmostActivity else { return }
        frontmostActivity = winner
    }
}
