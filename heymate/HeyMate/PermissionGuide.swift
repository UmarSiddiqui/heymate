//
//  PermissionGuide.swift
//  HeyMate
//
//  Every permission HeyMate uses, in one list, with one way to grant them
//  all. Each row says in plain words what HeyMate can or can't do yet.
//  "Allow all" walks the list in order: system prompts are answered in
//  place, and for the ones macOS only allows in System Settings it opens
//  the right pane and waits for the switch before moving on.
//
//  Nothing here asks on its own. Asking happens when the person presses
//  Allow, so HeyMate never nags on launch.
//

import AppKit
import AVFoundation
import Combine
import Contacts
import EventKit
import Speech
import SwiftUI
import UserNotifications

enum HeyMatePermission: String, CaseIterable, Identifiable {
    case microphone
    case speech
    case accessibility
    case inputMonitoring
    case screenRecording
    case notifications
    case calendar
    case reminders
    case contacts

    var id: String { rawValue }

    /// The ones HeyMate needs for talking, seeing and pointing.
    static let core: [HeyMatePermission] = [.microphone, .speech, .accessibility, .inputMonitoring, .screenRecording]
    /// Useful, never required.
    static let extras: [HeyMatePermission] = [.notifications, .calendar, .reminders, .contacts]

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speech: return "Speech Recognition"
        case .accessibility: return "Accessibility"
        case .inputMonitoring: return "Input Monitoring"
        case .screenRecording: return "Screen Recording"
        case .notifications: return "Notifications"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        }
    }

    /// What HeyMate can do once this is on.
    var onText: String {
        switch self {
        case .microphone: return "HeyMate can hear you while you hold ⌃⌥"
        case .speech: return "HeyMate can turn what you say into text"
        case .accessibility: return "HeyMate can point, click, and type for you"
        case .inputMonitoring: return "HeyMate hears ⌃⌥ in every app"
        case .screenRecording: return "HeyMate can see your screen when you ask"
        case .notifications: return "HeyMate can tell you when an agent finishes"
        case .calendar: return "HeyMate can read and add calendar events"
        case .reminders: return "HeyMate can read and add reminders"
        case .contacts: return "HeyMate can look up people you mention"
        }
    }

    /// What is missing while this is off.
    var offText: String {
        switch self {
        case .microphone: return "HeyMate can't hear you yet"
        case .speech: return "HeyMate can't turn your voice into text yet"
        case .accessibility: return "HeyMate can't click or type for you yet"
        case .inputMonitoring: return "⌃⌥ won't work in other apps yet"
        case .screenRecording: return "HeyMate can't see your screen yet"
        case .notifications: return "You won't hear when an agent finishes"
        case .calendar: return "HeyMate can't see your calendar"
        case .reminders: return "HeyMate can't see your reminders"
        case .contacts: return "HeyMate can't look up your contacts"
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic"
        case .speech: return "waveform"
        case .accessibility: return "cursorarrow.click"
        case .inputMonitoring: return "keyboard"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .notifications: return "bell"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .contacts: return "person.crop.circle"
        }
    }

    /// macOS only grants these in System Settings, after a first prompt.
    var isGrantedInSystemSettings: Bool {
        switch self {
        case .accessibility, .inputMonitoring, .screenRecording: return true
        case .microphone, .speech, .notifications, .calendar, .reminders, .contacts: return false
        }
    }

    var settingsAnchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .speech: return "Privacy_SpeechRecognition"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .notifications: return "Notifications"
        case .calendar: return "Privacy_Calendars"
        case .reminders: return "Privacy_Reminders"
        case .contacts: return "Privacy_Contacts"
        }
    }

    /// The order "Allow all" walks: quick prompts first, then the ones that
    /// need a trip to System Settings.
    static func allowAllOrder(includeExtras: Bool) -> [HeyMatePermission] {
        let list = core + (includeExtras ? extras : [])
        return list.filter { !$0.isGrantedInSystemSettings } + list.filter(\.isGrantedInSystemSettings)
    }
}

@MainActor
final class PermissionGuide: ObservableObject {
    static let shared = PermissionGuide()

    @Published private(set) var granted: Set<HeyMatePermission> = []
    /// The permission "Allow all" is waiting on, if any.
    @Published private(set) var waitingFor: HeyMatePermission?
    @Published private(set) var isAllowingAll = false

    /// How long "Allow all" waits for a switch in System Settings.
    nonisolated static let settingsWait: Duration = .seconds(90)

    private var skipRequested = false
    private var pollTask: Task<Void, Never>?

    /// Reads every permission that can be checked without waiting, so a
    /// "can't hear you" line never flashes before the first refresh.
    init() {
        granted = Set(HeyMatePermission.allCases.filter { $0 != .notifications && Self.syncStatus($0) })
        Task { await refresh() }
    }

    private static func syncStatus(_ permission: HeyMatePermission) -> Bool {
        switch permission {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech: return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .accessibility: return MacPermissions.hasAccessibilityPermission()
        case .inputMonitoring: return MacPermissions.hasInputMonitoringPermission()
        case .screenRecording: return MacPermissions.screenRecordingLooksGranted()
        case .calendar: return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders: return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .contacts: return CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .notifications: return false
        }
    }

    func isGranted(_ permission: HeyMatePermission) -> Bool { granted.contains(permission) }

    func allGranted(_ list: [HeyMatePermission]) -> Bool { list.allSatisfy(granted.contains) }

    /// Keeps the list current while a view that shows it is on screen.
    /// Views showing permissions right now. Polling stops when the last
    /// one goes, so one view closing can't freeze another that's waiting.
    private var watcherCount = 0

    func startWatching() {
        watcherCount += 1
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopWatching() {
        watcherCount = max(0, watcherCount - 1)
        guard watcherCount == 0 else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        var now: Set<HeyMatePermission> = []
        for permission in HeyMatePermission.allCases where await Self.status(permission) {
            now.insert(permission)
        }
        if now != granted { granted = now }
    }

    /// Asks for one permission the way macOS allows: a prompt the first
    /// time, System Settings after that.
    func request(_ permission: HeyMatePermission) async {
        Self.markAsked(permission)
        switch permission {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else {
                Self.openSettings(permission)
            }
        case .speech:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
                _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
                }
            } else {
                Self.openSettings(permission)
            }
        case .accessibility:
            // The first time this is macOS's own prompt, which has its own
            // button to System Settings; after that it opens the pane.
            MacPermissions.requestAccessibilityPermission()
        case .inputMonitoring:
            // The first time this is macOS's own prompt, which has its own
            // button to System Settings; after that it opens the pane.
            MacPermissions.requestInputMonitoringPermission()
        case .screenRecording:
            // The first time this is macOS's own prompt, which has its own
            // button to System Settings; after that it opens the pane.
            MacPermissions.requestScreenRecordingPermission()
        case .notifications:
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            } else {
                Self.openSettings(permission)
            }
        case .calendar:
            let before = EKEventStore.authorizationStatus(for: .event)
            if before == .notDetermined {
                // Held until the answer is in; a store dropped mid-request
                // can leave the grant unseen by this run of the app.
                let store = EKEventStore()
                let granted: Bool
                do { granted = try await store.requestFullAccessToEvents() } catch {
                    granted = false
                    HeyMateLog.log("⚠️ Calendar request failed: \(error.localizedDescription)")
                }
                HeyMateLog.log("🔑 Calendar request answered: granted=\(granted), status \(before.rawValue) → \(EKEventStore.authorizationStatus(for: .event).rawValue)")
                withExtendedLifetime(store) {}
            } else {
                HeyMateLog.log("🔑 Calendar already asked (status \(before.rawValue)); opening System Settings")
                Self.openSettings(permission)
            }
        case .reminders:
            let before = EKEventStore.authorizationStatus(for: .reminder)
            if before == .notDetermined {
                let store = EKEventStore()
                let granted: Bool
                do { granted = try await store.requestFullAccessToReminders() } catch {
                    granted = false
                    HeyMateLog.log("⚠️ Reminders request failed: \(error.localizedDescription)")
                }
                HeyMateLog.log("🔑 Reminders request answered: granted=\(granted), status \(before.rawValue) → \(EKEventStore.authorizationStatus(for: .reminder).rawValue)")
                withExtendedLifetime(store) {}
            } else {
                HeyMateLog.log("🔑 Reminders already asked (status \(before.rawValue)); opening System Settings")
                Self.openSettings(permission)
            }
        case .contacts:
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                _ = try? await CNContactStore().requestAccess(for: .contacts)
            } else {
                Self.openSettings(permission)
            }
        }
        await refresh()
    }

    /// Grants everything that is still off, one after another.
    func allowAll(includeExtras: Bool) async {
        guard !isAllowingAll else { return }
        isAllowingAll = true
        defer {
            isAllowingAll = false
            waitingFor = nil
        }
        await refresh()
        for permission in HeyMatePermission.allowAllOrder(includeExtras: includeExtras) where !isGranted(permission) {
            await request(permission)
            guard permission.isGrantedInSystemSettings, !isGranted(permission) else { continue }
            waitingFor = permission
            skipRequested = false
            let deadline = ContinuousClock.now + Self.settingsWait
            while !isGranted(permission), !skipRequested, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await refresh()
            }
            waitingFor = nil
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Moves "Allow all" past the switch it is waiting on.
    func skipWaiting() { skipRequested = true }

    // MARK: Status

    static func status(_ permission: HeyMatePermission) async -> Bool {
        guard permission == .notifications else { return syncStatus(permission) }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    // MARK: Asking once

    nonisolated static func askedKey(_ permission: HeyMatePermission) -> String {
        "heymate.permissionAsked.\(permission.rawValue)"
    }

    /// True once HeyMate has asked, here or from older launch-time prompts.
    nonisolated static func hasAsked(_ permission: HeyMatePermission, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: askedKey(permission))
    }

    nonisolated static func markAsked(_ permission: HeyMatePermission, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: askedKey(permission))
    }

    static func openSettings(_ permission: HeyMatePermission) {
        let base = permission == .notifications
            ? "x-apple.systempreferences:com.apple.preference.notifications"
            : "x-apple.systempreferences:com.apple.preference.security?\(permission.settingsAnchor)"
        if let url = URL(string: base) { NSWorkspace.shared.open(url) }
    }
}

/// The permission list with plain on/off lines and an Allow all button.
struct PermissionChecklist: View {
    @ObservedObject var guide: PermissionGuide = .shared
    /// Tighter rows for the notch card.
    var compact = false
    /// Shows Notifications, Calendar, Reminders and Contacts too.
    var showsExtras = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            header
            if let waiting = guide.waitingFor {
                waitingBanner(waiting)
            }
            group(HeyMatePermission.core)
            if showsExtras {
                Text("Also useful")
                    .font(DS.Fonts.sectionLabel)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, compact ? 4 : 8)
                group(HeyMatePermission.extras)
            }
        }
        .onAppear { guide.startWatching() }
        .onDisappear { guide.stopWatching() }
    }

    private var visible: [HeyMatePermission] {
        HeyMatePermission.core + (showsExtras ? HeyMatePermission.extras : [])
    }

    private var header: some View {
        HStack(spacing: 10) {
            let done = visible.filter(guide.isGranted).count
            Text(done == visible.count ? "Everything is on" : "\(done) of \(visible.count) on")
                .font(compact ? DS.Fonts.headline : DS.Fonts.title)
                .foregroundColor(DS.Colors.textPrimary)
            Spacer(minLength: 8)
            if !guide.allGranted(visible) {
                Button(guide.isAllowingAll ? "Allowing…" : "Allow all") {
                    Task { await guide.allowAll(includeExtras: showsExtras) }
                }
                .dsCapsuleButtonStyle(.primary, height: compact ? DS.ControlSize.small : DS.ControlSize.regular)
                .disabled(guide.isAllowingAll)
                .help("Asks for each one in turn. Some open System Settings so you can flip the switch.")
            }
        }
    }

    private func waitingBanner(_ permission: HeyMatePermission) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Turn on HeyMate under \(permission.title) in System Settings. This moves on by itself.")
                .font(DS.Fonts.caption)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Skip") { guide.skipWaiting() }
                .dsCapsuleButtonStyle(.quiet, height: DS.ControlSize.small)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func group(_ list: [HeyMatePermission]) -> some View {
        VStack(spacing: 0) {
            ForEach(list) { permission in
                row(permission)
            }
        }
    }

    private func row(_ permission: HeyMatePermission) -> some View {
        let isOn = guide.isGranted(permission)
        return HStack(spacing: 10) {
            Image(systemName: permission.systemImage)
                .font(DS.Glyph.regular)
                .foregroundColor(isOn ? DS.Colors.success : DS.Colors.textTertiary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.title)
                    .font(DS.Fonts.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(isOn ? permission.onText : permission.offText)
                    .font(DS.Fonts.caption)
                    .foregroundColor(isOn ? DS.Colors.textSecondary : DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isOn {
                Text("On")
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundColor(DS.Colors.success)
            } else {
                Button("Allow") { Task { await guide.request(permission) } }
                    .dsCapsuleButtonStyle(.secondary, height: DS.ControlSize.small)
                    .disabled(guide.isAllowingAll)
            }
        }
        .padding(.vertical, compact ? 5 : 8)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
