//
//  HeyMateSystemOutputVolume.swift
//  leanring-buddy
//
//  CoreAudio default-output scalar get/set. Main element, then L/R fallback.
//  Wake-word ducker primitive — no UI, no network, no CompanionManager.
//

import CoreAudio
import Foundation
import os

nonisolated enum HeyMateSystemOutputVolume {

    static func clampedScalar(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    static func currentScalar() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        if let master = scalar(for: deviceID, element: kAudioObjectPropertyElementMain) {
            return master
        }
        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
            .compactMap { scalar(for: deviceID, element: $0) }
        guard !channels.isEmpty else { return nil }
        return channels.reduce(0, +) / Float(channels.count)
    }

    @discardableResult
    static func setScalar(_ scalar: Float) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else { return false }
        let clamped = clampedScalar(scalar)
        if setScalar(clamped, for: deviceID, element: kAudioObjectPropertyElementMain) {
            return true
        }
        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)]
        return channels
            .map { setScalar(clamped, for: deviceID, element: $0) }
            .contains(true)
    }

    /// Nudges output volume by `delta` (−1…1). Returns the scalar that landed.
    @discardableResult
    static func adjust(by delta: Float) -> Float? {
        let current = currentScalar() ?? 0.5
        let next = clampedScalar(current + delta)
        guard setScalar(next) else { return nil }
        return next
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == 0, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    private static func scalar(
        for deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Float? {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == 0 else { return nil }
        return Float(value)
    }

    private static func setScalar(
        _ scalar: Float,
        for deviceID: AudioDeviceID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = volumeAddress(element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == 0,
              settable.boolValue else {
            return false
        }
        var value = Float32(scalar)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == 0
    }

    private static func volumeAddress(
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }
}

/// Duck/restore wrapper around the scalar primitive. Callers own when to duck.
final class HeyMateOutputVolumeDucker: @unchecked Sendable {
    private let duckedVolume: Float
    private let storage = OSAllocatedUnfairLock(initialState: DuckState())

    private struct DuckState {
        var restoreVolume: Float?
        var isDucked = false
    }

    init(duckedVolume: Float = 0.08) {
        self.duckedVolume = HeyMateSystemOutputVolume.clampedScalar(duckedVolume)
    }

    func duck() {
        storage.withLock { state in
            guard !state.isDucked else { return }
            state.restoreVolume = HeyMateSystemOutputVolume.currentScalar()
            _ = HeyMateSystemOutputVolume.setScalar(duckedVolume)
            state.isDucked = true
        }
    }

    func restore() {
        storage.withLock { state in
            guard state.isDucked else { return }
            if let restoreVolume = state.restoreVolume {
                _ = HeyMateSystemOutputVolume.setScalar(restoreVolume)
            }
            state.isDucked = false
            state.restoreVolume = nil
        }
    }
}
