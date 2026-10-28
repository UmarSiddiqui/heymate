//
//  MateRoutineScheduler.swift
//  HeyMate
//
//  Every 30 seconds, at startup, after network recovery, and when the Mac
//  or its screens wake.
//  Network and wake are injected so
//  tests never need a live path or a sleep cycle.
//

import AppKit
import Foundation
import Network
import IOKit.pwr_mgt
import IOKit.ps

protocol MateNetworkMonitoring: AnyObject {
    var hasUsableNetwork: Bool { get }
    func start(onUsableNetwork: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

@MainActor
protocol MateWakeSource: AnyObject {
    func shouldHold(now: Date) -> Bool
    func start(onWake: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

@MainActor
protocol MateRoutineRunning: AnyObject {
    var scheduledRoutines: [MateRoutine] { get }
    func deferRoutine(id: UUID, now: Date)
    func dueRoutines(now: Date) -> [MateRoutine]
    func markRoutineWaiting(id: UUID)
    func kickoffRoutine(_ routine: MateRoutine) -> MateRoutineKickoff
    func noteRoutineFailure(id: UUID, message: String, now: Date)
}

@MainActor
final class MateRoutineScheduler {
    static let pollInterval: TimeInterval = 30

    weak var owner: MateRoutineRunning?
    private var network: MateNetworkMonitoring?
    private var wake: MateWakeSource?
    private var timer: Timer?
    private var generation = 0
    private var started = false
    private var power: MateRoutinePowerManaging

    init(
        network: MateNetworkMonitoring? = nil,
        wake: MateWakeSource? = nil,
        power: MateRoutinePowerManaging? = nil
    ) {
        self.network = network
        self.wake = wake
        self.power = power ?? RoutinePowerAssertion()
    }

    func start() {
        started = true
        schedulesChanged()
    }

    func schedulesChanged() {
        guard started else { return }
        guard let owner, !owner.scheduledRoutines.isEmpty else {
            stopSources()
            return
        }
        power.update(armed: owner.scheduledRoutines.contains { $0.enabled && $0.pausedReason == nil })
        guard timer == nil else { return }
        generation += 1
        let currentGeneration = generation
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.timer != nil, self.generation == currentGeneration else { return }
                self.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        resolvedNetwork().start { [weak self] in
            guard let self, self.timer != nil, self.generation == currentGeneration else { return }
            self.tick()
        }
        resolvedWake().start { [weak self] in
            guard let self, self.timer != nil, self.generation == currentGeneration else { return }
            self.tick()
        }
        tick()
    }

    func stop() {
        started = false
        stopSources()
    }

    private func stopSources() {
        generation += 1
        timer?.invalidate()
        timer = nil
        network?.stop()
        wake?.stop()
        power.stop()
    }

    func tick(now: Date = Date()) {
        guard let owner else { return }
        if started {
            power.update(armed: owner.scheduledRoutines.contains { $0.enabled && $0.pausedReason == nil })
        }
        guard !resolvedWake().shouldHold(now: now) else { return }
        for routine in owner.dueRoutines(now: now) {
            attempt(routine, now: now, owner: owner)
        }
    }

    func run(_ routine: MateRoutine, now: Date = Date()) {
        guard let owner else { return }
        guard routine.enabled, routine.pausedReason == nil else { return }
        guard !resolvedWake().shouldHold(now: now) else { return }
        attempt(routine, now: now, owner: owner)
    }

    private func attempt(_ routine: MateRoutine, now: Date, owner: MateRoutineRunning) {
        guard resolvedNetwork().hasUsableNetwork else {
            owner.markRoutineWaiting(id: routine.id)
            return
        }
        switch owner.kickoffRoutine(routine) {
        case .started:
            break
        case .busy, .failed:
            // A refused dispatch did not run. Never count it as a failed run.
            owner.deferRoutine(id: routine.id, now: now)
        }
    }

    private func resolvedNetwork() -> MateNetworkMonitoring {
        if let network { return network }
        let created = PathMateNetworkMonitor()
        network = created
        return created
    }

    private func resolvedWake() -> MateWakeSource {
        if let wake { return wake }
        let created = WorkspaceMateWakeSource()
        wake = created
        return created
    }
}

final class PathMateNetworkMonitor: MateNetworkMonitoring, @unchecked Sendable {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "heymate.mate-network")
    private let lock = NSLock()
    /// Nil until the first path update. Unknown counts as usable, so a
    /// routine due at launch isn't marked "waiting for the internet".
    private var satisfied: Bool?
    private var generation = 0

    var hasUsableNetwork: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied ?? true
    }

    func start(onUsableNetwork: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        guard monitor == nil else { lock.unlock(); return }
        let next = NWPathMonitor()
        monitor = next
        generation += 1
        let currentGeneration = generation
        satisfied = nil
        lock.unlock()
        next.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let usable = path.status == .satisfied
            self.lock.lock()
            guard self.generation == currentGeneration else { self.lock.unlock(); return }
            let restored = usable && self.satisfied == false
            self.satisfied = usable
            self.lock.unlock()
            if restored {
                Task { @MainActor in onUsableNetwork() }
            }
        }
        next.start(queue: queue)
    }

    func stop() {
        lock.lock()
        generation += 1
        let old = monitor
        monitor = nil
        satisfied = nil
        lock.unlock()
        old?.cancel()
    }

}

// State survives ordinary ticks, so a dark wake cannot bypass the gate via
// a timer or network callback. The 180-second fallback begins with awake screens.
nonisolated struct RoutineWakeGate {
    static let maximumFullWakeWait: TimeInterval = 180
    var awaitingScreens = false
    var awaitingFullWake = false
    var screensAwakeSince: Date?

    mutating func willSleep() {
        awaitingScreens = true
        awaitingFullWake = true
        screensAwakeSince = nil
    }

    mutating func screensDidWake() { awaitingScreens = false }

    mutating func didWake() {
        awaitingFullWake = false
        screensAwakeSince = nil
    }

    mutating func shouldHold(displayAsleep: Bool, now: Date) -> Bool {
        guard awaitingScreens || awaitingFullWake else { return false }
        if displayAsleep { return true }
        awaitingScreens = false
        guard awaitingFullWake else { return false }
        guard let screensAwakeSince else {
            self.screensAwakeSince = now
            return true
        }
        if now.timeIntervalSince(screensAwakeSince) < Self.maximumFullWakeWait { return true }
        didWake()
        return false
    }
}

@MainActor
final class WorkspaceMateWakeSource: MateWakeSource {
    private var tokens: [NSObjectProtocol] = []
    private var generation = 0
    private var gate = RoutineWakeGate()

    func shouldHold(now: Date) -> Bool {
        gate.shouldHold(displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0, now: now)
    }

    func start(onWake: @escaping @MainActor @Sendable () -> Void) {
        guard tokens.isEmpty else { return }
        generation += 1
        let currentGeneration = generation
        let center = NSWorkspace.shared.notificationCenter
        tokens = [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                  NSWorkspace.screensDidWakeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration else { return }
                    switch name {
                    case NSWorkspace.willSleepNotification:
                        self.gate.willSleep()
                    case NSWorkspace.didWakeNotification:
                        self.gate.didWake()
                        onWake()
                    default:
                        self.gate.screensDidWake()
                        onWake()
                    }
                }
            }
        }
    }

    func stop() {
        generation += 1
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens.removeAll()
        gate = RoutineWakeGate()
    }
}

@MainActor
protocol MateRoutinePowerManaging: AnyObject {
    func update(armed: Bool)
    func stop()
}

@MainActor
final class RoutinePowerAssertion: MateRoutinePowerManaging {
    private var assertion: IOPMAssertionID?
    private var source: CFRunLoopSource?
    private var armed = false

    func update(armed: Bool) {
        self.armed = armed
        if armed && source == nil {
            let context = Unmanaged.passUnretained(self).toOpaque()
            source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let owner = Unmanaged<RoutinePowerAssertion>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { owner.refresh() }
            }, context)?.takeRetainedValue()
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        }
        refresh()
        if !armed { stop() }
    }

    private func refresh() {
        let onAC: Bool
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            onAC = type as String == kIOPSACPowerValue
        } else {
            onAC = false
        }
        if armed && onAC {
            guard assertion == nil else { return }
            var identifier: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "HeyMate has an armed routine schedule" as CFString,
                                          &identifier) == kIOReturnSuccess {
                assertion = identifier
            }
        } else {
            releaseAssertion()
        }
    }

    func stop() {
        armed = false
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        releaseAssertion()
    }

    private func releaseAssertion() {
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
    }
}
