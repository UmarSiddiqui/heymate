//
//  BluetoothActivityMonitor.swift
//  leanring-buddy
//
//  "AirPods Pro connected" as a transient notch activity. IOBluetooth posts
//  connect and disconnect notifications on the main run loop, so this costs
//  nothing between events — no polling, no scanning.
//
//  Devices that were already connected when the monitor starts are
//  registered for disconnect notifications but not announced, so launching
//  HeyMate with headphones on doesn't flash a "connected" HUD.
//

import AppKit
import Combine
import CoreBluetooth
import Foundation
import IOBluetooth

@MainActor
final class BluetoothActivityMonitor: NSObject, ObservableObject {

    struct DeviceEvent: Equatable {
        let deviceName: String
        let symbolName: String
        let isConnected: Bool
    }

    @Published private(set) var activity: NotchActivity?
    /// The last connect or disconnect, for the expanded card's chip.
    @Published private(set) var lastEvent: DeviceEvent?
    /// On but never asked: the launch restore leaves Bluetooth dark until
    /// the user taps the tile, instead of prompting at launch.
    @Published private(set) var needsPermissionPrompt = false

    private static let activityDuration: TimeInterval = 3.5
    /// Connect callbacks this soon after start describe devices that were
    /// already connected, not devices the user just connected.
    private static let startupQuietPeriod: TimeInterval = 1.5

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var startedAt: Date?
    private var clearTask: Task<Void, Never>?

    func start(promptForAccess: Bool) {
        guard connectNotification == nil else { return }

        switch CBManager.authorization {
        case .denied, .restricted:
            needsPermissionPrompt = false
            return
        case .notDetermined where !promptForAccess:
            needsPermissionPrompt = true
            return
        default:
            break
        }
        needsPermissionPrompt = false

        startedAt = Date()
        // The first IOBluetooth call is what asks macOS for access.
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:))
        )
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        for notification in disconnectNotifications.values {
            notification.unregister()
        }
        disconnectNotifications.removeAll()
        clearTask?.cancel()
        clearTask = nil
        startedAt = nil
        activity = nil
        lastEvent = nil
    }

    // MARK: IOBluetooth callbacks

    @objc private func deviceDidConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? UUID().uuidString
        if disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self,
                selector: #selector(deviceDidDisconnect(_:device:))
            )
        }

        if let startedAt, Date().timeIntervalSince(startedAt) < Self.startupQuietPeriod {
            return
        }
        publish(device: device, isConnected: true)
    }

    @objc private func deviceDidDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        if let address = device.addressString {
            disconnectNotifications[address] = nil
        }
        publish(device: device, isConnected: false)
    }

    private func publish(device: IOBluetoothDevice, isConnected: Bool) {
        let name = Self.displayName(forDeviceName: device.name ?? device.nameOrAddress ?? "Bluetooth device")
        let symbol = Self.symbolName(
            majorClass: device.deviceClassMajor,
            minorClass: device.deviceClassMinor
        )
        lastEvent = DeviceEvent(deviceName: name, symbolName: symbol, isConnected: isConnected)

        clearTask?.cancel()
        activity = NotchActivity(
            kind: .bluetooth,
            trailingText: NotchActivity.pillText(name),
            tintHex: isConnected ? nil : "84848C",
            expiresAt: Date().addingTimeInterval(Self.activityDuration),
            symbolOverride: symbol
        )
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.activityDuration))
            guard !Task.isCancelled else { return }
            self?.activity = nil
            self?.lastEvent = nil
        }
    }

    // MARK: Pure presentation rules

    /// "Umar's AirPods Pro" reads as "AirPods Pro" in a 14-character slot.
    nonisolated static func displayName(forDeviceName deviceName: String) -> String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let possessive = trimmed.range(of: #"^[^\s]+['’]s\s+"#, options: .regularExpression) else {
            return trimmed
        }
        let remainder = String(trimmed[possessive.upperBound...])
        return remainder.isEmpty ? trimmed : remainder
    }

    /// Bluetooth Core Spec class-of-device codes: major 0x04 is audio,
    /// major 0x05 is a peripheral whose minor bits mark keyboard/pointer.
    nonisolated static func symbolName(majorClass: UInt32, minorClass: UInt32) -> String {
        switch majorClass {
        case 0x04:
            return minorClass == 0x05 ? "hifispeaker.fill" : "headphones"
        case 0x05:
            switch minorClass & 0x30 {
            case 0x10: return "keyboard"
            case 0x20: return "computermouse"
            case 0x30: return "keyboard"
            default:
                // Low bits 1 and 2 are joystick and gamepad.
                let peripheralType = minorClass & 0x0F
                return peripheralType == 0x01 || peripheralType == 0x02
                    ? "gamecontroller"
                    : "dot.radiowaves.left.and.right"
            }
        default:
            return "dot.radiowaves.left.and.right"
        }
    }
}
