//
//  GlobalShortcutMonitor.swift
//  HeyMate
//
//  Watches one held-key chord system-wide while HeyMate is in the
//  background and publishes press and release. Every monitor shares a
//  single listen-only event tap, so Talk, Dictate, spatial select and chat
//  cost one tap between them instead of one each.
//
//  The chord is asked for on every event, so a change in Settings takes
//  effect on the next key press without restarting anything.
//

import AppKit
import Combine
import CoreGraphics

final class GlobalShortcutMonitor {
    let shortcutTransitionPublisher = PassthroughSubject<PushToTalkShortcut.Transition, Never>()

    private let currentOption: () -> PushToTalkShortcut.Option
    private var isHeld = false
    /// Safety net for a missed key-up: while the chord is held, polls the
    /// live keyboard and synthesizes the release once the keys are up.
    private var releaseWatchdog: Timer?

    init(optionProvider: @escaping () -> PushToTalkShortcut.Option = { PushToTalkShortcut.talk }) {
        currentOption = optionProvider
    }

    /// Safe to call repeatedly (the permission poller does): an already
    /// running monitor keeps its state, so a held chord is not dropped.
    func start() {
        SharedKeyboardTap.shared.add(self)
    }

    func stop() {
        SharedKeyboardTap.shared.remove(self)
        stopWatchdog()
        isHeld = false
    }

    fileprivate func handle(_ eventType: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
        let transition = PushToTalkShortcut.transition(
            for: eventType,
            keyCode: keyCode,
            modifierFlagsRawValue: flags.rawValue,
            wasHeld: isHeld,
            option: currentOption()
        )
        switch transition {
        case .none:
            return
        case .pressed:
            isHeld = true
            startWatchdog()
        case .released:
            isHeld = false
            stopWatchdog()
        }
        shortcutTransitionPublisher.send(transition)
    }

    /// Key-ups that arrive while the tap is disabled are lost for good, so
    /// this also runs whenever the tap comes back.
    fileprivate func releaseIfNoLongerHeld() {
        guard isHeld, !PushToTalkShortcut.isHeld(currentOption()) else { return }
        isHeld = false
        stopWatchdog()
        shortcutTransitionPublisher.send(.released)
    }

    private func startWatchdog() {
        releaseWatchdog?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.releaseIfNoLongerHeld()
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseWatchdog = timer
    }

    private func stopWatchdog() {
        releaseWatchdog?.invalidate()
        releaseWatchdog = nil
    }
}

/// The one CGEvent tap behind every `GlobalShortcutMonitor`. It lives on the
/// main run loop, so callbacks arrive on the main thread. It is created when
/// the first monitor starts (and retried on later starts until Accessibility
/// is granted) and torn down when the last one stops.
private final class SharedKeyboardTap {
    static let shared = SharedKeyboardTap()

    private var monitors: [ObjectIdentifier: GlobalShortcutMonitor] = [:]
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func add(_ monitor: GlobalShortcutMonitor) {
        monitors[ObjectIdentifier(monitor)] = monitor
        if tap == nil { install() }
    }

    func remove(_ monitor: GlobalShortcutMonitor) {
        monitors[ObjectIdentifier(monitor)] = nil
        if monitors.isEmpty { uninstall() }
    }

    private func install() {
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<SharedKeyboardTap>.fromOpaque(userInfo).takeUnretainedValue()
                        .dispatch(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            HeyMateLog.log("⚠️ Global shortcuts: couldn't create the keyboard event tap")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            HeyMateLog.log("⚠️ Global shortcuts: couldn't create the event tap run loop source")
            return
        }
        self.tap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func uninstall() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    private func dispatch(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            monitors.values.forEach { $0.releaseIfNoLongerHeld() }
            return
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        for monitor in monitors.values {
            monitor.handle(type, keyCode: keyCode, flags: flags)
        }
    }
}
