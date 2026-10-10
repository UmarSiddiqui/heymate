//
//  MateRoutineScheduler.swift
//  HeyMate
//
//  Once a minute, and when the Mac wakes. Network and wake are injected so
//  tests never need a live path or a sleep cycle.
//

import AppKit
import Foundation
import Network

protocol MateNetworkMonitoring: AnyObject {
    var hasUsableNetwork: Bool { get }
    func start()
}

@MainActor
protocol MateWakeSource: AnyObject {
    func start(onWake: @escaping () -> Void)
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
    weak var owner: MateRoutineRunning?
    private var network: MateNetworkMonitoring?
    private var wake: MateWakeSource?
    private var timer: Timer?

    init(
        network: MateNetworkMonitoring? = nil,
        wake: MateWakeSource? = nil
    ) {
        self.network = network
        self.wake = wake
    }

    func start() {
        guard timer == nil else { return }
        let network = resolvedNetwork()
        network.start()
        resolvedWake().start { [weak self] in
            self?.tick()
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "heymate.mate-network")
    private let lock = NSLock()
    private var satisfied = true
    private var didStart = false

    var hasUsableNetwork: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfied
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            self.satisfied = path.status == .satisfied
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }
}

@MainActor
final class WorkspaceMateWakeSource: MateWakeSource {
    private var token: NSObjectProtocol?

    func start(onWake: @escaping () -> Void) {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onWake()
            }
        }
    }
}
