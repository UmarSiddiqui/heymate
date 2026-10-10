//
//  GlobalShortcutMonitor.swift
//  HeyMate
//
//  Watches one held-key chord system-wide while HeyMate is in the
//  background and publishes press and release. Every monitor listens on
//  `SharedKeyboardTap`, so Talk, Dictate, spatial select and chat cost one
//  event tap between them instead of one each.
//
//  The chord is asked for on every event, so a change in Settings takes
//  effect on the next key press without restarting anything.
//

import AppKit
import Combine
import CoreGraphics

final class GlobalShortcutMonitor: SharedKeyboardTapListener, KeyboardShortcutChannel {
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

    func keyboardTapReceived(_ eventType: CGEventType, keyCode: UInt16, flags: CGEventFlags) {
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

    /// Key-ups that arrive while the tap is disabled are lost for good.
    func keyboardTapResumed() {
        releaseIfNoLongerHeld()
    }

    private func releaseIfNoLongerHeld() {
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
