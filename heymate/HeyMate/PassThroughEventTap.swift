//
//  PassThroughEventTap.swift
//  HeyMate
//
//  An active session event tap that never changes an event. macOS lets an
//  app with Accessibility create an active (`.defaultTap`) tap, while a
//  listen-only tap that sees key presses also needs Input Monitoring. Using
//  active taps keeps the global shortcuts on Accessibility alone, so setup
//  never has to ask for Input Monitoring.
//
//  The cost of an active tap is that each event it covers waits for the
//  callback before it reaches the app in front. So every tap here runs on
//  one dedicated thread, never the main run loop: a busy main thread can't
//  hold up typing anywhere on the Mac. The callback only copies the fields
//  it needs and hands them to the main queue. If macOS still switches a tap
//  off (a slow callback, or secure input taking the keyboard), it is
//  switched straight back on.
//

import CoreGraphics
import Foundation

nonisolated final class PassThroughEventTap: @unchecked Sendable {
    /// Runs on the tap thread for every event, while that event waits. Copy
    /// what you need and hop to the main queue; never block here.
    typealias Handler = @Sendable (CGEventType, CGEvent) -> Void

    private let name: String
    private let mask: CGEventMask
    private let handler: Handler
    /// Runs on the tap thread after macOS disabled the tap and it was
    /// re-enabled. Events in the gap are gone for good.
    private let onResume: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    init(
        name: String,
        events: [CGEventType],
        onResume: (@Sendable () -> Void)? = nil,
        handler: @escaping Handler
    ) {
        self.name = name
        self.mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        self.onResume = onResume
        self.handler = handler
    }

    var isRunning: Bool { lock.withLock { port != nil } }

    /// Creates and enables the tap. False when macOS refuses it, which
    /// means Accessibility is off; calling again later retries.
    @discardableResult
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if port != nil { return true }

        // Retained for as long as the tap can call back; released on the
        // tap thread in stop(), after any callback in flight has returned.
        let context = Unmanaged.passRetained(self)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: context.toOpaque()
        ) else {
            context.release()
            HeyMateLog.log("⚠️ \(name): couldn't create the event tap (needs Accessibility)")
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            context.release()
            HeyMateLog.log("⚠️ \(name): couldn't create the event tap run loop source")
            return false
        }
        self.port = port
        self.source = source
        let runLoop = EventTapThread.shared.runLoop
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopWakeUp(runLoop)
        return true
    }

    /// Safe to call repeatedly.
    func stop() {
        lock.lock()
        let port = self.port
        let source = self.source
        self.port = nil
        self.source = nil
        lock.unlock()
        guard let port else { return }

        let runLoop = EventTapThread.shared.runLoop
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        CFMachPortInvalidate(port)
        // Queued behind whatever the tap thread is doing now, so a callback
        // that already started finishes before the context goes away.
        let context = Unmanaged.passUnretained(self)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            context.release()
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func resume() {
        guard let port = lock.withLock({ self.port }) else { return }
        CGEvent.tapEnable(tap: port, enable: true)
        HeyMateLog.log("⌨️ \(name): macOS paused the event tap; switched it back on")
        onResume?()
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        if let userInfo {
            let tap = Unmanaged<PassThroughEventTap>.fromOpaque(userInfo).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                tap.resume()
            } else {
                tap.handler(type, event)
            }
        }
        // Every event goes on unchanged; this tap only watches.
        return Unmanaged.passUnretained(event)
    }
}

/// The one thread every PassThroughEventTap runs on.
nonisolated private final class EventTapThread: Thread, @unchecked Sendable {
    static let shared: EventTapThread = {
        let thread = EventTapThread()
        thread.name = "HeyMate event taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        thread.ready.wait()
        return thread
    }()

    private let ready = DispatchSemaphore(value: 0)
    private(set) var runLoop: CFRunLoop!

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        // A run loop with nothing to watch returns at once; this port keeps
        // it running while no tap is installed.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while true {
            CFRunLoopRun()
        }
    }
}
