//
//  DrivePointerEvaluationDriver.swift
//  HeyMate
//
//  Notices the person taking the wheel during a drive, and ends a drive
//  that runs past its deadline.
//
//  Clicks, scrolls and keys stop the drive at once. Pointer moves stop it
//  only when they add up to a deliberate shake (see `PointerShakeDetector`),
//  so the person can move the mouse while HeyMate works without ending the
//  drive. HeyMate's own synthesized input carries
//  `ComputerUseExecutor.synthesizedEventTag` and never counts.
//

import AppKit
import CoreGraphics
import Foundation

/// One raw input event, reduced to what the judge needs.
nonisolated struct DrivePointerInput: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case move, click, scroll, key(keyCode: Int64) }
    var kind: Kind
    var isSynthesized: Bool
    var location: CGPoint
}

/// Decides when input is the person's, not HeyMate's or a bumped desk.
nonisolated struct DriveTakeBackJudge: Equatable, Sendable {
    var shake = PointerShakeDetector()
    /// Where and when the person's pointer started moving, if it has.
    var userPointerMoveStart: CGPoint?
    var userPointerMoveStartedAt: Date?
    private var lastMoveLocation: CGPoint?

    /// Clicks and keys end the drive immediately. Moves end it only when
    /// they add up to a deliberate shake. While HeyMate is acting, only
    /// Escape counts: a driver that moves the real pointer (Cua's drag)
    /// posts events without HeyMate's tag, and an app may warp the pointer,
    /// so moves then are forgotten, not counted.
    mutating func observe(_ input: DrivePointerInput, at now: Date, actuatingUntil: Date = .distantPast) -> ComputerUseTakeBackReason? {
        guard !input.isSynthesized else { return nil }
        if now < actuatingUntil {
            if case .key(let keyCode) = input.kind, keyCode == ComputerUseTakeBack.escapeKeyCode { return .escape }
            forgetMoves()
            return nil
        }
        switch input.kind {
        case .key(let keyCode):
            return keyCode == ComputerUseTakeBack.escapeKeyCode ? .escape : .keyboard
        case .click, .scroll:
            return .pointer
        case .move:
            if userPointerMoveStart == nil {
                userPointerMoveStart = input.location
                userPointerMoveStartedAt = now
            }
            defer { lastMoveLocation = input.location }
            guard let last = lastMoveLocation else { return nil }
            let delta = CGVector(dx: input.location.x - last.x, dy: input.location.y - last.y)
            return shake.observe(delta, at: now.timeIntervalSinceReferenceDate) ? .pointer : nil
        }
    }

    private mutating func forgetMoves() {
        userPointerMoveStart = nil
        userPointerMoveStartedAt = nil
        lastMoveLocation = nil
        shake.reset()
    }
}

/// Listen-only session event tap. A subscription is live until cancelled.
@MainActor
final class DrivePointerEventSource {
    nonisolated final class Subscription: @unchecked Sendable {
        // Touched only on the main run loop, where the tap is installed.
        fileprivate nonisolated(unsafe) var tap: CFMachPort?
        fileprivate nonisolated(unsafe) var source: CFRunLoopSource?
        fileprivate let handler: @MainActor (DrivePointerInput) -> Void
        fileprivate init(handler: @escaping @MainActor (DrivePointerInput) -> Void) { self.handler = handler }

        func cancel() {
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            source = nil
            tap = nil
        }
    }

    private static let watchedTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .keyDown,
    ]

    /// Nil when the tap can't be made (no Accessibility permission).
    func subscribe(_ handler: @escaping @MainActor (DrivePointerInput) -> Void) -> Subscription? {
        let subscription = Subscription(handler: handler)
        let mask = Self.watchedTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let subscription = Unmanaged<Subscription>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = subscription.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let kind: DrivePointerInput.Kind
            switch type {
            case .keyDown: kind = .key(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .click
            case .scrollWheel: kind = .scroll
            default: kind = .move
            }
            // Core Graphics location (top-left origin); flipped on main.
            let raw = event.location
            let isSynthesized = event.getIntegerValueField(.eventSourceUserData) == ComputerUseExecutor.synthesizedEventTag
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
                    subscription.handler(DrivePointerInput(
                        kind: kind,
                        isSynthesized: isSynthesized,
                        location: CGPoint(x: raw.x, y: primaryHeight - raw.y)
                    ))
                }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(subscription).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            HeyMateLog.log("⚠️ Drive: couldn't watch input (needs Accessibility)")
            return nil
        }
        subscription.tap = tap
        subscription.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return subscription
    }
}

@MainActor
final class DrivePointerEvaluationDriver {
    /// How often pointer moves are judged, at most.
    var maximumPointerRateHz: Double = 30
    /// How often the pointer is checked even with no events.
    var slowCheckIntervalSeconds: Double = 0.25
    /// Runs the judgement. Set by the controller.
    var evaluation: () -> Void = {}
    /// Raw input, for immediate take-backs (clicks, keys).
    var onInput: ((DrivePointerInput) -> Void)?
    var onDeadline: (() -> Void)?

    private(set) var pointerSubscription: DrivePointerEventSource.Subscription?
    private var slowCheckTimer: Timer?
    private var deadlineTimer: Timer?
    private(set) var scheduledDeadline: Double?
    private(set) var isEvaluationScheduled = false
    private(set) var lastEvaluationTime: Double = 0
    private(set) var isRunning = false

    private let eventSource: DrivePointerEventSource
    private let clock: () -> Double

    init(eventSource: DrivePointerEventSource? = nil,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.eventSource = eventSource ?? DrivePointerEventSource()
        self.clock = clock
    }

    /// Returns false when input can't be watched; the caller must not drive
    /// blind, since take-back is the person's only brake.
    @discardableResult
    func start(deadlineSeconds: TimeInterval, watchInput: Bool = true) -> Bool {
        stop()
        if watchInput {
            pointerSubscription = eventSource.subscribe { [weak self] input in
                guard let self, self.isRunning else { return }
                self.onInput?(input)
                if input.kind == .move { self.scheduleEvaluation() }
            }
            guard pointerSubscription != nil else { return false }
        }
        isRunning = true
        let slow = Timer(timeInterval: slowCheckIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleEvaluation() }
        }
        RunLoop.main.add(slow, forMode: .common)
        slowCheckTimer = slow
        scheduledDeadline = clock() + deadlineSeconds
        let deadline = Timer(timeInterval: deadlineSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.onDeadline?()
            }
        }
        RunLoop.main.add(deadline, forMode: .common)
        deadlineTimer = deadline
        return true
    }

    func stop() {
        isRunning = false
        pointerSubscription?.cancel()
        pointerSubscription = nil
        slowCheckTimer?.invalidate()
        slowCheckTimer = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        scheduledDeadline = nil
        isEvaluationScheduled = false
    }

    /// Runs `evaluation` now if the rate allows, otherwise once when it does.
    func scheduleEvaluation() {
        guard isRunning, !isEvaluationScheduled else { return }
        let interval = 1 / max(1, maximumPointerRateHz)
        let wait = lastEvaluationTime + interval - clock()
        guard wait > 0 else { return runEvaluation() }
        isEvaluationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isEvaluationScheduled = false
                self.runEvaluation()
            }
        }
    }

    private func runEvaluation() {
        guard isRunning else { return }
        lastEvaluationTime = clock()
        evaluation()
    }
}
