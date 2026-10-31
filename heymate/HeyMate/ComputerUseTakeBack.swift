//
//  ComputerUseTakeBack.swift
//  HeyMate
//
//  The user can always take the wheel back. While HeyMate drives the Mac,
//  shaking the mouse, clicking, scrolling, typing, pressing Escape, or
//  starting to talk stops the drive at once: the action in flight is
//  cancelled and nothing else runs until the next turn. Plain pointer moves
//  don't count; only a deliberate shake does, like macOS's shake-to-locate.
//
//  Synthesized input carries `ComputerUseExecutor.synthesizedEventTag` in
//  its source user data, which is how the watcher tells HeyMate's own
//  events from the person's.
//

import CoreGraphics
import Foundation

/// Why a drive stopped.
nonisolated enum ComputerUseTakeBackReason: Equatable, Sendable {
    case pointer
    case keyboard
    case escape
    case voice

    /// Shown in the chat and approval card.
    var summary: String {
        switch self {
        case .pointer: return "You took the mouse, so I stopped."
        case .keyboard: return "You started typing, so I stopped."
        case .escape: return "You pressed Escape, so I stopped."
        case .voice: return "You started talking, so I stopped."
        }
    }

    /// Returned to the model in place of the action's result.
    var modelMessage: String {
        "Stopped: \(summary) The user took the screen back. Do not retry the action; ask what they want next."
    }
}

/// Spots a deliberate back-and-forth shake of the pointer, the gesture
/// macOS uses to enlarge the cursor. Ordinary moves, however long, never
/// count: a shake needs several quick reversals along one axis, each after
/// a real stroke.
nonisolated struct PointerShakeDetector: Equatable, Sendable {
    /// A stroke shorter than this before turning around is jitter.
    var minimumStroke: CGFloat = 40
    /// Reversals needed inside `window` (3 reversals = 4 strokes).
    var reversalsNeeded = 3
    var window: TimeInterval = 0.8

    private struct Axis: Equatable, Sendable {
        var direction: CGFloat = 0
        var stroke: CGFloat = 0
        var reversals: [TimeInterval] = []

        mutating func observe(_ delta: CGFloat, at time: TimeInterval, minimumStroke: CGFloat, window: TimeInterval) -> Int {
            reversals.removeAll { time - $0 > window }
            guard delta != 0 else { return reversals.count }
            let sign: CGFloat = delta > 0 ? 1 : -1
            if sign == direction {
                stroke += abs(delta)
            } else {
                if direction != 0, stroke >= minimumStroke { reversals.append(time) }
                direction = sign
                stroke = abs(delta)
            }
            return reversals.count
        }
    }

    private var horizontal = Axis()
    private var vertical = Axis()

    /// Feeds one physical move. True once the moves add up to a shake.
    mutating func observe(_ delta: CGVector, at time: TimeInterval) -> Bool {
        let x = horizontal.observe(delta.dx, at: time, minimumStroke: minimumStroke, window: window)
        let y = vertical.observe(delta.dy, at: time, minimumStroke: minimumStroke, window: window)
        return max(x, y) >= reversalsNeeded
    }

    mutating func reset() {
        horizontal = Axis()
        vertical = Axis()
    }
}

/// The pure decision: does this one event mean the person took over?
nonisolated enum ComputerUseTakeBack {
    static let escapeKeyCode: Int64 = 53

    struct Input: Equatable, Sendable {
        var type: CGEventType
        var isSynthesized: Bool
        var delta: CGVector = .zero
        var keyCode: Int64 = 0
        /// Seconds on a monotonic clock, for judging a shake.
        var time: TimeInterval = 0
    }

    /// `shake` remembers recent physical moves across calls; only a shake
    /// counts as taking the pointer back.
    static func reason(for input: Input, shake: inout PointerShakeDetector) -> ComputerUseTakeBackReason? {
        guard !input.isSynthesized else { return nil }
        switch input.type {
        case .keyDown:
            return input.keyCode == escapeKeyCode ? .escape : .keyboard
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            return .pointer
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return shake.observe(input.delta, at: input.time) ? .pointer : nil
        default:
            return nil
        }
    }
}

/// Watches for the person taking over. Replaced in tests.
@MainActor
protocol ComputerUseTakeBackWatching: AnyObject {
    func start(onTakeBack: @escaping @MainActor (ComputerUseTakeBackReason) -> Void)
    func stop()
}

/// Listen-only CGEvent tap, same pattern as `AnnotationClearKeyMonitor`.
/// Runs only while a drive is in progress.
final class ComputerUseTakeBackMonitor: ComputerUseTakeBackWatching {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var onTakeBack: (@MainActor (ComputerUseTakeBackReason) -> Void)?
    private var shake = PointerShakeDetector()

    private static let watchedTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .scrollWheel, .keyDown
    ]

    func start(onTakeBack: @escaping @MainActor (ComputerUseTakeBackReason) -> Void) {
        stop()
        self.onTakeBack = onTakeBack
        shake.reset()

        let eventMask = Self.watchedTypes.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let tapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let input = ComputerUseTakeBack.Input(
                type: eventType,
                isSynthesized: event.getIntegerValueField(.eventSourceUserData)
                    == ComputerUseExecutor.synthesizedEventTag,
                delta: CGVector(
                    dx: CGFloat(event.getIntegerValueField(.mouseEventDeltaX)),
                    dy: CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
                ),
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                time: ProcessInfo.processInfo.systemUptime
            )
            let monitor = Unmanaged<ComputerUseTakeBackMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                monitor.handle(input)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            HeyMateLog.log("⚠️ Take-back monitor: couldn't create CGEvent tap (needs Accessibility)")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        onTakeBack = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handle(_ input: ComputerUseTakeBack.Input) {
        guard let onTakeBack,
              let reason = ComputerUseTakeBack.reason(for: input, shake: &shake) else { return }
        stop()
        onTakeBack(reason)
    }
}
