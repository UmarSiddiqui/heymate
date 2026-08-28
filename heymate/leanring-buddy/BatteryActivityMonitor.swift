//
//  BatteryActivityMonitor.swift
//  leanring-buddy
//
//  Charging state and low-battery warnings as a transient notch activity.
//  IOKit posts a run-loop callback whenever any power source changes, so
//  this costs nothing between events — no polling timer.
//
//  Deliberately narrow: the notch shows battery only when something
//  *changed* (plugged in, unplugged, crossed a warning threshold) and then
//  gets out of the way. A permanent battery readout is what the menu bar
//  is for.
//

import Combine
import Foundation
import IOKit.ps

@MainActor
final class BatteryActivityMonitor: ObservableObject {

    struct PowerSnapshot: Equatable {
        let percentage: Int
        let isCharging: Bool
        let isPluggedIn: Bool
    }

    @Published private(set) var snapshot: PowerSnapshot?
    @Published private(set) var activity: NotchActivity?

    /// How long a plug/unplug activity stays on the notch before yielding
    /// to whatever else wants the space.
    private static let transientActivityDuration: TimeInterval = 4

    /// Below this, the low-battery activity persists instead of expiring —
    /// that one the user genuinely wants to keep seeing.
    private static let lowBatteryThreshold = 20

    private var runLoopSource: CFRunLoopSource?
    private var lastReportedPluggedIn: Bool?

    func start() {
        guard runLoopSource == nil else { return }

        // Unmanaged pointer to self so the C callback can find us. Balanced
        // in stop(); the monitor is owned for the app's lifetime.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<BatteryActivityMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                monitor.refreshFromPowerSources()
            }
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
        refreshFromPowerSources()
        // Seed the baseline so launching while plugged in doesn't
        // immediately announce "charging".
        lastReportedPluggedIn = snapshot?.isPluggedIn
        activity = currentLowBatteryActivity()
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
        snapshot = nil
        activity = nil
    }

    private func refreshFromPowerSources() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            guard let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximumCapacity = description[kIOPSMaxCapacityKey] as? Int,
                  maximumCapacity > 0 else { continue }

            let percentage = Int((Double(currentCapacity) / Double(maximumCapacity) * 100).rounded())
            let powerSourceState = description[kIOPSPowerSourceStateKey] as? String
            let isPluggedIn = powerSourceState == kIOPSACPowerValue
            let isCharging = (description[kIOPSIsChargingKey] as? Bool) ?? false

            let newSnapshot = PowerSnapshot(
                percentage: percentage,
                isCharging: isCharging,
                isPluggedIn: isPluggedIn
            )
            let previousPluggedIn = lastReportedPluggedIn
            snapshot = newSnapshot
            lastReportedPluggedIn = isPluggedIn

            if let previousPluggedIn, previousPluggedIn != isPluggedIn {
                activity = NotchActivity(
                    kind: .battery,
                    trailingText: "\(percentage)%",
                    progress: Double(percentage) / 100,
                    tintHex: isPluggedIn ? "34D399" : nil,
                    expiresAt: Date().addingTimeInterval(Self.transientActivityDuration)
                )
            } else {
                activity = currentLowBatteryActivity()
            }
            return
        }
    }

    /// Persistent (non-expiring) warning while discharging below the
    /// threshold; nil otherwise.
    private func currentLowBatteryActivity() -> NotchActivity? {
        guard let snapshot,
              !snapshot.isPluggedIn,
              snapshot.percentage <= Self.lowBatteryThreshold else { return nil }
        return NotchActivity(
            kind: .battery,
            trailingText: "\(snapshot.percentage)%",
            progress: Double(snapshot.percentage) / 100,
            tintHex: "FF6B5A"
        )
    }
}
