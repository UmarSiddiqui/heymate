//
//  MacPermissions.swift
//  HeyMate
//
//  The macOS privacy permissions HeyMate needs (Accessibility and Screen
//  Recording; the microphone is handled by VoiceDictation) and how to ask
//  for them. macOS only shows each system prompt once per launch, so the
//  first request shows the prompt and later ones open System Settings.
//

import AppKit
import ApplicationServices

enum MacPermissions {
    /// What a request did.
    enum Route: Equatable {
        case alreadyGranted
        case systemPrompt
        case systemSettings
    }

    private static var hasPromptedForAccessibility = false
    private static var hasPromptedForScreenRecording = false

    // MARK: - Accessibility

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityPermission() -> Route {
        let route = route(hasPermission: hasAccessibilityPermission(), alreadyPrompted: hasPromptedForAccessibility)
        switch route {
        case .alreadyGranted:
            break
        case .systemPrompt:
            hasPromptedForAccessibility = true
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        case .systemSettings:
            openAccessibilitySettings()
        }
        return route
    }

    static func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    // MARK: - Screen Recording

    /// Remembers that Screen Recording was granted at some point. The live
    /// check (CGPreflightScreenCaptureAccess) can report a false negative,
    /// most often until the next launch after the user clicks Allow.
    private static let screenRecordingConfirmedKey = "com.heymate.hasConfirmedScreenRecordingPermission"
    private static let legacyScreenRecordingConfirmedKey = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"

    static func hasScreenRecordingPermission() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if granted { rememberScreenRecordingGrant() }
        return granted
    }

    /// Whether to go ahead as if Screen Recording is granted: it is now, or
    /// it was confirmed before and the live check is just lagging.
    static func screenRecordingLooksGranted() -> Bool {
        screenRecordingCountsAsGranted(
            grantedNow: hasScreenRecordingPermission(),
            confirmedBefore: hasConfirmedScreenRecordingBefore
        )
    }

    @discardableResult
    static func requestScreenRecordingPermission() -> Route {
        let route = route(hasPermission: hasScreenRecordingPermission(), alreadyPrompted: hasPromptedForScreenRecording)
        switch route {
        case .alreadyGranted:
            break
        case .systemPrompt:
            hasPromptedForScreenRecording = true
            let promptGranted = CGRequestScreenCaptureAccess()
            if shouldRememberScreenRecordingGrant(preflightGranted: hasScreenRecordingPermission(),
                                                  promptGranted: promptGranted) {
                rememberScreenRecordingGrant()
            }
        case .systemSettings:
            openScreenRecordingSettings()
        }
        return route
    }

    static func openScreenRecordingSettings() {
        openPrivacyPane("Privacy_ScreenCapture")
    }

    private static var hasConfirmedScreenRecordingBefore: Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: screenRecordingConfirmedKey) { return true }
        guard defaults.bool(forKey: legacyScreenRecordingConfirmedKey) else { return false }
        rememberScreenRecordingGrant()
        defaults.removeObject(forKey: legacyScreenRecordingConfirmedKey)
        return true
    }

    private static func rememberScreenRecordingGrant() {
        UserDefaults.standard.set(true, forKey: screenRecordingConfirmedKey)
    }

    // MARK: - Decisions (pure, unit-tested)

    static func route(hasPermission: Bool, alreadyPrompted: Bool) -> Route {
        if hasPermission { return .alreadyGranted }
        return alreadyPrompted ? .systemSettings : .systemPrompt
    }

    static func screenRecordingCountsAsGranted(grantedNow: Bool, confirmedBefore: Bool) -> Bool {
        grantedNow || confirmedBefore
    }

    /// The prompt's own answer counts even when the live check still says no.
    static func shouldRememberScreenRecordingGrant(preflightGranted: Bool, promptGranted: Bool) -> Bool {
        preflightGranted || promptGranted
    }

    /// Setup needs Accessibility, Screen Recording and the microphone. The
    /// ScreenCaptureKit content picker follows Screen Recording on its own and
    /// is not a fourth thing the user has to grant.
    static func requiredPermissionsAreGranted(
        hasAccessibility: Bool,
        hasScreenRecording: Bool,
        hasMicrophone: Bool
    ) -> Bool {
        hasAccessibility && hasScreenRecording && hasMicrophone
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// When HeyMate doesn't appear in a Privacy list, the user drags the app in.
/// macOS ties the grant to the bundle's path, so the dragged copy should be
/// the stable one in /Applications, made once per launch.
nonisolated enum PrivacyDropBundle {
    enum Plan: Equatable {
        case useExistingApplicationsCopy
        case copyToApplications
        case copyToDesktop
    }

    static var runningAppURL: URL { Bundle.main.bundleURL.standardizedFileURL }

    static func plan(isAlreadyInApplications: Bool, canCopyToApplications: Bool) -> Plan {
        if isAlreadyInApplications { return .useExistingApplicationsCopy }
        return canCopyToApplications ? .copyToApplications : .copyToDesktop
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var preparedURL: URL?

    /// The URL to put on the drag pasteboard. The copy happens at most once
    /// per launch; doing it inside the drag used to take so long that the
    /// mouse was up before the drag began.
    @discardableResult
    static func prepare() -> URL {
        lock.withLock {
            if let preparedURL, FileManager.default.fileExists(atPath: preparedURL.path) {
                return preparedURL
            }
            let url = makeCopy()
            preparedURL = url
            return url
        }
    }

    /// Makes the copy in the background so the first drag is instant, but
    /// only when nothing is installed in /Applications yet: showing the
    /// Permissions card must never replace an installed copy.
    static func prewarm() {
        guard runningAppURL != applicationsURL,
              !FileManager.default.fileExists(atPath: applicationsURL.path) else { return }
        Task.detached(priority: .utility) { _ = prepare() }
    }

    @MainActor
    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([prepare()])
    }

    private static var applicationsURL: URL {
        FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)[0]
            .appendingPathComponent("HeyMate.app").standardizedFileURL
    }

    private static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HeyMate.app").standardizedFileURL
    }

    private static func makeCopy() -> URL {
        let source = runningAppURL
        let targets: [URL]
        switch plan(isAlreadyInApplications: source == applicationsURL, canCopyToApplications: true) {
        case .useExistingApplicationsCopy: return applicationsURL
        case .copyToApplications: targets = [applicationsURL, desktopURL]
        case .copyToDesktop: targets = [desktopURL]
        }
        return targets.first { copy(source, to: $0) } ?? source
    }

    private static func copy(_ source: URL, to destination: URL) -> Bool {
        guard source != destination else { return true }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return true
        } catch {
            HeyMateLog.log("⚠️ Could not copy HeyMate.app to \(destination.path): \(error)")
            return false
        }
    }
}

extension NSScreen {
    /// The Core Graphics display ID behind this screen.
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
