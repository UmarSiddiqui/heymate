//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while HeyMate is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//
//  The monitor is generic over any modifier-based push-to-talk/dictate shortcut:
//  each event asks `shortcutOptionProvider` for the currently active shortcut
//  definition, so multiple independent monitors (e.g. Talk and Dictate) can share
//  this tap machinery without hard-coding which shortcut they watch for.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    /// Safety net for a missed key-up: while the shortcut is held, polls the
    /// live keyboard state and synthesizes the release if the keys are up.
    private var releaseWatchdogTimer: Timer?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    /// Resolved fresh on every event so the monitor always evaluates against the
    /// shortcut definition that is active right now (e.g. a user-chosen custom
    /// shortcut), rather than a snapshot taken at init time. Defaults to the
    /// app-wide Talk shortcut so existing callers behave unchanged.
    private let shortcutOptionProvider: () -> BuddyPushToTalkShortcut.ShortcutOption

    init(
        optionProvider: @escaping () -> BuddyPushToTalkShortcut.ShortcutOption = {
            BuddyPushToTalkShortcut.currentShortcutOption
        }
    ) {
        self.shortcutOptionProvider = optionProvider
    }

    deinit {
        stop()
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
    }

    func stop() {
        stopReleaseWatchdog()
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            // Key-ups that landed while the tap was off are gone for good.
            releaseIfShortcutNoLongerHeld()
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed,
            option: shortcutOptionProvider()
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            startReleaseWatchdog()
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            stopReleaseWatchdog()
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(.released)
        }

        return Unmanaged.passUnretained(event)
    }

    private func startReleaseWatchdog() {
        releaseWatchdogTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.releaseIfShortcutNoLongerHeld()
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatchdogTimer = timer
    }

    private func stopReleaseWatchdog() {
        releaseWatchdogTimer?.invalidate()
        releaseWatchdogTimer = nil
    }

    private func releaseIfShortcutNoLongerHeld() {
        guard isShortcutCurrentlyPressed else { return }
        guard !BuddyPushToTalkShortcut.isShortcutPhysicallyHeld(option: shortcutOptionProvider()) else { return }
        stopReleaseWatchdog()
        isShortcutCurrentlyPressed = false
        shortcutTransitionPublisher.send(.released)
    }
}
