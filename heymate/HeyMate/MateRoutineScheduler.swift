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

protocol MateNetworkMonitoring: AnyObject {
    var hasUsableNetwork: Bool { get }
    func start(onUsableNetwork: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

@MainActor
protocol MateWakeSource: AnyObject {
    func start(onWake: @escaping () -> Void)
    func stop()
}

@MainActor
protocol MateRoutineRunning: AnyObject {
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

    init(
        network: MateNetworkMonitoring? = nil,
        wake: MateWakeSource? = nil
    ) {
        self.network = network
        self.wake = wake
    }

    func start() {
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
        generation += 1
        timer?.invalidate()
        timer = nil
        network?.stop()
        wake?.stop()
    }

    func tick(now: Date = Date()) {
        guard let owner else { return }
        for routine in owner.dueRoutines(now: now) {
            attempt(routine, now: now, owner: owner)
        }
    }

    func run(_ routine: MateRoutine, now: Date = Date()) {
        guard let owner else { return }
        guard routine.enabled, routine.pausedReason == nil else { return }
        attempt(routine, now: now, owner: owner)
    }

    private func attempt(_ routine: MateRoutine, now: Date, owner: MateRoutineRunning) {
        guard resolvedNetwork().hasUsableNetwork else {
            owner.markRoutineWaiting(id: routine.id)
            return
        }
        switch owner.kickoffRoutine(routine) {
        case .started, .busy:
            break
        case .failed(let message):
            owner.noteRoutineFailure(id: routine.id, message: message, now: now)
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

@MainActor
final class WorkspaceMateWakeSource: MateWakeSource {
    private var tokens: [NSObjectProtocol] = []
    /// Wi-Fi and the display take a moment after wake; checking straight
    /// away would mark every due routine as waiting for the internet.
    static let settleDelay: Duration = .seconds(5)

    func start(onWake: @escaping () -> Void) {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        tokens = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    try? await Task.sleep(for: Self.settleDelay)
                    onWake()
                }
            }
        }
    }
    func stop() {
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens.removeAll()
    }

}
